"""
Tests for allsky_sqm.py — the nightly allsky sky-quality capture.

Covers the three pieces that can silently corrupt calibration data if wrong:
timestamp reconstruction (charts samples carry time-of-day only), dark-window
clipping, and the upsert/lookup helpers in calibration_log. Plus config
validation (loud failures) and a mocked end-to-end main() run.

No network: fetch_charts is patched everywhere. The autouse fixture in
conftest.py already redirects calibration_log.DB_PATH to a tmp path.
"""

from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import pytest

import allsky_sqm
import calibration_log as cl

# Test camera zone: needs a REAL, nonzero UTC offset (so offset conversion is
# actually exercised — UTC would make it vanish) and NO DST (so tests pass on
# transition days). America/Phoenix is the canonical zone with both properties.
PHX = ZoneInfo("America/Phoenix")


# ─────────────────────────────────────────────────────────────────────────────
# resolve_sample_times — pinning HH:MM:SS-only samples to real UTC instants
# ─────────────────────────────────────────────────────────────────────────────


def test_resolve_times_before_now_are_today():
	now = datetime(2026, 8, 18, 8, 0, 0, tzinfo=PHX)  # 8 AM capture
	pts = allsky_sqm.resolve_sample_times([{"x": "03:15:00", "y": 5.0}], now)
	assert len(pts) == 1
	t, y = pts[0]
	assert y == 5.0
	# 03:15 Phoenix (UTC-7) on the 18th = 10:15 UTC on the 18th.
	assert t == datetime(2026, 8, 18, 10, 15, 0, tzinfo=timezone.utc)


def test_resolve_times_after_now_wrap_to_yesterday():
	# At an 00:30 capture, a 23:50 sample can't be tonight — it's yesterday
	# evening. This is the midnight-crossing case every night hits.
	now = datetime(2026, 8, 18, 0, 30, 0, tzinfo=PHX)
	pts = allsky_sqm.resolve_sample_times([{"x": "23:50:00", "y": 1.0}], now)
	assert pts[0][0] == datetime(2026, 8, 17, 23, 50, 0, tzinfo=PHX).astimezone(timezone.utc)


def test_resolve_times_small_clock_skew_stays_today():
	# A sample stamped 30 s "ahead" of us is clock skew, not yesterday.
	now = datetime(2026, 8, 18, 8, 0, 0, tzinfo=PHX)
	pts = allsky_sqm.resolve_sample_times([{"x": "08:00:30", "y": 1.0}], now)
	assert pts[0][0].date() == datetime(2026, 8, 18).date()


def test_resolve_times_beyond_skew_slack_wraps_to_yesterday():
	# Pins the slack from the OUTSIDE (QA TA-5): 2 min ahead is past the 60 s
	# allowance and must wrap — a slack quietly widened to an hour would let
	# late-evening samples time-travel to tomorrow and land outside the clip.
	now = datetime(2026, 8, 18, 8, 0, 0, tzinfo=PHX)
	pts = allsky_sqm.resolve_sample_times([{"x": "08:02:00", "y": 1.0}], now)
	assert pts[0][0] == datetime(2026, 8, 17, 8, 2, 0, tzinfo=PHX).astimezone(timezone.utc)


def test_resolve_times_drops_malformed_points():
	now = datetime(2026, 8, 18, 8, 0, 0, tzinfo=PHX)
	pts = allsky_sqm.resolve_sample_times(
		[{"x": "notatime", "y": 1.0}, {"x": "08:00", "y": 1.0},
		 {"x": "01:00:00", "y": "high"}, {"y": 2.0}, {"x": "01:00:00", "y": 3.0}],
		now)
	assert len(pts) == 1 and pts[0][1] == 3.0


def test_clip_to_window_is_inclusive():
	base = datetime(2026, 8, 18, 4, 0, 0, tzinfo=timezone.utc)
	pts = [(base + timedelta(hours=h), float(h)) for h in range(5)]
	clipped = allsky_sqm.clip_to_window(pts, base + timedelta(hours=1),
										base + timedelta(hours=3))
	assert [y for (_, y) in clipped] == [1.0, 2.0, 3.0]
	# Pairs come back with their times intact — the caller's coverage-gap
	# check depends on them.
	assert clipped[0][0] == base + timedelta(hours=1)


# ─────────────────────────────────────────────────────────────────────────────
# calibration_log helpers — dark-window lookup + sky-reading upsert
# ─────────────────────────────────────────────────────────────────────────────


