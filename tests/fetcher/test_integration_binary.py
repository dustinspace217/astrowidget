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


def _run_with_precip(tmp_path, precip_for_hour, night_index=0):
	"""Runs the full pipeline with a custom per-hour precip-probability pattern
	and returns the night dict at `night_index` (0=Tonight, 1=+1 night).
	`precip_for_hour(i)` returns the precip probability for hour index i
	(i=0 is midnight UTC today).

	NOTE this harness runs fx.main(), so now_utc is the REAL wall clock — a
	test whose assertion depends on where "now" falls inside Tonight's window
	must either use night_index=1 (always fully in the future) or the
	controlled-now _run_binary_direct harness below."""
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
	return state["sites"][0]["nights"][night_index]


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

	Asserted on the +1 NIGHT: its window is always entirely in the future, so
	the remaining-night clamp (vetoes ignore already-elapsed hours,
	2026-08-20) never touches the spike regardless of when the suite runs.
	Tonight's spike may already be in the past mid-night — that behavior has
	its own controlled-now tests below.
	"""
	night = _run_with_precip(tmp_path, lambda i: 40 if (i % 24) == 8 else 0,
							 night_index=1)
	assert _precip_vetoed(night), "an overnight rain-chance peak must veto"
	assert night["recommendation"] == "Neither"
	# Step 5 end-to-end: the binary emits the exposure-window PEAK (40), and the
	# display now reflects that peak — NOT the dark-window average (a single 40%
	# hour over a ~6-8h window would average to ~5%). This proves enrich reads
	# precip_peak_pct, so the display and the veto agree on the same number.
	assert night["precip_peak_pct"] == 40
	assert night["displayFactors"]["precipPct"] == 40


# ─────────────────────────────────────────────────────────────────────────────
# Direct-binary invocation with a CONTROLLED now_utc — the only way to test
# behavior that depends on how much of the night has already elapsed (the
# _run_with_precip harness runs fx.main(), whose now is the real wall clock).
# ─────────────────────────────────────────────────────────────────────────────

# Fixture calendar: 96 hours from 2026-04-10T00:00Z at the synthetic lat 45 /
# lon -120 site (solar midnight ≈ 08:00Z). For the night of Apr 10→11:
# sunset ≈ 02:45Z, astro dark ≈ 04:30Z→11:40Z, sunrise ≈ 13:25Z (Apr 11).
_DB_START = datetime(2026, 4, 10, 0, 0, tzinfo=timezone.utc)


def _run_binary_direct(now_utc_iso, precip_for_hour=None, override_for_hour=None):
	"""Invoke the REAL scoring binary directly with a fully-controlled now_utc
	and a custom per-hour precip pattern (index 0 = 2026-04-10T00:00Z).
	`override_for_hour(i)` may return a dict merged over row i, for tests that
	drive wind/dewpoint instead of precip. Returns tonight's night dict from
	the binary's own output."""
	precip_for_hour = precip_for_hour or (lambda i: 0)
	hours = []
	for i in range(96):
		t = _DB_START + timedelta(hours=i)
		row = {
			"time": t.strftime("%Y-%m-%dT%H:%M:%S"),
			"cloud_cover": 5, "cloud_cover_low": 0, "cloud_cover_mid": 0,
			"cloud_cover_high": 5, "relative_humidity_2m": 60,
			"temperature_2m": 12.0, "dewpoint_2m": 6.0,
			"wind_speed_10m": 5, "wind_gusts_10m": 8,
			"precipitation_probability": precip_for_hour(i),
			"precipitation": 0, "visibility": 24000,
		}
		if override_for_hour:
			row.update(override_for_hour(i) or {})
		hours.append(row)
	payload = {"now_utc": now_utc_iso, "sites": [{
		"id": "site_a", "label": "Test Site", "lat": 45.0, "lon": -120.0,
		"thresholds": {}, "hourly": hours, "bortle": 4, "nb_leakage": 0.38,
		"managed": False, "airQuality": [], "firesNearby": None,
	}]}
	proc = subprocess.run(
		[str(fx.SCORING_BINARY)], input=json.dumps(payload).encode(),
		capture_output=True, timeout=120)
	assert proc.returncode == 0, proc.stderr.decode()
	return json.loads(proc.stdout)["sites"][0]["nights"][0]


