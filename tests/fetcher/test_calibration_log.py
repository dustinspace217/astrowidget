"""
Tests for calibration_log.py — the Phase-3 calibration DB (forecast logging).

Covers the observing-night date convention (the join key) and log_run inserting
the right rows from a scoring-binary output, best-effort.
"""

from datetime import datetime, timezone

import calibration_log as cl


# ─────────────────────────────────────────────────────────────────────────────
# observing_date — the noon-to-noon "observing night" join key
# ─────────────────────────────────────────────────────────────────────────────


def test_observing_date_evening_is_that_date():
	# 11 PM June 3 → the night of June 3.
	assert cl.observing_date(datetime(2026, 6, 3, 23, 0)) == "2026-06-03"


def test_observing_date_after_midnight_is_prior_evening():
	# 12:30 AM June 4 (a Bainbridge-near-solstice dark-window start) → still June 3.
	assert cl.observing_date(datetime(2026, 6, 4, 0, 30)) == "2026-06-03"
	# 2 AM answer about the same night → also June 3 (the persistent form case).
	assert cl.observing_date(datetime(2026, 6, 4, 2, 0)) == "2026-06-03"


def test_observing_date_afternoon_is_that_date():
	assert cl.observing_date(datetime(2026, 6, 3, 13, 0)) == "2026-06-03"


# ─────────────────────────────────────────────────────────────────────────────
# log_run — append forecast rows from a scoring-binary output
# ─────────────────────────────────────────────────────────────────────────────

_SCORING_OUTPUT = {
	"schema_version": 2,
	"sites": [
		{
			"id": "bainbridge",
			"status": "ok",
			"nights": [
				{
					"label": "Tonight",
					"recommendation": "Neither",
					"broadband": {"score": 46, "verdict": "marginal",
						"factors": {"cloud": 6, "stability": 25,
									"skyBrightness": 66, "transparency": 87}},
					"narrowband": {"score": 40, "verdict": "marginal"},
					"moon": {"illumination_pct": 30.0, "max_alt_during_dark": 0.3},
					"best_window": None,
					"managed": False,
					"precip_peak_pct": 10,
					"dark_window": {"start": "2026-06-04T07:00",
									"end": "2026-06-04T09:27", "duration_minutes": 147},
				},
				{
					"label": "+1 night",
					"recommendation": "BB+NB",
					"broadband": {"score": 78, "verdict": "good",
						"factors": {"cloud": 95, "stability": 70,
									"skyBrightness": 60, "transparency": 92}},
					"narrowband": {"score": 84, "verdict": "excellent"},
					"moon": {"illumination_pct": 22.0, "max_alt_during_dark": -10.0},
					"best_window": {"start": "2026-06-05T07:10", "end": "2026-06-05T09:30"},
					"managed": False,
					"precip_peak_pct": 2,
					"dark_window": {"start": "2026-06-05T07:05",
									"end": "2026-06-05T09:33", "duration_minutes": 148},
				},
			],
		},
		{"id": "broken", "status": "error", "error": "API failure", "nights": []},
	],
}


def _db(tmp_path, monkeypatch):
	monkeypatch.setattr(cl, "DB_PATH", tmp_path / "astrowidget.db")
	return cl.connect()


def test_log_run_inserts_one_row_per_ok_site_night(tmp_path, monkeypatch):
	monkeypatch.setattr(cl, "DB_PATH", tmp_path / "astrowidget.db")
	now = datetime(2026, 6, 4, 4, 0, tzinfo=timezone.utc)
	written = cl.log_run(_SCORING_OUTPUT, now)
	assert written == 2  # bainbridge's two nights; the error site contributes nothing

	conn = cl.connect()
	rows = conn.execute(
		"SELECT night_label, recommendation, bb_score, nb_score, cloud, managed "
		"FROM forecasts ORDER BY night_label"
	).fetchall()
	conn.close()
	# '+1 night' sorts before 'Tonight'
	assert rows[0] == ("+1 night", "BB+NB", 78, 84, 95, 0)
	assert rows[1] == ("Tonight", "Neither", 46, 40, 6, 0)


