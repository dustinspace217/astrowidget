"""
Tests for the 7-site multi-source layer:

  - ensemble_cloud_by_hour: the AS Cloud Sense + Open-Meteo (NA) / Open-Meteo-only
    (international) consensus cloud, plus the per-model display dict.
  - build_7timer_by_hour + the 7Timer label mappers: international seeing/
    transparency on the INVERTED 1-8 scale (1 = best).
  - main() per-site source routing: an international site must skip Astrospheric
    entirely (no out-of-domain call, no credits) and use 7Timer.
"""

import json
from datetime import datetime, timezone
from unittest.mock import MagicMock, patch

import pytest

import astrowidget_fetch as fx


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────


def _as(value, offset):
	"""One Astrospheric hourly entry in the real nested shape."""
	return {"Value": {"ActualValue": float(value), "ValueColor": "#000000"}, "HourOffset": offset}


# ─────────────────────────────────────────────────────────────────────────────
# ensemble_cloud_by_hour
# ─────────────────────────────────────────────────────────────────────────────


def test_ensemble_na_means_cloudsense_plus_three_om_models():
	"""North-America: the scoring consensus is the equal-weight mean of four
	DISTINCT documented models — Astrospheric Cloud Sense (RDPS) + Open-Meteo
	GFS/ECMWF/ICON. Astrospheric's undocumented GFS rides along in per_model for
	display only, so the same model is never double-counted in the mean."""
	conv = {
		"time": ["2026-05-29T00:00:00", "2026-05-29T01:00:00"],
		"cloud_cover_gfs_seamless": [10, 20],
		"cloud_cover_ecmwf_ifs04": [30, 40],
		"cloud_cover_icon_seamless": [20, 30],
	}
	astro = {
		"UTCStartTime": "2026-05-29T00:00:00Z",
		"RDPS_CloudCover": [_as(40, 0), _as(60, 1)],   # Cloud Sense (scoring)
		"GFS_CloudCover": [_as(99, 0)],                # undocumented → display only
	}
	consensus, per_model = fx.ensemble_cloud_by_hour(astro, conv)
	h0 = fx._parse_utc_hour("2026-05-29T00:00:00")
	# Scoring mean: (cloudsense 40 + gfs 10 + ecmwf 30 + icon 20) / 4 = 25.
	assert consensus[h0] == 25.0
	# per_model carries the 4 scoring models PLUS the display-only as_gfs.
	assert per_model[h0]["cloudsense"] == 40
	assert per_model[h0]["gfs"] == 10
	assert per_model[h0]["ecmwf"] == 30
	assert per_model[h0]["icon"] == 20
	assert per_model[h0]["as_gfs"] == 99
	# The display-only AS GFS must NOT have entered the scoring mean (no
	# double-count): 25.0 already proves it (a 5-way mean incl. 99 would be 39.8).


def test_ensemble_international_is_open_meteo_only():
	"""International (astrospheric=None): consensus is the mean of the Open-Meteo
	models only; no Cloud Sense key appears."""
	conv = {
		"time": ["2026-05-29T00:00:00"],
		"cloud_cover_gfs_seamless": [10],
		"cloud_cover_ecmwf_ifs04": [30],
		"cloud_cover_icon_seamless": [20],
	}
	consensus, per_model = fx.ensemble_cloud_by_hour(None, conv)
	h0 = fx._parse_utc_hour("2026-05-29T00:00:00")
	assert consensus[h0] == 20.0   # (10 + 30 + 20) / 3
	assert set(per_model[h0].keys()) == {"gfs", "ecmwf", "icon"}
	assert "cloudsense" not in per_model[h0]


def test_ensemble_empty_inputs_yield_empty():
	"""No Astrospheric and no convergence → empty consensus (caller falls back to
	Open-Meteo's own cloud_cover in merge_hourly)."""
	consensus, per_model = fx.ensemble_cloud_by_hour(None, {})
	assert consensus == {}
	assert per_model == {}