# Evening rain (03-05Z ≈ twilight/early dark, inside sunset→sunrise) for the
# Apr 10→11 night; bone dry after. Indices 27-29 = Apr 11 03:00-05:00Z.
_EVENING_RAIN = lambda i: 60 if i in (27, 28, 29) else 0  # noqa: E731


def test_past_rain_hours_do_not_veto_the_remaining_night():
	"""
	THE 2026-08-20 CSV incident: a 27% evening shower had already PASSED when
	the 1 AM fetch ran, the rest of the night was clear — and the veto still
	warned about it until sunrise. Rain confined to hours that have already
	elapsed at now_utc must neither veto nor appear as the displayed peak:
	the veto protects the night AHEAD, and past rain either fell or didn't.
	"""
	night = _run_binary_direct("2026-04-11T09:00:00Z", _EVENING_RAIN)
	assert not _precip_vetoed(night), \
		"rain that already passed must not veto the clear remaining night"
	assert night["precip_peak_pct"] == 0


def test_upcoming_evening_rain_still_vetoes_at_sunset():
	"""Control for the past-hours clamp: the SAME evening rain, evaluated just
	after sunset while it is still ahead, must veto exactly as before."""
	night = _run_binary_direct("2026-04-11T02:50:00Z", _EVENING_RAIN)
	assert _precip_vetoed(night), "upcoming overnight rain must still veto"
	assert night["precip_peak_pct"] == 60


def test_rain_in_the_current_hour_still_vetoes():
	"""The in-progress hour is NOT past: a fetch at 04:30Z with rain in the
	04:00Z hour row must keep the veto (conservative equipment protection —
	the hour containing 'now' is partly ahead)."""
	night = _run_binary_direct("2026-04-11T04:30:00Z",
							   lambda i: 60 if i == 28 else 0)
	assert _precip_vetoed(night), "the hour containing now must still count"
	assert night["precip_peak_pct"] == 60


def test_hour_boundary_drop_and_keep_sides():
	"""Pins the clamp's hour boundary from BOTH sides (QA VTA-2): at exactly
	05:00:00Z the 04:00Z row is one full hour old → dropped; at exactly
	04:00:00Z the 04:00Z row IS the current hour → kept. A clamp loosened by
	one hour ("keep the previous hour too") goes red on the drop side."""
	rain_at_28 = lambda i: 60 if i == 28 else 0  # noqa: E731
	dropped = _run_binary_direct("2026-04-11T05:00:00Z", rain_at_28)
	assert not _precip_vetoed(dropped)
	assert dropped["precip_peak_pct"] == 0
	kept = _run_binary_direct("2026-04-11T04:00:00Z", rain_at_28)
	assert _precip_vetoed(kept)
	assert kept["precip_peak_pct"] == 60


def _vetoed_by(night, name) -> bool:
	"""True if a veto with this name fired for the night."""
	return any(v.get("name") == name
			   for v in night.get("broadband", {}).get("vetoes", []))


def test_past_wind_does_not_veto_but_upcoming_wind_does():
	"""The wind clamp, pinned from both sides (QA VTA-1: reverting the wind
	veto to whole-window hours while keeping the precip clamp must go red).
	60 km/h (over the 40 default) at 05-06Z inside the dark window: already
	past at 09:00Z → no veto; still ahead at 04:30Z → veto."""
	gusty_early = lambda i: {"wind_speed_10m": 60} if i in (29, 30) else None  # noqa: E731
	calm_rest = _run_binary_direct("2026-04-11T09:00:00Z",
								   override_for_hour=gusty_early)
	assert not _vetoed_by(calm_rest, "wind"), \
		"a gust front that already passed must not veto the calm remainder"
	ahead = _run_binary_direct("2026-04-11T04:30:00Z",
							   override_for_hour=gusty_early)
	assert _vetoed_by(ahead, "wind"), "upcoming over-threshold wind must veto"


def test_past_dew_hours_do_not_drag_the_condensation_average():
	"""The condensation clamp (QA VTA-1). Condensation is an AVERAGE veto, so
	the pin is about the average's population: wet early hours (spread 0°C at
	05-07Z) pull the WHOLE-window average to ~1.14°C (< the 1.5 default) while
	the remaining hours alone average 2.0°C (>= threshold). Evaluated mid-night
	at 08:00Z the passed wet hours must be excluded → no veto; evaluated at
	04:30Z with the wet stretch still ahead → veto."""
	def dew(i):
		if i in (29, 30, 31):
			return {"dewpoint_2m": 12.0}   # spread 0.0 — condensation-wet
		if 32 <= i <= 35:
			return {"dewpoint_2m": 10.0}   # spread 2.0 — safely dry
		return None
	later = _run_binary_direct("2026-04-11T08:00:00Z", override_for_hour=dew)
	assert not _vetoed_by(later, "condensation"), \
		"passed damp hours must not drag the remaining night's average under"
	ahead = _run_binary_direct("2026-04-11T04:30:00Z", override_for_hour=dew)
	assert _vetoed_by(ahead, "condensation"), \
		"an upcoming damp stretch must still veto"


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
	assert tonight["narrowband"]["method"] == "retention-v2"

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