def _seed_forecast(conn, night_date, site_id, dark_start, dark_end,
				   fetched_at="2026-08-18T04:00:00", label="Tonight"):
	conn.execute(
		"""INSERT INTO forecasts (fetched_at, night_date, night_label, site_id,
								  dark_start, dark_end)
		   VALUES (?,?,?,?,?,?)""",
		(fetched_at, night_date, label, site_id, dark_start, dark_end))
	conn.commit()


def test_latest_dark_window_prefers_freshest_fetch():
	conn = cl.connect()
	_seed_forecast(conn, "2026-08-17", "CSV", "old_s", "old_e",
				   fetched_at="2026-08-17T20:00:00")
	_seed_forecast(conn, "2026-08-17", "CSV", "new_s", "new_e",
				   fetched_at="2026-08-18T04:00:00")
	assert cl.latest_dark_window(conn, "2026-08-17", "CSV") == ("new_s", "new_e")
	conn.close()


def test_latest_dark_window_none_when_missing_or_null():
	conn = cl.connect()
	assert cl.latest_dark_window(conn, "2026-08-17", "CSV") is None
	# A row with NULL dark bounds (site had no astro dark) doesn't count.
	_seed_forecast(conn, "2026-08-17", "CSV", None, None)
	assert cl.latest_dark_window(conn, "2026-08-17", "CSV") is None
	# Non-'Tonight' labels don't count either — they're forecasts, not the night.
	_seed_forecast(conn, "2026-08-17", "CSV", "s", "e", label="+1 night")
	assert cl.latest_dark_window(conn, "2026-08-17", "CSV") is None
	conn.close()


def test_latest_dark_window_site_id_case_insensitive():
	# Site ids in the live DB are mixed-case; = is case-sensitive in SQLite.
	# Same COLLATE NOCASE guard as every other calibration query.
	conn = cl.connect()
	_seed_forecast(conn, "2026-08-17", "csv", "s", "e")
	assert cl.latest_dark_window(conn, "2026-08-17", "CSV") == ("s", "e")
	conn.close()


def test_upsert_sky_reading_inserts_then_replaces():
	conn = cl.connect()
	cl.upsert_sky_reading(conn, "2026-08-17", "CSV", 1400.0, 1250.0, 2900.0,
						  990.0, 1080, 300, "ds", "de", "http://x")
	# Backdate the first row's capture stamp so the refresh assertion below
	# can't false-pass on two same-instant timestamps (QA TA-7 / CR flake note).
	conn.execute("UPDATE sky_readings SET captured_at = '2020-01-01T00:00:00+00:00'")
	conn.commit()
	# Second capture for the same night (the morning run after a mid-night
	# smoke test) must REPLACE, not duplicate or fail.
	cl.upsert_sky_reading(conn, "2026-08-17", "CSV", 1425.0, 1250.0, 2973.0,
						  996.0, 1082, 620, "ds", "de", "http://x")
	rows = conn.execute(
		"SELECT sqm_median, sample_count, captured_at FROM sky_readings").fetchall()
	assert len(rows) == 1
	assert rows[0][0:2] == (1425.0, 620)
	# The replacement must also refresh captured_at — a row claiming a 2020
	# capture time for this morning's data is wrong provenance (QA TA-7).
	assert rows[0][2] != "2020-01-01T00:00:00+00:00"
	conn.close()


# ─────────────────────────────────────────────────────────────────────────────
# load_allsky_config — loud validation of the [allsky] block
# ─────────────────────────────────────────────────────────────────────────────

# Synthetic coordinates only, per the repo's privacy rule for tests.
_SITES = [{"id": "CSV", "lat": 12.3, "lon": -45.6}]


def _cfg(allsky):
	return {"sites": _SITES, "allsky": allsky}


def _patch_config(monkeypatch, cfg):
	monkeypatch.setattr(allsky_sqm, "load_config", lambda: cfg)


def test_config_happy_path_applies_defaults(monkeypatch):
	_patch_config(monkeypatch, _cfg(
		{"url": "https://cam.example/indi-allsky/", "site_id": "CSV",
		 "timezone": "America/Denver"}))
	acfg = allsky_sqm.load_allsky_config()
	assert acfg["url"] == "https://cam.example/indi-allsky"  # trailing / stripped
	assert acfg["camera_id"] == 1 and acfg["window_hours"] == 14
	assert acfg["insecure_tls"] is False
	assert str(acfg["tz"]) == "America/Denver"


