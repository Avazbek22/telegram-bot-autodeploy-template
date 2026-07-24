from __future__ import annotations

import os
import time
from pathlib import Path

HEALTH_MARKER = Path("/tmp/telegram-bot.healthy")
DEFAULT_MAX_AGE_SECONDS = 120


def marker_is_fresh(
    marker: Path = HEALTH_MARKER,
    *,
    max_age_seconds: int = DEFAULT_MAX_AGE_SECONDS,
    now: float | None = None,
) -> bool:
    try:
        modified = marker.stat().st_mtime
    except (FileNotFoundError, OSError):
        return False
    age = (time.time() if now is None else now) - modified
    return 0 <= age < max_age_seconds


def main() -> int:
    marker = Path(os.getenv("HEALTH_MARKER", str(HEALTH_MARKER)))
    raw_max_age = os.getenv("HEALTH_MAX_AGE_SECONDS", str(DEFAULT_MAX_AGE_SECONDS))
    try:
        max_age = int(raw_max_age)
    except ValueError:
        return 1
    if not 1 <= max_age <= 3600:
        return 1
    return 0 if marker_is_fresh(marker, max_age_seconds=max_age) else 1


if __name__ == "__main__":
    raise SystemExit(main())