def test_log_run_night_date_uses_observing_convention(tmp_path, monkeypatch):
	"""Tonight's dark window starts 2026-06-04T07:00Z. In a UTC-negative zone that
	is the evening of June 3 (observing night); in a positive zone it could be the
	4th. Assert it equals observing_date of the LOCAL dark-start — i.e. the same
	key the form will compute — rather than hard-coding a timezone."""
	monkeypatch.setattr(cl, "DB_PATH", tmp_path / "astrowidget.db")
	cl.log_run(_SCORING_OUTPUT, datetime(2026, 6, 4, 4, 0, tzinfo=timezone.utc))
	expected = cl.observing_date(cl._iso_to_local("2026-06-04T07:00"))
	conn = cl.connect()
	got = conn.execute(
		"SELECT night_date FROM forecasts WHERE night_label='Tonight'"
	).fetchone()[0]
	conn.close()
	assert got == expected


def test_log_run_is_best_effort_on_garbage(tmp_path, monkeypatch):
	"""Malformed input must NOT raise into the fetcher — it returns 0."""
	monkeypatch.setattr(cl, "DB_PATH", tmp_path / "astrowidget.db")
	assert cl.log_run({"sites": "not a list"}, datetime.now(timezone.utc)) == 0
	assert cl.log_run({}, datetime.now(timezone.utc)) == 0


def test_connect_is_idempotent(tmp_path, monkeypatch):
	"""Re-connecting re-runs the schema + _migrate safely on an already-current DB (a
	no-op). The ALTER branch on an OLD DB is covered by
	test_migrate_adds_raw_columns_to_old_db."""
	monkeypatch.setattr(cl, "DB_PATH", tmp_path / "astrowidget.db")
	cl.connect().close()
	conn = cl.connect()  # must not raise
	tables = {r[0] for r in conn.execute(
		"SELECT name FROM sqlite_master WHERE type='table'").fetchall()}
	conn.close()
	assert {"forecasts", "decisions", "fits_grades"} <= tables


def test_log_run_stores_raw_readings(tmp_path, monkeypatch):
	# A night enriched with displayFactors (what enrich_night_factors adds in the
	# fetcher) → the raw forecast READINGS land in the row, next to the scores.
	monkeypatch.setattr(cl, "DB_PATH", tmp_path / "astrowidget.db")
	out = {"sites": [{"id": "bainbridge", "status": "ok", "nights": [{
		"label": "Tonight", "recommendation": "BB+NB",
		"broadband": {"score": 80, "factors": {"cloud": 90}},
		"narrowband": {"score": 85}, "moon": {}, "best_window": None,
		"managed": False, "precip_peak_pct": 7,  # distinct from precipPct (5) below, so
		"dark_window": {"start": "2026-06-04T07:00", "end": "2026-06-04T09:27"},
		"displayFactors": {
			"seeing": {"raw": 2.5, "label": "Good"},
			"transparency": {"raw": 21.5, "label": "Above Average"},
			"source": "astrospheric",
			"cloudPct": 12, "cloudLow": 3, "cloudMid": 5, "cloudHigh": 8,
			"windKmh": 9, "gustsKmh": 14, "dewSpreadC": 4.2,
			"precipPct": 5, "visibilityKm": 24.0,
			"cloudConvergence": {"models": {}, "spread": 18},
		},
	}]}]}
	cl.log_run(out, datetime(2026, 6, 4, 6, 0, tzinfo=timezone.utc))
	conn = cl.connect()
	row = conn.execute(
		"SELECT seeing_raw, seeing_label, transparency_raw, transparency_label, "
		"st_source, cloud_pct, cloud_low, cloud_mid, cloud_high, wind_kmh, gusts_kmh, "
		"dew_spread_c, precip_pct, visibility_km, cloud_spread FROM forecasts").fetchone()
	conn.close()
	assert row == (2.5, "Good", 21.5, "Above Average", "astrospheric",
				   12, 3, 5, 8, 9, 14, 4.2, 5, 24.0, 18)