_TZ = {"timezone": "America/Denver"}  # valid zone for the bad-block cases below


@pytest.mark.parametrize("allsky", [
	None,                                              # block missing entirely
	{"site_id": "CSV", **_TZ},                         # no url
	{"url": "ftp://x", "site_id": "CSV", **_TZ},       # non-http(s) url
	{"url": "https://x", "site_id": "", **_TZ},        # empty site
	{"url": "https://x", "site_id": "nope", **_TZ},    # site not in [[sites]]
	{"url": "https://x", "site_id": "CSV"},            # timezone MISSING — it is
	                                                   # required: samples are
	                                                   # uninterpretable without it
	{"url": "https://x", "site_id": "CSV", "timezone": "PDT"},        # not IANA
	{"url": "https://x", "site_id": "CSV", **_TZ, "window_hours": 0},   # too small
	{"url": "https://x", "site_id": "CSV", **_TZ, "window_hours": 24},  # over the
	                                                   # 23 h cap (24 h would make
	                                                   # date reconstruction ambiguous)
	{"url": "https://x", "site_id": "CSV", **_TZ, "window_hours": True}, # TOML true
	                                                   # is a bool; isinstance(True,
	                                                   # int) is True — must reject
	{"url": "https://x", "site_id": "CSV", **_TZ, "camera_id": -1},     # bad camera
	{"url": "https://x", "site_id": "CSV", **_TZ, "camera_id": True},   # bool camera
])
def test_config_rejects_bad_blocks(monkeypatch, allsky):
	_patch_config(monkeypatch, _cfg(allsky) if allsky is not None
				  else {"sites": _SITES})
	with pytest.raises(SystemExit):
		allsky_sqm.load_allsky_config()


def test_config_site_id_canonicalized_to_sites_casing(monkeypatch):
	# Config [[sites]] says "CSV"; [allsky] saying "csv" must still match, and
	# the returned site_id must be the [[sites]] CASING — sky_readings'
	# UNIQUE(night_date, site_id) is case-sensitive, so writing the [allsky]
	# block's own casing would split one night across two rows (QA TA-4/SA-2,
	# confirmed empirically: "CSV" then "csv" upserts produced two rows).
	_patch_config(monkeypatch, _cfg(
		{"url": "https://x", "site_id": "csv", "timezone": "America/Denver"}))
	assert allsky_sqm.load_allsky_config()["site_id"] == "CSV"


# ─────────────────────────────────────────────────────────────────────────────
# _iso_to_utc — the dark-window bound parser (QA TA-1: the live DB carries
# Dart's "Z"-suffixed strings; naive strings must be read as UTC, never local)
# ─────────────────────────────────────────────────────────────────────────────


def test_iso_to_utc_z_suffix():
	# The production shape: scoring binary emits toIso8601String + "Z".
	assert allsky_sqm._iso_to_utc("2026-08-18T03:26:57.944Z") == datetime(
		2026, 8, 18, 3, 26, 57, 944000, tzinfo=timezone.utc)


def test_iso_to_utc_naive_is_utc_not_machine_local():
	# A naive string is the fetcher's UTC convention. Treating it as machine-
	# local would silently shift the clip window by the machine's whole UTC
	# offset — the exact slip TA-1 flagged as green-under-revert.
	assert allsky_sqm._iso_to_utc("2026-08-18T03:26:57") == datetime(
		2026, 8, 18, 3, 26, 57, tzinfo=timezone.utc)


def test_iso_to_utc_offset_converted():
	assert allsky_sqm._iso_to_utc("2026-08-18T08:26:57+05:00") == datetime(
		2026, 8, 18, 3, 26, 57, tzinfo=timezone.utc)


@pytest.mark.parametrize("bad", ["garbage", "", None, 42])
def test_iso_to_utc_bad_input_is_none(bad):
	assert allsky_sqm._iso_to_utc(bad) is None


# ─────────────────────────────────────────────────────────────────────────────
# main() — mocked end-to-end: charts payload → one sky_readings row
# ─────────────────────────────────────────────────────────────────────────────


def _phx_hms(dt_utc):
	"""Format a UTC instant the way the charts endpoint does: HH:MM:SS in the
	camera's local zone."""
	return dt_utc.astimezone(PHX).strftime("%H:%M:%S")


