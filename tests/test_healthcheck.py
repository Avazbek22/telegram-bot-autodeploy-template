from __future__ import annotations

import os
from pathlib import Path

from app.healthcheck import marker_is_fresh


def test_missing_marker_is_unhealthy(tmp_path: Path) -> None:
    assert not marker_is_fresh(tmp_path / "missing")


def test_fresh_and_stale_marker(tmp_path: Path) -> None:
    marker = tmp_path / "health"
    marker.touch()
    os.utime(marker, (1_000, 1_000))
    assert marker_is_fresh(marker, max_age_seconds=120, now=1_100)
    assert not marker_is_fresh(marker, max_age_seconds=120, now=1_120)
    assert not marker_is_fresh(marker, max_age_seconds=120, now=999)
