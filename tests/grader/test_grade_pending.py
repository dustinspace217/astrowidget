"""
Tests for the daily-sweep auto-grader (grade.py).

Covers the SELECTION + write orchestration of grade_pending and its helpers
(_session_dirs, _graded_keys, _site_coords) plus DB-level idempotency. The FITS read
is mocked — grade_session is monkeypatched to a canned stand-in — so nothing here
touches the NAS or astropy. The real FITS path is covered by the opt-in real-data
validation, not the unit suite.
"""

from datetime import datetime, timedelta
from pathlib import Path

import pytest

import calibration_log as cl
import grade


# ---- helpers ---------------------------------------------------------------

def _make_session(root: Path, target: str, date: str, rig: str | None = "Eon70",
				  n_files: int = 3) -> Path:
	"""Create a Raws/<target>[/<rig>]/<date>/ folder with n_files placeholder .fits
	files (empty — the real read is mocked). Returns the date folder."""
	d = root / target / rig / date if rig else root / target / date
	d.mkdir(parents=True, exist_ok=True)
	for i in range(n_files):
		(d / f"{rig or target}_{target}_{date}_L_{i:04d}.fits").write_bytes(b"")
	return d


def _offset(days: int) -> str:
	"""A YYYY-MM-DD string `days` BEFORE today's local date (negative = future)."""
	return (datetime.now().astimezone().date() - timedelta(days=days)).isoformat()


def _canned_grade(folder: str, site_id="Bainbridge", lat=None, lon=None, target=None):
	"""Stand-in for grade_session: no FITS read. Returns one grade whose night_date is
	the folder's own date name, so written rows line up with the dir_date the sweep
	used for its skip checks."""
	night = Path(folder).name
	return [{
		"target": target or "T", "filter": "L", "n_subs": 5,
		"star_count_median": 1000.0, "star_count_trend": 0.0, "bg_median": 100.0,
		"transition": grade.STABLE, "detail": {}, "night_date": night,
		"site_id": site_id,
	}]


@pytest.fixture
def recorded(monkeypatch):
	"""Patch grade.grade_session to record (date, target) it's asked to grade, while
	returning canned grades. Yields the list of calls."""
	calls: list[tuple[str, str]] = []

	def _fn(folder, site_id="Bainbridge", lat=None, lon=None, target=None):
		calls.append((Path(folder).name, target))
		return _canned_grade(folder, site_id, lat, lon, target)

	monkeypatch.setattr(grade, "grade_session", _fn)
	return calls


# ---- _session_dirs ---------------------------------------------------------

def test_session_dirs_depth3(tmp_path):
	# NINA's Raws/<Target>/<Rig>/<date>/ layout. The identity folds in the rig so two
	# rigs on one target don't collide on the DB UNIQUE key.
	_make_session(tmp_path, "M81", "2026-05-31")
	found = list(grade._session_dirs(str(tmp_path)))
	assert len(found) == 1
	_dir, target, rig, date = found[0]
	assert target == "M81 / Eon70" and rig == "Eon70" and date == "2026-05-31"


def test_session_dirs_depth2(tmp_path):
	# Missing <Rig> level (Raws/<Target>/<date>/) still resolves target + date; rig=None.
	_make_session(tmp_path, "M31", "2026-05-30", rig=None)
	found = list(grade._session_dirs(str(tmp_path)))
	assert len(found) == 1
	_dir, target, rig, date = found[0]
	assert target == "M31" and rig is None and date == "2026-05-30"


def test_session_dirs_ignores_nondate_dirs(tmp_path):
	# A non-date folder (e.g. a stray "LIGHT" or "Calibration" dir) is not a session.
	(tmp_path / "M81" / "Eon70" / "Calibration").mkdir(parents=True)
	(tmp_path / "M81" / "Eon70" / "2026-05-31").mkdir(parents=True)
	dates = {date for _d, _t, _r, date in grade._session_dirs(str(tmp_path))}
	assert dates == {"2026-05-31"}


# ---- grade_pending selection ----------------------------------------------

def test_grades_a_new_complete_night(tmp_path, recorded):
	_make_session(tmp_path, "M81", _offset(1))  # last night
	written = grade.grade_pending(str(tmp_path), "Bainbridge")
	assert recorded == [(_offset(1), "M81 / Eon70")]
	assert len(written) == 1
	# And it landed in the DB.
	conn = cl.connect()
	try:
		n = conn.execute("SELECT COUNT(*) FROM fits_grades").fetchone()[0]
	finally:
		conn.close()
	assert n == 1