def _z_iso(dt_utc):
	"""Format a UTC instant the way the LIVE forecasts table stores dark-window
	bounds: Dart's toIso8601String + "Z" (e.g. 2026-08-18T03:26:57.944Z). The
	seeds must use the production shape or the tests never exercise the
	Z-replace parse path (QA TA-1)."""
	return dt_utc.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def _run_main(monkeypatch, payload, dark_offsets=(-10, -2)):
	"""Run main() with a canned config, a seeded dark window (now+offsets, in
	hours, stored in the production "Z" shape), and a patched charts fetch.
	Returns (exit_code, connection).

	Default offsets put the dark window ENTIRELY IN THE PAST — the real morning
	scenario the timer fires (multimodel review, Kimi: the old (-6, +1) default
	made every "morning" test secretly a mid-night test, so the normal
	stored-bounds-equal-forecast case had zero coverage). The mid-night case is
	exercised explicitly by test_main_mid_night_run_stores_clipped_end."""
	monkeypatch.setattr(allsky_sqm, "load_allsky_config", lambda: {
		"url": "https://cam.example/indi-allsky", "site_id": "CSV",
		"camera_id": 2, "tz": PHX, "window_hours": 14, "insecure_tls": False,
	})
	monkeypatch.setattr(allsky_sqm, "fetch_charts",
						lambda *a, **k: payload)
	now_utc = datetime.now(timezone.utc)
	# Night keyed machine-local, matching main()'s convention (QA CR-1) — and
	# every other writer's (log_run, the decision form).
	night_date = cl.observing_date(datetime.now().astimezone())
	conn = cl.connect()
	_seed_forecast(
		conn, night_date, "CSV",
		_z_iso(now_utc + timedelta(hours=dark_offsets[0])),
		_z_iso(now_utc + timedelta(hours=dark_offsets[1])))
	return allsky_sqm.main(), conn


def test_main_writes_stats_for_dark_window_samples(monkeypatch, capsys):
	now_utc = datetime.now(timezone.utc)
	# Five samples spanning the WHOLE dark window (within the 30 min edge
	# allowance — this is the genuinely-happy path, so the edge-gap warning
	# must stay silent; stabilization QA STA-1), plus one daytime sample far
	# outside it (huge value, like the real daytime series) that MUST be
	# clipped away.
	sqm = [{"x": _phx_hms(now_utc - timedelta(minutes=m)), "y": v}
		   for m, v in ((595, 1300.0), (300, 1350.0), (240, 1400.0),
						(180, 1450.0), (125, 1500.0))]
	sqm.append({"x": _phx_hms(now_utc - timedelta(hours=13)), "y": 4_000_000.0})
	stars = [{"x": _phx_hms(now_utc - timedelta(hours=4)), "y": 900}]
	rc, conn = _run_main(monkeypatch, {"chart_data": {"sqm": sqm, "stars": stars}})
	assert rc == 0
	# Full coverage → no cry-wolf: the gap warning must NOT fire (pins the
	# 30 min threshold from the quiet side; a threshold mutated to always-warn
	# is alarm fatigue, the failure mode the warning exists to prevent).
	assert "no samples for" not in capsys.readouterr().err
	row = conn.execute("""SELECT sqm_median, sqm_min, sqm_max, stars_median,
								 stars_max, sample_count, site_id
						  FROM sky_readings""").fetchone()
	assert row == (1400.0, 1300.0, 1500.0, 900.0, 900, 5, "CSV")
	# Morning run over a fully-past window: the stored bounds must equal the
	# forecast's window (no clipping applied) — the normal-case pin the old
	# mid-night-shaped default never provided (multimodel review, Kimi).
	now_utc = datetime.now(timezone.utc)
	ds, de = conn.execute(
		"SELECT dark_start, dark_end FROM sky_readings").fetchone()
	assert abs(datetime.fromisoformat(ds)
			   - (now_utc - timedelta(hours=10))) < timedelta(seconds=10)
	assert abs(datetime.fromisoformat(de)
			   - (now_utc - timedelta(hours=2))) < timedelta(seconds=10)
	conn.close()


def test_main_fails_loudly_without_dark_window(monkeypatch, capsys):
	monkeypatch.setattr(allsky_sqm, "load_allsky_config", lambda: {
		"url": "https://cam.example", "site_id": "CSV", "camera_id": 2,
		"tz": PHX, "window_hours": 14, "insecure_tls": False,
	})
	monkeypatch.setattr(allsky_sqm, "fetch_charts",
						lambda *a, **k: pytest.fail("must not fetch without a window"))
	assert allsky_sqm.main() == 1
	assert "no dark window" in capsys.readouterr().err