def test_log_run_handles_missing_displayfactors(tmp_path, monkeypatch):
	# A night with NO displayFactors (no hourly slice) → raw columns NULL, no crash.
	monkeypatch.setattr(cl, "DB_PATH", tmp_path / "astrowidget.db")
	out = {"sites": [{"id": "b", "status": "ok", "nights": [{
		"label": "Tonight", "recommendation": "Neither",
		"broadband": {"score": 30}, "narrowband": {"score": 25}, "moon": {},
		"dark_window": {"start": "2026-06-04T07:00", "end": "2026-06-04T09:00"},
	}]}]}
	n = cl.log_run(out, datetime(2026, 6, 4, 6, 0, tzinfo=timezone.utc))
	conn = cl.connect()
	sr = conn.execute("SELECT seeing_raw, cloud_pct FROM forecasts").fetchone()
	conn.close()
	assert n == 1 and sr == (None, None)


def test_migrate_adds_raw_columns_to_old_db(tmp_path, monkeypatch):
	# The riskiest new code: _migrate ALTERs an OLD forecasts table (no raw columns) to
	# add them. Build the pre-raw shape, connect (runs _migrate), and prove the columns
	# exist AND are writable (a reading round-trips), and that re-migrating is a no-op.
	import sqlite3
	monkeypatch.setattr(cl, "DB_PATH", tmp_path / "old.db")
	old = sqlite3.connect(str(cl.DB_PATH))
	# The PRE-raw forecasts schema (what a real old DB has): all original columns,
	# none of the 15 raw-reading ones. _migrate must add exactly those 15.
	old.execute("""CREATE TABLE forecasts (
		id INTEGER PRIMARY KEY, fetched_at TEXT, night_date TEXT, night_label TEXT,
		site_id TEXT, recommendation TEXT, bb_score INTEGER, bb_verdict TEXT,
		nb_score INTEGER, nb_verdict TEXT, cloud INTEGER, stability INTEGER,
		sky_brightness INTEGER, transparency INTEGER, moon_illum REAL, moon_alt REAL,
		precip_peak_pct INTEGER, best_window_start TEXT, best_window_end TEXT,
		managed INTEGER, dark_start TEXT, dark_end TEXT)""")
	old.commit(); old.close()

	conn = cl.connect()  # runs _migrate → ALTERs the raw columns in
	cols = {r[1] for r in conn.execute("PRAGMA table_info(forecasts)")}
	conn.close()
	assert {name for name, _ in cl._FORECAST_RAW_COLUMNS} <= cols  # all 15 added

	# The migrated columns are WRITABLE, not just named.
	out = {"sites": [{"id": "b", "status": "ok", "nights": [{
		"label": "Tonight", "recommendation": "Neither", "broadband": {"score": 30},
		"narrowband": {"score": 25}, "moon": {},
		"dark_window": {"start": "2026-06-04T07:00", "end": "2026-06-04T09:00"},
		"displayFactors": {"seeing": {"raw": 3.0, "label": "Fair"},
						   "transparency": {}, "source": "7timer", "cloudPct": 40,
						   "cloudLow": None, "cloudMid": None, "cloudHigh": None,
						   "windKmh": 5, "gustsKmh": None, "dewSpreadC": None,
						   "precipPct": 10, "visibilityKm": None,
						   "cloudConvergence": None},
	}]}]}
	cl.log_run(out, datetime(2026, 6, 4, 6, 0, tzinfo=timezone.utc))
	conn2 = cl.connect()  # re-migrate must be a no-op (no duplicate-column error)
	got = conn2.execute("SELECT seeing_raw, cloud_pct, st_source FROM forecasts").fetchone()
	conn2.close()
	assert got == (3.0, 40, "7timer")


