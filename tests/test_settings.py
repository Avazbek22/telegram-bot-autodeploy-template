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
            "HEALTH_HEARTBEAT_SECONDS": "20",
            "HEALTH_MAX_AGE_SECONDS": "100",
        },
    )
    assert settings.bot_token == VALID_TOKEN
    assert settings.log_level == "WARNING"
    assert settings.polling_timeout_seconds == 10
    assert settings.data_dir == (tmp_path / "state").resolve()


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
        ("HEALTH_HEARTBEAT_SECONDS", "-1"),
        ("HEALTH_MAX_AGE_SECONDS", "601"),
    ],
)
def test_invalid_numeric_configuration(tmp_path: Path, name: str, value: str) -> None:
    with pytest.raises(SettingsError):
        load_settings(
            tmp_path,
            environ={"BOT_TOKEN": VALID_TOKEN, name: value},
        )


def test_health_threshold_must_exceed_two_heartbeats(tmp_path: Path) -> None:
    with pytest.raises(SettingsError, match="twice"):
        load_settings(
            tmp_path,
            environ={
                "HEALTH_HEARTBEAT_SECONDS": "30",
                "HEALTH_MAX_AGE_SECONDS": "60",
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