def test_ensemble_tolerates_present_but_null_as_arrays():
	"""REGRESSION (2026-05-30 live-fetch crash): the real Astrospheric response
	sends the undocumented GFS_CloudCover / NAM_CloudCover as JSON null
	(present-but-None) for some coords/times. dict.get returns its default only
	for MISSING keys, so `.get(key, [])` returned None and `for item in None`
	raised TypeError on the very first live fetch. Present-but-null must be
	treated as absent — Cloud Sense alone still produces a consensus."""
	astro = {
		"UTCStartTime": "2026-05-29T00:00:00Z",
		"RDPS_CloudCover": [_as(30, 0)],
		"GFS_CloudCover": None,   # present but null — the exact crash trigger
		"NAM_CloudCover": None,
	}
	consensus, per_model = fx.ensemble_cloud_by_hour(astro, {})
	h0 = fx._parse_utc_hour("2026-05-29T00:00:00")
	assert consensus[h0] == 30.0           # Cloud Sense alone, no crash
	assert "as_gfs" not in per_model[h0]    # null GFS contributed nothing


def test_ensemble_tolerates_present_but_null_convergence_array():
	"""Same null-vs-missing trap on the Open-Meteo side: a model column present
	with a null value (a model out of coverage for these coords) must not crash
	the consensus build."""
	conv = {
		"time": ["2026-05-29T00:00:00"],
		"cloud_cover_gfs_seamless": [20],
		"cloud_cover_ecmwf_ifs04": None,   # present but null
	}
	consensus, per_model = fx.ensemble_cloud_by_hour(None, conv)
	h0 = fx._parse_utc_hour("2026-05-29T00:00:00")
	assert consensus[h0] == 20.0           # GFS alone, no crash
	assert "ecmwf" not in per_model[h0]


# ─────────────────────────────────────────────────────────────────────────────
# build_7timer_by_hour + label mappers
# ─────────────────────────────────────────────────────────────────────────────


def test_build_7timer_expands_3hourly_to_hourly():
	"""Each 3-hourly 7Timer point is expanded across its 3-hour block and keyed
	by UTC hour (init 'YYYYMMDDHH' + timepoint)."""
	parsed = {
		"init": "2026052900",   # 2026-05-29T00:00 UTC
		"dataseries": [
			{"timepoint": 3, "seeing": 2, "transparency": 1},
			{"timepoint": 6, "seeing": 5, "transparency": 4},
		],
	}
	out = fx.build_7timer_by_hour(parsed)
	# timepoint 3 -> 03:00 UTC, expanded across 03/04/05.
	for h in (3, 4, 5):
		assert out[datetime(2026, 5, 29, h, tzinfo=timezone.utc)] == (2.0, 1.0)
	# timepoint 6 -> 06:00 UTC.
	assert out[datetime(2026, 5, 29, 6, tzinfo=timezone.utc)] == (5.0, 4.0)


def test_build_7timer_bad_input_returns_empty():
	"""Unusable responses degrade to {} (caller shows '—', site still scores)."""
	assert fx.build_7timer_by_hour({}) == {}
	assert fx.build_7timer_by_hour({"init": "not-a-date", "dataseries": []}) == {}
	assert fx.build_7timer_by_hour({"init": "2026052900", "dataseries": "nope"}) == {}


def test_seventimer_labels_invert_scale():
	"""7Timer uses 1 = best, 8 = worst — the OPPOSITE of Astrospheric seeing.
	Getting this backwards would render the sky inverted."""
	assert fx.seventimer_seeing_label(1) == "Excellent"
	assert fx.seventimer_seeing_label(8) == "Cloudy"
	assert fx.seventimer_transparency_label(1) == "Excellent"
	assert fx.seventimer_transparency_label(8) == "Cloudy"
	# None -> dash; out-of-range clamps to [1, 8].
	assert fx.seventimer_seeing_label(None) == "—"
	assert fx.seventimer_seeing_label(0) == "Excellent"   # clamps up to 1
	assert fx.seventimer_seeing_label(99) == "Cloudy"     # clamps down to 8


# ─────────────────────────────────────────────────────────────────────────────
# main() source routing
# ─────────────────────────────────────────────────────────────────────────────


def _om_one_hour():
	"""Minimal Open-Meteo response with the single 04:00 UTC hour (inside the
	scoring stub's dark window)."""
	return {
		"hourly": {
			"time": ["2026-05-29T04:00:00"],
			"cloud_cover": [10], "cloud_cover_low": [0], "cloud_cover_mid": [0],
			"cloud_cover_high": [10], "relative_humidity_2m": [60],
			"temperature_2m": [12], "dewpoint_2m": [7], "wind_speed_10m": [5],
			"wind_gusts_10m": [8], "precipitation_probability": [5],
			"precipitation": [0], "visibility": [24000],
		}
	}