def test_skips_today_and_future(tmp_path, recorded):
	_make_session(tmp_path, "M81", _offset(0))   # tonight — not complete
	_make_session(tmp_path, "M82", _offset(-1))  # tomorrow — future
	grade.grade_pending(str(tmp_path), "Bainbridge")
	assert recorded == []  # neither graded


def test_skips_already_graded_night(tmp_path, recorded):
	night = _offset(2)
	# Pre-populate the DB as if this night+target was already graded. The target must
	# match the rig-folded identity the sweep derives ("M81 / Eon70").
	grade._write_grades(_canned_grade(str(tmp_path / "M81" / "Eon70" / night),
									  target="M81 / Eon70"), "Bainbridge")
	_make_session(tmp_path, "M81", night)
	grade.grade_pending(str(tmp_path), "Bainbridge")
	assert recorded == []  # already in fits_grades → skipped


def test_skips_nights_older_than_window(tmp_path, recorded):
	_make_session(tmp_path, "M81", _offset(40))  # older than default 30-day window
	grade.grade_pending(str(tmp_path), "Bainbridge", since_days=30)
	assert recorded == []


def test_since_days_zero_backfills_old(tmp_path, recorded):
	_make_session(tmp_path, "M81", _offset(40))
	grade.grade_pending(str(tmp_path), "Bainbridge", since_days=0)
	assert recorded == [(_offset(40), "M81 / Eon70")]


def test_mixed_tree_selects_only_eligible(tmp_path, recorded):
	_make_session(tmp_path, "M81", _offset(1))   # last night → grade
	_make_session(tmp_path, "M82", _offset(0))   # tonight → skip
	_make_session(tmp_path, "M31", _offset(40))  # too old → skip
	_make_session(tmp_path, "NGC", _offset(3))   # in window, complete → grade
	grade.grade_pending(str(tmp_path), "Bainbridge")
	graded = {target for _date, target in recorded}
	assert graded == {"M81 / Eon70", "NGC / Eon70"}


# ---- idempotency -----------------------------------------------------------

def test_write_grades_is_idempotent(tmp_path):
	g = _canned_grade(str(tmp_path / "M81" / "Eon70" / "2026-05-31"), target="M81")
	grade._write_grades(g, "Bainbridge")
	grade._write_grades(g, "Bainbridge")  # re-grade same night+target+filter
	conn = cl.connect()
	try:
		n = conn.execute("SELECT COUNT(*) FROM fits_grades").fetchone()[0]
	finally:
		conn.close()
	assert n == 1  # UNIQUE(night_date, site_id, target, filter) → REPLACE, not dup


def test_pending_run_twice_does_not_duplicate(tmp_path, recorded):
	_make_session(tmp_path, "M81", _offset(1))
	grade.grade_pending(str(tmp_path), "Bainbridge")
	grade.grade_pending(str(tmp_path), "Bainbridge")  # second sweep
	conn = cl.connect()
	try:
		n = conn.execute("SELECT COUNT(*) FROM fits_grades").fetchone()[0]
	finally:
		conn.close()
	assert n == 1  # second run sees it already graded → no new row


# ---- _graded_keys ----------------------------------------------------------

def test_graded_keys_returns_night_target_pairs(tmp_path):
	grade._write_grades(_canned_grade(str(tmp_path / "A" / "r" / "2026-05-30"),
									  target="A"), "Bainbridge")
	grade._write_grades(_canned_grade(str(tmp_path / "B" / "r" / "2026-05-31"),
									  target="B"), "Bainbridge")
	conn = cl.connect()
	try:
		keys = grade._graded_keys(conn, "Bainbridge")
	finally:
		conn.close()
	assert keys == {("2026-05-30", "A"), ("2026-05-31", "B")}


# ---- _site_coords ----------------------------------------------------------

def test_site_coords_reads_config(tmp_path):
	cfg = tmp_path / "config.toml"
	# Obviously-fake round-number coords (the repo is PUBLIC): the old fixture
	# carried 47.62/-122.52, which matched the real home config to fixture
	# precision — location PII in a public tree (QA 2026-06-09). The site NAME
	# stays; only coords must be synthetic, per test_fetch_astrospheric's model.
	cfg.write_text(
		'[[sites]]\nid = "Bainbridge"\nlat = 47.0\nlon = -122.0\n'
		'[[sites]]\nid = "UDRO"\nlat = 38.0\nlon = -113.0\n'
	)
	assert grade._site_coords("Bainbridge", str(cfg)) == (47.0, -122.0)
	assert grade._site_coords("UDRO", str(cfg)) == (38.0, -113.0)


