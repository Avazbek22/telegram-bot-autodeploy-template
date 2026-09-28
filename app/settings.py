from __future__ import annotations

import os
import re
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

TOKEN_PATTERN = re.compile(r"^[0-9]{5,20}:[A-Za-z0-9_-]{20,128}$")
API_URL_PATTERN = re.compile(r"^https?://[^\s/?#]+(/[^\s?#]*)?$")
LOG_LEVELS = frozenset({"DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"})


class SettingsError(ValueError):
    """Raised when configuration is missing or unsafe."""


def read_env_file(path: Path) -> dict[str, str]:
    """Read simple KEY=VALUE files without executing shell syntax."""
    if not path.is_file():
        return {}

    values: dict[str, str] = {}
    for line_number, raw_line in enumerate(
        path.read_text(encoding="utf-8-sig").splitlines(), start=1
    ):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise SettingsError(f"Invalid .env syntax on line {line_number}")
        key, value = (part.strip() for part in line.split("=", 1))
        if not key or not key.replace("_", "").isalnum() or not key[0].isalpha():
            raise SettingsError(f"Invalid .env key on line {line_number}")
        if value[:1] in {'"', "'"}:
            if len(value) < 2 or value[-1] != value[0]:
                raise SettingsError(f"Unclosed quote in .env on line {line_number}")
            value = value[1:-1]
        values[key] = value
    return values


def _value(source: Mapping[str, str], name: str, default: str = "") -> str:
    value = source.get(name, default)
    return value.strip() if value is not None else ""


def _integer(
    source: Mapping[str, str],
    name: str,
    default: int,
    minimum: int,
    maximum: int,
) -> int:
    raw = _value(source, name)
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError as exc:
        raise SettingsError(f"{name} must be an integer") from exc
    if not minimum <= value <= maximum:
        raise SettingsError(f"{name} must be between {minimum} and {maximum}")
    return value


def _api_url(source: Mapping[str, str]) -> str:
    raw = _value(source, "TELEGRAM_API_URL").rstrip("/")
    if raw and not API_URL_PATTERN.fullmatch(raw):
        raise SettingsError("TELEGRAM_API_URL must be an http(s) URL")
    return raw


def _directory(source: Mapping[str, str], name: str, default: Path) -> Path:
    raw = _value(source, name)
    if "\x00" in raw:
        raise SettingsError(f"{name} contains an invalid character")
    return Path(raw or default).expanduser().resolve()


@dataclass(frozen=True, slots=True)
class Settings:
    bot_token: str
    log_level: str
    data_dir: Path
    logs_dir: Path
    polling_timeout_seconds: int
    long_polling_timeout_seconds: int
    health_max_age_seconds: int
    telegram_api_url: str = ""

    def validate_token(self) -> None:
        if not self.bot_token:
            raise SettingsError("BOT_TOKEN is required at startup")
        if not TOKEN_PATTERN.fullmatch(self.bot_token):
            raise SettingsError("BOT_TOKEN has an invalid format")


def load_settings(
    base_dir: Path | None = None,
    *,
    require_token: bool = False,
    environ: Mapping[str, str] | None = None,
) -> Settings:
    base = (base_dir or Path(__file__).resolve().parents[1]).resolve()
    file_values = read_env_file(base / ".env")
    process_values = dict(os.environ if environ is None else environ)
    source = {**file_values, **process_values}

    token = _value(source, "BOT_TOKEN")
    if token and not TOKEN_PATTERN.fullmatch(token):
        raise SettingsError("BOT_TOKEN has an invalid format")

    log_level = _value(source, "LOG_LEVEL", "INFO").upper()
    if log_level not in LOG_LEVELS:
        allowed = ", ".join(sorted(LOG_LEVELS))
        raise SettingsError(f"LOG_LEVEL must be one of: {allowed}")

    settings = Settings(
        bot_token=token,
        log_level=log_level,
        data_dir=_directory(source, "DATA_DIR", base / "data"),
        logs_dir=_directory(source, "LOGS_DIR", base / "logs"),
        polling_timeout_seconds=_integer(source, "POLLING_TIMEOUT_SECONDS", 20, 1, 120),
        long_polling_timeout_seconds=_integer(
            source, "LONG_POLLING_TIMEOUT_SECONDS", 30, 1, 180
        ),
        health_max_age_seconds=_integer(source, "HEALTH_MAX_AGE_SECONDS", 120, 30, 600),
        telegram_api_url=_api_url(source),
    )
    # A healthy bot completes getUpdates at least once per long-polling cycle.
    if settings.health_max_age_seconds <= settings.long_polling_timeout_seconds * 2:
        raise SettingsError(
            "HEALTH_MAX_AGE_SECONDS must exceed twice LONG_POLLING_TIMEOUT_SECONDS"
        )
    if require_token:
        settings.validate_token()
    return settings
