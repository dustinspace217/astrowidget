"""Tests for fetcher/firms.py — NASA FIRMS active-fire proximity.

Synthetic coordinates only (public-repo discipline). Network is mocked; there are
no live FIRMS calls in the suite.
"""
import math
from unittest.mock import MagicMock, patch

import pytest
import requests

import firms


# ── Pure helpers (no network) ────────────────────────────────────────────────


def test_haversine_known_distance():
	"""~111 km per degree of latitude near the equator (synthetic coords)."""
	d = firms._haversine_km(0.0, 0.0, 1.0, 0.0)
	assert 110.0 < d < 112.0


def test_bounding_box_order_west_south_east_north():
	w, s, e, n = firms._bounding_box(10.0, 20.0, 111.0)
	assert w < 20.0 < e and s < 10.0 < n          # box brackets the point
	assert math.isclose(n - 10.0, 1.0, abs_tol=0.05)  # ~1° lat for 111 km


def test_aggregate_filters_to_radius_and_summarizes():
	dets = [
		{"latitude": 0.2, "longitude": 0.0, "frp": 50.0},    # ~22 km — inside
		{"latitude": 0.9, "longitude": 0.0, "frp": 120.0},   # ~100 km — inside
		{"latitude": 2.0, "longitude": 0.0, "frp": 999.0},   # ~222 km — outside
	]
	out = firms._aggregate(dets, 0.0, 0.0, radius_km=150.0)
	assert out["count"] == 2
	assert out["maxFrp"] == 120.0
	assert 20.0 < out["nearestKm"] < 25.0


def test_aggregate_returns_none_when_no_fires_in_radius():
	out = firms._aggregate(
		[{"latitude": 5.0, "longitude": 5.0, "frp": 10.0}], 0.0, 0.0, radius_km=150.0)
	assert out is None


def test_parse_detections_drops_low_confidence_and_bad_rows():
	csv_text = (
		"latitude,longitude,bright_ti4,frp,confidence,acq_date\n"
		"0.1,0.1,330,12.0,n,2026-06-25\n"     # nominal — keep
		"0.2,0.2,331,20.0,h,2026-06-25\n"     # high — keep
		"0.3,0.3,300,5.0,l,2026-06-25\n"      # low — drop
		"notanumber,0.4,300,5.0,h,2026-06-25\n"  # malformed — drop
	)
	dets = firms._parse_detections(csv_text)
	assert len(dets) == 2
	assert all(d["frp"] in (12.0, 20.0) for d in dets)


# ── fetch_fires_nearby (network mocked) ──────────────────────────────────────


def test_fetch_fires_nearby_no_key_returns_none():
	"""No map key → None (feature disabled), no network call."""
	assert firms.fetch_fires_nearby(0.0, 0.0, map_key="") is None


def test_fetch_fires_nearby_parses_mocked_response():
	sample_csv = (
		"latitude,longitude,bright_ti4,frp,confidence,acq_date\n"
		"0.2,0.0,330,80.0,n,2026-06-25\n"     # ~22 km from (0,0)
	)
	resp = MagicMock()
	resp.text = sample_csv
	resp.raise_for_status = MagicMock()
	with patch.object(firms.requests, "get", return_value=resp):
		out = firms.fetch_fires_nearby(0.0, 0.0, "fakekey", radius_km=150.0)
	assert out["count"] == 1
	assert out["maxFrp"] == 80.0
	assert out["radiusKm"] == 150
	assert out["source"] == "VIIRS_NOAA20_NRT"


def test_fetch_fires_nearby_no_fires_returns_none_not_error():
	"""A 200 OK with a header-only CSV (no detections) is a clean no-fire night →
	None, NOT a FirmsError (the two states must never be conflated)."""
	resp = MagicMock()
	resp.text = "latitude,longitude,bright_ti4,frp,confidence,acq_date\n"
	resp.raise_for_status = MagicMock()
	with patch.object(firms.requests, "get", return_value=resp):
		out = firms.fetch_fires_nearby(0.0, 0.0, "fakekey")
	assert out is None


def test_fetch_fires_nearby_raises_firms_error_on_http_failure():
	"""A network/HTTP failure raises FirmsError so the caller can flag degraded."""
	with patch.object(firms.requests, "get",
					  side_effect=requests.RequestException("503")):
		with pytest.raises(firms.FirmsError):
			firms.fetch_fires_nearby(0.0, 0.0, "fakekey")


def test_fetch_fires_nearby_uses_day_range_2():
	"""DAY_RANGE must be 2, not 1: a 1-day window misses the PRIOR UTC day's
	detections after the date rolls at night — the 2026-06-25 UDRO case (a fire
	54 km away, detected on the prior UTC day, invisible at day-range 1)."""
	captured = {}
	resp = MagicMock()
	resp.text = "latitude,longitude,bright_ti4,frp,confidence,acq_date\n"
	resp.raise_for_status = MagicMock()

	def fake_get(url, **kwargs):
		captured["url"] = url
		return resp

	with patch.object(firms.requests, "get", side_effect=fake_get):
		firms.fetch_fires_nearby(0.0, 0.0, "fakekey")
	assert captured["url"].endswith("/2")
