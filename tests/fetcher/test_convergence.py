"""
Tests for multi-model cloud convergence (DEF-V1-02, the user's explicit
"cloud cover, each model and the convergences" request).

build_convergence_index() turns Open-Meteo's per-model response into a
UTC-hour lookup; enrich_night_factors() averages per model over the dark
window and reports the per-model means + the numeric spread.

(In production the per-night convergence index now comes from
ensemble_cloud_by_hour's per_model output, which also carries Astrospheric
Cloud Sense / GFS / NAM for NA sites. build_convergence_index remains a
tested utility with the same {hour: {model: pct}} shape.)
"""

import astrowidget_fetch as fx


def _conv_hourly():
	"""Open-Meteo multi-model response shape: per-model suffixed cloud arrays."""
	return {
		"time": ["2026-05-29T04:00:00", "2026-05-29T05:00:00"],
		"cloud_cover_gfs_seamless": [10, 12],
		"cloud_cover_ecmwf_ifs04": [15, 18],
		"cloud_cover_icon_seamless": [8, 10],
	}


def test_build_index_keys_by_utc_hour():
	idx = fx.build_convergence_index(_conv_hourly(), fx.OPEN_METEO_CONVERGENCE_MODELS)
	assert len(idx) == 2
	# Each hour maps to a per-model dict.
	hour0 = fx._parse_utc_hour("2026-05-29T04:00:00")
	assert idx[hour0]["gfs_seamless"] == 10.0
	assert idx[hour0]["ecmwf_ifs04"] == 15.0
	assert idx[hour0]["icon_seamless"] == 8.0


def test_build_index_empty_input():
	assert fx.build_convergence_index({}, fx.OPEN_METEO_CONVERGENCE_MODELS) == {}


def test_convergence_reports_numeric_spread():
	"""enrich reports the per-model means and the numeric SPREAD (max - min)
	across models — there is no strong/moderate/weak bucket anymore (those
	thresholds were arbitrary magic numbers, dropped in the 7-site rework)."""
	conv = fx.build_convergence_index(_conv_hourly(), fx.OPEN_METEO_CONVERGENCE_MODELS)
	night = {"dark_window": {"start": "2026-05-29T04:00:00Z", "end": "2026-05-29T06:00:00Z"}}
	slc = [
		{"time": "2026-05-29T04:00:00", "cloud_cover": 11, "cloud_cover_low": 0,
		 "cloud_cover_mid": 0, "cloud_cover_high": 11, "temperature_2m": 12,
		 "dewpoint_2m": 8, "wind_speed_10m": 8, "wind_gusts_10m": 13,
		 "precipitation_probability": 5, "visibility": 24000,
		 "_seeing_raw": 4, "_transparency_raw": 3},
		{"time": "2026-05-29T05:00:00", "cloud_cover": 13, "cloud_cover_low": 0,
		 "cloud_cover_mid": 0, "cloud_cover_high": 13, "temperature_2m": 12,
		 "dewpoint_2m": 8, "wind_speed_10m": 8, "wind_gusts_10m": 13,
		 "precipitation_probability": 5, "visibility": 24000,
		 "_seeing_raw": 4, "_transparency_raw": 3},
	]
	fx.enrich_night_factors(night, slc, conv)
	c = night["displayFactors"]["cloudConvergence"]
	assert c is not None
	# gfs mean=11, ecmwf mean=16.5, icon mean=9 -> spread = round(16.5 - 9) = 8.
	assert c["spread"] == 8
	assert "agreement" not in c   # the magic-number bucket is gone
	assert set(c["models"].keys()) == {"gfs_seamless", "ecmwf_ifs04", "icon_seamless"}


def test_convergence_survives_one_short_model_array():
	"""
	If one model's cloud array is shorter than the others (partial model run),
	build_convergence_index still indexes the hours that ARE present, and
	enrichment produces a panel from the >=2 models that cover the window.
	"""
	conv = {
		"time": ["2026-05-29T04:00:00", "2026-05-29T05:00:00"],
		"cloud_cover_gfs_seamless": [10, 12],
		"cloud_cover_ecmwf_ifs04": [15],          # short — only hour 0
		"cloud_cover_icon_seamless": [8, 10],
	}
	idx = fx.build_convergence_index(conv, fx.OPEN_METEO_CONVERGENCE_MODELS)
	hour0 = fx._parse_utc_hour("2026-05-29T04:00:00")
	hour1 = fx._parse_utc_hour("2026-05-29T05:00:00")
	# Hour 0 has all three; hour 1 has only the two full models.
	assert set(idx[hour0].keys()) == {"gfs_seamless", "ecmwf_ifs04", "icon_seamless"}
	assert "ecmwf_ifs04" not in idx[hour1]
	assert set(idx[hour1].keys()) == {"gfs_seamless", "icon_seamless"}


def test_convergence_absent_when_no_data():
	"""No convergence index -> cloudConvergence is None, rest still computed."""
	night = {"dark_window": {"start": "2026-05-29T04:00:00Z", "end": "2026-05-29T06:00:00Z"}}
	slc = [
		{"time": "2026-05-29T04:00:00", "cloud_cover": 11, "cloud_cover_low": 0,
		 "cloud_cover_mid": 0, "cloud_cover_high": 11, "temperature_2m": 12,
		 "dewpoint_2m": 8, "wind_speed_10m": 8, "wind_gusts_10m": 13,
		 "precipitation_probability": 5, "visibility": 24000,
		 "_seeing_raw": 4, "_transparency_raw": 3},
	]
	fx.enrich_night_factors(night, slc, {})
	assert night["displayFactors"]["cloudConvergence"] is None
	assert night["displayFactors"]["cloudPct"] == 11  # other factors unaffected
