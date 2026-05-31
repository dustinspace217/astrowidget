"""
Tests for the main() pipeline — end-to-end resilience and partial-success
behavior.

These tests mock the external boundaries (config load, both API calls,
scoring binary subprocess) and exercise the pipeline glue that lives in
main(): per-site loop, error counting, scoring-output merge by id,
state.json shape, notify dispatch.

The test_analyzer review identified this as a HIGH-risk coverage gap
because partial-failure resilience is the whole point of the multi-site
design.
"""

from pathlib import Path
from unittest.mock import patch

import pytest

import astrowidget_fetch as fx


VALID_CFG = {
	"api": {"astrospheric_key": "fake", "astrospheric_daily_credit_budget": 100},
	"open_meteo": {"models": []},
	"sites": [
		{"id": "site_a", "label": "A", "lat": 47.0, "lon": -122.0, "timezone": "UTC"},
		{"id": "site_b", "label": "B", "lat": 37.0, "lon": -119.0, "timezone": "UTC"},
	],
	"thresholds": {},
	"notifications": {
		"upward_transitions": False,
		"downward_transitions_day_of": False,
		"astro_dark_start_reminder": False,
	},
}


def _astrospheric_stub():
	"""Minimal good-shape Astrospheric response."""
	return {
		"TimeZone": "UTC",
		"APICreditUsedToday": 5,
		"Astrospheric_Seeing": [{"Value": 4, "ColorIndex": 1}],
		"Astrospheric_Transparency": [{"Value": 3, "ColorIndex": 1}],
		"RDPS_CloudCover": [{"Value": 10, "ColorIndex": 1}],
		"RDPS_DewPoint": [{"Value": 281.5, "ColorIndex": 1}],
		"RDPS_Temperature": [{"Value": 284.0, "ColorIndex": 1}],
		"RDPS_WindVelocity": [{"Value": 2.5, "ColorIndex": 1}],
		"RDPS_WindDirection": [{"Value": 220, "ColorIndex": 1}],
	}


def _open_meteo_stub():
	"""Minimal good-shape Open-Meteo response."""
	return {
		"hourly": {
			"time": ["2026-05-29T04:00:00"],
			"cloud_cover": [10],
			"cloud_cover_low": [0],
			"cloud_cover_mid": [0],
			"cloud_cover_high": [15],
			"relative_humidity_2m": [65],
			"temperature_2m": [11],
			"dewpoint_2m": [8],
			"wind_speed_10m": [8],
			"wind_gusts_10m": [13],
			"precipitation_probability": [5],
			"precipitation": [0],
			"visibility": [24000],
		}
	}


def _scoring_output(*site_ids):
	"""Minimal scoring binary output with one Tonight per site."""
	return {
		"schema_version": 1,
		"sites": [
			{
				"id": sid,
				"label": sid.upper(),
				"status": "ok",
				"nights": [
					{
						"label": "Tonight",
						"dark_window": {
							"start": "2026-05-29T04:00:00Z",
							"end": "2026-05-29T10:00:00Z",
							"duration_minutes": 360,
						},
						"recommendation": "BB+NB",
						"broadband": {"score": 80, "verdict": "excellent", "vetoes": []},
						"narrowband": {"score": 85, "verdict": "excellent", "vetoes": []},
					}
				],
			}
			for sid in site_ids
		],
	}


@pytest.fixture(autouse=True)
def no_convergence_network(monkeypatch):
	"""
	Stub the multi-model convergence fetch so pipeline tests never hit the
	real Open-Meteo network. Convergence is best-effort (returns {} on
	failure), so an empty stub exercises the no-convergence path cleanly.
	Convergence-specific behavior is tested separately in test_convergence.py.
	"""
	monkeypatch.setattr(fx, "fetch_open_meteo_convergence", lambda *a, **k: {})


@pytest.fixture
def patched_paths(tmp_path, monkeypatch):
	"""Reroute CACHE_DIR and STATE_PATH to tmp_path so tests don't touch ~/.cache."""
	monkeypatch.setattr(fx, "CACHE_DIR", tmp_path / "cache")
	monkeypatch.setattr(fx, "STATE_PATH", tmp_path / "cache" / "state.json")
	monkeypatch.setattr(fx, "PREV_STATE_PATH", tmp_path / "cache" / "state.prev.json")
	yield tmp_path


def test_main_all_sites_succeed_returns_0(patched_paths):
	"""Happy path: both sites succeed → exit 0, state.json contains both."""
	with patch.object(fx, "load_config", return_value=VALID_CFG), \
		 patch.object(fx, "fetch_astrospheric", return_value=_astrospheric_stub()), \
		 patch.object(fx, "fetch_open_meteo", return_value=_open_meteo_stub()), \
		 patch.object(fx, "invoke_scoring_binary",
					  return_value=_scoring_output("site_a", "site_b")), \
		 patch.object(fx, "_notify"):
		rc = fx.main()
	assert rc == 0
	state_path = patched_paths / "cache" / "state.json"
	assert state_path.exists()
	import json
	state = json.loads(state_path.read_text())
	assert len(state["sites"]) == 2
	assert all(s["status"] == "ok" for s in state["sites"])
	# Scoring output merged into site_results.
	assert all("nights" in s for s in state["sites"])


