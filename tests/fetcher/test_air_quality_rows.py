"""Tests for the air-quality row builder's AQI/PM2.5 extension.

The Phase-1 transparency factor scores AOD; the smoke feature (2026-06-25) also
surfaces US AQI and PM2.5 for the user's independent cross-check. These rows must
carry the new fields when present and tolerate their absence (a non-US site
returns no us_aqi) without fabricating zeros.
"""
import astrowidget_fetch as fx


def test_build_air_quality_rows_includes_aqi_and_pm25():
	"""When the hourly payload carries AQI + PM2.5, each row surfaces them."""
	hourly = {
		"time": ["2026-06-26T05:00", "2026-06-26T06:00"],
		"aerosol_optical_depth": [0.08, 0.09],
		"us_aqi": [52, 50],
		"pm2_5": [7.6, 6.0],
	}
	rows = fx.build_air_quality_rows(hourly)
	assert rows[0] == {
		"time": "2026-06-26T05:00",
		"aerosol_optical_depth": 0.08,
		"us_aqi": 52,
		"pm2_5": 7.6,
	}


def test_build_air_quality_rows_tolerates_missing_aqi_pm25():
	"""AOD present, AQI/PM2.5 absent (e.g. a non-US site) → fields default to None,
	never 0 (null ≠ clean air — the Phase-1 null-polarity rule)."""
	hourly = {"time": ["t0"], "aerosol_optical_depth": [0.05]}
	rows = fx.build_air_quality_rows(hourly)
	assert rows[0]["us_aqi"] is None
	assert rows[0]["pm2_5"] is None


def test_build_air_quality_rows_short_aqi_column_defaults_tail_to_none():
	"""A truncated AQI column must not crash or fabricate a tail value — hours past
	the AQI array length default to None (same length-mismatch defense as AOD)."""
	hourly = {
		"time": ["t0", "t1"],
		"aerosol_optical_depth": [0.05, 0.06],
		"us_aqi": [40],          # shorter than time/AOD
		"pm2_5": [3.0, 4.0],
	}
	rows = fx.build_air_quality_rows(hourly)
	assert rows[0]["us_aqi"] == 40
	assert rows[1]["us_aqi"] is None
	assert rows[1]["pm2_5"] == 4.0
