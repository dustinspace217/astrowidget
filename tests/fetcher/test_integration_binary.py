"""
End-to-end integration test against the REAL compiled Dart scoring binary.

This is the committed, repeatable version of the spec-to-screen trace. It runs
the full fetcher pipeline (real merge + real subprocess to astrowidget-score +
real enrichment) with only the two network fetches mocked, and asserts that:
  - paid Astrospheric seeing/transparency reach state.json displayFactors with
    correct (inverted-polarity) labels — the CRIT-1 guard;
  - the narrowband score is tagged the heuristic method (Fix #5 guard);
  - the +2-night dark window is covered by the 4-day forecast (Fix #4 guard).

Skips cleanly (not fails) when the binary hasn't been built, so the unit suite
stays green on a fresh checkout. Build it with:
  cd scoring && dart pub get && dart build cli -t bin/score_location.dart -o /tmp/b \
    && cp /tmp/b/bundle/bin/score_location ../bin/astrowidget-score
"""

import contextlib
import json
import os
import subprocess
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

import pytest

import astrowidget_fetch as fx

pytestmark = pytest.mark.skipif(
	not fx.SCORING_BINARY.exists(),
	reason=f"scoring binary not built at {fx.SCORING_BINARY}",
)

# Fail-loud guard (QA 2026-06-09): same as test_scoring_redesign.py — with
# ASTROWIDGET_REQUIRE_BINARY=1 a missing binary is a collection error, so the
# end-to-end pipeline trace can't silently vanish as a skip in CI.
if os.environ.get("ASTROWIDGET_REQUIRE_BINARY") == "1" and not fx.SCORING_BINARY.exists():
	raise RuntimeError(
		f"ASTROWIDGET_REQUIRE_BINARY=1 but the scoring binary is missing at "
		f"{fx.SCORING_BINARY} — build it (see CLAUDE.md Key Commands)"
	)

# Anchor the fixture to the START of the current UTC day so the 96-hour (4-day)
# window always covers tonight + the next two nights relative to main()'s real
# now_utc. A hardcoded calendar date made this test rot: once real time advanced
# past the fixture window, the +2 night's dark window fell off the end and its
# hourly slice came back empty (displayFactors None). Anchoring to "now" keeps
# the same now_utc-relative alignment the test was written against, on any date.
_START = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
_N = 96


def _iso(i: int) -> str:
	return (_START + timedelta(hours=i)).strftime("%Y-%m-%dT%H:%M:%S")


def _fake_open_meteo(lat, lon):
	h = {"time": [_iso(i) for i in range(_N)]}
	for k, v in {
		"cloud_cover": 12, "cloud_cover_low": 0, "cloud_cover_mid": 3,
		"cloud_cover_high": 9, "relative_humidity_2m": 65, "temperature_2m": 11.0,
		"dewpoint_2m": 7.5, "wind_speed_10m": 9, "wind_gusts_10m": 14,
		"precipitation_probability": 5, "precipitation": 0, "visibility": 23000,
	}.items():
		h[k] = [v] * _N
	return {"hourly": h}


def _fake_astrospheric(key, lat, lon):
	# Real Astrospheric shape: value nested under Value.ActualValue + HourOffset.
	def col(v):
		return [
			{"Value": {"ActualValue": float(v), "ValueColor": "#000000"}, "HourOffset": i}
			for i in range(_N)
		]
	return {
		"TimeZone": "America/Los_Angeles", "UTCStartTime": _iso(0),
		"APICreditUsedToday": 5,
		"Astrospheric_Seeing": col(4),        # 4 -> "Above Average"
		"Astrospheric_Transparency": col(3),  # 3 -> "Excellent" (low = good)
		"RDPS_CloudCover": col(12), "RDPS_DewPoint": col(281.5),
		"RDPS_Temperature": col(284.0), "RDPS_WindVelocity": col(2.5),
		"RDPS_WindDirection": col(220),
	}