def test_main_partial_failure_continues_with_other_sites(patched_paths):
	"""One Astrospheric call fails → site has error status, other succeeds, exit 0."""
	call_count = [0]
	def maybe_fail(*a, **kw):
		call_count[0] += 1
		if call_count[0] == 1:
			raise fx.AstrosphericFetchError("simulated network failure")
		return _astrospheric_stub()

	with patch.object(fx, "load_config", return_value=VALID_CFG), \
		 patch.object(fx, "fetch_astrospheric", side_effect=maybe_fail), \
		 patch.object(fx, "fetch_open_meteo", return_value=_open_meteo_stub()), \
		 patch.object(fx, "invoke_scoring_binary",
					  return_value=_scoring_output("site_b")), \
		 patch.object(fx, "_notify"):
		rc = fx.main()
	assert rc == 0  # partial success is still 0 — surviving sites still updated
	import json
	state = json.loads((patched_paths / "cache" / "state.json").read_text())
	statuses = {s["id"]: s["status"] for s in state["sites"]}
	assert statuses["site_a"] == "error"
	assert statuses["site_b"] == "ok"


def test_main_all_sites_fail_returns_3(patched_paths):
	"""Every site fails its API call → exit 3 (per documented contract)."""
	with patch.object(fx, "load_config", return_value=VALID_CFG), \
		 patch.object(fx, "fetch_astrospheric",
					  side_effect=fx.AstrosphericFetchError("down")), \
		 patch.object(fx, "fetch_open_meteo", return_value=_open_meteo_stub()), \
		 patch.object(fx, "invoke_scoring_binary",
					  return_value=_scoring_output()), \
		 patch.object(fx, "_notify"):
		rc = fx.main()
	assert rc == 3


def test_main_writes_credit_cost_to_state(patched_paths):
	"""Per-site Astrospheric cost (5 credits) tallied in state.json."""
	with patch.object(fx, "load_config", return_value=VALID_CFG), \
		 patch.object(fx, "fetch_astrospheric", return_value=_astrospheric_stub()), \
		 patch.object(fx, "fetch_open_meteo", return_value=_open_meteo_stub()), \
		 patch.object(fx, "invoke_scoring_binary",
					  return_value=_scoring_output("site_a", "site_b")), \
		 patch.object(fx, "_notify"):
		fx.main()
	import json
	state = json.loads((patched_paths / "cache" / "state.json").read_text())
	# 2 sites × 5 credits/call = 10 credits.
	assert state["astrosphericCreditCost"] == 10
	assert state["astrosphericCreditBudget"] == 100


def test_main_merges_scoring_output_by_id(patched_paths):
	"""Scoring binary output is matched to site_results by id, not by index."""
	# Reverse scoring output order — main() must still pair by id.
	with patch.object(fx, "load_config", return_value=VALID_CFG), \
		 patch.object(fx, "fetch_astrospheric", return_value=_astrospheric_stub()), \
		 patch.object(fx, "fetch_open_meteo", return_value=_open_meteo_stub()), \
		 patch.object(fx, "invoke_scoring_binary",
					  return_value=_scoring_output("site_b", "site_a")), \
		 patch.object(fx, "_notify"):
		fx.main()
	import json
	state = json.loads((patched_paths / "cache" / "state.json").read_text())
	by_id = {s["id"]: s for s in state["sites"]}
	# Both sites should have nights attached (the merge worked despite the
	# reversed order in the scoring output).
	assert "nights" in by_id["site_a"]
	assert "nights" in by_id["site_b"]


def test_main_budget_warning_fires_at_80pct(patched_paths):
	"""When credit_cost ≥ 80% of budget, a normal-urgency notification fires."""
	cfg = dict(VALID_CFG)
	cfg["sites"] = [
		{"id": f"site_{i}", "label": f"S{i}", "lat": 47.0+i, "lon": -122.0, "timezone": "UTC"}
		for i in range(16)  # 16 sites × 5 credits = 80 credits = 80% of 100
	]
	with patch.object(fx, "load_config", return_value=cfg), \
		 patch.object(fx, "fetch_astrospheric", return_value=_astrospheric_stub()), \
		 patch.object(fx, "fetch_open_meteo", return_value=_open_meteo_stub()), \
		 patch.object(fx, "invoke_scoring_binary",
					  return_value=_scoring_output()), \
		 patch.object(fx, "_notify") as nf:
		fx.main()
	# A budget-warning notify-send must have been emitted.
	titles = [c.args[0] for c in nf.call_args_list]
	assert any("quota" in t.lower() or "budget" in t.lower() for t in titles)
