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


# ---- header-coordinate site attribution (remote-site calibration 2026-06-10) ----

_SITES = [
	{"id": "Bainbridge", "lat": 47.62, "lon": -122.5},
	{"id": "SRO", "lat": 37.07, "lon": -119.4},
	{"id": "UDRO", "lat": 37.74, "lon": -113.7},
]


def test_nearest_site_matches_within_tolerance():
	# Header coords a few hundredths of a degree off (header rounding) still match.
	assert grade._nearest_site(47.6167, -122.502, _SITES)["id"] == "Bainbridge"
	assert grade._nearest_site(37.0703, -119.4131, _SITES)["id"] == "SRO"


def test_nearest_site_rejects_far_coordinates():
	# A site not in the config (e.g. Siding Spring) must NOT fuzzy-match anything.
	assert grade._nearest_site(-31.27, 149.07, _SITES) is None


def test_sweep_attributes_sessions_by_header_coords(tmp_path, monkeypatch):
	"""Attribution mode: two sessions from different sites (per their header coords)
	land under their own site_ids — the home/remote mislabeling bug stays dead."""
	night = _offset(1)
	_make_session(tmp_path, "M81", night, rig="Eon 70")
	_make_session(tmp_path, "Caldwell 5", night, rig="T68")
	coords = {"Eon 70": (47.6167, -122.502), "T68": (37.7378, -113.6975)}

	def _fake_read_sub(p, k=5.0):
		rig = next(r for r in coords if r in str(p))
		la, lo = coords[rig]
		return _sub("2026-06-09T08:00:00", 1000, path=str(p)) | {
			"lat_obs": la, "lon_obs": lo}

	monkeypatch.setattr(grade.fm, "read_sub", _fake_read_sub)
	written = grade.grade_pending(str(tmp_path), sites=_SITES)
	by_site = {g["site_id"]: g["target"] for g in written}
	assert by_site == {"Bainbridge": "M81 / Eon 70", "UDRO": "Caldwell 5 / T68"}


def test_sweep_skips_unattributable_sessions(tmp_path, monkeypatch):
	"""No header coords (or no config match) → skipped loudly, never guessed."""
	_make_session(tmp_path, "M81", _offset(1), rig="Mystery")
	monkeypatch.setattr(
		grade.fm, "read_sub",
		lambda p, k=5.0: _sub("2026-06-09T08:00:00", 1000, path=str(p)))  # no lat_obs
	written = grade.grade_pending(str(tmp_path), sites=_SITES)
	assert written == []
	conn = cl.connect()
	try:
		n = conn.execute("SELECT COUNT(*) FROM fits_grades").fetchone()[0]
	finally:
		conn.close()
	assert n == 0


def test_sweep_attribution_skip_check_is_site_agnostic(tmp_path, monkeypatch):
	"""A night+target already graded under its site is skipped WITHOUT re-reading
	headers (the done-check covers all sites in attribution mode)."""
	night = _offset(1)
	_make_session(tmp_path, "Caldwell 5", night, rig="T68")
	grade._write_grades(_canned_grade(str(tmp_path / "Caldwell 5" / "T68" / night),
									  target="Caldwell 5 / T68"), "UDRO")

	def _boom(p, k=5.0):  # any header read would mean the skip-check failed
		raise AssertionError("read_sub called for an already-graded session")

	monkeypatch.setattr(grade.fm, "read_sub", _boom)
	written = grade.grade_pending(str(tmp_path), sites=_SITES)
	assert written == []


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


# ---- astro-dark restriction in grade_session (2026-06-20) -------------------

def test_grade_session_excludes_pre_dark_subs(tmp_path, monkeypatch):
	"""WITH site coords, grade_session restricts the metric to true astro-dark: subs
	taken before dark_start (twilight) are dropped, so n_subs and the median reflect
	only the dark core. Bainbridge near solstice — dark_start ≈07:16Z on 2026-06-16."""
	d = _populate(tmp_path, 8)
	# i 0..2 twilight (pre-dark, star count ramping up); i 3..7 dark (stable ~1000).
	times = ["06:30", "06:45", "07:00", "07:30", "07:45", "08:00", "08:15", "08:30"]
	procs = [100, 200, 300, 1000, 1010, 1005, 1015, 1008]
	_stub_read_sub(monkeypatch,
				   lambda i, p: _sub(f"2026-06-16T{times[i]}:00", procs[i], filt="H", path=p))
	grades = grade.grade_session(str(d), "Bainbridge",
								 lat=47.62, lon=-122.5, target="Iris / Eon 70")
	assert len(grades) == 1
	g = grades[0]
	assert g["n_subs"] == 5                      # 3 twilight subs excluded
	assert g["star_count_median"] > 900          # median = dark core, not dragged down
	assert "outside astro-dark excluded" in (g["notes"] or "")


def test_grade_session_all_twilight_group_emits_zero_row(tmp_path, monkeypatch):
	"""A group shot ENTIRELY before dark (Ha front-loaded in twilight) yields a row with
	n_subs=0 — so re-grading REPLACEs a stale contaminated grade instead of leaving it.
	The row is emitted (not silently skipped)."""
	d = _populate(tmp_path, 4)
	twi = ["06:00", "06:15", "06:30", "06:45"]   # all before ~07:16Z dark_start
	_stub_read_sub(monkeypatch,
				   lambda i, p: _sub(f"2026-06-16T{twi[i]}:00", 100 + i, filt="H", path=p))
	grades = grade.grade_session(str(d), "Bainbridge",
								 lat=47.62, lon=-122.5, target="Iris / Eon 70")
	assert len(grades) == 1
	assert grades[0]["n_subs"] == 0
	assert grades[0]["transition"] == grade.TOO_FEW


