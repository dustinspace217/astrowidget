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
	"""Re-connecting re-runs the schema safely (IF NOT EXISTS) — also the forward
	migration path."""
	monkeypatch.setattr(cl, "DB_PATH", tmp_path / "astrowidget.db")
	cl.connect().close()
	conn = cl.connect()  # must not raise
	tables = {r[0] for r in conn.execute(
		"SELECT name FROM sqlite_master WHERE type='table'").fetchall()}
	conn.close()
	assert {"forecasts", "decisions", "fits_grades"} <= tables
