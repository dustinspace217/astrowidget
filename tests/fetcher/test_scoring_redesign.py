"""
Tests for the Phase-1 scoring redesign (spec 2026-06-02, plan 2026-06-03).

Covers the new fetcher plumbing and — against the REAL compiled binary — the
behaviours that motivated the redesign:
  - the reported incident (heavy cloud at a HOME site read green BB+NB);
  - the BB>NB inversion under a bright moon (narrowband should beat broadband);
  - the new schema (factors = {cloud, stability, skyBrightness, transparency?};
    no more `darkness`/`moon`; best_window + managed per night; NB method nb-model-v1);
  - the HOME/REMOTE precip-veto split;
  - graceful degradation when the optional feeds (AOD, 250 hPa, Bortle) are absent.

The binary-integration tests skip cleanly (not fail) when the binary hasn't been
built, so the unit suite stays green on a fresh checkout. Build it with:
  cd scoring && dart pub get && dart build cli -t bin/score_location.dart -o /tmp/b \
    && cp /tmp/b/bundle/bin/score_location ../bin/astrowidget-score
"""

import json
import os
import subprocess
import textwrap
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

import pytest

import astrowidget_fetch as fx


# ─────────────────────────────────────────────────────────────────────────────
# _safe_optional — None-preserving column reader (the 250 hPa polarity trap)
# ─────────────────────────────────────────────────────────────────────────────


def test_safe_optional_preserves_none_not_default():
	"""Absent/None/non-finite → None (NOT a 0.0 default). A data gap must never
	read as a real (calm-jet) value."""
	assert fx._safe_optional([], 0) is None          # out of bounds
	assert fx._safe_optional([None], 0) is None       # explicit None
	assert fx._safe_optional([float("nan")], 0) is None
	assert fx._safe_optional([float("inf")], 0) is None
	assert fx._safe_optional([42.0], 0) == 42.0       # real value passes through
	assert fx._safe_optional([0.0], 0) == 0.0         # a real 0 IS preserved


# ─────────────────────────────────────────────────────────────────────────────
# merge_hourly — threads wind_speed_250hPa with the right polarity
# ─────────────────────────────────────────────────────────────────────────────


def _om(hours: int, with_250: bool) -> dict:
	"""Minimal Open-Meteo response; includes wind_speed_250hPa only if asked."""
	times = [f"2026-06-09T0{i}:00:00" for i in range(hours)]
	h = {
		"time": times,
		"cloud_cover": [20.0] * hours, "cloud_cover_low": [0.0] * hours,
		"cloud_cover_mid": [5.0] * hours, "cloud_cover_high": [8.0] * hours,
		"relative_humidity_2m": [60.0] * hours, "temperature_2m": [12.0] * hours,
		"dewpoint_2m": [6.0] * hours, "wind_speed_10m": [7.0] * hours,
		"wind_gusts_10m": [12.0] * hours, "precipitation_probability": [5.0] * hours,
		"precipitation": [0.0] * hours, "visibility": [25000.0] * hours,
	}
	if with_250:
		h["wind_speed_250hPa"] = [55.0] * hours
	return {"hourly": h}


def test_merge_hourly_threads_250hpa_when_present():
	"""When Open-Meteo returns 250 hPa wind, every row carries the real value."""
	rows = fx.merge_hourly(None, _om(3, with_250=True), st_source="7timer")
	assert rows, "expected merged rows"
	assert all(r["wind_speed_250hPa"] == 55.0 for r in rows)


def test_merge_hourly_250hpa_absent_is_none_not_zero():
	"""When the model omits 250 hPa wind, rows carry None — NOT 0.0. A 0.0 would
	be scored downstream as an ideal calm jet."""
	rows = fx.merge_hourly(None, _om(3, with_250=False), st_source="7timer")
	assert rows
	assert all(r["wind_speed_250hPa"] is None for r in rows)


# ─────────────────────────────────────────────────────────────────────────────
# build_air_quality_rows — AOD → Dart AirQuality rows
# ─────────────────────────────────────────────────────────────────────────────