def _scoring_stub(sid):
	"""Minimal scoring output: one Tonight with a dark window over 04:00-10:00."""
	return {
		"schema_version": 1,
		"sites": [{
			"id": sid, "label": sid, "status": "ok",
			"nights": [{
				"label": "Tonight",
				"dark_window": {"start": "2026-05-29T04:00:00Z",
								"end": "2026-05-29T10:00:00Z", "duration_minutes": 360},
				"recommendation": "BB+NB",
				"broadband": {"score": 80, "verdict": "excellent", "vetoes": []},
				"narrowband": {"score": 85, "verdict": "excellent", "vetoes": []},
			}],
		}],
	}


def test_main_international_site_skips_astrospheric(tmp_path):
	"""A site outside Astrospheric's domain (Chile) must NOT call Astrospheric
	(its API errors out-of-domain), spends no credits, tags meta.source as the
	7Timer stack, and its 7Timer seeing reaches displayFactors with the INVERTED
	label scale. The seeing assertion also guards the fetch_7timer double-build
	regression (a re-wrapped lookup would come back empty → '—')."""
	cfg = {
		"api": {"astrospheric_key": "fake", "astrospheric_daily_credit_budget": 100},
		"open_meteo": {"models": []},
		"sites": [{
			"id": "chile", "label": "Deep Sky Chile", "lat": -33.0, "lon": -70.0,
			"timezone": "America/Santiago", "primary": True,
		}],
		"thresholds": {},
		"notifications": {"upward_transitions": False,
			"downward_transitions_day_of": False, "astro_dark_start_reminder": False},
	}
	astro_mock = MagicMock(name="fetch_astrospheric")
	seventimer = {fx._parse_utc_hour("2026-05-29T04:00:00"): (2, 1)}  # (seeing, transparency)

	with patch.object(fx, "load_config", return_value=cfg), \
		 patch.object(fx, "fetch_astrospheric", astro_mock), \
		 patch.object(fx, "fetch_open_meteo", return_value=_om_one_hour()), \
		 patch.object(fx, "fetch_open_meteo_convergence", lambda *a, **k: {}), \
		 patch.object(fx, "fetch_7timer", return_value=seventimer), \
		 patch.object(fx, "invoke_scoring_binary", return_value=_scoring_stub("chile")), \
		 patch.object(fx, "CACHE_DIR", tmp_path), \
		 patch.object(fx, "STATE_PATH", tmp_path / "state.json"), \
		 patch.object(fx, "PREV_STATE_PATH", tmp_path / "state.prev.json"), \
		 patch.object(fx, "_notify"):
		rc = fx.main()

	assert rc == 0
	astro_mock.assert_not_called()   # Astrospheric never touched for an intl site
	state = json.loads((tmp_path / "state.json").read_text())
	site = state["sites"][0]
	assert site["status"] == "ok"
	assert site["meta"]["source"] == "7timer+openmeteo"
	assert state["astrosphericCreditCost"] == 0          # no AS call → no credits
	# 7Timer seeing=2 on the inverted scale -> "Above Average" (NOT "Below
	# Average", which is what the Astrospheric scale would give for 2).
	df = site["nights"][0]["displayFactors"]
	assert df["seeing"]["label"] == "Above Average"
	assert df["transparency"]["label"] == "Excellent"   # 7Timer transparency 1 = best


def test_ensemble_na_with_empty_convergence_uses_cloudsense_alone():
	"""Reachable in production whenever the Open-Meteo convergence fetch fails on
	an NA site (its documented best-effort {} return): Astrospheric present,
	convergence empty → the consensus is Cloud Sense alone, not a crash."""
	astro = {
		"UTCStartTime": "2026-05-29T00:00:00Z",
		"RDPS_CloudCover": [_as(40, 0), _as(50, 1)],
	}
	consensus, per_model = fx.ensemble_cloud_by_hour(astro, {})
	h0 = fx._parse_utc_hour("2026-05-29T00:00:00")
	assert consensus[h0] == 40.0          # mean of a single model
	assert per_model[h0] == {"cloudsense": 40}