def test_main_fails_loudly_on_missing_sqm_series(monkeypatch, capsys):
	rc, conn = _run_main(monkeypatch, {"chart_data": {"stars": []}})
	assert rc == 1
	assert "no sqm/jsqm series" in capsys.readouterr().err
	assert conn.execute("SELECT COUNT(*) FROM sky_readings").fetchone() == (0,)
	conn.close()


def test_main_fails_loudly_when_no_samples_in_window(monkeypatch, capsys):
	# Camera was up during the day but produced nothing during astro dark
	# (e.g. powered off overnight): loud failure, no half-empty row.
	now_utc = datetime.now(timezone.utc)
	sqm = [{"x": _phx_hms(now_utc - timedelta(hours=13)), "y": 4_000_000.0}]
	rc, conn = _run_main(monkeypatch, {"chart_data": {"sqm": sqm}})
	assert rc == 1
	assert "no sqm samples inside the dark window" in capsys.readouterr().err
	assert conn.execute("SELECT COUNT(*) FROM sky_readings").fetchone() == (0,)
	conn.close()


def test_main_succeeds_without_stars_series(monkeypatch):
	# sqm present, stars absent entirely (QA TA-3): star stats are secondary —
	# the capture must still succeed and store NULL star columns, not crash.
	now_utc = datetime.now(timezone.utc)
	sqm = [{"x": _phx_hms(now_utc - timedelta(hours=4)), "y": 1400.0}]
	rc, conn = _run_main(monkeypatch, {"chart_data": {"sqm": sqm}})
	assert rc == 0
	row = conn.execute("""SELECT sqm_median, stars_median, stars_max
						  FROM sky_readings""").fetchone()
	assert row == (1400.0, None, None)
	conn.close()


def test_main_accepts_jsqm_series_key(monkeypatch):
	# indi-allsky renamed the series "sqm" → "jsqm" in a 2026-08 server update
	# (same metric, same scale — verified live). The capture must accept
	# either key, or every camera-server upgrade kills the feature.
	now_utc = datetime.now(timezone.utc)
	jsqm = [{"x": _phx_hms(now_utc - timedelta(hours=4)), "y": 1234.0}]
	rc, conn = _run_main(monkeypatch, {"chart_data": {"sqm": None,
													  "jsqm": jsqm}})
	assert rc == 0
	assert conn.execute(
		"SELECT sqm_median FROM sky_readings").fetchone() == (1234.0,)
	conn.close()


def test_main_rejects_oversized_sqm_series(monkeypatch, capsys):
	# The MAX_SAMPLES guard must actually fire (QA TA-2) — main() reads the
	# module global, so a lowered cap exercises the real code path.
	monkeypatch.setattr(allsky_sqm, "MAX_SAMPLES", 10)
	now_utc = datetime.now(timezone.utc)
	sqm = [{"x": _phx_hms(now_utc - timedelta(minutes=m)), "y": 1300.0}
		   for m in range(11)]
	rc, conn = _run_main(monkeypatch, {"chart_data": {"sqm": sqm}})
	assert rc == 1
	assert "absurdly large" in capsys.readouterr().err
	assert conn.execute("SELECT COUNT(*) FROM sky_readings").fetchone() == (0,)
	conn.close()


def test_main_skips_oversized_stars_but_keeps_sqm(monkeypatch, capsys):
	# stars oversize must not kill the capture OR truncate silently (QA CR-6):
	# star stats are skipped with a warning, the sqm row still lands.
	monkeypatch.setattr(allsky_sqm, "MAX_SAMPLES", 10)
	now_utc = datetime.now(timezone.utc)
	sqm = [{"x": _phx_hms(now_utc - timedelta(hours=4)), "y": 1400.0}]
	stars = [{"x": _phx_hms(now_utc - timedelta(minutes=m)), "y": 900}
			 for m in range(11)]
	rc, conn = _run_main(monkeypatch,
						 {"chart_data": {"sqm": sqm, "stars": stars}})
	assert rc == 0
	assert "stars series absurdly large" in capsys.readouterr().err
	row = conn.execute(
		"SELECT sqm_median, stars_median FROM sky_readings").fetchone()
	assert row == (1400.0, None)
	conn.close()