def _cfg():
	return {
		"api": {"astrospheric_key": "fake", "astrospheric_daily_credit_budget": 100},
		# Synthetic mid-latitude site (NOT a real location). lon -120 puts solar
		# midnight at ~08:00 UTC, which the precip-hour tests rely on; lat 45 has
		# astronomical dark in the fixture window. Real coordinates must never be
		# committed (this repo is public-bound) — see notes/local-context.md.
		"sites": [{"id": "site_a", "label": "Test Site", "lat": 45.0,
				   "lon": -120.0, "timezone": "America/Los_Angeles"}],
		"thresholds": {},
		"notifications": {"upward_transitions": False,
			"downward_transitions_day_of": False, "astro_dark_start_reminder": False},
	}


def _run_with_precip(tmp_path, precip_for_hour):
	"""Runs the full pipeline with a custom per-hour precip-probability pattern
	and returns tonight's night dict. `precip_for_hour(i)` returns the precip
	probability for hour index i (i=0 is 2026-05-29T00:00 UTC)."""
	def om(lat, lon):
		h = {"time": [_iso(i) for i in range(_N)]}
		for k, v in {
			"cloud_cover": 5, "cloud_cover_low": 0, "cloud_cover_mid": 0,
			"cloud_cover_high": 5, "relative_humidity_2m": 60, "temperature_2m": 12.0,
			"dewpoint_2m": 6.0, "wind_speed_10m": 5, "wind_gusts_10m": 8,
			"precipitation": 0, "visibility": 24000,
		}.items():
			h[k] = [v] * _N
		h["precipitation_probability"] = [precip_for_hour(i) for i in range(_N)]
		return {"hourly": h}

	with patch.object(fx, "load_config", return_value=_cfg()), \
		 patch.object(fx, "fetch_open_meteo", om), \
		 patch.object(fx, "fetch_astrospheric", _fake_astrospheric), \
		 patch.object(fx, "fetch_open_meteo_convergence", lambda *a, **k: {}), \
		 patch.object(fx, "CACHE_DIR", tmp_path), \
		 patch.object(fx, "STATE_PATH", tmp_path / "state.json"), \
		 patch.object(fx, "PREV_STATE_PATH", tmp_path / "state.prev.json"), \
		 patch.object(fx, "_notify", lambda *a, **k: None):
		fx.main()
	state = json.loads((tmp_path / "state.json").read_text())
	return state["sites"][0]["nights"][0]


def _precip_vetoed(night) -> bool:
	"""True if a precipitation veto fired for this night."""
	vetoes = night.get("broadband", {}).get("vetoes", [])
	return any(v.get("name") == "precipitation" for v in vetoes)


def test_daytime_rain_is_ignored(tmp_path):
	"""
	Rain ONLY in the solar afternoon (≈19-21h UTC for the lon -120 test site,
	scope covered) with dry overnight → NO precipitation veto. Proves the exposure
	window excludes daytime, per the user's "daytime rain while covered is
	fine" requirement.
	"""
	# 80% precip each day at solar afternoon; 0 overnight.
	night = _run_with_precip(tmp_path, lambda i: 80 if (i % 24) in (19, 20, 21) else 0)
	assert not _precip_vetoed(night), "daytime-only rain must NOT veto"
	# The peak over the EXPOSURE window is 0 — the daytime 80% is outside it.
	assert night["precip_peak_pct"] == 0
	assert night["displayFactors"]["precipPct"] == 0


def test_overnight_rain_peak_vetoes(tmp_path):
	"""
	A single 40% spike at solar midnight (≈8h UTC, scope uncovered), dry
	otherwise → precipitation veto fires. Proves PEAK (not average) over the
	sunset→sunrise exposure window: one risky overnight hour triggers
	protection even though the window average is tiny.
	"""
	night = _run_with_precip(tmp_path, lambda i: 40 if (i % 24) == 8 else 0)
	assert _precip_vetoed(night), "an overnight rain-chance peak must veto"
	assert night["recommendation"] == "Neither"
	# Step 5 end-to-end: the binary emits the exposure-window PEAK (40), and the
	# display now reflects that peak — NOT the dark-window average (a single 40%
	# hour over a ~6-8h window would average to ~5%). This proves enrich reads
	# precip_peak_pct, so the display and the veto agree on the same number.
	assert night["precip_peak_pct"] == 40
	assert night["displayFactors"]["precipPct"] == 40