def _clear_hourly(start, n=110):
	"""n clear-sky hourly entries from `start` (UTC) — enough to cover several scored nights."""
	out = []
	for i in range(n):
		t = (start + timedelta(hours=i)).isoformat().replace("+00:00", "Z")
		out.append({"time": t, "cloud_cover": 3, "cloud_cover_low": 0,
					"cloud_cover_mid": 0, "cloud_cover_high": 0,
					"relative_humidity_2m": 35, "temperature_2m": 14.0,
					"dewpoint_2m": 1.0, "wind_speed_10m": 6, "wind_gusts_10m": 9,
					"precipitation_probability": 0, "precipitation": 0,
					"visibility": 60000, "wind_speed_250hPa": 18})
	return out


def _run_clear_nights(now_utc):
	"""Score a clear-sky site at lat 45 from now_utc; return its nights (real moon ephemeris)."""
	start = datetime.fromisoformat(now_utc.replace("Z", "+00:00"))
	payload = {"now_utc": now_utc, "sites": [{"id": "s", "label": "S", "lat": 45.0,
			   "lon": -120.0, "hourly": _clear_hourly(start), "firesNearby": None}]}
	out = subprocess.run([str(fx.SCORING_BINARY)], input=json.dumps(payload).encode(),
						 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True)
	return json.loads(out.stdout)["sites"][0]["nights"]


def test_partial_moon_emits_moonfree_window_and_bb():
	"""Moon-window feature (2026-06-29): a waning night (moon down for the early hours)
	surfaces a usable moon-free window + a Moon-free BB score, and every night carries
	moon.freeFraction. Uses real moon ephemeris (deterministic)."""
	nights = _run_clear_nights("2026-07-07T20:00:00Z")
	assert nights, "expected scored nights"
	for n in nights:
		assert isinstance(n["moon"]["freeFraction"], (int, float))
	withgap = [n for n in nights if n["moonFreeBroadband"] is not None]
	assert withgap, "expected at least one partial-moon night with Moon-free BB"
	n = withgap[0]
	assert 0 < n["moon"]["freeFraction"] < 1
	assert n["moon"]["freeWindow"] is not None
	mfb = n["moonFreeBroadband"]
	assert isinstance(mfb["score"], int)
	assert mfb["window"]["start"] < mfb["window"]["end"]
	# The load-bearing claim (QA 2026-07-01): on a CLEAR partial-moon night the moon-free
	# gap must score ABOVE the moon-averaged headline — that's the whole point of the
	# third number. (Clear fixture → the gap can't be the cloudy part.)
	assert mfb["score"] > n["broadband"]["score"], (
		f"moon-free BB {mfb['score']} should beat the moonlit headline "
		f"{n['broadband']['score']} on a clear night"
	)


def test_subhour_moonfree_gap_is_suppressed():
	"""A near-full night whose only moon-free time is a sub-hour dawn sliver reports the
	true proportion but does NOT surface a (degenerate-stability) Moon-free BB."""
	tonight = _run_clear_nights("2026-07-03T20:00:00Z")[0]
	assert tonight["moon"]["freeFraction"] < 0.05  # moon up ~all night
	assert tonight["moonFreeBroadband"] is None
	assert tonight["moon"]["freeWindow"] is None


def _run_night(now_utc, cloud_pct):
	"""One scored night at lat 45, Bortle 2, uniform cloud_pct (real moon ephemeris)."""
	start = datetime.fromisoformat(now_utc.replace("Z", "+00:00"))
	hourly = _clear_hourly(start)
	for h in hourly:
		h["cloud_cover"] = cloud_pct
		h["cloud_cover_high"] = cloud_pct
	payload = {"now_utc": now_utc, "sites": [{"id": "s", "label": "S", "lat": 45.0,
			   "lon": -120.0, "bortle": 2, "hourly": hourly, "firesNearby": None}]}
	out = subprocess.run([str(fx.SCORING_BINARY)], input=json.dumps(payload).encode(),
						 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True)
	return json.loads(out.stdout)["sites"][0]["nights"][0]


