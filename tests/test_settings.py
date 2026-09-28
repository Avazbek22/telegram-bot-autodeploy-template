from __future__ import annotations

from pathlib import Path

import pytest

from app.settings import SettingsError, load_settings, read_env_file

VALID_TOKEN = "123456789:abcdefghijklmnopqrstuvwxyzABCDE"


def test_valid_settings(tmp_path: Path) -> None:
    settings = load_settings(
        tmp_path,
        require_token=True,
        environ={
            "BOT_TOKEN": VALID_TOKEN,
            "LOG_LEVEL": "warning",
            "DATA_DIR": str(tmp_path / "state"),
            "LOGS_DIR": str(tmp_path / "output"),
            "POLLING_TIMEOUT_SECONDS": "10",
            "LONG_POLLING_TIMEOUT_SECONDS": "40",
            "HEALTH_MAX_AGE_SECONDS": "100",
            "TELEGRAM_API_URL": "http://bot-api:8081/",
        },
    )
    assert settings.bot_token == VALID_TOKEN
    assert settings.log_level == "WARNING"
    assert settings.polling_timeout_seconds == 10
    assert settings.data_dir == (tmp_path / "state").resolve()
    assert settings.telegram_api_url == "http://bot-api:8081"


def test_legacy_heartbeat_setting_is_ignored(tmp_path: Path) -> None:
    settings = load_settings(tmp_path, environ={"HEALTH_HEARTBEAT_SECONDS": "25"})
    assert settings.health_max_age_seconds == 120
    assert settings.telegram_api_url == ""


@pytest.mark.parametrize(
    "url", ["ftp://bot-api", "http://", "bot-api:8081", "http://bot api"]
)
def test_invalid_api_url(tmp_path: Path, url: str) -> None:
    with pytest.raises(SettingsError, match="TELEGRAM_API_URL"):
        load_settings(tmp_path, environ={"TELEGRAM_API_URL": url})


def test_token_is_optional_until_startup(tmp_path: Path) -> None:
    assert load_settings(tmp_path, environ={}).bot_token == ""
    with pytest.raises(SettingsError, match="required"):
        load_settings(tmp_path, require_token=True, environ={})


@pytest.mark.parametrize(
    "token",
    ["", "123:short", "not-a-token", "123456:contains space in secret"],
)
def test_invalid_token(tmp_path: Path, token: str) -> None:
    with pytest.raises(SettingsError):
        load_settings(
            tmp_path,
            require_token=True,
            environ={"BOT_TOKEN": token},
        )


@pytest.mark.parametrize(
    ("name", "value"),
    [
        ("POLLING_TIMEOUT_SECONDS", "zero"),
        ("POLLING_TIMEOUT_SECONDS", "0"),
        ("LONG_POLLING_TIMEOUT_SECONDS", "181"),
        ("HEALTH_MAX_AGE_SECONDS", "29"),
        ("HEALTH_MAX_AGE_SECONDS", "601"),
    ],
)
def test_invalid_numeric_configuration(tmp_path: Path, name: str, value: str) -> None:
    with pytest.raises(SettingsError):
        load_settings(
            tmp_path,
            environ={"BOT_TOKEN": VALID_TOKEN, name: value},
        )


def test_health_threshold_must_exceed_two_polling_cycles(tmp_path: Path) -> None:
    with pytest.raises(SettingsError, match="twice"):
        load_settings(
            tmp_path,
            environ={
                "LONG_POLLING_TIMEOUT_SECONDS": "60",
                "HEALTH_MAX_AGE_SECONDS": "120",
            },
        )


def test_local_env_loading_and_process_precedence(
    tmp_path: Path,
) -> None:
    (tmp_path / ".env").write_text(
        f"BOT_TOKEN={VALID_TOKEN}\nLOG_LEVEL='debug'\n",
        encoding="utf-8",
    )
    settings = load_settings(
        tmp_path,
        require_token=True,
        environ={"LOG_LEVEL": "ERROR"},
    )
    assert settings.bot_token == VALID_TOKEN
    assert settings.log_level == "ERROR"


def test_env_loader_rejects_shell_syntax(tmp_path: Path) -> None:
    env_file = tmp_path / ".env"
    env_file.write_text("export BOT_TOKEN=value\n", encoding="utf-8")
    with pytest.raises(SettingsError):
        read_env_file(env_file)