def test_real_binary_pipeline_surfaces_astrospheric_and_tags(tmp_path):
	"""The committed spec-to-screen trace: paid astro data reaches the screen."""
	with patch.object(fx, "load_config", return_value=_cfg()), \
		 patch.object(fx, "fetch_open_meteo", _fake_open_meteo), \
		 patch.object(fx, "fetch_astrospheric", _fake_astrospheric), \
		 patch.object(fx, "fetch_open_meteo_convergence", lambda *a, **k: {}), \
		 patch.object(fx, "CACHE_DIR", tmp_path), \
		 patch.object(fx, "STATE_PATH", tmp_path / "state.json"), \
		 patch.object(fx, "PREV_STATE_PATH", tmp_path / "state.prev.json"), \
		 patch.object(fx, "_notify", lambda *a, **k: None):
		rc = fx.main()

	assert rc == 0
	state = json.loads((tmp_path / "state.json").read_text())
	assert state["schemaVersion"] == 2
	nights = state["sites"][0]["nights"]
	assert len(nights) == 3, "tonight + 2 nights"

	# CRIT-1 guard: seeing/transparency reach displayFactors with right labels.
	tonight = nights[0]
	df = tonight["displayFactors"]
	assert df is not None
	assert df["seeing"]["label"] == "Above Average"
	assert df["transparency"]["label"] == "Excellent"

	# Fix #5 guard: narrowband carries its method tag. nb-model-v1 (DEF-V2-03) — the NB
	# verdict is now a real forward model (NB-correct sky sub-score), not a re-weight.
	assert tonight["narrowband"]["method"] == "nb-model-v1"

	# Fix #4 guard: the +2 night has a real dark window (covered by 4-day fcst),
	# not a degenerate/empty one.
	plus2 = nights[2]
	assert plus2["dark_window"] is not None
	assert plus2["displayFactors"] is not None, "+2 night must be enriched, not truncated"


# ── FIRMS fire-proximity through the REAL binary (smoke feature) ──────────────


def _clear_om(lat, lon):
	"""A near-clear sky so the cloud gate is NOT the binding constraint, letting the
	transparency dock drive the narrowband score (so the NB-inheritance is visible)."""
	h = {"time": [_iso(i) for i in range(_N)]}
	for k, v in {
		"cloud_cover": 2, "cloud_cover_low": 0, "cloud_cover_mid": 0,
		"cloud_cover_high": 2, "relative_humidity_2m": 40, "temperature_2m": 15.0,
		"dewpoint_2m": 0.0, "wind_speed_10m": 6, "wind_gusts_10m": 10,
		"precipitation_probability": 0, "precipitation": 0, "visibility": 50000,
	}.items():
		h[k] = [v] * _N
	return {"hourly": h}


def _clear_aq(lat, lon):
	"""Clear AOD (0.05) so a transparency factor exists for the fire penalty to dock."""
	return {
		"time": [_iso(i) for i in range(_N)],
		"aerosol_optical_depth": [0.05] * _N,
		"us_aqi": [40] * _N, "pm2_5": [5.0] * _N,
	}


def _clear_astrospheric(key, lat, lon):
	"""Astrospheric fixture with near-clear cloud. The SCORING cloud comes from the
	Astrospheric RDPS_CloudCover (via the ensemble), not Open-Meteo's cloud_cover, so
	to keep the cloud gate from capping BOTH bands we must clear it here too."""
	base = _fake_astrospheric(key, lat, lon)
	base["RDPS_CloudCover"] = [
		{"Value": {"ActualValue": 2.0, "ValueColor": "#000000"}, "HourOffset": i}
		for i in range(_N)
	]
	return base


def _run_main_with_firms(tmp_path, cfg, firms_fn, om_fn=_fake_open_meteo,
						 aq_fn=None, astro_fn=_fake_astrospheric):
	"""Runs the full pipeline (REAL binary) with firms.fetch_fires_nearby patched to
	firms_fn (and optional om/air-quality/astrospheric fns), returning tonight's night."""
	patches = [
		patch.object(fx, "load_config", return_value=cfg),
		patch.object(fx, "fetch_open_meteo", om_fn),
		patch.object(fx, "fetch_astrospheric", astro_fn),
		patch.object(fx, "fetch_open_meteo_convergence", lambda *a, **k: {}),
		patch.object(fx.firms, "fetch_fires_nearby", firms_fn),
		patch.object(fx, "CACHE_DIR", tmp_path),
		patch.object(fx, "STATE_PATH", tmp_path / "state.json"),
		patch.object(fx, "PREV_STATE_PATH", tmp_path / "state.prev.json"),
		patch.object(fx, "_notify", lambda *a, **k: None),
	]
	if aq_fn is not None:
		patches.append(patch.object(fx, "fetch_open_meteo_air_quality", aq_fn))
	with contextlib.ExitStack() as stack:
		for p in patches:
			stack.enter_context(p)
		fx.main()
	return json.loads((tmp_path / "state.json").read_text())["sites"][0]["nights"][0]


