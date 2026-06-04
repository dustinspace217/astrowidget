"""
Tests for grader/grade.py — the transition classifier (Dustin's load-bearing rule).

Synthetic star-count series, so no FITS/NAS needed. The grade_session folder-walk +
DB write are exercised by the opt-in real-data validation, not here.
"""

from datetime import datetime, timedelta, timezone

import grade


def _series(values, start="2026-05-31T08:00:00"):
	"""Build a time-sorted metrics list from a star_proxy value sequence (5-min cadence)."""
	t0 = datetime.fromisoformat(start)
	return [
		{"date_obs": (t0 + timedelta(minutes=5 * i)).isoformat(), "star_proxy": v}
		for i, v in enumerate(values)
	]


def test_stable_night_holds():
	m = _series([10000, 9900, 10100, 9800, 10000, 9900, 10050])
	assert grade.classify_transition(m)["class"] == grade.STABLE


def test_gradual_decline_is_cloud_when_no_dawn():
	# A sustained downward drift, no single cliff → cloud/transparency event.
	m = _series([10000, 9500, 9000, 8000, 7000, 6000, 5000])
	out = grade.classify_transition(m, dawn_utc=None)
	assert out["class"] == grade.GRADUAL_CLOUD
	assert out["detail"]["decline_frac"] > 0.35


def test_sudden_cliff_is_artifact():
	# One sub-to-sub cliff carrying most of the decline → mechanical/obstruction.
	m = _series([10000, 9800, 9600, 2000, 1900, 1800, 1700])
	assert grade.classify_transition(m)["class"] == grade.SUDDEN_ARTIFACT


def test_gradual_decline_after_dawn_is_excluded():
	# Same gradual decline, but astronomical dawn is before the onset → DAWN (excluded).
	m = _series([10000, 9500, 9000, 8000, 7000, 6000, 5000])
	dawn = datetime.fromisoformat("2026-05-31T08:00:00").replace(tzinfo=timezone.utc)
	assert grade.classify_transition(m, dawn_utc=dawn)["class"] == grade.DAWN


def test_too_few_subs():
	assert grade.classify_transition(_series([10000, 9000, 8000]))["class"] == grade.TOO_FEW


def test_dateobs_parse_handles_naive_utc():
	dt = grade._parse_dateobs("2025-01-20T12:03:55.992")
	assert dt is not None and dt.tzinfo is not None
	assert grade._parse_dateobs("garbage") is None