def test_ensemble_keeps_as_gfs_and_as_nam_distinct():
	"""The display per_model must carry as_gfs and as_nam as SEPARATE keys so the
	QML can map them to distinct labels. (An earlier QML key.split('_')[0]
	collapsed both to 'as'; the data layer keeps them distinct regardless.)"""
	conv = {"time": ["2026-05-29T00:00:00"], "cloud_cover_gfs_seamless": [10]}
	astro = {
		"UTCStartTime": "2026-05-29T00:00:00Z",
		"RDPS_CloudCover": [_as(40, 0)],
		"GFS_CloudCover": [_as(88, 0)],
		"NAM_CloudCover": [_as(77, 0)],
	}
	_, per_model = fx.ensemble_cloud_by_hour(astro, conv)
	h0 = fx._parse_utc_hour("2026-05-29T00:00:00")
	assert per_model[h0]["as_gfs"] == 88
	assert per_model[h0]["as_nam"] == 77


def test_build_7timer_rejects_bool_seeing():
	"""bool is an int subclass: a stray JSON true/false in a 7Timer numeric field
	must become None ('—'), NOT coerce to 1.0/0.0 and render a confident-but-
	wrong 'Excellent'/'Cloudy' label."""
	parsed = {
		"init": "2026052900",
		"dataseries": [{"timepoint": 0, "seeing": True, "transparency": 3}],
	}
	out = fx.build_7timer_by_hour(parsed)
	h0 = datetime(2026, 5, 29, 0, tzinfo=timezone.utc)
	assert out[h0] == (None, 3.0)   # bool seeing → None; real transparency kept


def test_main_mixed_na_and_international_in_one_run(tmp_path):
	"""One NA site + one international site in the SAME main() run must route
	INDEPENDENTLY: the NA site uses Astrospheric (spends credits, Astrospheric
	seeing scale), the international site uses 7Timer (no AS call, inverted
	scale). Guards against cross-wiring the per-site source/convergence dicts —
	the exact failure the 7-site routing could introduce."""
	cfg = {
		"api": {"astrospheric_key": "fake", "astrospheric_daily_credit_budget": 100},
		"open_meteo": {"models": []},
		"sites": [
			{"id": "na", "label": "NA Site", "lat": 45.0, "lon": -120.0,
			 "timezone": "UTC"},
			{"id": "intl", "label": "Intl Site", "lat": -33.0, "lon": -70.0,
			 "timezone": "UTC"},
		],
		"thresholds": {},
		"notifications": {"upward_transitions": False,
			"downward_transitions_day_of": False, "astro_dark_start_reminder": False},
	}
	as_calls = []
	def tracking_as(key, lat, lon):
		as_calls.append((lat, lon))
		return {
			"TimeZone": "UTC", "UTCStartTime": "2026-05-29T04:00:00Z",
			"APICreditUsedToday": 5,
			"Astrospheric_Seeing": [_as(2, 0)],          # AS scale: 2 = "Below Average"
			"Astrospheric_Transparency": [_as(3, 0)],
			"RDPS_CloudCover": [_as(20, 0)],
		}
	# 7Timer seeing=2 on the inverted scale = "Above Average" at the 04:00 hour.
	seventimer = {fx._parse_utc_hour("2026-05-29T04:00:00"): (2, 1)}
	scoring = {"schema_version": 1, "sites": [
		_scoring_stub("na")["sites"][0], _scoring_stub("intl")["sites"][0]]}

	with patch.object(fx, "load_config", return_value=cfg), \
		 patch.object(fx, "fetch_astrospheric", tracking_as), \
		 patch.object(fx, "fetch_open_meteo", return_value=_om_one_hour()), \
		 patch.object(fx, "fetch_open_meteo_convergence", lambda *a, **k: {}), \
		 patch.object(fx, "fetch_7timer", return_value=seventimer), \
		 patch.object(fx, "invoke_scoring_binary", return_value=scoring), \
		 patch.object(fx, "CACHE_DIR", tmp_path), \
		 patch.object(fx, "STATE_PATH", tmp_path / "state.json"), \
		 patch.object(fx, "PREV_STATE_PATH", tmp_path / "state.prev.json"), \
		 patch.object(fx, "_notify"):
		rc = fx.main()

	assert rc == 0
	# Astrospheric was called for the NA site ONLY (one call, with NA coords).
	assert as_calls == [(45.0, -120.0)]
	state = json.loads((tmp_path / "state.json").read_text())
	by_id = {s["id"]: s for s in state["sites"]}
	assert by_id["na"]["meta"]["source"] == "astrospheric+openmeteo"
	assert by_id["intl"]["meta"]["source"] == "7timer+openmeteo"
	assert state["astrosphericCreditCost"] == 5   # only the NA site spent credits
	# SAME raw seeing=2, but DIFFERENT labels — each site used its own scale,
	# proving the per-site st_source wasn't cross-wired.
	assert by_id["na"]["nights"][0]["displayFactors"]["seeing"]["label"] == "Below Average"
	assert by_id["intl"]["nights"][0]["displayFactors"]["seeing"]["label"] == "Above Average"