def test_firms_fire_docks_both_bands_and_advises(tmp_path):
	"""The central integration claim, through the REAL binary: a nearby fire docks
	BOTH broadband and narrowband (NB inherits the docked transparency), the ⚠
	advisory reaches the reasons list, and the per-night smoke block carries
	firesNearby with main()'s stamped asOf."""
	cfg = _cfg()
	cfg["api"]["firms_map_key"] = "fakekey"
	fire = {"count": 5, "nearestKm": 10.0, "maxFrp": 200.0,
			"radiusKm": 150, "source": "VIIRS_NOAA20_NRT"}
	no_fire = _run_main_with_firms(
		tmp_path, cfg, lambda *a, **k: None, _clear_om, _clear_aq,
		astro_fn=_clear_astrospheric)
	with_fire = _run_main_with_firms(
		tmp_path, cfg, lambda *a, **k: dict(fire), _clear_om, _clear_aq,
		astro_fn=_clear_astrospheric)

	sn = with_fire["smoke"]["firesNearby"]
	assert sn["count"] == 5 and sn["asOf"], "smoke block + main()-stamped asOf"
	assert any("active fire" in r for r in with_fire["reasons"]), "advisory in reasons"
	assert (with_fire["broadband"]["factors"]["transparency"]
			< no_fire["broadband"]["factors"]["transparency"]), "broadband docked"
	assert with_fire["narrowband"]["score"] < no_fire["narrowband"]["score"], \
		"narrowband inherits the dock"


def test_firms_failure_flags_degraded_through_main(tmp_path):
	"""A genuine FIRMS failure (FirmsError) surfaces a meta.degraded firms entry —
	the user-visible 'fire check failed' notice — and never aborts the run."""
	cfg = _cfg()
	cfg["api"]["firms_map_key"] = "fakekey"

	def boom(*a, **k):
		raise fx.firms.FirmsError("scrubbed")

	_run_main_with_firms(tmp_path, cfg, boom)
	state = json.loads((tmp_path / "state.json").read_text())
	degraded = state["sites"][0]["meta"].get("degraded", [])
	assert any(d.get("source") == "firms" and d.get("code") == "firms_fetch_failed"
			   for d in degraded), "FIRMS failure must flag meta.degraded"


def test_binary_ignores_malformed_firesnearby(tmp_path):
	"""The wrapper's shape guard (SF-7): a non-map firesNearby in the scorer JSON is
	ignored (stderr diagnostic) and the site still scores, rather than crashing the
	binary. Exercised at the binary level — the fetcher never emits a malformed shape,
	so this guards the cross-language contract, not a reachable fetcher path."""
	now = datetime.now(timezone.utc)
	hourly = [{
		"time": _iso(i), "cloud_cover": 5, "cloud_cover_low": 0, "cloud_cover_mid": 0,
		"cloud_cover_high": 0, "relative_humidity_2m": 40, "temperature_2m": 12.0,
		"dewpoint_2m": 2.0, "wind_speed_10m": 5, "wind_gusts_10m": 8,
		"precipitation_probability": 0, "precipitation": 0, "visibility": 50000,
		"wind_speed_250hPa": 20,
	} for i in range(_N)]
	payload = {
		"now_utc": now.isoformat().replace("+00:00", "Z"),
		"sites": [{"id": "s", "label": "S", "lat": 45.0, "lon": -120.0,
				   "hourly": hourly, "firesNearby": ["not", "a", "map"]}],
	}
	out = subprocess.run(
		[str(fx.SCORING_BINARY)], input=json.dumps(payload).encode(),
		stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True)
	result = json.loads(out.stdout)
	assert result["sites"][0]["status"] == "ok", "malformed firesNearby must not crash"