def test_grade_session_no_coords_grades_whole_group(tmp_path, monkeypatch):
	"""WITHOUT coords there's no dark window, so grade_session grades the whole group
	unrestricted (existing behavior preserved) — nothing dropped, no astro-dark note."""
	d = _populate(tmp_path, 6)
	# Times that WOULD straddle a dark boundary if coords were supplied.
	times = ["06:30", "06:45", "07:30", "08:00", "08:30", "09:30"]
	_stub_read_sub(monkeypatch,
				   lambda i, p: _sub(f"2026-06-16T{times[i]}:00", 1000, filt="H", path=p))
	grades = grade.grade_session(str(d), "Bainbridge", target="Iris / Eon 70")  # no lat/lon
	assert len(grades) == 1
	assert grades[0]["n_subs"] == 6                       # nothing excluded without coords
	assert "astro-dark" not in (grades[0]["notes"] or "")


def test_grade_session_already_dark_no_dusk_exclusion(tmp_path, monkeypatch):
	"""Imaging STARTS after astro-dark began (earliest sub already past −18°) → there are
	no twilight subs, so nothing is excluded on the dusk side. Documents that the dusk
	no-op is CORRECT here (no twilight exists), not the bug a reviewer suspected."""
	d = _populate(tmp_path, 5)
	# All subs 08:00–08:40Z = 01:00–01:40 PDT, inside the 06-15 dark window [~07:16,~09:04]Z.
	times = ["08:00", "08:10", "08:20", "08:30", "08:40"]
	_stub_read_sub(monkeypatch,
				   lambda i, p: _sub(f"2026-06-16T{times[i]}:00", 1000, filt="L", path=p))
	grades = grade.grade_session(str(d), "Bainbridge",
								 lat=47.62, lon=-122.5, target="Iris / Eon 70")
	assert len(grades) == 1
	assert grades[0]["n_subs"] == 5                       # all kept — none were twilight
	assert "outside astro-dark" not in (grades[0]["notes"] or "")


def test_grade_session_two_filters_one_twilight_one_dark(tmp_path, monkeypatch):
	"""One dark window, applied PER group: an all-twilight filter → n_subs=0 row, an
	all-dark filter → full row, from the same session. The all-twilight row must still
	carry the night_date (else it silently breaks the calibration join)."""
	d = _populate(tmp_path, 8)
	# 0..3 Ha all twilight (pre-dark); 4..7 L all dark.
	specs = [("H", "06:00"), ("H", "06:15"), ("H", "06:30"), ("H", "06:45"),
			 ("L", "07:30"), ("L", "07:45"), ("L", "08:00"), ("L", "08:15")]
	_stub_read_sub(monkeypatch, lambda i, p: _sub(
		f"2026-06-16T{specs[i][1]}:00", 1000, filt=specs[i][0], path=p))
	grades = grade.grade_session(str(d), "Bainbridge",
								 lat=47.62, lon=-122.5, target="Iris / Eon 70")
	by_filter = {g["filter"]: g for g in grades}
	assert by_filter["H"]["n_subs"] == 0                 # all twilight → excluded
	assert by_filter["L"]["n_subs"] == 4                 # all dark → kept
	assert by_filter["H"]["night_date"] and \
		by_filter["H"]["night_date"] == by_filter["L"]["night_date"]


def test_force_regrade_overwrites_existing_row(tmp_path, monkeypatch):
	"""--force re-grades an already-graded night and the write REPLACEs the prior row
	(INSERT OR REPLACE on the UNIQUE key) instead of skipping it. Without --force the
	night is skipped."""
	_make_session(tmp_path, "M81", _offset(2))
	night = _offset(2)
	state = {"n": 5}

	def _fake_session(folder, site_id="Bainbridge", lat=None, lon=None, target=None):
		return [{"target": target or "M81 / Eon70", "filter": "L", "n_subs": state["n"],
				 "star_count_median": 1000.0, "star_count_trend": 0.0, "bg_median": 100.0,
				 "transition": grade.STABLE, "detail": {}, "night_date": night,
				 "site_id": site_id}]

	monkeypatch.setattr(grade, "grade_session", _fake_session)
	# First grade writes n_subs=5.
	grade.grade_pending(str(tmp_path), "Bainbridge", write=True, since_days=0)
	# Without --force: already graded → skipped, even though grade_session would now say 9.
	state["n"] = 9
	assert grade.grade_pending(str(tmp_path), "Bainbridge", write=True, since_days=0) == []
	# With --force: re-grades and REPLACEs the row.
	w3 = grade.grade_pending(str(tmp_path), "Bainbridge", write=True, since_days=0, force=True)
	assert len(w3) == 1
	conn = cl.connect()
	try:
		rows = conn.execute(
			"SELECT n_subs FROM fits_grades WHERE night_date=? AND target=?",
			(night, "M81 / Eon70")).fetchall()
	finally:
		conn.close()
	assert len(rows) == 1 and rows[0][0] == 9            # one row, REPLACEd to 9


def test_grade_session_flags_dawn_off_on_gradual_cloud(tmp_path, monkeypatch):
	d = _populate(tmp_path, 6)
	vals = [10000, 9000, 8000, 7000, 6000, 5000]  # sustained gradual decline → cloud
	_stub_read_sub(monkeypatch, lambda i, p: _sub(f"2026-05-31T08:{i:02d}:00", vals[i], path=p))
	# No coords → dawn-exclusion off → the gradual-cloud verdict is flagged unverified.
	grades = grade.grade_session(str(d), "Bainbridge", lat=None, lon=None, target="T / Rig")
	assert len(grades) == 1 and grades[0]["transition"] == grade.GRADUAL_CLOUD
	assert grades[0]["notes"] and "dawn-exclusion off" in grades[0]["notes"]
