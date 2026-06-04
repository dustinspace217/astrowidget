"""Shared fixtures for grader tests.

Adds grader/ and fetcher/ to sys.path (so `import grade` / `import calibration_log`
work directly), and isolates the calibration DB to a tmp file so no grader test ever
writes to the real ~/.local/share/astrowidget/astrowidget.db. Mirrors the fetcher
conftest's _isolate_calibration_db.
"""

import sys
from pathlib import Path

import pytest

PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT / "grader"))
sys.path.insert(0, str(PROJECT_ROOT / "fetcher"))


@pytest.fixture(autouse=True)
def _isolate_calibration_db(tmp_path, monkeypatch):
	"""Redirect calibration_log.DB_PATH to a tmp file for every grader test. connect()
	reads the module global at call time, so patching the attribute reroutes all writes.
	"""
	import calibration_log

	monkeypatch.setattr(calibration_log, "DB_PATH", tmp_path / "test_astrowidget.db")