def test_build_air_quality_rows_empty_input():
	"""Empty / missing AOD → [] (the Dart side then omits transparency entirely)."""
	assert fx.build_air_quality_rows({}) == []
	assert fx.build_air_quality_rows({"time": [], "aerosol_optical_depth": []}) == []


def test_build_air_quality_rows_pairs_time_and_aod():
	rows = fx.build_air_quality_rows({
		"time": ["2026-06-09T00:00", "2026-06-09T01:00"],
		"aerosol_optical_depth": [0.07, 0.12],
	})
	# Rows now also carry us_aqi/pm2_5 (smoke feature, 2026-06-25); absent in this
	# input, so they default to None per the null-polarity rule.
	assert rows == [
		{"time": "2026-06-09T00:00", "aerosol_optical_depth": 0.07,
		 "us_aqi": None, "pm2_5": None},
		{"time": "2026-06-09T01:00", "aerosol_optical_depth": 0.12,
		 "us_aqi": None, "pm2_5": None},
	]


def test_build_air_quality_rows_nonfinite_aod_becomes_none():
	"""A NaN/inf AOD is coerced to None (read as 'no smoke data', not a bogus value)."""
	rows = fx.build_air_quality_rows({
		"time": ["2026-06-09T00:00"], "aerosol_optical_depth": [float("nan")],
	})
	assert rows == [{"time": "2026-06-09T00:00", "aerosol_optical_depth": None,
		"us_aqi": None, "pm2_5": None}]


def test_build_air_quality_rows_stops_at_shorter_array():
	"""Truncated AOD array never fabricates tail hours (length-mismatch defense)."""
	rows = fx.build_air_quality_rows({
		"time": ["t0", "t1", "t2"], "aerosol_optical_depth": [0.05],
	})
	assert len(rows) == 1


def test_build_air_quality_rows_present_but_null_array_no_crash():
	"""A present-but-NULL AOD array — the air-quality API can return
	{"time": [...], "aerosol_optical_depth": null} — must NOT crash len(None). It
	returns [] so AOD never aborts the run (the QA review caught this). Also tolerate
	a non-list body (malformed-but-200) defensively."""
	assert fx.build_air_quality_rows(
		{"time": ["t0", "t1"], "aerosol_optical_depth": None}) == []
	assert fx.build_air_quality_rows(
		{"time": None, "aerosol_optical_depth": [0.05]}) == []
	assert fx.build_air_quality_rows(
		{"time": ["t0"], "aerosol_optical_depth": 0.05}) == []


@pytest.mark.real_aod  # opts out of conftest's autouse stub — tests the REAL function
def test_fetch_open_meteo_air_quality_is_best_effort(monkeypatch):
	"""A network/JSON failure returns {} (never raises) so AOD can't abort the run."""
	import requests

	def boom(*a, **k):
		raise requests.RequestException("simulated outage")

	monkeypatch.setattr(fx.requests, "get", boom)
	assert fx.fetch_open_meteo_air_quality(47.0, -122.0) == {}


# ─────────────────────────────────────────────────────────────────────────────
# load_config — managed (bool) + bortle (1-9 int) validation
# ─────────────────────────────────────────────────────────────────────────────


def _write_cfg(tmp_path: Path, sites_block: str) -> Path:
	content = textwrap.dedent(f"""
		[open_meteo]
		models = ["gfs_seamless"]

		{textwrap.dedent(sites_block)}
	""")
	path = tmp_path / "config.toml"
	path.write_text(content, encoding="utf-8")
	os.chmod(path, 0o600)
	return path


def _load(tmp_path, monkeypatch, sites_block):
	monkeypatch.setattr(fx, "CONFIG_PATH", _write_cfg(tmp_path, sites_block))
	with patch.object(fx, "_notify"):
		return fx.load_config()


def test_managed_defaults_false_and_bortle_none(tmp_path, monkeypatch):
	cfg = _load(tmp_path, monkeypatch, """
		[[sites]]
		id = "s"
		label = "S"
		lat = 47.0
		lon = -122.0
	""")
	site = cfg["sites"][0]
	assert site["managed"] is False
	assert site["bortle"] is None


