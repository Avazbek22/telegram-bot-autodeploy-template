"""Minimal stand-in for the Telegram Bot API used by the end-to-end test.

Requests under /conflict/ answer getUpdates with HTTP 409, which is what
Telegram does when a second instance polls the same token.
"""

from __future__ import annotations

import argparse
import json
import threading
import time
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

CALLS: Counter[str] = Counter()
LOCK = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    stats_path: Path

    def do_GET(self) -> None:
        self._handle()

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        self._handle()

    def _handle(self) -> None:
        parts = urlparse(self.path).path.strip("/").split("/")
        conflict = parts[:1] == ["conflict"]
        if conflict:
            parts = parts[1:]
        if len(parts) != 2 or not parts[0].startswith("bot"):
            self._reply(404, {"ok": False, "description": "Not Found"})
            return
        method = parts[1]
        key = f"conflict:{method}" if conflict else method
        with LOCK:
            CALLS[key] += 1
            self.stats_path.write_text(json.dumps(CALLS), encoding="utf-8")

        if method == "getMe":
            result: object = {
                "id": 1,
                "is_bot": True,
                "first_name": "E2E",
                "username": "e2e_test_bot",
            }
        elif method == "getUpdates" and conflict:
            self._reply(
                409,
                {
                    "ok": False,
                    "error_code": 409,
                    "description": "Conflict: terminated by other getUpdates request",
                },
            )
            return
        elif method == "getUpdates":
            time.sleep(1)
            result = []
        else:
            result = True
        self._reply(200, {"ok": True, "result": result})

    def _reply(self, status: int, payload: dict[str, object]) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        del format, args


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8081)
    parser.add_argument("--stats", type=Path, required=True)
    arguments = parser.parse_args()
    Handler.stats_path = arguments.stats
    arguments.stats.write_text("{}", encoding="utf-8")
    ThreadingHTTPServer(("0.0.0.0", arguments.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
