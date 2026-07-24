from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path


def test_import_main_has_no_runtime_side_effects(tmp_path: Path) -> None:
    project_root = Path(__file__).resolve().parents[1]
    code = """
import json
import pathlib
import threading
before = {p.name for p in pathlib.Path.cwd().iterdir()}
import main
after = {p.name for p in pathlib.Path.cwd().iterdir()}
result = {"threads": len(threading.enumerate()), "created": sorted(after - before)}
print(json.dumps(result))
"""
    result = subprocess.run(
        [sys.executable, "-c", code],
        cwd=tmp_path,
        env={"PYTHONPATH": str(project_root)},
        capture_output=True,
        text=True,
        check=True,
        timeout=10,
    )
    outcome = json.loads(result.stdout)
    assert outcome == {"threads": 1, "created": []}