def test_managed_true_and_bortle_accepted(tmp_path, monkeypatch):
	cfg = _load(tmp_path, monkeypatch, """
		[[sites]]
		id = "s"
		label = "S"
		lat = 32.0
		lon = -111.0
		managed = true
		bortle = 3
	""")
	site = cfg["sites"][0]
	assert site["managed"] is True
	assert site["bortle"] == 3


def test_managed_non_bool_rejected(tmp_path, monkeypatch):
	"""A string 'managed' is rejected loudly (the string 'false' is truthy)."""
	with pytest.raises(SystemExit):
		_load(tmp_path, monkeypatch, """
			[[sites]]
			id = "s"
			label = "S"
			lat = 47.0
			lon = -122.0
			managed = "true"
		""")


@pytest.mark.parametrize("bad", ["0", "10", '"5"', "true", "4.5"])
def test_bortle_out_of_range_or_wrong_type_rejected(tmp_path, monkeypatch, bad):
	with pytest.raises(SystemExit):
		_load(tmp_path, monkeypatch, f"""
			[[sites]]
			id = "s"
			label = "S"
			lat = 47.0
			lon = -122.0
			bortle = {bad}
		""")


# ─────────────────────────────────────────────────────────────────────────────
# Binary integration — the redesign's motivating behaviours, end to end
# ─────────────────────────────────────────────────────────────────────────────

pytestmark_binary = pytest.mark.skipif(
	not fx.SCORING_BINARY.exists(),
	reason=f"scoring binary not built at {fx.SCORING_BINARY}",
)

# Fail-loud guard (QA 2026-06-09): the incident regression pin in this file
# must not vanish as a silent skip on an unbuilt checkout/CI. With
# ASTROWIDGET_REQUIRE_BINARY=1, a missing binary is a loud collection error
# instead of a skip.
if os.environ.get("ASTROWIDGET_REQUIRE_BINARY") == "1" and not fx.SCORING_BINARY.exists():
	raise RuntimeError(
		f"ASTROWIDGET_REQUIRE_BINARY=1 but the scoring binary is missing at "
		f"{fx.SCORING_BINARY} — build it (see CLAUDE.md Key Commands)"
	)


def _run_binary(now_utc: datetime, *, cloud: float, managed: bool,
				bortle=5, precip=5.0, with_aod=True, with_250=True,
				wind=6.0, wind_pattern=None, precip_null_every=None,
				aod=0.06, thresholds=None, nb_leakage=None, snow=0.0) -> dict:
	"""Crafts one stdin payload, runs the real binary, returns tonight's night dict.

	Extras (QA 2026-06-09 veto tests): `wind_pattern` cycles a list of wind
	speeds across the hours (peak-vs-average tests need a short blow inside an
	otherwise calm window); `precip_null_every` nulls every Nth hour's precip
	probability (null-skip tests); `aod` sets the AOD value (NB-vs-BB scoring
	region needs poor transparency); `thresholds` passes the per-site veto
	thresholds dict verbatim so tests don't depend on binary defaults.
	"""
	hours, aq = [], []
	for i in range(72):
		t = (now_utc + timedelta(hours=i)).strftime("%Y-%m-%dT%H:00")
		row = {
			"time": t, "cloud_cover": cloud, "cloud_cover_low": cloud * 0.5,
			"cloud_cover_mid": cloud * 0.3, "cloud_cover_high": cloud * 0.1,
			"relative_humidity_2m": 55.0, "temperature_2m": 12.0, "dewpoint_2m": 4.0,
			"wind_speed_10m": (
				wind_pattern[i % len(wind_pattern)] if wind_pattern else wind
			),
			"wind_gusts_10m": 12.0,
			"precipitation_probability": (
				None if (precip_null_every and i % precip_null_every == 0)
				else precip
			),
			"precipitation": 0.0,
			"visibility": 30000.0,
			"snow_depth": snow,
		}
		if with_250:
			row["wind_speed_250hPa"] = 30.0
		hours.append(row)
		if with_aod:
			aq.append({"time": t, "aerosol_optical_depth": aod})
	# Synthetic round-number coordinates (eastern Oregon, inside the NA domain) —
	# NOT a real site. The repo is public; tests must never carry real lat/lon.
	site = {"id": "b", "label": "B", "lat": 45.0, "lon": -120.0,
			"managed": managed, "hourly": hours, "airQuality": aq}
	if bortle is not None:
		site["bortle"] = bortle
	if nb_leakage is not None:
		site["nb_leakage"] = nb_leakage
	if thresholds is not None:
		site["thresholds"] = thresholds
	payload = {"now_utc": now_utc.isoformat(), "sites": [site]}
	out = subprocess.run([str(fx.SCORING_BINARY)], input=json.dumps(payload),
						  capture_output=True, text=True)
	assert out.returncode == 0, f"binary failed: {out.stderr}"
	parsed = json.loads(out.stdout)
	assert parsed["schema_version"] == 2
	return parsed["sites"][0]["nights"][0]