@pytest.fixture
def intl_cfg():
	"""Single-international-site config (Deep Sky Chile). A fixture because it's
	shared test CONTEXT two tests run inside — distinct from the pure value
	builders above (_as / _om_one_hour / _scoring_stub), which stay plain
	functions. Function-scoped, so each test gets a fresh dict (no leak)."""
	return {
		"api": {"astrospheric_key": "fake", "astrospheric_daily_credit_budget": 100},
		"open_meteo": {"models": []},
		"sites": [{"id": "chile", "label": "Deep Sky Chile", "lat": -33.0, "lon": -70.0,
				   "timezone": "America/Santiago", "primary": True}],
		"thresholds": {},
		"notifications": {"upward_transitions": False,
			"downward_transitions_day_of": False, "astro_dark_start_reminder": False},
	}


def test_main_international_7timer_down_sets_degraded(intl_cfg, tmp_path):
	"""When fetch_7timer returns {} (its failure mode), the site's meta carries
	degraded=['7timer'] so the widget shows the "7Timer unavailable" badge
	instead of a silent "—". The site still scores on Open-Meteo cloud, so its
	status stays ok — the degradation is partial, not a site failure."""
	with patch.object(fx, "load_config", return_value=intl_cfg), \
		 patch.object(fx, "fetch_astrospheric", MagicMock()), \
		 patch.object(fx, "fetch_open_meteo", return_value=_om_one_hour()), \
		 patch.object(fx, "fetch_open_meteo_convergence", lambda *a, **k: {}), \
		 patch.object(fx, "fetch_7timer", return_value={}), \
		 patch.object(fx, "invoke_scoring_binary", return_value=_scoring_stub("chile")), \
		 patch.object(fx, "CACHE_DIR", tmp_path), \
		 patch.object(fx, "STATE_PATH", tmp_path / "state.json"), \
		 patch.object(fx, "PREV_STATE_PATH", tmp_path / "state.prev.json"), \
		 patch.object(fx, "_notify"):
		assert fx.main() == 0
	site = json.loads((tmp_path / "state.json").read_text())["sites"][0]
	assert site["status"] == "ok"
	assert site["meta"]["degraded"] == [{"source": "7timer"}]


def test_main_international_7timer_up_no_degraded(intl_cfg, tmp_path):
	"""When 7Timer returns data, meta carries no 'degraded' key (no badge)."""
	seventimer = {fx._parse_utc_hour("2026-05-29T04:00:00"): (2, 1)}
	with patch.object(fx, "load_config", return_value=intl_cfg), \
		 patch.object(fx, "fetch_astrospheric", MagicMock()), \
		 patch.object(fx, "fetch_open_meteo", return_value=_om_one_hour()), \
		 patch.object(fx, "fetch_open_meteo_convergence", lambda *a, **k: {}), \
		 patch.object(fx, "fetch_7timer", return_value=seventimer), \
		 patch.object(fx, "invoke_scoring_binary", return_value=_scoring_stub("chile")), \
		 patch.object(fx, "CACHE_DIR", tmp_path), \
		 patch.object(fx, "STATE_PATH", tmp_path / "state.json"), \
		 patch.object(fx, "PREV_STATE_PATH", tmp_path / "state.prev.json"), \
		 patch.object(fx, "_notify"):
		assert fx.main() == 0
	assert "degraded" not in json.loads((tmp_path / "state.json").read_text())["sites"][0]["meta"]