def test_migrate_adds_grade_columns_to_old_db(tmp_path, monkeypatch):
	# Same migration path for fits_grades: an OLD grades table (no dir_date /
	# source_file_count) must gain both columns on connect(), and they must be writable.
	# Both tables must exist (_migrate PRAGMAs each); build their explicit PRE-DEF-3b shapes.
	import sqlite3
	monkeypatch.setattr(cl, "DB_PATH", tmp_path / "old_grades.db")
	old = sqlite3.connect(str(cl.DB_PATH))
	old.execute("""CREATE TABLE forecasts (
		id INTEGER PRIMARY KEY, fetched_at TEXT, night_date TEXT, night_label TEXT,
		site_id TEXT, recommendation TEXT, bb_score INTEGER, bb_verdict TEXT,
		nb_score INTEGER, nb_verdict TEXT, cloud INTEGER, stability INTEGER,
		sky_brightness INTEGER, transparency INTEGER, moon_illum REAL, moon_alt REAL,
		precip_peak_pct INTEGER, best_window_start TEXT, best_window_end TEXT,
		managed INTEGER, dark_start TEXT, dark_end TEXT)""")
	# Pre-DEF-3b fits_grades: original columns, NO dir_date / source_file_count.
	old.execute("""CREATE TABLE fits_grades (
		id INTEGER PRIMARY KEY, graded_at TEXT NOT NULL, night_date TEXT NOT NULL,
		site_id TEXT NOT NULL, target TEXT, filter TEXT, n_subs INTEGER,
		star_count_median REAL, star_count_trend REAL, bg_median REAL,
		transition_class TEXT, notes TEXT,
		UNIQUE(night_date, site_id, target, filter))""")
	old.commit()
	old.close()

	conn = cl.connect()  # runs _migrate → ALTERs the two grade columns in
	cols = {r[1] for r in conn.execute("PRAGMA table_info(fits_grades)")}
	assert {"dir_date", "source_file_count"} <= cols
	# Writable, not just named: a grade round-trips through the new columns.
	conn.execute(
		"""INSERT INTO fits_grades (graded_at, night_date, site_id, target, filter,
			n_subs, dir_date, source_file_count)
		   VALUES ('2026-06-20T00:00:00Z','2026-06-15','B','T','L',6,'2026-06-15',9)""")
	conn.commit()
	got = conn.execute(
		"SELECT dir_date, source_file_count FROM fits_grades").fetchone()
	conn.close()
	assert got == ("2026-06-15", 9)


def test_log_run_handles_null_cloud_convergence(tmp_path, monkeypatch):
	# Common production state (international sites / skipped convergence fetch):
	# displayFactors present, cloudConvergence None → cloud_spread NULL, no crash on
	# the `conv = df.get(...) or {}` guard.
	monkeypatch.setattr(cl, "DB_PATH", tmp_path / "astrowidget.db")
	out = {"sites": [{"id": "b", "status": "ok", "nights": [{
		"label": "Tonight", "recommendation": "BB+NB", "broadband": {"score": 70},
		"narrowband": {"score": 70}, "moon": {},
		"dark_window": {"start": "2026-06-04T07:00", "end": "2026-06-04T09:00"},
		"displayFactors": {"seeing": {"raw": 2.0, "label": "Good"},
						   "transparency": {"raw": 21.0, "label": "Average"},
						   "source": "astrospheric", "cloudPct": 10, "cloudLow": 2,
						   "cloudMid": 3, "cloudHigh": 5, "windKmh": 8, "gustsKmh": 12,
						   "dewSpreadC": 3.0, "precipPct": 0, "visibilityKm": 20.0,
						   "cloudConvergence": None},
	}]}]}
	cl.log_run(out, datetime(2026, 6, 4, 6, 0, tzinfo=timezone.utc))
	conn = cl.connect()
	spread = conn.execute("SELECT cloud_spread FROM forecasts").fetchone()[0]
	conn.close()
	assert spread is None


# ─────────────────────────────────────────────────────────────────────────────
# Decision-form support (Part 2)
# ─────────────────────────────────────────────────────────────────────────────