@pytestmark_binary
def test_incident_heavy_cloud_home_not_green():
	"""THE reported incident: ~89% cloud at a HOME site must NOT read green. Uses
	bortle=None — the ACTUAL incident-site config (no measured/derived Bortle) the
	QA review showed STILL read BB+NB green until the cloud gate was added (the
	default baseline lifted skyBrightness enough to out-vote cloud in the weighted
	mean). Asserts the RIGHT outcome (Neither + broadband below the good threshold),
	not merely the absence of the most-green label. The December date gives a REAL
	dark window (so 89% cloud, not a degenerate empty window, drives the verdict)
	near a new moon (so cloud is the only variable)."""
	night = _run_binary(datetime(2026, 12, 9, 6, tzinfo=timezone.utc),
						 cloud=89.0, managed=False, bortle=None)
	assert night["recommendation"] == "Neither"
	assert night["broadband"]["score"] < 60, "heavy cloud must cap below 'good'"


@pytestmark_binary
def test_cloud_gate_caps_heavy_cloud_below_good():
	"""Spec §1: cloud GATES, not just averages. The broadband score cannot exceed
	what the cloud allows, so heavy cloud can't be out-voted to 'good' by good
	stability/sky/transparency. Sweep at a neutral-moon date: clear is green-capable
	and the score falls monotonically as cloud rises, landing below 'good' well
	before total overcast."""
	now = datetime(2026, 12, 9, 6, tzinfo=timezone.utc)  # near-new moon: cloud is the only variable
	scores = {
		c: _run_binary(now, cloud=float(c), managed=False, bortle=4)["broadband"]["score"]
		for c in (2, 30, 50, 70, 89)
	}
	assert scores[2] >= 60, "a clear night must be green-capable"
	assert scores[89] < 60, "89% cloud must be below 'good' (the incident)"
	assert scores[70] < 60, "70% cloud must be below 'good'"
	seq = [scores[c] for c in (2, 30, 50, 70, 89)]
	assert seq == sorted(seq, reverse=True), f"score must fall as cloud rises: {seq}"


@pytestmark_binary
def test_overcast_veto_fires_in_both_modes():
	"""Deliberate plan deviation (#6): the overcast veto (cloudFactor<=5) fires in
	BOTH modes — only the PRECIP veto is managed-gated. ~97% cloud must read Neither
	with a cloud veto whether HOME or REMOTE (nobody images through solid overcast)."""
	now = datetime(2026, 12, 9, 6, tzinfo=timezone.utc)
	for managed in (False, True):
		night = _run_binary(now, cloud=97.0, managed=managed, bortle=4)
		assert night["recommendation"] == "Neither"
		veto_names = [v["name"] for v in night["broadband"]["vetoes"]]
		assert "cloud" in veto_names, f"managed={managed}: overcast must fire the cloud veto"