def test_site_coords_missing_config_returns_none(tmp_path):
	assert grade._site_coords("Bainbridge", str(tmp_path / "nope.toml")) == (None, None)


def test_site_coords_unknown_site_returns_none(tmp_path):
	cfg = tmp_path / "config.toml"
	cfg.write_text('[[sites]]\nid = "Bainbridge"\nlat = 47.0\nlon = -122.0\n')
	assert grade._site_coords("Mars", str(cfg)) == (None, None)


def test_site_coords_malformed_toml_returns_none(tmp_path):
	cfg = tmp_path / "config.toml"
	cfg.write_text("this is not = valid toml [[[")
	assert grade._site_coords("Bainbridge", str(cfg)) == (None, None)


def test_site_coords_non_numeric_returns_none(tmp_path):
	# Quoted coordinates (a real foot-gun) must not silently pass through as strings.
	cfg = tmp_path / "config.toml"
	cfg.write_text('[[sites]]\nid = "Bainbridge"\nlat = "47.0"\nlon = "-122.0"\n')
	assert grade._site_coords("Bainbridge", str(cfg)) == (None, None)


# ---- rig disambiguation (two rigs, one target, same night) -----------------

def test_two_rigs_same_target_do_not_overwrite(tmp_path, recorded):
	"""Two rigs imaging the same target the same night must yield two DISTINCT grades,
	not one silently REPLACE-ing the other on the UNIQUE key."""
	night = _offset(1)
	_make_session(tmp_path, "M81", night, rig="Eon70")
	_make_session(tmp_path, "M81", night, rig="RC8")
	grade.grade_pending(str(tmp_path), "Bainbridge")
	assert set(recorded) == {(night, "M81 / Eon70"), (night, "M81 / RC8")}
	conn = cl.connect()
	try:
		n = conn.execute("SELECT COUNT(*) FROM fits_grades").fetchone()[0]
	finally:
		conn.close()
	assert n == 2  # both rigs persisted, neither overwritten


def test_rigs_filter_grades_only_home_rig(tmp_path, recorded):
	"""rigs={...} restricts the sweep to a site's own rigs, so iTelescope rentals in
	the same Raws/ tree aren't graded under the home site (the real-world bug)."""
	night = _offset(1)
	_make_session(tmp_path, "M81", night, rig="Eon 70")   # home scope
	_make_session(tmp_path, "Caldwell 5", night, rig="T26")  # iTelescope rental
	grade.grade_pending(str(tmp_path), "Bainbridge", rigs={"Eon 70"})
	assert set(recorded) == {(night, "M81 / Eon 70")}  # only the home rig graded


# ---- resilience + boundaries ----------------------------------------------

def test_one_bad_session_does_not_sink_the_sweep(tmp_path, monkeypatch):
	_make_session(tmp_path, "GOOD", _offset(1))
	_make_session(tmp_path, "BAD", _offset(2))

	def _fn(folder, site_id="Bainbridge", lat=None, lon=None, target=None):
		if "BAD" in str(folder):
			raise RuntimeError("simulated unreadable session")
		return _canned_grade(folder, site_id, lat, lon, target)

	monkeypatch.setattr(grade, "grade_session", _fn)
	written = grade.grade_pending(str(tmp_path), "Bainbridge")
	assert len(written) == 1 and written[0]["target"] == "GOOD / Eon70"


def test_cutoff_boundary_is_inclusive(tmp_path, recorded):
	# A night EXACTLY since_days old is inside the window (skip is dir_date < cutoff).
	_make_session(tmp_path, "EDGE", _offset(30))
	grade.grade_pending(str(tmp_path), "Bainbridge", since_days=30)
	assert recorded == [(_offset(30), "EDGE / Eon70")]


def test_one_day_past_cutoff_is_skipped(tmp_path, recorded):
	_make_session(tmp_path, "OLD", _offset(31))
	grade.grade_pending(str(tmp_path), "Bainbridge", since_days=30)
	assert recorded == []


def test_today_dated_folder_isolated_is_skipped(tmp_path, recorded):
	_make_session(tmp_path, "TONIGHT", _offset(0))
	grade.grade_pending(str(tmp_path), "Bainbridge")
	assert recorded == []


def test_dry_run_returns_grades_but_writes_nothing(tmp_path, recorded):
	_make_session(tmp_path, "M81", _offset(1))
	written = grade.grade_pending(str(tmp_path), "Bainbridge", write=False)
	assert len(written) == 1
	conn = cl.connect()
	try:
		n = conn.execute("SELECT COUNT(*) FROM fits_grades").fetchone()[0]
	finally:
		conn.close()
	assert n == 0


