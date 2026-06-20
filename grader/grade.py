"""
grade.py — session grading for the astrowidget auto-grader (Phase 3, spec §6b/§6c).

Reads a night's FITS subs (via fits_metrics), groups them by target+filter, and
classifies the star-count trend across the session using **Dustin's load-bearing
rule**:

  - **Gradual decline → clouds OR dawn.** Dawn is deterministic (compare the decline
    onset to astronomical dawn at the site) and is EXCLUDED; a gradual decline not
    explained by dawn is a cloud/transparency event → fed to weather calibration.
  - **Sudden cliff → usually mechanical / obstruction** (flip-flat closed, tree, dew-
    over). FLAGGED as an artifact, excluded from weather calibration — it would
    otherwise mislabel a closed flat-panel as "cloudy". "Usually, not always" — so we
    surface it, never silently discard.

The classifier takes a plain time-sorted series, so it's unit-tested with synthetic
sessions (no FITS needed). grade_session is the folder→grade wrapper; main() is the
CLI that prints the grade and (optionally) writes a fits_grades row joined to the
forecast + the nightly decision by observing-night date.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "fetcher"))
import fits_metrics as fm  # noqa: E402

# Transition classes.
STABLE = "stable"
GRADUAL_CLOUD = "gradual-cloud"
SUDDEN_ARTIFACT = "sudden-artifact"
DAWN = "dawn"
TOO_FEW = "too-few"


def _parse_dateobs(iso: str | None) -> datetime | None:
	"""Parse a FITS DATE-OBS (UTC, usually no offset) to an aware UTC datetime."""
	if not isinstance(iso, str) or not iso:
		return None
	s = iso.replace("Z", "+00:00")
	try:
		dt = datetime.fromisoformat(s)
	except ValueError:
		return None
	return dt.replace(tzinfo=timezone.utc) if dt.tzinfo is None else dt.astimezone(timezone.utc)


def classify_transition(
	metrics: list[dict[str, Any]],
	dawn_utc: datetime | None = None,
	decline_frac: float = 0.35,
	sudden_frac: float = 0.6,
) -> dict[str, Any]:
	"""Classify the star-count trend across ONE target+filter session.

	Receives: [metrics] time-sorted per-sub dicts (need 'date_obs' + 'star_proxy');
	    [dawn_utc] astronomical dawn for the night (for dawn-exclusion), or None to
	    skip it; [decline_frac] last-third must fall this far below the first-third to
	    count as a decline; [sudden_frac] the single largest inter-sub drop must be at
	    least this fraction of the total decline to read as a sudden cliff.
	Returns: {class, detail{...}} where class is one of the constants above.

	Thresholds are heuristic defaults — calibrate them against known nights (the
	May 30 clear / May 31 overcast Bode's pair) once enough are graded.
	"""
	n = len(metrics)
	if n < 4:
		return {"class": TOO_FEW, "detail": {"n_subs": n}}
	sp = np.array([m.get("star_proxy") or 0 for m in metrics], dtype=float)
	third = max(1, n // 3)
	first = float(np.median(sp[:third]))
	last = float(np.median(sp[-third:]))
	if first <= 0:
		return {"class": TOO_FEW, "detail": {"reason": "no signal in opening subs"}}

	total_decline = (first - last) / first  # >0 = the night got worse
	detail = {"n_subs": n, "first_third": first, "last_third": last,
			  "decline_frac": round(total_decline, 3)}
	if total_decline < decline_frac:
		return {"class": STABLE, "detail": detail}

	# Declining. Locate the biggest single sub-to-sub fractional drop (a cliff).
	steps = (sp[:-1] - sp[1:]) / first        # positive = a drop between i and i+1
	i = int(np.argmax(steps))
	max_step = float(steps[i])
	onset = _parse_dateobs(metrics[i + 1].get("date_obs"))
	detail.update({"max_step_frac": round(max_step, 3),
				   "onset": metrics[i + 1].get("date_obs")})

	# One cliff carrying most of the decline → mechanical/obstruction artifact.
	if max_step >= sudden_frac * total_decline and max_step > 0.25:
		return {"class": SUDDEN_ARTIFACT, "detail": detail}

	# Gradual decline: dawn (deterministic, excluded) or a real cloud event.
	if dawn_utc is not None and onset is not None and onset >= dawn_utc:
		return {"class": DAWN, "detail": detail}
	return {"class": GRADUAL_CLOUD, "detail": detail}


def _dark_window(start_utc: datetime, lat: float,
				 lon: float) -> tuple[datetime | None, datetime | None]:
	"""The night's astronomical-dark window [dark_start, dark_end] (UTC), via astropy:
	dark_start = the Sun descending through −18°, dark_end = the next ascending crossing.

	Returns (None, None) when there is no usable window: the Sun never reaches −18° (polar
	summer / no astro-dark), OR no dark_end is found within the 16 h search (a near-solstice
	graze — treating it as open-ended would wrongly admit every post-midnight sub), OR the
	window is shorter than 20 min (a graze with no calibration-useful dark). Callers grade
	those nights UNFILTERED-and-flagged rather than restrict to a degenerate window. astropy
	is a hard dependency (read_sub already used it to read every sub), so it is imported
	directly — were it somehow absent, the read would have failed long before here.

	WHY both ends (this generalises the old dawn-only exclusion): the star-proxy counts
	pixels above a sky-relative threshold, so in twilight (before dark_start) and at dawn
	(after dark_end) the bright sky suppresses the count — it ramps UP through dusk and
	fades DOWN at dawn purely from sky brightness, indistinguishable from a real
	transparency change. Grades must be computed over true-dark subs only. The dusk end
	matters because Dustin starts imaging before astro-dark (narrowband-in-twilight is
	correct practice), so near-solstice sessions are twilight-heavy."""
	from astropy.coordinates import AltAz, EarthLocation, get_sun
	from astropy.time import Time
	import astropy.units as u
	loc = EarthLocation(lat=lat * u.deg, lon=lon * u.deg)
	base = Time(start_utc)
	# 5-min sampling over 16 h: long enough to span an early-evening start through next
	# morning's dawn; fine enough that the crossing is located to ±5 min (well inside the
	# margin between a session's twilight subs and its first true-dark sub).
	dt = np.arange(0, 16 * 60, 5) * u.min
	times = base + dt
	alt = get_sun(times).transform_to(AltAz(obstime=times, location=loc)).alt.deg
	# dark_start: already below −18° at the start (imaging began after dark), else the
	# first descending crossing.
	if alt[0] <= -18:
		dark_start, start_idx = times[0].to_datetime(timezone.utc), 0
	else:
		dark_start, start_idx = None, None
		for j in range(1, len(alt)):
			if alt[j - 1] > -18 >= alt[j]:
				dark_start, start_idx = times[j].to_datetime(timezone.utc), j
				break
	if dark_start is None:
		return None, None   # Sun never dips to −18° → no astronomical dark this night
	# dark_end: the first ascending crossing after dark_start. If none is found in range,
	# the window is a graze (or the search is too short for this latitude) — return NO
	# window rather than an open-ended one that would admit every post-midnight sub.
	for j in range(start_idx + 1, len(alt)):
		if alt[j - 1] < -18 <= alt[j]:
			dark_end = times[j].to_datetime(timezone.utc)
			if (dark_end - dark_start) < timedelta(minutes=20):
				return None, None   # degenerate graze → no calibration-useful dark
			return dark_start, dark_end
	return None, None   # no dark_end within the search → unusable (see docstring)


def _restrict_to_dark(group: list[dict[str, Any]], dark_start: datetime,
					  dark_end: datetime | None) -> list[dict[str, Any]]:
	"""Keep only the subs whose DATE-OBS falls inside [dark_start, dark_end] (true
	astronomical dark). dark_end=None means dark runs past the search window, so there
	is no upper bound. Pure + time-only, so it unit-tests without astropy or the NAS."""
	out: list[dict[str, Any]] = []
	for m in group:
		t = _parse_dateobs(m.get("date_obs"))
		if t is None or t < dark_start:
			continue
		if dark_end is not None and t > dark_end:
			continue
		out.append(m)
	return out


def grade_session(
	folder: str, site_id: str = "Bainbridge",
	lat: float | None = None, lon: float | None = None,
	target: str | None = None,
) -> list[dict[str, Any]]:
	"""Grade every (target, filter) group of FITS subs under `folder` (recursive).

	Returns one grade dict per group: {target, filter, n_subs, star_count_median,
	star_count_trend, bg_median, transition, night_date}. night_date is the
	observing-night date (for the DB join). dawn-exclusion runs only when lat/lon
	are given. `target`, when given, labels ALL subs (used by the daily sweep, which
	knows the target from the Raws/<Target>/<Rig>/<date>/ path — more reliable than
	the folder heuristic). Does NOT write to the DB — callers do — so it stays
	pure/testable.
	"""
	import calibration_log as cl  # for observing_date only

	paths = [str(p) for p in Path(folder).rglob("*.fits")] + \
			[str(p) for p in Path(folder).rglob("*.fit")]
	subs: list[dict[str, Any]] = []
	read_failures = 0
	for p in sorted(paths):
		try:
			subs.append(fm.read_sub(p))
		except Exception as e:  # noqa: BLE001 — one bad sub shouldn't sink the night
			read_failures += 1
			sys.stderr.write(f"grader: skipping unreadable {os.path.basename(p)}: {e}\n")
	attempted = len(paths)

	# Drop explicit calibration frames (flats/darks/bias). The auto-grader points at a
	# whole session date-dir, which may co-locate calibration with lights; a star-count
	# grade is only meaningful for lights. Permissive: a sub with no IMAGETYP is KEPT
	# (treated as a light), so non-NINA files without the header still grade.
	_CALIB = {"FLAT", "DARK", "BIAS", "DARKFLAT", "FLATDARK"}
	subs = [s for s in subs
			if (s.get("imagetyp") or "").upper().replace(" ", "") not in _CALIB]

	# Dedup by capture time. NINA writes exactly one sub per DATE-OBS, so two files
	# with the SAME timestamp are duplicate COPIES (e.g. a night re-saved into a
	# subfolder) — keep the first so copies don't double-count the night.
	seen_times: set[str] = set()
	deduped: list[dict[str, Any]] = []
	for s in subs:
		t = s.get("date_obs")
		if t and t in seen_times:
			continue
		if t:
			seen_times.add(t)
		deduped.append(s)
	subs = deduped

	# Group by (target, filter) — same target+filter is the only valid comparison
	# unit (spec §6a). The target comes from the caller when known (the daily sweep
	# passes the Raws/<Target>/… folder name, which is authoritative); otherwise we
	# fall back to the folder heuristic since OBJECT isn't reliably present.
	groups: dict[tuple[str, str], list[dict[str, Any]]] = {}
	for s in subs:
		tgt = target if target is not None else _target_of(s["path"], folder)
		groups.setdefault((tgt, s.get("filter") or "?"), []).append(s)

	# Session-level provenance (shared by every grade row of this session), stamped
	# into fits_grades.notes so a degraded read is self-documenting for the eventual
	# re-tune rather than silently authoritative.
	read_note = f"read {len(subs)}/{attempted} subs" if read_failures else None

	have_coords = lat is not None and lon is not None
	# The night's astro-dark window — computed ONCE (it depends on site + date, not the
	# group). Every grade is restricted to this window so twilight/dawn subs (bright-sky
	# subs whose star count tracks sky brightness, not transparency) don't pollute the
	# median/trend. See _dark_window for the physics. We anchor the window on the
	# session's EARLIEST sub (the evening start) so the dusk crossing is in range.
	all_obs = sorted(t for t in (_parse_dateobs(s.get("date_obs")) for s in subs) if t)
	session_start = None
	if all_obs:
		# Anchor on the earliest sub — but first drop any sub more than 18 h before the
		# MEDIAN sub time. A single stray from another night co-located in the folder would
		# otherwise anchor the dark-window search on the wrong night and exclude every real
		# sub; a real session spans < 16 h, so > 18 h from the median is a different night.
		median_t = all_obs[len(all_obs) // 2]
		in_night = [t for t in all_obs if (median_t - t) <= timedelta(hours=18)]
		session_start = in_night[0] if in_night else all_obs[0]
	dark_start = dark_end = None
	dark_unavailable = False
	if have_coords and session_start is not None:
		dark_start, dark_end = _dark_window(session_start, lat, lon)
		# No usable window DESPITE coords (no astro-dark, or a graze). Don't silently zero
		# the night's data — grade the whole group UNFILTERED and flag it. For the
		# configured mid-latitude sites this never fires.
		dark_unavailable = dark_start is None

	grades: list[dict[str, Any]] = []
	for (tgt, filt), group in groups.items():
		group.sort(key=lambda m: m.get("date_obs") or "")
		if dark_start is not None:
			# Separate subs with an UNPARSEABLE DATE-OBS from genuine out-of-dark
			# exclusions, so a corrupt timestamp isn't silently miscounted as "twilight".
			parseable = [m for m in group if _parse_dateobs(m.get("date_obs")) is not None]
			unparseable = len(group) - len(parseable)
			dark_group = _restrict_to_dark(parseable, dark_start, dark_end)
			excluded = len(parseable) - len(dark_group)
		else:
			dark_group, unparseable, excluded = group, 0, 0
		# night_date from a dark sub if any, else fall back to the group's first sub so a
		# fully-excluded (all-twilight) group still records the night it belongs to.
		first_obs = _parse_dateobs((dark_group or group)[0].get("date_obs"))
		# classify only the dark subs; dark_end as the dawn backstop (post-dark subs are
		# already removed, so this only bites on the no-coords path).
		cls = classify_transition(dark_group, dawn_utc=dark_end)
		sp = [m.get("star_proxy") or 0 for m in dark_group]
		# Trend: simple normalized slope (first→last fractional change), negative = worse.
		trend = ((sp[-1] - sp[0]) / sp[0]) if sp and sp[0] else 0.0
		night_date = cl.observing_date(first_obs.astimezone()) if first_obs else ""
		note_parts = [n for n in (
			read_note,
			f"{excluded} sub(s) outside astro-dark excluded" if excluded else None,
			f"{unparseable} sub(s) with unparseable DATE-OBS dropped" if unparseable else None,
			"dark-window unavailable — unfiltered" if dark_unavailable else None,
			# A gradual-cloud verdict reached WITHOUT coords couldn't rule out dawn — flag
			# it so the re-tune can treat that particular cloud label as unverified.
			"dawn-exclusion off (no coords)"
				if (cls["class"] == GRADUAL_CLOUD and not have_coords) else None,
		) if n]
		grades.append({
			"target": tgt, "filter": filt, "n_subs": len(dark_group),
			"star_count_median": float(np.median(sp)) if sp else 0.0,
			"star_count_trend": round(trend, 4),
			"bg_median": float(np.median([m.get("median_bg") or 0.0 for m in dark_group]))
				if dark_group else 0.0,
			"transition": cls["class"], "detail": cls["detail"],
			"night_date": night_date, "site_id": site_id,
			"notes": "; ".join(note_parts) or None,
		})
	return grades


def _target_of(path: str, root: str) -> str:
	"""Best-effort target name = the first path component under the session root,
	else the file's grandparent dir."""
	try:
		rel = Path(path).relative_to(root)
		return rel.parts[0] if len(rel.parts) > 1 else Path(path).parent.name
	except ValueError:
		return Path(path).parent.name


# ---------------------------------------------------------------------------
# Daily sweep (auto-grader). A systemd timer calls grade_pending() each morning;
# it POLLS the Raws/ tree (the right primitive for a CIFS NAS written remotely by
# the capture PC's robocopy — inotify can't see those writes) and grades every
# complete, not-yet-graded night. Idempotent: already-graded nights are skipped
# by a DB query, and the write itself REPLACEs on the UNIQUE key.
# ---------------------------------------------------------------------------

# A session folder is named for its observing EVENING (NINA's default noon-rollover
# naming), e.g. "2026-06-02". We match that shape to find session dirs and to compare
# against today's date / the already-graded set.
_DATE_DIR_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def _session_dirs(raws_root: str):
	"""Yield (session_dir: Path, target: str, dir_date: str) for each date-named
	session folder under raws_root.

	NINA's layout is Raws/<Target>/<Rig>/<YYYY-MM-DD>/…, but we accept the date dir
	at depth 2 OR 3 below raws_root so a missing <Rig> level still works. `target` is
	the first path component under raws_root (the <Target> folder — authoritative, so
	the sweep passes it to grade_session rather than relying on the folder heuristic).
	`dir_date` is the folder's own name; it's used only as a cheap pre-filter (the
	completeness + already-graded checks), while grade_session recomputes the
	authoritative night_date from each sub's DATE-OBS. The two agree for NINA's
	noon-rollover evening-naming on a single-timezone setup (the only deployment).
	If they ever diverge (e.g. the grader runs in a different timezone than the
	capture PC), the night is harmlessly RE-READ every sweep until it ages out of the
	window — wasteful over CIFS, but never wrong data: the written row keys on the
	authoritative night_date, so a re-read just REPLACEs the identical row.

	Globbing is a directory listing (cheap over CIFS — no file reads); only the
	ungraded sessions get their FITS opened, downstream.
	"""
	root = Path(raws_root)
	seen: set[str] = set()
	# Depth 2 = Raws/<Target>/<date>; depth 3 = Raws/<Target>/<Rig>/<date>.
	for pattern in ("*/*", "*/*/*"):
		try:
			matches = sorted(root.glob(pattern))
		except OSError as e:
			# NAS unreachable / permission denied. LOG it (don't silently swallow) so
			# a down mount is distinguishable from a genuinely empty tree — see also
			# main()'s up-front readability check, which exits non-zero in that case.
			sys.stderr.write(f"grader: cannot list {root} pattern {pattern!r}: {e}\n")
			continue
		for d in matches:
			if not _DATE_DIR_RE.match(d.name):
				continue
			try:
				if not d.is_dir():
					continue
			except OSError:
				continue
			key = str(d)
			if key in seen:
				continue
			seen.add(key)
			# Identity = <Target>, plus <Rig> when the layout has that level, so two
			# rigs imaging the same target + filter the same night don't collide on the
			# fits_grades UNIQUE key (one would otherwise silently REPLACE the other).
			# parts is (<Target>, <date>) at depth 2, (<Target>, <Rig>, <date>) at depth 3.
			parts = d.relative_to(root).parts
			target = parts[0] if len(parts) < 3 else f"{parts[0]} / {parts[1]}"
			# The <Rig> component (when present) identifies the capture source, e.g.
			# "Eon 70" (a home scope) vs "T26" (an iTelescope rental). grade_pending
			# uses it to grade only a site's own rigs — Raws/ mixes home + remote.
			rig = parts[1] if len(parts) >= 3 else None
			yield d, target, rig, d.name


def _graded_keys(conn, site_id: str) -> set[tuple[str, str]]:
	"""Set of (night_date, target) pairs already in fits_grades for this site — the
	sweep skips these so it doesn't re-read a graded night's FITS over the network.
	The DB UNIQUE constraint is the backstop if the dir-date pre-filter ever misses."""
	rows = conn.execute(
		"SELECT DISTINCT night_date, target FROM fits_grades WHERE site_id = ? COLLATE NOCASE",
		(site_id,),
	).fetchall() if site_id is not None else conn.execute(
		# site_id None = attribution mode: keys across ALL sites. Valid because
		# target embeds the rig and a rig is physically at one site, so the
		# (night_date, target) pair is globally unique — and site-agnostic
		# checking avoids re-reading headers for already-graded sessions.
		"SELECT DISTINCT night_date, target FROM fits_grades").fetchall()
	return {(r[0], r[1]) for r in rows}


def _site_coords(site_id: str, config_path: str | None = None):
	"""Look up a site's (lat, lon) from the fetcher's gitignored config.toml, for
	dawn-exclusion. Returns (None, None) if the config or site is absent — the grader
	then simply skips dawn-exclusion rather than failing. Reading coords here (at the
	CLI boundary) keeps them OUT of the committed systemd unit: the unit names no
	coordinates, this pulls them from the same private config the fetcher reads."""
	import tomllib  # stdlib (3.11+); read-only parse of the user's config
	cfg_path = Path(config_path) if config_path else (
		Path.home() / ".config" / "astrowidget" / "config.toml")
	try:
		with cfg_path.open("rb") as f:
			cfg = tomllib.load(f)
	except (OSError, tomllib.TOMLDecodeError):
		return None, None
	for site in cfg.get("sites", []):
		# Case-insensitive id match (QA 2026-06-09): config ids are mixed-case
		# and a casing drift here silently disabled dawn-exclusion (the lookup
		# returned None,None and the grader "simply skips" by design).
		if str(site.get("id", "")).lower() == site_id.lower():
			lat, lon = site.get("lat"), site.get("lon")
			if isinstance(lat, (int, float)) and isinstance(lon, (int, float)):
				return float(lat), float(lon)
	return None, None


def _config_sites(config_path: str | None = None) -> list[dict[str, Any]]:
	"""All configured sites as [{id, lat, lon}], from the same gitignored
	config.toml the fetcher reads. Sites without numeric coords are omitted (they
	can't be matched against header coordinates). Empty list when the config is
	absent/unreadable — the sweep then can't attribute and skips loudly."""
	import tomllib  # stdlib (3.11+); read-only parse of the user's config
	cfg_path = Path(config_path) if config_path else (
		Path.home() / ".config" / "astrowidget" / "config.toml")
	try:
		with cfg_path.open("rb") as f:
			cfg = tomllib.load(f)
	except (OSError, tomllib.TOMLDecodeError):
		return []
	sites = []
	for site in cfg.get("sites", []):
		lat, lon = site.get("lat"), site.get("lon")
		if site.get("id") and isinstance(lat, (int, float)) and isinstance(lon, (int, float)):
			sites.append({"id": str(site["id"]), "lat": float(lat), "lon": float(lon)})
	return sites


def _nearest_site(lat: float, lon: float,
				  sites: list[dict[str, Any]], tol_deg: float = 0.25) -> dict[str, Any] | None:
	"""The configured site whose coordinates match (lat, lon) within [tol_deg],
	or None when nothing is close enough.

	The remote-site attribution core (2026-06-10): each session's FITS headers
	carry the capture site's decimal coordinates, so matching them to the config
	beats any hand-maintained rig→site table — iTelescope relocates and renumbers
	scopes (T26 moved to UDRO at some point), and the header records where the
	sub was ACTUALLY shot. 0.25° (~25 km) is generous against header rounding yet
	unambiguous: the closest configured pair (the two Spanish sites) is ~4° apart.
	Chebyshev distance (max of the axis deltas) is sufficient at this tolerance —
	no great-circle math needed."""
	best, best_d = None, tol_deg
	for s in sites:
		d = max(abs(s["lat"] - lat), abs(s["lon"] - lon))
		if d <= best_d:
			best, best_d = s, d
	return best


def _attribute_session(session_dir: str | Path,
					   sites: list[dict[str, Any]]) -> dict[str, Any] | None:
	"""Match a session folder to a configured site via its FITS header coordinates.

	Reads ONE sub (the first readable) — every sub in a session shares the capture
	site, so one header decides it. Returns the matched site dict ({id, lat, lon}),
	or None when the session has no readable sub, the capture stack wrote no
	coordinates, or the coordinates match no configured site. The caller skips
	unattributed sessions LOUDLY — guessing a site would poison the calibration
	join, which is the exact mislabeling bug this mechanism replaced."""
	for p in sorted(Path(session_dir).rglob("*.fit*")):
		try:
			sub = fm.read_sub(str(p))
		except Exception:  # noqa: BLE001 — unreadable file: try the next sub
			continue
		la, lo = sub.get("lat_obs"), sub.get("lon_obs")
		if la is None or lo is None:
			return None  # the whole session's stack writes no coords; don't guess
		return _nearest_site(la, lo, sites)
	return None


def grade_pending(
	raws_root: str, site_id: str = "Bainbridge",
	lat: float | None = None, lon: float | None = None, write: bool = True,
	since_days: int = 30, rigs: set[str] | None = None,
	sites: list[dict[str, Any]] | None = None, force: bool = False,
) -> list[dict[str, Any]]:
	"""Scan raws_root and grade every COMPLETE, not-yet-graded session folder.

	The auto-grader's entry point (a systemd timer calls this each morning).

	Two attribution modes:
	  - `sites` given (the timer's default, remote-site calibration 2026-06-10):
	    each session is attributed to a configured site by matching its FITS
	    header coordinates (_attribute_session) — home AND iTelescope sessions
	    all land under their TRUE site_id, with that site's coords driving
	    dawn-exclusion. Sessions that can't be attributed are skipped loudly.
	    site_id/lat/lon are ignored in this mode.
	  - `sites` None: every graded session is stamped with the fixed site_id
	    (+ lat/lon for dawn-exclusion) — the legacy single-site mode, kept for
	    explicit `--site` runs and tests.

	Skips:
	  - other rigs: when `rigs` is given, only sessions whose <Rig> folder is in the set
	    are graded (an additional filter, orthogonal to attribution).
	  - tonight / future: a folder whose date is >= today's local date — imaging
	    isn't done. (The timer runs mid-morning, after dawn, so "today's" folder is
	    either tonight's not-yet-started session or still being written; either way
	    it's not ready. Yesterday's folder is < today and gets graded.)
	  - already-graded: (dir_date, target) already present in fits_grades for the site.
	  - older than `since_days`: bounds the FIRST run (which would otherwise read the
	    whole Raws/ history over CIFS) to the forward-collection window — the only
	    nights that have, or will soon have, a logged forecast to correlate against.
	    NOT silent: the count skipped-as-old is logged. Pass since_days=0 to disable
	    the lower bound and backfill everything (e.g. `--since-days 0`).

	Writes each session's grades as it goes (when write=True) so a mid-scan failure
	still persists the sessions already done. Returns all grade dicts written.

	`lat`/`lon` (when given) enable dawn-exclusion; main() resolves them from config
	for the systemd path, so this function stays pure/testable (no config read here).
	"""
	import calibration_log as cl

	# "Complete" = strictly before today's LOCAL calendar date. The folder name is the
	# observing-evening date, so yesterday's session (imaged overnight, done by morning)
	# is < today and grades; tonight's (== today) waits for the next run. String compare
	# is valid for zero-padded YYYY-MM-DD.
	now_local = datetime.now().astimezone()
	today = now_local.date().isoformat()
	# Lower bound (inclusive). since_days<=0 disables it (full backfill).
	cutoff = (now_local.date() - timedelta(days=since_days)).isoformat() if since_days > 0 else ""

	conn = cl.connect()
	try:
		# Attribution mode checks (night, target) across ALL sites — see _graded_keys.
		done = _graded_keys(conn, None if sites is not None else site_id)
	finally:
		conn.close()

	written: list[dict[str, Any]] = []
	seen = 0
	skipped_old = 0
	skipped_rig = 0
	skipped_unattributed = 0
	for session_dir, target, rig, dir_date in _session_dirs(raws_root):
		seen += 1
		if rigs is not None and rig not in rigs:
			skipped_rig += 1
			continue  # not one of this site's rigs (e.g. an iTelescope remote scope)
		if dir_date >= today:
			continue  # tonight or later — imaging not complete
		if cutoff and dir_date < cutoff:
			skipped_old += 1
			continue  # older than the lookback window
		if not force and (dir_date, target) in done:
			continue  # already graded this night + target (--force re-grades anyway)
		# Which site is this session's data FROM? In attribution mode the session's
		# own header coordinates decide; in fixed mode the caller's site_id does.
		g_site, g_lat, g_lon = site_id, lat, lon
		if sites is not None:
			match = _attribute_session(session_dir, sites)
			if match is None:
				skipped_unattributed += 1
				sys.stderr.write(
					f"grader: cannot attribute {target} {dir_date} to a configured site "
					f"(no readable header coordinates, or none match) — skipped\n")
				continue
			g_site, g_lat, g_lon = match["id"], match["lat"], match["lon"]
		try:
			grades = grade_session(str(session_dir), g_site, g_lat, g_lon, target=target)
		except Exception as e:  # noqa: BLE001 — one bad session shouldn't sink the sweep
			sys.stderr.write(f"grader: skipping {session_dir} ({e})\n")
			continue
		if not grades:
			continue
		if write:
			_write_grades(grades, g_site)
		written.extend(grades)
		sys.stderr.write(
			f"grader: graded {target} {dir_date} -> {g_site} — {len(grades)} group(s)\n")
	# Always summarize what was swept. "swept 0 dirs" makes an empty / unreachable tree
	# visible in the journal instead of looking like a quiet idle morning (main() also
	# exits non-zero up front when the root isn't a readable directory at all).
	sys.stderr.write(
		f"grader: swept {seen} session dir(s) under {raws_root}; graded {len(written)}\n")
	if skipped_rig:
		sys.stderr.write(
			f"grader: skipped {skipped_rig} session(s) from rigs not in {sorted(rigs)} "
			f"(remote rentals etc.)\n")
	if skipped_unattributed:
		sys.stderr.write(
			f"grader: skipped {skipped_unattributed} session(s) that could not be "
			f"attributed to a configured site — check header coords / config sites\n")
	if skipped_old:
		# Surface the bound rather than hiding it — a future run can backfill with
		# --since-days 0 if these older nights are wanted.
		sys.stderr.write(
			f"grader: skipped {skipped_old} session(s) older than {cutoff} "
			f"(--since-days {since_days}); pass --since-days 0 to include them\n")
	return written


def main() -> int:
	ap = argparse.ArgumentParser(description="astrowidget FITS auto-grader (Phase 3)")
	ap.add_argument("folder", nargs="?",
					help="a single session folder of FITS light frames (recursive). "
						 "Omit when using --scan.")
	ap.add_argument("--scan", metavar="RAWS_ROOT", default=None,
					help="auto-grader sweep: walk a Raws/ tree and grade every "
						 "complete, not-yet-graded night (idempotent). This is what "
						 "the systemd timer runs each morning.")
	ap.add_argument("--site", default=None,
					help="fix every grade to this site id. For --scan, OMITTING it "
						 "enables automatic per-session site attribution from FITS "
						 "header coordinates (the timer's mode); single-folder mode "
						 "defaults to Bainbridge.")
	ap.add_argument("--lat", type=float, default=None, help="site latitude (for dawn-exclusion)")
	ap.add_argument("--lon", type=float, default=None, help="site longitude (for dawn-exclusion)")
	ap.add_argument("--write", action="store_true",
					help="write the grades to the calibration DB (fits_grades)")
	ap.add_argument("--since-days", type=int, default=30, metavar="N",
					help="--scan only: grade nights within the last N days "
						 "(default 30; 0 = backfill all history)")
	ap.add_argument("--rig", action="append", metavar="RIG", default=None,
					help="--scan only: grade only sessions from this rig folder "
						 "(repeatable). Raws/ mixes home + remote scopes, so pass your "
						 "home rig(s) (e.g. --rig 'Eon 70') to keep rentals out of this site.")
	ap.add_argument("--force", action="store_true",
					help="--scan only: re-grade nights even if already graded. Use after a "
						 "metric change (e.g. the astro-dark restriction) to recompute "
						 "existing rows — the write REPLACEs on the UNIQUE key.")
	args = ap.parse_args()

	# --scan: the daily sweep.
	if args.scan is not None:
		# Up-front: the root must be a readable directory. If the NAS mount is down or
		# the path is wrong, fail LOUD (non-zero exit → systemd marks the unit failed →
		# visible in `systemctl status`) instead of globbing nothing and reporting a
		# cheerful "no new nights", which is indistinguishable from a healthy idle run.
		if not os.path.isdir(args.scan):
			sys.stderr.write(
				f"grader: --scan root is not a readable directory: {args.scan}\n"
				f"        (NAS unmounted? wrong path?) — nothing swept.\n")
			return 1
		# Require lat/lon together or not at all — a lone --lat is silently useless
		# (dawn-exclusion needs both), so reject it rather than drop it.
		if (args.lat is None) != (args.lon is None):
			ap.error("pass BOTH --lat and --lon, or neither (dawn-exclusion needs both)")
		if args.site is None:
			# Attribution mode (the timer's default): per-session site from FITS
			# header coordinates matched against the configured sites. Needs the
			# config to know the sites — fail loud if it yields nothing.
			cfg_sites = _config_sites()
			if not cfg_sites:
				sys.stderr.write(
					"grader: no configured sites with coordinates (config.toml missing "
					"or unreadable) — cannot attribute sessions; nothing swept.\n")
				return 1
			written = grade_pending(args.scan,
									write=args.write, since_days=args.since_days,
									rigs=set(args.rig) if args.rig else None,
									sites=cfg_sites, force=args.force)
		else:
			# Fixed-site mode (explicit --site): every grade stamped with that id.
			# Resolve dawn-exclusion coords from the gitignored config (so the
			# committed systemd unit names none) unless overridden on the CLI.
			lat, lon = args.lat, args.lon
			if lat is None and lon is None:
				lat, lon = _site_coords(args.site)
			if lat is None or lon is None:
				# No coords → dawn-exclusion is OFF. Surface it: a clear night that
				# fades at dawn will misclassify as gradual-cloud, polluting the
				# calibration set. (Each such grade is also stamped in notes.)
				sys.stderr.write(
					f"grader: no coordinates for site {args.site!r} — dawn-exclusion "
					f"DISABLED; dawn-fade nights may misclassify as gradual-cloud.\n")
			written = grade_pending(args.scan, args.site, lat, lon,
									write=args.write, since_days=args.since_days,
									rigs=set(args.rig) if args.rig else None,
									force=args.force)
		if not written:
			print("Auto-grader: no new complete nights to grade.")
			return 0
		for g in written:
			_print_grade(g)
		if args.write:
			print(f"wrote {len(written)} grade(s) to the calibration DB.")
		else:
			print(f"(dry run — {len(written)} grade(s) NOT written; pass --write)")
		return 0

	# Single-folder mode (manual grade of one session). --site keeps its historic
	# Bainbridge default here — manual one-folder grades are the home-site remedy
	# path (e.g. correcting a partial night), not the multi-site sweep.
	if not args.folder:
		ap.error("provide a session folder, or use --scan RAWS_ROOT")
	grades = grade_session(args.folder, args.site or "Bainbridge", args.lat, args.lon)
	if not grades:
		print("No FITS subs found under", args.folder)
		return 1
	for g in grades:
		_print_grade(g)
	if args.write:
		_write_grades(grades, args.site)
		print(f"wrote {len(grades)} grade(s) to the calibration DB.")
	return 0


def _print_grade(g: dict[str, Any]) -> None:
	"""One-line human summary of a grade dict (shared by single-folder + --scan)."""
	print(f"{g['night_date']}  {g['target']} [{g['filter']}]  "
		  f"{g['n_subs']} subs  median★≈{g['star_count_median']:.0f}  "
		  f"trend={g['star_count_trend']:+.2f}  →  {g['transition'].upper()}")


def _write_grades(grades: list[dict[str, Any]], site_id: str) -> None:
	import calibration_log as cl
	conn = cl.connect()
	try:
		for g in grades:
			# INSERT OR REPLACE keys on the UNIQUE(night_date, site_id, target, filter)
			# constraint: re-grading a night (the daily sweep re-runs, or a manual
			# re-grade after more subs land) overwrites that night's row instead of
			# accumulating duplicates. Idempotent by construction.
			conn.execute(
				"""INSERT OR REPLACE INTO fits_grades (graded_at, night_date, site_id,
					target, filter, n_subs, star_count_median, star_count_trend,
					bg_median, transition_class, notes)
				   VALUES (?,?,?,?,?,?,?,?,?,?,?)""",
				(datetime.now(timezone.utc).isoformat(), g["night_date"], site_id,
				 g["target"], g["filter"], g["n_subs"], g["star_count_median"],
				 g["star_count_trend"], g["bg_median"], g["transition"], g.get("notes")),
			)
		conn.commit()
	finally:
		conn.close()


if __name__ == "__main__":
	sys.exit(main())
