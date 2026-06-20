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


# ---- astro-dark restriction (2026-06-20: twilight/dawn subs corrupt the metric) ----

def test_restrict_to_dark_keeps_only_in_window_subs():
	"""Pure time filter: subs before dark_start (twilight) or after dark_end (dawn)
	are dropped; only the in-window subs survive into the metric."""
	ds = datetime.fromisoformat("2026-06-16T07:16:00+00:00")
	de = datetime.fromisoformat("2026-06-16T09:04:00+00:00")
	group = [
		{"date_obs": "2026-06-16T06:30:00", "star_proxy": 1},   # twilight (pre-dark)
		{"date_obs": "2026-06-16T07:00:00", "star_proxy": 2},   # twilight (pre-dark)
		{"date_obs": "2026-06-16T07:30:00", "star_proxy": 3},   # dark
		{"date_obs": "2026-06-16T08:30:00", "star_proxy": 4},   # dark
		{"date_obs": "2026-06-16T09:30:00", "star_proxy": 5},   # post-dawn
	]
	kept = grade._restrict_to_dark(group, ds, de)
	assert [m["star_proxy"] for m in kept] == [3, 4]


def test_restrict_to_dark_open_ended_when_no_dark_end():
	"""dark_end=None (dark runs past the search window) → no upper bound, keep all
	subs at or after dark_start."""
	ds = datetime.fromisoformat("2026-12-21T02:00:00+00:00")
	group = [
		{"date_obs": "2026-12-21T01:00:00", "star_proxy": 1},   # before dark
		{"date_obs": "2026-12-21T03:00:00", "star_proxy": 2},   # dark
		{"date_obs": "2026-12-21T06:00:00", "star_proxy": 3},   # dark
	]
	kept = grade._restrict_to_dark(group, ds, None)
	assert [m["star_proxy"] for m in kept] == [2, 3]


def test_dark_window_bainbridge_near_solstice():
	"""Real ephemeris (astropy): Bainbridge on the 2026-06-15 observing night has a
	short astro-dark window starting ~07:1x UTC and lasting under ~2.5 h — the
	near-solstice regime where starting before dark makes most subs twilight."""
	start = datetime.fromisoformat("2026-06-16T05:00:00+00:00")  # evening, pre-dark
	ds, de = grade._dark_window(start, 47.62, -122.5)
	assert ds is not None and de is not None
	assert ds < de                                # ordering, not just specific hours
	# dusk lands in the late-evening UTC hours (≈07:1x), dawn ≈09:0x.
	assert ds.hour == 7 and de.hour == 9
	dur_h = (de - ds).total_seconds() / 3600
	assert 1.0 < dur_h < 2.5


def test_dark_window_none_when_no_astro_dark():
	"""High latitude near solstice: the Sun never reaches −18°, so there is no astro-dark
	window → (None, None). grade_session falls back to unfiltered-and-flagged for these."""
	# ~69.6°N (Tromsø) on the June solstice — no astronomical night at all.
	start = datetime.fromisoformat("2026-06-21T18:00:00+00:00")
	ds, de = grade._dark_window(start, 69.6, 18.9)
	assert ds is None and de is None