def test_upsert_decision_inserts_then_overwrites(tmp_path, monkeypatch):
	monkeypatch.setattr(cl, "DB_PATH", tmp_path / "astrowidget.db")
	conn = cl.connect()
	cl.upsert_decision(conn, "2026-06-03", "bainbridge", imaged=False, reason="cloudy")
	cl.upsert_decision(conn, "2026-06-03", "bainbridge", imaged=True, reason="cleared up")
	rows = conn.execute(
		"SELECT imaged, reason FROM decisions WHERE night_date='2026-06-03'").fetchall()
	conn.close()
	assert rows == [(1, "cleared up")]  # one row, overwritten


def test_upsert_decision_stores_pending_null(tmp_path, monkeypatch):
	monkeypatch.setattr(cl, "DB_PATH", tmp_path / "astrowidget.db")
	conn = cl.connect()
	cl.upsert_decision(conn, "2026-06-03", "bainbridge", imaged=None)
	got = conn.execute(
		"SELECT imaged FROM decisions WHERE night_date='2026-06-03'").fetchone()[0]
	conn.close()
	assert got is None


def test_ensure_pending_is_noop_when_answered(tmp_path, monkeypatch):
	monkeypatch.setattr(cl, "DB_PATH", tmp_path / "astrowidget.db")
	conn = cl.connect()
	cl.upsert_decision(conn, "2026-06-03", "bainbridge", imaged=True, reason="went out")
	cl.ensure_pending(conn, "2026-06-03", "bainbridge")  # must NOT clobber the answer
	got = conn.execute(
		"SELECT imaged, reason FROM decisions WHERE night_date='2026-06-03'").fetchone()
	conn.close()
	assert got == (1, "went out")


def test_latest_forecast_returns_most_recent(tmp_path, monkeypatch):
	monkeypatch.setattr(cl, "DB_PATH", tmp_path / "astrowidget.db")
	# Two fetches for the same night; latest_forecast must return the newer one.
	out = dict(_SCORING_OUTPUT)
	cl.log_run(_SCORING_OUTPUT, datetime(2026, 6, 4, 0, 0, tzinfo=timezone.utc))
	# Second fetch: Tonight's recommendation improved to BB+NB.
	out2 = {"sites": [{"id": "bainbridge", "status": "ok", "nights": [{
		"label": "Tonight", "recommendation": "BB+NB",
		"broadband": {"score": 80, "factors": {"cloud": 90}},
		"narrowband": {"score": 88}, "moon": {}, "best_window": None,
		"managed": False, "precip_peak_pct": 1,
		"dark_window": {"start": "2026-06-04T07:00", "end": "2026-06-04T09:27"},
	}]}]}
	cl.log_run(out2, datetime(2026, 6, 4, 6, 0, tzinfo=timezone.utc))
	conn = cl.connect()
	nd = cl.observing_date(cl._iso_to_local("2026-06-04T07:00"))
	fc = cl.latest_forecast(conn, nd, "bainbridge")
	conn.close()
	assert fc["recommendation"] == "BB+NB" and fc["bb_score"] == 80


def test_pending_nights_lists_unanswered_only(tmp_path, monkeypatch):
	monkeypatch.setattr(cl, "DB_PATH", tmp_path / "astrowidget.db")
	cl.log_run(_SCORING_OUTPUT, datetime(2026, 6, 4, 0, 0, tzinfo=timezone.utc))
	conn = cl.connect()
	nd = cl.observing_date(cl._iso_to_local("2026-06-04T07:00"))
	# Before answering, tonight is pending.
	assert nd in cl.pending_nights(conn, "bainbridge")
	# After answering, it drops off.
	cl.upsert_decision(conn, nd, "bainbridge", imaged=True)
	assert nd not in cl.pending_nights(conn, "bainbridge")
	conn.close()