def test_main_mid_night_run_stores_clipped_end(monkeypatch):
	# A mid-night manual run only covers dark_start → now; the stored bounds
	# must say so (QA CR-3) — a row claiming the full window while holding
	# partial-night stats is wrong provenance if the morning re-run fails.
	now_utc = datetime.now(timezone.utc)
	sqm = [{"x": _phx_hms(now_utc - timedelta(hours=4)), "y": 1400.0}]
	rc, conn = _run_main(monkeypatch, {"chart_data": {"sqm": sqm}},
						 dark_offsets=(-6, 1))  # dark_end 1 h in the FUTURE
	assert rc == 0
	stored_end = conn.execute(
		"SELECT dark_end FROM sky_readings").fetchone()[0]
	delta = abs(datetime.fromisoformat(stored_end) - now_utc)
	assert delta < timedelta(seconds=10)
	conn.close()


def test_main_warns_and_clips_when_window_misses_dark_start(monkeypatch, capsys):
	# Late boot catch-up (QA CR-2): the 14 h charts window can't reach a dark
	# start 16 h ago. The capture keeps the reachable data, warns loudly, and
	# stores the truncated start bound instead of claiming full coverage.
	now_utc = datetime.now(timezone.utc)
	sqm = [{"x": _phx_hms(now_utc - timedelta(hours=2)), "y": 1350.0}]
	rc, conn = _run_main(monkeypatch, {"chart_data": {"sqm": sqm}},
						 dark_offsets=(-16, -1))
	assert rc == 0
	assert "capture ran too late" in capsys.readouterr().err
	stored_start = conn.execute(
		"SELECT dark_start FROM sky_readings").fetchone()[0]
	delta = abs(datetime.fromisoformat(stored_start)
				- (now_utc - timedelta(hours=14)))
	assert delta < timedelta(seconds=10)
	conn.close()


def test_main_afternoon_catchup_steps_back_to_finished_night(monkeypatch):
	# After-noon boot catch-up (found independently by all three peer models in
	# the 2026-08-20 multimodel review): past local noon the noon-to-noon key
	# names TODAY's night, whose dark window is still in the future. main()
	# must detect the future window and step back one day to the finished,
	# recoverable night instead of failing on a night that hasn't happened.
	monkeypatch.setattr(allsky_sqm, "load_allsky_config", lambda: {
		"url": "https://cam.example/indi-allsky", "site_id": "CSV",
		"camera_id": 2, "tz": PHX, "window_hours": 14, "insecure_tls": False,
	})
	now_utc = datetime.now(timezone.utc)
	sqm = [{"x": _phx_hms(now_utc - timedelta(hours=4)), "y": 1375.0}]
	monkeypatch.setattr(allsky_sqm, "fetch_charts",
						lambda *a, **k: {"chart_data": {"sqm": sqm}})
	tonight = cl.observing_date(datetime.now().astimezone())
	last_night = (datetime.fromisoformat(tonight)
				  - timedelta(days=1)).date().isoformat()
	conn = cl.connect()
	# Tonight's window: entirely in the FUTURE (the after-noon shape).
	_seed_forecast(conn, tonight, "CSV",
				   _z_iso(now_utc + timedelta(hours=5)),
				   _z_iso(now_utc + timedelta(hours=9)))
	# Last night's window: finished, and the sample falls inside it.
	_seed_forecast(conn, last_night, "CSV",
				   _z_iso(now_utc - timedelta(hours=10)),
				   _z_iso(now_utc - timedelta(hours=2)))
	assert allsky_sqm.main() == 0
	rows = conn.execute(
		"SELECT night_date, sqm_median FROM sky_readings").fetchall()
	assert rows == [(last_night, 1375.0)]
	conn.close()


def test_main_narrower_rerun_never_replaces_wider_row(monkeypatch, capsys):
	# Coverage-regression guard (multimodel review, Sol): a manual re-run
	# whose clip window covers LESS night than the row already stored must
	# leave the wider row untouched — "newest wins" only when it's not worse.
	existing_conn = cl.connect()
	now_utc = datetime.now(timezone.utc)
	night = cl.observing_date(datetime.now().astimezone())
	cl.upsert_sky_reading(
		existing_conn, night, "CSV", 1390.0, 1250.0, 2900.0, 990.0, 1080, 700,
		(now_utc - timedelta(hours=11)).isoformat(),
		(now_utc - timedelta(hours=2)).isoformat(),  # 9 h of coverage
		"http://x")
	existing_conn.close()
	# New run: dark window seeded to a 4 h span → narrower than the 9 h row.
	sqm = [{"x": _phx_hms(now_utc - timedelta(hours=3)), "y": 9999.0}]
	rc, conn = _run_main(monkeypatch, {"chart_data": {"sqm": sqm}},
						 dark_offsets=(-6, -2))
	assert rc == 0
	assert "keeping it, nothing written" in capsys.readouterr().out
	row = conn.execute(
		"SELECT sqm_median, sample_count FROM sky_readings").fetchone()
	assert row == (1390.0, 700)  # the wide row survived; 9999 never landed
	conn.close()


