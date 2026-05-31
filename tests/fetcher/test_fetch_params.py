"""
Regression guards for request parameters and timestamp parsing.

These pin two things a future edit could silently break:
- fetch_open_meteo / fetch_open_meteo_convergence must request forecast_days=4
  (a revert to 3 would re-truncate the +2-night dark window).
- _parse_utc_hour must handle negative UTC offsets (not just 'Z'/naive UTC).
"""

from unittest.mock import MagicMock, patch

import astrowidget_fetch as fx


def _fake_get(captured: dict):
	"""Returns a requests.get stand-in that records params and returns a
	minimal valid Open-Meteo body."""
	def _get(url, params=None, timeout=None):
		captured["url"] = url
		captured["params"] = params
		resp = MagicMock()
		resp.status_code = 200
		resp.raise_for_status.return_value = None
		resp.json.return_value = {"hourly": {"time": [], "cloud_cover": []}}
		return resp
	return _get


def test_fetch_open_meteo_requests_4_forecast_days():
	"""Fix #4 regression guard: forecast_days must be 4, not 3."""
	captured: dict = {}
	with patch.object(fx.requests, "get", _fake_get(captured)):
		fx.fetch_open_meteo(47.0, -122.0)
	assert captured["params"]["forecast_days"] == fx.OPEN_METEO_FORECAST_DAYS == 4


def test_fetch_open_meteo_requests_utc_and_units():
	"""Pin the UTC timezone + km/h + celsius request invariants."""
	captured: dict = {}
	with patch.object(fx.requests, "get", _fake_get(captured)):
		fx.fetch_open_meteo(47.0, -122.0)
	p = captured["params"]
	assert p["timezone"] == "UTC"
	assert p["wind_speed_unit"] == "kmh"
	assert p["temperature_unit"] == "celsius"


def test_convergence_requests_models_and_4_days():
	"""Convergence call must request the models param + matching horizon."""
	captured: dict = {}
	with patch.object(fx.requests, "get", _fake_get(captured)):
		fx.fetch_open_meteo_convergence(47.0, -122.0, fx.OPEN_METEO_CONVERGENCE_MODELS)
	assert captured["params"]["forecast_days"] == 4
	assert captured["params"]["models"] == ",".join(fx.OPEN_METEO_CONVERGENCE_MODELS)
	assert captured["params"]["hourly"] == "cloud_cover"


def test_convergence_single_model_skips_call():
	"""<2 models → no convergence (returns {}), no network call."""
	with patch.object(fx.requests, "get") as g:
		out = fx.fetch_open_meteo_convergence(47.0, -122.0, ["gfs_seamless"])
	assert out == {}
	g.assert_not_called()


# ── _parse_utc_hour timezone handling ─────────────────────────────────────────

def test_parse_utc_hour_naive_treated_as_utc():
	dt = fx._parse_utc_hour("2026-05-29T04:30:00")
	assert dt is not None
	assert (dt.year, dt.month, dt.day, dt.hour, dt.minute) == (2026, 5, 29, 4, 0)
	assert dt.tzinfo is not None


def test_parse_utc_hour_z_suffix():
	dt = fx._parse_utc_hour("2026-05-29T04:00:00Z")
	assert dt is not None and dt.hour == 4


def test_parse_utc_hour_negative_offset_converts_to_utc():
	"""
	The fix: a NEGATIVE offset must be parsed and converted, not corrupted.
	2026-05-29T00:00:00-08:00 == 2026-05-29T08:00:00Z.
	"""
	dt = fx._parse_utc_hour("2026-05-29T00:00:00-08:00")
	assert dt is not None
	assert (dt.day, dt.hour) == (29, 8)


def test_parse_utc_hour_positive_offset_converts_to_utc():
	dt = fx._parse_utc_hour("2026-05-29T10:00:00+05:30")
	assert dt is not None
	# 10:00 +05:30 -> 04:30 UTC -> truncated to 04:00.
	assert (dt.day, dt.hour) == (29, 4)


def test_parse_utc_hour_garbage_is_none():
	assert fx._parse_utc_hour("not a date") is None
	assert fx._parse_utc_hour(None) is None
	assert fx._parse_utc_hour("") is None
