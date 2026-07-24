from __future__ import annotations

import logging
import signal

from app.application import Application, create_application
from app.logging_setup import configure_logging
from app.settings import SettingsError, load_settings


def _install_signal_handlers(application: Application) -> None:
    def handle_stop(signum: int, frame: object) -> None:
        del signum, frame
        application.stop()

    signal.signal(signal.SIGTERM, handle_stop)
    signal.signal(signal.SIGINT, handle_stop)


def main() -> int:
    application: Application | None = None
    try:
        settings = load_settings(require_token=True)
        configure_logging(settings.logs_dir, settings.log_level)
        application = create_application(settings)
        _install_signal_handlers(application)
        application.startup()
        application.run()
        return 0
    except SettingsError:
        logging.getLogger("telegram_bot").error("Configuration is invalid")
        return 2
    except Exception:
        logging.getLogger("telegram_bot").exception(
            "Application stopped due to an internal error"
        )
        return 1
    finally:
        if application is not None:
            application.stop()


if __name__ == "__main__":
    raise SystemExit(main())