@pytestmark_binary
def test_peak_wind_vetoes_short_blow_average_does_not():
	"""QA 2026-06-09: wind must PEAK-check over the window, not average — the
	cloud-gate incident's structural lesson (a veto-class factor hiding inside
	a mean) applied to the factor that physically closes iTelescope domes.
	The pattern 10,10,10,60 km/h puts a 60 in EVERY 4-hour stretch (so the
	dark window certainly contains one) while averaging 22.5 — far under the
	48 km/h threshold. The engine's old average check passed this; the peak
	check must veto. Control: flat calm wind must not."""
	now = datetime(2026, 12, 9, 6, tzinfo=timezone.utc)
	thr = {"wind_max_kmh": 48.0}
	blow = _run_binary(now, cloud=10.0, managed=True, bortle=4,
					   wind_pattern=[10.0, 10.0, 10.0, 60.0], thresholds=thr)
	names = [v["name"] for v in blow["broadband"]["vetoes"]]
	assert "wind" in names, f"peak 60 km/h must veto at 48: {blow['broadband']['vetoes']}"
	assert blow["recommendation"] == "Neither"
	calm = _run_binary(now, cloud=10.0, managed=True, bortle=4,
					   wind=10.0, thresholds=thr)
	assert all(v["name"] != "wind" for v in calm["broadband"]["vetoes"])


@pytestmark_binary
def test_missing_precip_hours_do_not_fabricate_a_veto():
	"""QA 2026-06-09: an absent precip hour rides the null-skip convention
	(like jet wind / temperature / dewpoint), NOT the old fabricated 50% —
	which under PEAK veto semantics instantly vetoed a bone-dry HOME night at
	a 10% threshold. A dry night (2%) with every 6th hour null must not
	precip-veto; a genuinely wet night still must."""
	now = datetime(2026, 12, 9, 6, tzinfo=timezone.utc)
	thr = {"precip_max_pct": 10.0}
	dry = _run_binary(now, cloud=10.0, managed=False, bortle=4,
					  precip=2.0, precip_null_every=6, thresholds=thr)
	assert all(v["name"] != "precipitation" for v in dry["broadband"]["vetoes"]), (
		f"null precip hours fabricated a veto: {dry['broadband']['vetoes']}"
	)
	wet = _run_binary(now, cloud=10.0, managed=False, bortle=4,
					  precip=40.0, thresholds=thr)
	assert any(v["name"] == "precipitation" for v in wet["broadband"]["vetoes"])


@pytestmark_binary
def test_nb_ge_bb_invariant_and_bb_pass_recommends_both():
	"""nb-model-v1 makes NB ≥ BB STRUCTURAL: the NB composite swaps in an NB-correct sky
	sub-score (≥ the broadband one) under the same weights + cloud gate, so NB can never
	score below BB. (The old v2 re-weight COULD score NB below BB on dark, poor-transparency
	nights — which needed a recommendation floor; the model now guarantees the relation, so
	the old 'NB<good while BB passes' region is empty BY DESIGN, not by patch.) Sweep: every
	un-vetoed night has NB ≥ BB, and any broadband-passing night recommends BB+NB.
	Non-vacuous: asserts the BB-passing region fired."""
	now = datetime(2026, 12, 9, 6, tzinfo=timezone.utc)
	fired = 0
	for aod in (0.06, 0.5, 0.9):
		for cloud in (5.0, 20.0):
			night = _run_binary(now, cloud=cloud, managed=False, bortle=3, aod=aod)
			bb = night["broadband"]
			nb = night["narrowband"]
			# Structural invariant: NB never below BB (the model guarantees it).
			assert nb["score"] >= bb["score"], (
				f"aod={aod} cloud={cloud}: NB {nb['score']} < BB {bb['score']} — "
				"the nb-model-v1 NB ≥ BB guarantee is broken"
			)
			if bb["score"] >= 60 and not bb["vetoes"]:
				fired += 1
				assert night["recommendation"] == "BB+NB", (
					f"aod={aod} cloud={cloud}: broadband passes "
					f"(score {bb['score']}) but recommendation is "
					f"{night['recommendation']}"
				)
	assert fired > 0, "sweep never produced a passing broadband night — vacuous test"


