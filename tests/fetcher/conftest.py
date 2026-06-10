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
def _no_aod_network(request, monkeypatch):
	"""Stub the Open-Meteo air-quality (AOD) fetch for EVERY test.

	QA 2026-06-09: main() calls fetch_open_meteo_air_quality() once per site
	and no main()-level test patched it — a bare `pytest tests/` fired 30+
	LIVE HTTPS GETs at Open-Meteo. Best-effort + timeout meant the suite
	passed even offline, which is exactly why it went unnoticed.

	{} is the function's own documented absence value: build_air_quality_rows
	maps it to "no transparency data" and the factor is OMITTED downstream
	(the Phase-1 null-polarity rule) — so stubbed tests exercise the same
	path as a real AOD outage. A test needing specific AOD data monkeypatches
	over this (test-local patches apply after autouse ones); the one test
	that exercises the REAL function opts out via @pytest.mark.real_aod
	(registered in pytest.ini).
	"""
	if request.node.get_closest_marker("real_aod"):
		return
	import astrowidget_fetch
	monkeypatch.setattr(
		astrowidget_fetch, "fetch_open_meteo_air_quality", lambda lat, lon: {}
	)


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
