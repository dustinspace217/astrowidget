"""
Tests for grader/calibration_readiness.py — the "is there enough data for a re-tune?"
check. assess() is pure (takes an open conn), so these drive it with a synthetic DB
(isolated to a tmp file by the grader conftest). No FITS, no GUI.
"""

import calibration_log as cl
import calibration_readiness as cr


def _forecast(conn, night, cloud, site="Bainbridge", label="Tonight"):
	conn.execute(
		"INSERT INTO forecasts (fetched_at, night_date, night_label, site_id, "
		"recommendation, cloud) VALUES (?,?,?,?,?,?)",
		("2026-06-04T00:00:00Z", night, label, site, "x", cloud))
	conn.commit()


def _grade(conn, night, site="Bainbridge"):
	conn.execute(
		"INSERT INTO fits_grades (graded_at, night_date, site_id, target, filter, n_subs) "
		"VALUES (?,?,?,?,?,?)", ("x", night, site, "T", "L", 5))
	conn.commit()


def test_band_classification():
	assert cr._band(85) == "clear"
	assert cr._band(50) == "marginal"
	assert cr._band(20) == "cloudy"
	assert cr._band(None) == "unknown"


def test_empty_db_not_ready():
	conn = cl.connect()
	a = cr.assess(conn, "Bainbridge")
	conn.close()
	assert a["n"] == 0 and a["ready"] is False


def test_graded_night_is_joinable():
	conn = cl.connect()
	_forecast(conn, "2026-06-04", 85)
	_grade(conn, "2026-06-04")
	a = cr.assess(conn, "Bainbridge")
	conn.close()
	assert a["n"] == 1 and a["n_graded"] == 1
	assert a["rows"][0]["outcome"] == "imaged · graded" and a["rows"][0]["band"] == "clear"


def test_skip_decision_is_joinable():
	conn = cl.connect()
	_forecast(conn, "2026-06-04", 20)
	cl.upsert_decision(conn, "2026-06-04", "Bainbridge", imaged=False, reason="Cloudy")
	a = cr.assess(conn, "Bainbridge")
	conn.close()
	assert a["n"] == 1 and a["n_skipped"] == 1 and a["rows"][0]["outcome"] == "skipped"


def test_forecast_without_outcome_not_joinable():
	conn = cl.connect()
	_forecast(conn, "2026-06-04", 85)  # forecast logged, but no grade/decision
	a = cr.assess(conn, "Bainbridge")
	conn.close()
	assert a["n"] == 0


def test_grade_without_forecast_not_joinable():
	# Historical FITS (graded before forecast logging existed) can't be paired.
	conn = cl.connect()
	_grade(conn, "2026-05-20")
	a = cr.assess(conn, "Bainbridge")
	conn.close()
	assert a["n"] == 0


def test_readiness_needs_both_count_and_spread():
	conn = cl.connect()
	# 12 joinable nights but ALL clear → only one band → not ready.
	for i in range(12):
		nd = f"2026-06-{i + 1:02d}"
		_forecast(conn, nd, 85)
		_grade(conn, nd)
	a = cr.assess(conn, "Bainbridge", min_nights=12, min_bands=3)
	assert a["n"] == 12 and a["bands"] == ["clear"] and a["ready"] is False
	# Add a marginal + a cloudy night → 3 bands + enough nights → ready.
	_forecast(conn, "2026-07-01", 50); _grade(conn, "2026-07-01")
	_forecast(conn, "2026-07-02", 20); _grade(conn, "2026-07-02")
	a = cr.assess(conn, "Bainbridge", min_nights=12, min_bands=3)
	conn.close()
	assert len(a["bands"]) == 3 and a["ready"] is True