# ---- grade_session real path (mock read_sub one level down) -----------------
# These exercise the UNMOCKED grade_session — the target override, the IMAGETYP
# calibration filter, and the notes provenance — by stubbing fits_metrics.read_sub
# so no FITS/astropy is touched. The sweep tests above mock grade_session wholesale;
# these cover what that mock hides.

def _sub(date_obs, star_proxy, filt="L", imagetyp="LIGHT", median_bg=100.0, path="x.fits"):
	"""A canned read_sub() return — one sub's metrics dict."""
	return {"date_obs": date_obs, "filter": filt, "imagetyp": imagetyp,
			"moonangl": None, "exptime": 180.0, "median_bg": median_bg,
			"star_proxy": star_proxy, "path": path}


def _stub_read_sub(monkeypatch, per_index):
	"""Patch fm.read_sub to return per_index(i, path) on the i-th call (sorted order)."""
	state = {"i": 0}

	def _fake(p, k=5.0):
		i = state["i"]
		state["i"] += 1
		return per_index(i, p)

	monkeypatch.setattr(grade.fm, "read_sub", _fake)


def _populate(tmp_path, n):
	d = tmp_path / "T" / "Rig" / "2026-05-31"
	d.mkdir(parents=True)
	for i in range(n):
		(d / f"f{i}.fits").write_bytes(b"")
	return d


def test_grade_session_honors_target_override(tmp_path, monkeypatch):
	d = _populate(tmp_path, 5)
	_stub_read_sub(monkeypatch, lambda i, p: _sub(f"2026-05-31T08:{i:02d}:00", 1000, path=p))
	grades = grade.grade_session(str(d), "Bainbridge", target="My Target / Rig")
	assert len(grades) == 1 and grades[0]["target"] == "My Target / Rig"


def test_grade_session_excludes_calibration_frames(tmp_path, monkeypatch):
	d = _populate(tmp_path, 6)
	types = ["LIGHT", "LIGHT", "FLAT", "LIGHT", "DARK", "LIGHT"]  # 4 lights, 2 calib
	_stub_read_sub(monkeypatch,
				   lambda i, p: _sub(f"2026-05-31T08:{i:02d}:00", 1000, imagetyp=types[i], path=p))
	grades = grade.grade_session(str(d), "Bainbridge", target="T / Rig")
	assert len(grades) == 1 and grades[0]["n_subs"] == 4  # calibration dropped


def test_grade_session_keeps_subs_without_imagetyp(tmp_path, monkeypatch):
	# Permissive: a missing IMAGETYP (non-NINA file) is treated as a light, not dropped.
	d = _populate(tmp_path, 4)
	_stub_read_sub(monkeypatch,
				   lambda i, p: _sub(f"2026-05-31T08:{i:02d}:00", 1000, imagetyp=None, path=p))
	grades = grade.grade_session(str(d), "Bainbridge", target="T / Rig")
	assert len(grades) == 1 and grades[0]["n_subs"] == 4


def test_grade_session_stamps_partial_read_in_notes(tmp_path, monkeypatch):
	d = _populate(tmp_path, 5)

	def _per(i, p):
		if i in (1, 3):
			raise OSError("simulated unreadable sub")
		return _sub(f"2026-05-31T08:{i:02d}:00", 1000, path=p)

	_stub_read_sub(monkeypatch, _per)
	grades = grade.grade_session(str(d), "Bainbridge", target="T / Rig")
	assert len(grades) == 1 and grades[0]["n_subs"] == 3
	assert grades[0]["notes"] and "read 3/5 subs" in grades[0]["notes"]


def test_grade_session_flags_dawn_off_on_gradual_cloud(tmp_path, monkeypatch):
	d = _populate(tmp_path, 6)
	vals = [10000, 9000, 8000, 7000, 6000, 5000]  # sustained gradual decline → cloud
	_stub_read_sub(monkeypatch, lambda i, p: _sub(f"2026-05-31T08:{i:02d}:00", vals[i], path=p))
	# No coords → dawn-exclusion off → the gradual-cloud verdict is flagged unverified.
	grades = grade.grade_session(str(d), "Bainbridge", lat=None, lon=None, target="T / Rig")
	assert len(grades) == 1 and grades[0]["transition"] == grade.GRADUAL_CLOUD
	assert grades[0]["notes"] and "dawn-exclusion off" in grades[0]["notes"]
