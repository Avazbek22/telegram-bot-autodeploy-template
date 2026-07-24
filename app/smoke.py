from __future__ import annotations

import sys

import telebot

from app.settings import load_settings


def main() -> int:
    if sys.version_info[:2] != (3, 12):
        return 1
    try:
        settings = load_settings(require_token=True)
        bot = telebot.TeleBot(settings.bot_token)
        bot.get_me()
    except Exception:
        # Fail closed without echoing API exceptions that may contain a token.
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