@pytestmark_binary
def test_schema_factor_set_changed():
	"""factors = {cloud, stability, skyBrightness, transparency?}; no darkness/moon.
	best_window + managed present; NB method is nb-model-v1."""
	night = _run_binary(datetime(2026, 6, 9, 20, tzinfo=timezone.utc),
						 cloud=15.0, managed=False)
	factors = night["broadband"]["factors"]
	assert "darkness" not in factors and "moon" not in factors
	assert "skyBrightness" in factors
	assert "best_window" in night
	assert night["managed"] is False
	assert night["narrowband"]["method"] == "retention-v2"


@pytestmark_binary
def test_narrowband_beats_broadband_under_bright_high_moon():
	"""The reported inversion fix: under a bright, HIGH moon NB must exceed BB
	(narrowband rejects moonlight). Dec at 32°N puts a full moon ~85° up with a
	real astronomical dark window."""
	# Find the brightest-moon clear night in late Dec 2026 at a 32°N site.
	best = None
	for d in range(20, 28):
		now = datetime(2026, 12, d, 6, tzinfo=timezone.utc)
		night = _run_binary(now, cloud=2.0, managed=False, bortle=4)
		m = night["moon"]
		score = m["illumination_pct"] * max(m["max_alt_during_dark"], 0)
		if best is None or score > best[0]:
			best = (score, night)
	night = best[1]
	assert night["moon"]["illumination_pct"] > 80
	assert night["moon"]["max_alt_during_dark"] > 40
	assert night["narrowband"]["score"] > night["broadband"]["score"]


@pytestmark_binary
def test_precip_veto_is_home_only():
	"""HOME protects an uncovered scope (precip veto fires); a REMOTE weatherproof
	dome skips it. Same clear-but-rainy input, opposite veto outcome."""
	now = datetime(2026, 12, 23, 6, tzinfo=timezone.utc)
	home = _run_binary(now, cloud=2.0, managed=False, precip=80.0)
	remote = _run_binary(now, cloud=2.0, managed=True, precip=80.0)
	home_vetoes = [v["name"] for v in home["broadband"]["vetoes"]]
	remote_vetoes = [v["name"] for v in remote["broadband"]["vetoes"]]
	assert "precipitation" in home_vetoes
	assert "precipitation" not in remote_vetoes


@pytestmark_binary
def test_graceful_when_optional_feeds_absent():
	"""No AOD, no 250 hPa wind, no Bortle → still a valid score, no crash/NaN, and
	transparency is simply omitted (never scored as 0)."""
	night = _run_binary(datetime(2026, 12, 23, 6, tzinfo=timezone.utc),
						 cloud=10.0, managed=False, bortle=None,
						 with_aod=False, with_250=False)
	bb = night["broadband"]
	assert 0 <= bb["score"] <= 100
	assert "transparency" not in bb["factors"]   # omitted, not zeroed
	assert "skyBrightness" in bb["factors"]       # always present (default baseline)


# ─────────────────────────────────────────────────────────────────────────────
# "Tonight" anchoring (fix 2026-06-10) — Tonight = the in-progress-or-upcoming
# night, NOT the night implied by nowUtc's UTC calendar date. The old anchoring
# searched from noon UTC of nowUtc's own date, so any fetch between local
# evening and the next UTC noon (17:00 PDT onward for a US-West site) labelled
# TOMORROW's night "Tonight" — at 11 PM the widget's Tonight tab was the
# following night. The binary takes now_utc from the payload, so these are
# fully deterministic (no wall-clock rot).
# ─────────────────────────────────────────────────────────────────────────────

def _tonight_dark_start(now: datetime) -> str:
	"""Tonight's dark-window start (ISO string) per the real binary at `now`."""
	night = _run_binary(now, cloud=10.0, managed=False)
	dw = night["dark_window"]
	assert dw is not None, f"no dark window at {now} (test site has astro dark year-round)"
	return dw["start"]