def test_main_warns_on_coverage_gap_at_window_edge(monkeypatch, capsys):
	# Edge-gap warning (multimodel review, Sol): a camera down from dusk until
	# late still yields a valid row, but the hole must be loud in the journal —
	# a quiet outage must not read as a quiet night.
	now_utc = datetime.now(timezone.utc)
	# Window is 8 h; the only samples sit in the final hour → huge start gap.
	sqm = [{"x": _phx_hms(now_utc - timedelta(hours=2, minutes=m)), "y": 1400.0}
		   for m in range(0, 50, 10)]
	rc, conn = _run_main(monkeypatch, {"chart_data": {"sqm": sqm}},
						 dark_offsets=(-10, -2))
	assert rc == 0
	assert "no samples for" in capsys.readouterr().err
	conn.close()


def test_main_equal_bounds_rerun_replaces(monkeypatch):
	# The tie side of the regression guard (stabilization QA STA-2/SCR-2):
	# equal bounds are NOT strictly contained, so a same-morning corrected
	# re-run must REPLACE — a guard mutated to block ties would silently pin
	# the first (possibly wrong) capture forever.
	now_utc = datetime.now(timezone.utc)
	sqm1 = [{"x": _phx_hms(now_utc - timedelta(hours=4)), "y": 1300.0}]
	rc, conn = _run_main(monkeypatch, {"chart_data": {"sqm": sqm1}})
	assert rc == 0
	conn.close()
	sqm2 = [{"x": _phx_hms(now_utc - timedelta(hours=4)), "y": 1444.0}]
	rc, conn = _run_main(monkeypatch, {"chart_data": {"sqm": sqm2}})
	assert rc == 0
	assert conn.execute(
		"SELECT sqm_median FROM sky_readings").fetchone() == (1444.0,)
	conn.close()


def test_main_overwrites_row_with_unparseable_bounds(monkeypatch):
	# Guard fall-through (stabilization QA STA-3/SCR-4, converged): a stored
	# row with garbage bounds can't be compared, so the fresh capture — whose
	# bounds are good — must overwrite it, not be blocked defensively.
	conn0 = cl.connect()
	night = cl.observing_date(datetime.now().astimezone())
	cl.upsert_sky_reading(conn0, night, "CSV", 1.0, 1.0, 1.0, None, None, 1,
						  "garbage", "also-garbage", "http://x")
	conn0.close()
	now_utc = datetime.now(timezone.utc)
	sqm = [{"x": _phx_hms(now_utc - timedelta(hours=4)), "y": 1380.0}]
	rc, conn = _run_main(monkeypatch, {"chart_data": {"sqm": sqm}})
	assert rc == 0
	assert conn.execute(
		"SELECT sqm_median FROM sky_readings").fetchone() == (1380.0,)
	conn.close()


def test_main_prefers_sqm_over_jsqm_and_skips_empty_lists(monkeypatch):
	# Series-key lookup order pinned (stabilization QA STA-4): "sqm" wins when
	# both are populated (deterministic choice), and an EMPTY sqm list falls
	# through to jsqm — after the live rename, an empty legacy list is the
	# likelier future server shape than a null.
	now_utc = datetime.now(timezone.utc)
	pt = lambda v: [{"x": _phx_hms(now_utc - timedelta(hours=4)), "y": v}]  # noqa: E731
	rc, conn = _run_main(monkeypatch, {"chart_data": {"sqm": pt(1111.0),
													  "jsqm": pt(2222.0)}})
	assert rc == 0
	assert conn.execute(
		"SELECT sqm_median FROM sky_readings").fetchone() == (1111.0,)
	conn.close()
	conn0 = cl.connect()
	conn0.execute("DELETE FROM sky_readings")
	conn0.commit()
	conn0.close()
	rc, conn = _run_main(monkeypatch, {"chart_data": {"sqm": [],
													  "jsqm": pt(2222.0)}})
	assert rc == 0
	assert conn.execute(
		"SELECT sqm_median FROM sky_readings").fetchone() == (2222.0,)
	conn.close()


