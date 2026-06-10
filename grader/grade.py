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


def _astronomical_dawn(date_utc: datetime, lat: float, lon: float) -> datetime | None:
	"""The night's astronomical dawn (Sun rising through −18°) in UTC, via astropy.
	Used for dawn-exclusion. None if it can't be computed (e.g. polar) or astropy is
	unavailable. Searches the morning hours after the given instant."""
	try:
		from astropy.coordinates import AltAz, EarthLocation, get_sun
		from astropy.time import Time
		import astropy.units as u
	except ImportError:
		return None
	loc = EarthLocation(lat=lat * u.deg, lon=lon * u.deg)
	# Sample sun altitude every 10 min over the 12 h after `date_utc`; dawn = the
	# first time it crosses up through −18°.
	base = Time(date_utc)
	dt = np.arange(0, 12 * 60, 10) * u.min
	times = base + dt
	alt = get_sun(times).transform_to(AltAz(obstime=times, location=loc)).alt.deg
	for j in range(1, len(alt)):
		if alt[j - 1] < -18 <= alt[j]:
			return times[j].to_datetime(timezone.utc)
	return None


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

	grades: list[dict[str, Any]] = []
	for (tgt, filt), group in groups.items():
		group.sort(key=lambda m: m.get("date_obs") or "")
		first_obs = _parse_dateobs(group[0].get("date_obs"))
		have_coords = lat is not None and lon is not None
		dawn = (_astronomical_dawn(first_obs, lat, lon)
				if (first_obs and have_coords) else None)
		cls = classify_transition(group, dawn_utc=dawn)
		sp = [m.get("star_proxy") or 0 for m in group]
		# Trend: simple normalized slope (first→last fractional change), negative = worse.
		trend = ((sp[-1] - sp[0]) / sp[0]) if sp and sp[0] else 0.0
		night_date = cl.observing_date(first_obs.astimezone()) if first_obs else ""
		# A gradual-cloud verdict reached WITHOUT coords couldn't rule out dawn — flag
		# it so the re-tune can treat that particular cloud label as unverified.
		note_parts = [n for n in (
			read_note,
			"dawn-exclusion off (no coords)"
				if (cls["class"] == GRADUAL_CLOUD and not have_coords) else None,
		) if n]
		grades.append({
			"target": tgt, "filter": filt, "n_subs": len(group),
			"star_count_median": float(np.median(sp)) if sp else 0.0,
			"star_count_trend": round(trend, 4),
			"bg_median": float(np.median([m.get("median_bg") or 0.0 for m in group])),
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
	).fetchall()
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


def grade_pending(
	raws_root: str, site_id: str = "Bainbridge",
	lat: float | None = None, lon: float | None = None, write: bool = True,
	since_days: int = 30, rigs: set[str] | None = None,
) -> list[dict[str, Any]]:
	"""Scan raws_root and grade every COMPLETE, not-yet-graded session folder.

	The auto-grader's entry point (a systemd timer calls this each morning). Skips:
	  - other rigs: when `rigs` is given, only sessions whose <Rig> folder is in the set
	    are graded. Raws/ mixes the home scope with iTelescope rentals, and the site
	    label would otherwise be stamped on remote data — so the home-site sweep passes
	    its own rig(s) (e.g. {"Eon 70"}) and the T-number rentals are skipped.
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
		done = _graded_keys(conn, site_id)
	finally:
		conn.close()

	written: list[dict[str, Any]] = []
	seen = 0
	skipped_old = 0
	skipped_rig = 0
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
		if (dir_date, target) in done:
			continue  # already graded this night + target
		try:
			grades = grade_session(str(session_dir), site_id, lat, lon, target=target)
		except Exception as e:  # noqa: BLE001 — one bad session shouldn't sink the sweep
			sys.stderr.write(f"grader: skipping {session_dir} ({e})\n")
			continue
		if not grades:
			continue
		if write:
			_write_grades(grades, site_id)
		written.extend(grades)
		sys.stderr.write(
			f"grader: graded {target} {dir_date} — {len(grades)} group(s)\n")
	# Always summarize what was swept. "swept 0 dirs" makes an empty / unreachable tree
	# visible in the journal instead of looking like a quiet idle morning (main() also
	# exits non-zero up front when the root isn't a readable directory at all).
	sys.stderr.write(
		f"grader: swept {seen} session dir(s) under {raws_root}; graded {len(written)}\n")
	if skipped_rig:
		sys.stderr.write(
			f"grader: skipped {skipped_rig} session(s) from rigs not in {sorted(rigs)} "
			f"(remote rentals etc.)\n")
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
	ap.add_argument("--site", default="Bainbridge")
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
		# Resolve dawn-exclusion coords from the gitignored config (so the committed
		# systemd unit names none) unless explicitly overridden on the CLI.
		lat, lon = args.lat, args.lon
		if lat is None and lon is None:
			lat, lon = _site_coords(args.site)
		if lat is None or lon is None:
			# No coords → dawn-exclusion is OFF. Surface it: a clear night that fades at
			# dawn will misclassify as gradual-cloud, polluting the calibration set.
			# (Each such grade is also stamped in fits_grades.notes.)
			sys.stderr.write(
				f"grader: no coordinates for site {args.site!r} — dawn-exclusion DISABLED; "
				f"dawn-fade nights may misclassify as gradual-cloud.\n")
		written = grade_pending(args.scan, args.site, lat, lon,
								write=args.write, since_days=args.since_days,
								rigs=set(args.rig) if args.rig else None)
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

	# Single-folder mode (manual grade of one session).
	if not args.folder:
		ap.error("provide a session folder, or use --scan RAWS_ROOT")
	grades = grade_session(args.folder, args.site, args.lat, args.lon)
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