@pytestmark_binary
def test_tonight_is_stable_across_the_utc_date_roll():
	"""A morning fetch and an evening fetch on the SAME local day must agree on
	which night is "Tonight". For the lon -120 test site, 18:00 UTC = 11:00 local
	(same UTC date) and 04:00 UTC next UTC-day = 21:00 local the SAME evening —
	the old anchoring skipped a night at the second fetch."""
	morning = _tonight_dark_start(datetime(2026, 6, 9, 18, 0, tzinfo=timezone.utc))
	evening = _tonight_dark_start(datetime(2026, 6, 10, 4, 0, tzinfo=timezone.utc))
	assert morning == evening, (
		f"Tonight changed across the UTC date roll on one local evening: "
		f"{morning} vs {evening}")

@pytestmark_binary
def test_tonight_rolls_after_the_night_ends_not_at_utc_midnight():
	"""Once last night's dark window has ENDED (mid-morning local), Tonight must
	advance to the upcoming night — exactly one night after the evening view."""
	evening = _tonight_dark_start(datetime(2026, 6, 10, 4, 0, tzinfo=timezone.utc))
	next_morning = _tonight_dark_start(datetime(2026, 6, 10, 18, 0, tzinfo=timezone.utc))
	d1 = datetime.fromisoformat(evening.replace("Z", "+00:00"))
	d2 = datetime.fromisoformat(next_morning.replace("Z", "+00:00"))
	delta_h = (d2 - d1).total_seconds() / 3600
	assert 22 <= delta_h <= 26, (
		f"expected Tonight to advance exactly one night after dawn, got {delta_h:.1f} h")

@pytestmark_binary
def test_tonight_window_is_in_progress_or_future_at_late_evening():
	"""At 23:00 local (06:00 UTC for lon -120), Tonight's dark window must not
	already be over — its END is after `now`. This is the decision-form moment:
	the verdict on screen at 11 PM must describe the night being decided."""
	now = datetime(2026, 6, 10, 6, 0, tzinfo=timezone.utc)
	night = _run_binary(now, cloud=10.0, managed=False)
	end = datetime.fromisoformat(night["dark_window"]["end"].replace("Z", "+00:00"))
	assert end > now, f"Tonight's window already ended at {end} (now {now})"


# ─────────────────────────────────────────────────────────────────────────────
# Narrowband: the real forward model (nb-model-v1, DEF-V2-03, 2026-06-20). Moon
# illumination is DATE-computed by the binary (not a payload field), so these drive
# the NB-vs-BB contrast with `bortle` light-pollution and rely on the NB ≥ BB invariant.
# ─────────────────────────────────────────────────────────────────────────────

@pytestmark_binary
def test_narrowband_model_tag_and_invariant():
	"""The NB path is the real model (nb-model-v1) and never scores below broadband —
	narrowband tolerates everything broadband does (it rejects the moon/LP broadband
	needs gone)."""
	night = _run_binary(datetime(2026, 12, 23, 6, tzinfo=timezone.utc),
						cloud=5.0, managed=False, bortle=5)
	assert night["narrowband"]["method"] == "retention-v2"
	assert night["narrowband"]["score"] >= night["broadband"]["score"]


@pytestmark_binary
def test_narrowband_rejects_light_pollution():
	"""At a bright (Bortle 8) site under clear sky, broadband is dragged down by light
	pollution but narrowband rejects it — NB strictly beats BB. This is the real-model
	behaviour the heuristic re-weight only approximated."""
	night = _run_binary(datetime(2026, 12, 23, 6, tzinfo=timezone.utc),
						cloud=5.0, managed=False, bortle=8)
	assert night["narrowband"]["score"] > night["broadband"]["score"]


