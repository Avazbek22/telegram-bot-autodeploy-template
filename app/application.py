from __future__ import annotations

import logging
import threading
from collections.abc import Callable
from contextlib import suppress
from pathlib import Path
from typing import Protocol

import telebot

from app.handlers import register_handlers
from app.healthcheck import HEALTH_MARKER
from app.settings import Settings

LOGGER = logging.getLogger("telegram_bot.application")


class BotProtocol(Protocol):
    def get_me(self) -> object: ...

    def infinity_polling(
        self, *, timeout: int, long_polling_timeout: int
    ) -> object: ...

    def stop_polling(self) -> None: ...


BotFactory = Callable[[str], BotProtocol]


class Application:
    def __init__(
        self,
        settings: Settings,
        *,
        bot_factory: BotFactory = telebot.TeleBot,
        health_marker: Path = HEALTH_MARKER,
    ) -> None:
        self.settings = settings
        self.bot_factory = bot_factory
        self.health_marker = health_marker
        self.bot: BotProtocol | None = None
        self.stop_event = threading.Event()
        self.heartbeat_thread: threading.Thread | None = None
        self.active = False
        self.polling_finished_unexpectedly = False

    def startup(self) -> None:
        self._remove_health_marker()
        self.settings.validate_token()
        self._prepare_directory(self.settings.data_dir)
        self._prepare_directory(self.settings.logs_dir)

        bot = self.bot_factory(self.settings.bot_token)
        bot.get_me()
        register_handlers(bot)  # type: ignore[arg-type]

        self.bot = bot
        self.stop_event.clear()
        self.active = True
        self.polling_finished_unexpectedly = False
        self.heartbeat_thread = threading.Thread(
            target=self._heartbeat_loop,
            name="health-heartbeat",
            daemon=False,
        )
        self.heartbeat_thread.start()
        self._write_health_marker()
        LOGGER.info("Startup completed; Telegram identity verified")

    def run(self) -> None:
        if not self.active or self.bot is None:
            raise RuntimeError("Application must be started before run")
        LOGGER.info("Long polling started")
        self.bot.infinity_polling(
            timeout=self.settings.polling_timeout_seconds,
            long_polling_timeout=self.settings.long_polling_timeout_seconds,
        )
        if not self.stop_event.is_set():
            self.polling_finished_unexpectedly = True
            self.active = False
            self._remove_health_marker()
            raise RuntimeError("Long polling stopped unexpectedly")

    def stop(self) -> None:
        already_stopped = self.stop_event.is_set() and not self.active
        self.stop_event.set()
        self.active = False
        if self.bot is not None:
            self.bot.stop_polling()
        thread = self.heartbeat_thread
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=self.settings.health_heartbeat_seconds + 5)
            if thread.is_alive():
                LOGGER.error("Heartbeat thread did not stop in time")
        self._remove_health_marker()
        if not already_stopped:
            LOGGER.info("Shutdown completed")

    def _heartbeat_loop(self) -> None:
        interval = self.settings.health_heartbeat_seconds
        while not self.stop_event.wait(interval):
            if (
                self.active
                and not self.stop_event.is_set()
                and not self.polling_finished_unexpectedly
            ):
                self._write_health_marker()

    def _write_health_marker(self) -> None:
        self.health_marker.parent.mkdir(parents=True, exist_ok=True)
        self.health_marker.touch()

    def _remove_health_marker(self) -> None:
        with suppress(FileNotFoundError):
            self.health_marker.unlink()

    @staticmethod
    def _prepare_directory(path: Path) -> None:
        path.mkdir(parents=True, exist_ok=True)
        probe = path / ".write-test"
        try:
            probe.write_text("ok", encoding="utf-8")
        except OSError as exc:
            raise RuntimeError(f"Directory is not writable: {path}") from exc
        finally:
            with suppress(FileNotFoundError):
                probe.unlink()


def create_application(
    settings: Settings,
    *,
    bot_factory: BotFactory = telebot.TeleBot,
    health_marker: Path = HEALTH_MARKER,
) -> Application:
    return Application(
        settings,
        bot_factory=bot_factory,
        health_marker=health_marker,
    )