def test_pending_nights_excludes_not_yet_occurred(tmp_path, monkeypatch):
	# A fetch logs the UPCOMING night as 'Tonight', so just after midnight a night that
	# hasn't started is already in forecasts. pending_nights must not surface it: with
	# as_of strictly before the night, it's excluded; once as_of reaches it, it appears.
	monkeypatch.setattr(cl, "DB_PATH", tmp_path / "astrowidget.db")
	cl.log_run(_SCORING_OUTPUT, datetime(2026, 6, 4, 0, 0, tzinfo=timezone.utc))
	conn = cl.connect()
	nd = cl.observing_date(cl._iso_to_local("2026-06-04T07:00"))
	assert cl.pending_nights(conn, "bainbridge", as_of="2000-01-01") == []
	assert nd in cl.pending_nights(conn, "bainbridge", as_of=nd)
	conn.close()


def test_get_decision_roundtrips(tmp_path, monkeypatch):
	# get_decision feeds the form's pre-fill: None when absent, the stored answer when set.
	monkeypatch.setattr(cl, "DB_PATH", tmp_path / "astrowidget.db")
	conn = cl.connect()
	assert cl.get_decision(conn, "2026-06-04", "bainbridge") is None
	cl.upsert_decision(conn, "2026-06-04", "bainbridge", imaged=False,
					   reason="Precipitation (rain / snow)", notes="rainy")
	assert cl.get_decision(conn, "2026-06-04", "bainbridge") == {
		"imaged": 0, "reason": "Precipitation (rain / snow)", "notes": "rainy"}
	conn.close()


def test_site_id_reads_join_across_case_but_writes_stay_binary(tmp_path, monkeypatch):
	"""Two-part pin of the site-id casing behavior (QA 2026-06-09).

	READ side (the fix): every site_id query carries COLLATE NOCASE, so a
	casing drift between writers (config vs systemd units vs DB history —
	the live DB holds mixed-case ids) degrades to NOTHING instead of weeks of
	silently-zero joins. 'Bainbridge' forecasts must join 'bainbridge'
	decisions regardless of the casing the caller queries with.

	WRITE side, pinned as EXPECTED CURRENT BEHAVIOR: the UNIQUE constraints
	remain BINARY-collated, so case-variant writers bifurcate into separate
	rows (a phantom forever-pending night). If someone later adds NOCASE to
	the constraint/migrates, the second half FAILS and forces a conscious
	review of existing-row migration — visible hazard beats invisible.
	"""
	monkeypatch.setattr(cl, "DB_PATH", tmp_path / "astrowidget.db")
	conn = cl.connect()
	try:
		# Seed one Tonight forecast under the capitalized id, dated yesterday
		# (pending_nights only surfaces nights that have already occurred).
		from datetime import timedelta
		night = (datetime.now().astimezone() - timedelta(days=1)).strftime("%Y-%m-%d")
		conn.execute(
			"INSERT INTO forecasts (fetched_at, night_date, night_label, site_id)"
			" VALUES (?, ?, 'Tonight', 'Bainbridge')",
			(datetime.now(timezone.utc).isoformat(), night))
		conn.commit()

		# READ: a lowercase pending row + an UPPERCASE query still join.
		cl.ensure_pending(conn, night, "bainbridge")
		assert cl.pending_nights(conn, "BAINBRIDGE") == [night]
		# Answering through yet another casing of the SAME row's site_id —
		# upsert targets (night_date, site_id) BINARY, so to answer the
		# existing row we must use ITS casing; the read-side join then clears.
		cl.upsert_decision(conn, night, "bainbridge", imaged=True)
		assert cl.pending_nights(conn, "Bainbridge") == []

		# WRITE: a case-variant upsert does NOT replace — it bifurcates.
		cl.upsert_decision(conn, night, "BAINBRIDGE", imaged=False, reason="x")
		n_rows = conn.execute(
			"SELECT COUNT(*) FROM decisions WHERE night_date = ?", (night,)
		).fetchone()[0]
		assert n_rows == 2, (
			"BINARY-collated UNIQUE bifurcated as expected; if this fails, "
			"the constraint went NOCASE — review existing-row migration!"
		)
	finally:
		conn.close()