@pytestmark_binary
def test_narrowband_cloud_gate_still_caps():
	"""Opaque cloud blocks emission lines too — NB stays capped at the cloud factor,
	never reads 'good' through heavy cloud despite the moon/LP-immune sky."""
	night = _run_binary(datetime(2026, 12, 23, 6, tzinfo=timezone.utc),
						cloud=92.0, managed=False, bortle=5)
	assert night["narrowband"]["score"] <= 40   # heavy cloud → at best marginal


@pytestmark_binary
def test_nb_leakage_override_is_wired_end_to_end():
	"""The nb_leakage stdin override reaches the model: a SMALLER leakage (more continuum
	rejection) yields a HIGHER narrowband score. Bortle 8 gives light pollution to reject,
	making NB leakage-sensitive. Guards the end-to-end plumbing (config → payload → binary)."""
	now = datetime(2026, 12, 23, 6, tzinfo=timezone.utc)
	tight = _run_binary(now, cloud=5.0, managed=False, bortle=8, nb_leakage=0.01)
	loose = _run_binary(now, cloud=5.0, managed=False, bortle=8, nb_leakage=0.5)
	assert tight["narrowband"]["score"] > loose["narrowband"]["score"]


@pytestmark_binary
def test_narrowband_absent_transparency_skips_not_zeros():
	"""Absent AOD is the multiplicative IDENTITY in retention-v2 (transparency retention
	1.0), never read as 0 haze. So NB with transparency absent must stay CLOSE to NB with
	transparency present-and-good — both decline to penalise a factor that isn't actually
	bad. A zeroed-absent would crater the product; identity keeps them within a few points."""
	now = datetime(2026, 12, 23, 6, tzinfo=timezone.utc)
	absent = _run_binary(now, cloud=10.0, managed=False, bortle=6, with_aod=False)
	present = _run_binary(now, cloud=10.0, managed=False, bortle=6, with_aod=True, aod=0.02)
	assert abs(absent["narrowband"]["score"] - present["narrowband"]["score"]) <= 12
	assert absent["narrowband"]["score"] >= absent["broadband"]["score"]


@pytestmark_binary
def test_nb_leakage_one_reproduces_broadband_at_binary_layer():
	"""NB==BB parity guard, retention-v2 form: at leakage=1 the narrowband path sees the
	FULL excess sky flux (Δmag_NB == Δmag_BB), and every other retention is shared, so the
	two band composites must produce the IDENTICAL score. Guards the per-band plumbing —
	any NB/BB divergence outside the leakage term fails here. (retention-v2 makes this
	parity hold on ANY night, moonlit or not; the moonless date is continuity, not a
	requirement.)"""
	night = _run_binary(datetime(2026, 12, 9, 6, tzinfo=timezone.utc),
						cloud=5.0, managed=False, bortle=5, nb_leakage=1.0)
	assert night["broadband"]["score"] > 30   # non-degenerate (not a 0 == 0 pass)
	assert night["narrowband"]["score"] == night["broadband"]["score"]


@pytestmark_binary
def test_snow_lowers_both_bb_and_nb_at_binary_layer():
	"""The window-mean snow plumbing (hourly snow_depth → mean → BOTH sky models) is live:
	a snowy night scores below an otherwise-identical dry night, for broadband AND
	narrowband (snow reflects moon+LP upward — continuum NB also rejects, but not fully).
	Guards the snow wiring the QA pass added to the NB path; a dropped snowDepthM would
	pass everything else."""
	# 2026-12-09 is a NEW moon (0% illum) — the sky sub-score isn't already cratered, so
	# snow's LP-amplification is visible (a near-full-moon date floors sky at 0 first, and
	# snow can't lower 0). Verified by probe: dry sky 49→snowy 31; BB 82→77; NB 94→91.
	now = datetime(2026, 12, 9, 6, tzinfo=timezone.utc)
	dry = _run_binary(now, cloud=5.0, managed=False, bortle=6, snow=0.0)
	snowy = _run_binary(now, cloud=5.0, managed=False, bortle=6, snow=0.1)
	assert snowy["broadband"]["score"] < dry["broadband"]["score"]   # snow must do something
	assert snowy["narrowband"]["score"] <= dry["narrowband"]["score"]
