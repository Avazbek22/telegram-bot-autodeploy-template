from __future__ import annotations

import logging
import re
import sys
import time
from logging.handlers import TimedRotatingFileHandler
from pathlib import Path

TOKEN_PATTERN = re.compile(r"(?<![A-Za-z0-9_-])[0-9]{5,20}:[A-Za-z0-9_-]{20,128}")


class RedactingFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        return TOKEN_PATTERN.sub("<bot-token-redacted>", super().format(record))


class ConsoleFormatter(RedactingFormatter):
    """Keep tracebacks in the protected log file, not in container stdout."""

    def format(self, record: logging.LogRecord) -> str:
        safe_record = logging.makeLogRecord(record.__dict__.copy())
        safe_record.exc_info = None
        safe_record.exc_text = None
        safe_record.stack_info = None
        return super().format(safe_record)


def configure_logging(logs_dir: Path, level: str) -> logging.Logger:
    logs_dir.mkdir(parents=True, exist_ok=True)
    logging.Formatter.converter = time.gmtime

    root = logging.getLogger()
    root.setLevel(getattr(logging, level))
    root.handlers.clear()
    root.propagate = False

    format_string = "%(asctime)sZ %(levelname)s %(name)s %(message)s"
    date_format = "%Y-%m-%dT%H:%M:%S"

    console = logging.StreamHandler(sys.stdout)
    console.setFormatter(ConsoleFormatter(format_string, datefmt=date_format))

    file_handler = TimedRotatingFileHandler(
        logs_dir / "bot.log",
        when="midnight",
        interval=1,
        backupCount=60,
        encoding="utf-8",
        utc=True,
    )
    file_handler.setFormatter(RedactingFormatter(format_string, datefmt=date_format))

    root.addHandler(console)
    root.addHandler(file_handler)
    return logging.getLogger("telegram_bot")
