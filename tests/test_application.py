from __future__ import annotations

import threading
from pathlib import Path
from typing import Any

import pytest

from app.application import Application, create_application
from app.settings import Settings

VALID_TOKEN = "123456789:abcdefghijklmnopqrstuvwxyzABCDE"


class FakeBot:
    def __init__(self, token: str) -> None:
        self.token = token
        self.handlers: list[dict[str, Any]] = []
        self.get_me_calls = 0
        self.poll_calls = 0
        self.stop_calls = 0

    def get_me(self) -> object:
        self.get_me_calls += 1
        return object()

    def message_handler(self, **kwargs: Any) -> Any:
        self.handlers.append(kwargs)

        def decorator(function: Any) -> Any:
            return function

        return decorator

    def reply_to(self, message: object, text: str) -> None:
        del message, text

    def infinity_polling(self, *, timeout: int, long_polling_timeout: int) -> None:
        del timeout, long_polling_timeout
        self.poll_calls += 1

    def stop_polling(self) -> None:
        self.stop_calls += 1


def settings(tmp_path: Path) -> Settings:
    return Settings(
        bot_token=VALID_TOKEN,
        log_level="INFO",
        data_dir=tmp_path / "data",
        logs_dir=tmp_path / "logs",
        polling_timeout_seconds=20,
        long_polling_timeout_seconds=30,
        health_heartbeat_seconds=5,
        health_max_age_seconds=120,
    )


def test_health_marker_absent_before_startup(tmp_path: Path) -> None:
    marker = tmp_path / "health"
    create_application(settings(tmp_path), health_marker=marker)
    assert not marker.exists()


def test_handlers_register_only_during_successful_startup(tmp_path: Path) -> None:
    bot = FakeBot(VALID_TOKEN)
    application = create_application(
        settings(tmp_path),
        bot_factory=lambda token: bot,
        health_marker=tmp_path / "health",
    )
    assert bot.handlers == []
    application.startup()
    try:
        assert bot.get_me_calls == 1
        assert len(bot.handlers) == 3
    finally:
        application.stop()


def test_marker_removed_at_shutdown(tmp_path: Path) -> None:
    marker = tmp_path / "health"
    application = create_application(
        settings(tmp_path),
        bot_factory=FakeBot,
        health_marker=marker,
    )
    application.startup()
    assert marker.is_file()
    application.stop()
    assert not marker.exists()
    assert application.heartbeat_thread is not None
    assert not application.heartbeat_thread.is_alive()


def test_unexpected_polling_exit_is_unhealthy(tmp_path: Path) -> None:
    marker = tmp_path / "health"
    application = create_application(
        settings(tmp_path),
        bot_factory=FakeBot,
        health_marker=marker,
    )
    application.startup()
    with pytest.raises(RuntimeError, match="unexpectedly"):
        application.run()
    assert application.polling_finished_unexpectedly
    assert not marker.exists()
    application.stop()


def test_failed_get_me_does_not_register_handlers_or_mark_healthy(
    tmp_path: Path,
) -> None:
    marker = tmp_path / "health"

    class FailingBot(FakeBot):
        def get_me(self) -> object:
            raise ConnectionError("secret upstream detail")

    bot = FailingBot(VALID_TOKEN)
    application = create_application(
        settings(tmp_path),
        bot_factory=lambda token: bot,
        health_marker=marker,
    )
    with pytest.raises(ConnectionError):
        application.startup()
    assert bot.handlers == []
    assert not marker.exists()
    assert threading.current_thread() is threading.main_thread()


def test_graceful_signal_handler_stops_application(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    import main

    callbacks: dict[int, Any] = {}
    application = Application(settings(tmp_path), bot_factory=FakeBot)
    application.active = True

    def capture(signum: int, callback: Any) -> None:
        callbacks[signum] = callback

    monkeypatch.setattr(main.signal, "signal", capture)
    main._install_signal_handlers(application)
    callbacks[main.signal.SIGTERM](main.signal.SIGTERM, None)
    assert application.stop_event.is_set()
    assert not application.active
