"""
Pytest configuration shared across all fetcher tests.

Adds the project's fetcher/ directory to sys.path so tests can import
astrowidget_fetch directly: `from astrowidget_fetch import load_config`.
"""

import sys
from pathlib import Path

import pytest

# fetcher/ lives at ~/Claude/astrowidget/fetcher/; this file is at
# ~/Claude/astrowidget/tests/fetcher/conftest.py. Walk up twice to find
# project root.
PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT / "fetcher"))


@pytest.fixture(autouse=True)
def _isolate_calibration_db(tmp_path, monkeypatch):
	"""Redirect the Phase-3 calibration DB to a per-test tmp path for EVERY test.

	The full fetcher pipeline (test_integration_binary, test_main_pipeline) calls
	calibration_log.log_run(), which would otherwise write test rows into the
	user's REAL ~/.local/share/astrowidget/astrowidget.db and contaminate the
	calibration dataset. Autouse = no individual test has to remember this.
	"""
	import calibration_log
	monkeypatch.setattr(calibration_log, "DB_PATH", tmp_path / "test_astrowidget.db")
