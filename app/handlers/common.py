from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from telebot import TeleBot
    from telebot.types import Message


def register_handlers(bot: TeleBot) -> None:
    @bot.message_handler(commands=["start"])
    def handle_start(message: Message) -> None:
        bot.reply_to(message, "Hello! I am ready. Send me a text message.")

    @bot.message_handler(commands=["help"])
    def handle_help(message: Message) -> None:
        bot.reply_to(message, "Send any text and I will echo it back.")

    @bot.message_handler(
        func=lambda message: bool(message.text),
        content_types=["text"],
    )
    def handle_text(message: Message) -> None:
        if message.text:
            bot.reply_to(message, message.text)