# Real lunar anchors for the four-corner test: 2026-06-29 is a FULL moon (up all night);
# 2026-07-14 is a NEW moon (down all night). Deterministic ephemeris, and each test
# verifies its anchor via the emitted moon block so a wrong date fails loudly.
_FULL = "2026-06-29T20:00:00Z"
_NEW = "2026-07-14T20:00:00Z"


def test_four_corner_ordering_through_real_binary():
	"""Dustin's retention-v2 acceptance test (spec 2026-07-01): effects COMPOUND.
	moonless-cloudless best > each single-problem night > fullmoon-cloudy worst."""
	best = _run_night(_NEW, 3)
	moony = _run_night(_FULL, 3)
	cloudy = _run_night(_NEW, 55)
	worst = _run_night(_FULL, 55)
	# guard the ephemeris anchors (loud, not silent):
	assert best["moon"]["illumination_pct"] < 15
	assert moony["moon"]["illumination_pct"] > 90

	def bb(n):
		return n["broadband"]["score"]
	assert bb(best) > bb(moony), "full moon must crunch a clear night"
	assert bb(best) > bb(cloudy), "cloud must crunch a moonless night"
	assert bb(moony) > bb(worst), "cloud must compound ON TOP of the moon"
	assert bb(cloudy) > bb(worst), "the moon must compound ON TOP of cloud"


def test_scoring_audit_block_and_product_identity():
	"""Auditability (Dustin 2026-07-01): the scoring block carries every input + retention,
	and score == round(100 × Π retentions) holds for both bands (±1 for the 3-decimal
	rounding of the emitted retentions)."""
	night = _run_night(_FULL, 3)
	sc = night["scoring"]
	assert sc["model"] == "retention-v2"
	for band in ("broadband", "narrowband"):
		rets = sc[band]["retentions"]
		prod = 1.0
		for key in ("timeCloud", "sky", "transparency", "seeing"):
			assert 0.0 <= rets[key] <= 1.0
			prod *= rets[key]
		assert abs(night[band]["score"] - round(100 * prod)) <= 1
	inputs = sc["inputs"]
	assert inputs["moonAvgBurden"] > 0.2  # full-moon night: real burden, visible for audit
	assert inputs["bortle"] == 2
	assert "cloudFactor" in inputs and "stabilityFactor" in inputs


def test_overcast_still_craters_no_green_regression():
	"""The no-green-under-overcast incident guard, retention-v2 form: near-total overcast
	→ the time retention floors the composite regardless of a perfect moonless sky."""
	night = _run_night(_NEW, 97)
	assert night["broadband"]["score"] <= 10
	assert night["narrowband"]["score"] <= 10
	assert night["recommendation"] == "Neither"


def test_fire_docks_transparency_without_aod_through_binary():
	"""The v2 spec deviation, locked at the binary level (QA 2026-07-01): a nearby fire
	docks the transparency retention EVEN WITH NO AOD data. v1 refused (a fabricated
	factor could raise the weighted mean); a multiplicative dock can only lower — and
	the original smoke incident was a fire with under-resolved AOD. No airQuality is
	sent here, so the dock below is attributable to the fire alone."""
	start = datetime.fromisoformat(_NEW.replace("Z", "+00:00"))
	fires = {"count": 12, "nearestKm": 40.0, "maxFrp": 80.0, "radiusKm": 150,
			 "source": "VIIRS_NOAA20_NRT", "asOf": _NEW}
	payload = {"now_utc": _NEW, "sites": [{"id": "s", "label": "S", "lat": 45.0,
			   "lon": -120.0, "bortle": 2, "hourly": _clear_hourly(start),
			   "firesNearby": fires}]}
	out = subprocess.run([str(fx.SCORING_BINARY)], input=json.dumps(payload).encode(),
						 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True)
	night = json.loads(out.stdout)["sites"][0]["nights"][0]
	sc = night["scoring"]
	assert sc["inputs"]["aodMean"] is None  # genuinely no AOD in this run
	assert sc["inputs"]["firePenalty"] > 0  # the fire registered
	assert sc["broadband"]["retentions"]["transparency"] < 1.0  # and it docked