def test_main_stepback_to_missing_night_fails_naming_it(monkeypatch, capsys):
	# Step-back lands on a night with NO forecast row (stabilization QA
	# STA-5): fetch outage yesterday + after-noon boot today. Must fail
	# loudly, naming the STEPPED-BACK date so the journal points at the right
	# night.
	monkeypatch.setattr(allsky_sqm, "load_allsky_config", lambda: {
		"url": "https://cam.example", "site_id": "CSV", "camera_id": 2,
		"tz": PHX, "window_hours": 14, "insecure_tls": False,
	})
	monkeypatch.setattr(allsky_sqm, "fetch_charts",
						lambda *a, **k: pytest.fail("must not fetch"))
	now_utc = datetime.now(timezone.utc)
	tonight = cl.observing_date(datetime.now().astimezone())
	last_night = (datetime.fromisoformat(tonight)
				  - timedelta(days=1)).date().isoformat()
	conn = cl.connect()
	_seed_forecast(conn, tonight, "CSV",
				   _z_iso(now_utc + timedelta(hours=5)),
				   _z_iso(now_utc + timedelta(hours=9)))
	assert allsky_sqm.main() == 1
	assert f"no dark window logged for {last_night}" in capsys.readouterr().err
	conn.close()


def test_main_no_stepback_on_missing_row(monkeypatch, capsys):
	# The trigger boundary the comment promises (stabilization QA SCR-3):
	# step-back fires ONLY on a future window, never on a missing row — a
	# missing row for the resolved night is a fetch-outage failure even when
	# last night's row exists and would have matched.
	monkeypatch.setattr(allsky_sqm, "load_allsky_config", lambda: {
		"url": "https://cam.example", "site_id": "CSV", "camera_id": 2,
		"tz": PHX, "window_hours": 14, "insecure_tls": False,
	})
	monkeypatch.setattr(allsky_sqm, "fetch_charts",
						lambda *a, **k: pytest.fail("must not fetch"))
	now_utc = datetime.now(timezone.utc)
	tonight = cl.observing_date(datetime.now().astimezone())
	last_night = (datetime.fromisoformat(tonight)
				  - timedelta(days=1)).date().isoformat()
	conn = cl.connect()
	# ONLY last night seeded — the resolved night has no row at all.
	_seed_forecast(conn, last_night, "CSV",
				   _z_iso(now_utc - timedelta(hours=30)),
				   _z_iso(now_utc - timedelta(hours=22)))
	assert allsky_sqm.main() == 1
	assert f"no dark window logged for {tonight}" in capsys.readouterr().err
	assert conn.execute("SELECT COUNT(*) FROM sky_readings").fetchone() == (0,)
	conn.close()


def test_main_fails_honestly_when_window_unreachable(monkeypatch, capsys):
	# Wholly-unreachable night (stabilization QA SCR-1): the history window
	# and the dark window don't overlap at all. Must fail with the real
	# diagnosis before fetching — not the misleading "was the camera down?".
	# (The empty payload below discriminates: if the pre-fetch check were
	# deleted, main() would reach the series lookup and fail with the
	# no-sqm/jsqm message instead, and the assertion goes red.)
	rc, conn = _run_main(monkeypatch, {"chart_data": {}},
						 dark_offsets=(-20, -15))  # 14 h window reaches -14 h
	assert rc == 1
	assert "no longer overlaps" in capsys.readouterr().err
	assert conn.execute("SELECT COUNT(*) FROM sky_readings").fetchone() == (0,)
	conn.close()


def test_fetch_charts_verifies_tls_unless_opted_out(monkeypatch):
	# Pins the one security-load-bearing line (QA SA cross-exam on TA-8):
	# verify=True must be the default; verify=False ONLY on explicit opt-in.
	calls = []

	class _Resp:
		headers = {}
		def raise_for_status(self): pass
		def json(self): return {"chart_data": {}}
		def close(self): pass

	def fake_get(url, **kwargs):
		calls.append(kwargs)
		return _Resp()

	monkeypatch.setattr(allsky_sqm.requests, "get", fake_get)
	allsky_sqm.fetch_charts("https://cam.example", 2, 14, insecure_tls=False)
	allsky_sqm.fetch_charts("https://cam.example", 2, 14, insecure_tls=True)
	assert calls[0]["verify"] is True
	assert calls[1]["verify"] is False
	# And the history window must be requested in seconds.
	assert calls[0]["params"]["limit_s"] == 14 * 3600
