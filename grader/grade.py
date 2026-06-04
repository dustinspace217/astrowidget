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
import sys
from datetime import datetime, timezone
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
) -> list[dict[str, Any]]:
	"""Grade every (target, filter) group of FITS subs under `folder` (recursive).

	Returns one grade dict per group: {target, filter, n_subs, star_count_median,
	star_count_trend, bg_median, transition, night_date}. night_date is the
	observing-night date (for the DB join). dawn-exclusion runs only when lat/lon
	are given. Does NOT write to the DB — main() does, so this stays pure/testable.
	"""
	import calibration_log as cl  # for observing_date only

	paths = [str(p) for p in Path(folder).rglob("*.fits")] + \
			[str(p) for p in Path(folder).rglob("*.fit")]
	subs: list[dict[str, Any]] = []
	for p in sorted(paths):
		try:
			subs.append(fm.read_sub(p))
		except Exception as e:  # noqa: BLE001 — one bad sub shouldn't sink the night
			sys.stderr.write(f"grader: skipping unreadable {os.path.basename(p)}: {e}\n")

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

	# Group by (target-ish, filter). We don't have OBJECT reliably, so group by the
	# parent target folder name + filter — same target+filter is the only valid
	# comparison unit (spec §6a).
	groups: dict[tuple[str, str], list[dict[str, Any]]] = {}
	for s in subs:
		target = _target_of(s["path"], folder)
		groups.setdefault((target, s.get("filter") or "?"), []).append(s)

	grades: list[dict[str, Any]] = []
	for (target, filt), group in groups.items():
		group.sort(key=lambda m: m.get("date_obs") or "")
		first_obs = _parse_dateobs(group[0].get("date_obs"))
		dawn = (_astronomical_dawn(first_obs, lat, lon)
				if (first_obs and lat is not None and lon is not None) else None)
		cls = classify_transition(group, dawn_utc=dawn)
		sp = [m.get("star_proxy") or 0 for m in group]
		# Trend: simple normalized slope (first→last fractional change), negative = worse.
		trend = ((sp[-1] - sp[0]) / sp[0]) if sp and sp[0] else 0.0
		night_date = cl.observing_date(first_obs.astimezone()) if first_obs else ""
		grades.append({
			"target": target, "filter": filt, "n_subs": len(group),
			"star_count_median": float(np.median(sp)) if sp else 0.0,
			"star_count_trend": round(trend, 4),
			"bg_median": float(np.median([m["median_bg"] for m in group])),
			"transition": cls["class"], "detail": cls["detail"],
			"night_date": night_date, "site_id": site_id,
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


def main() -> int:
	ap = argparse.ArgumentParser(description="astrowidget FITS auto-grader (Phase 3)")
	ap.add_argument("folder", help="session folder of FITS light frames (recursive)")
	ap.add_argument("--site", default="Bainbridge")
	ap.add_argument("--lat", type=float, default=None, help="site latitude (for dawn-exclusion)")
	ap.add_argument("--lon", type=float, default=None, help="site longitude (for dawn-exclusion)")
	ap.add_argument("--write", action="store_true",
					help="write the grades to the calibration DB (fits_grades)")
	args = ap.parse_args()

	grades = grade_session(args.folder, args.site, args.lat, args.lon)
	if not grades:
		print("No FITS subs found under", args.folder)
		return 1
	for g in grades:
		print(f"{g['night_date']}  {g['target']} [{g['filter']}]  "
			  f"{g['n_subs']} subs  median★≈{g['star_count_median']:.0f}  "
			  f"trend={g['star_count_trend']:+.2f}  →  {g['transition'].upper()}")
	if args.write:
		_write_grades(grades, args.site)
		print(f"wrote {len(grades)} grade(s) to the calibration DB.")
	return 0


def _write_grades(grades: list[dict[str, Any]], site_id: str) -> None:
	import calibration_log as cl
	conn = cl.connect()
	try:
		for g in grades:
			conn.execute(
				"""INSERT INTO fits_grades (graded_at, night_date, site_id, target,
					filter, n_subs, star_count_median, star_count_trend, bg_median,
					transition_class, notes)
				   VALUES (?,?,?,?,?,?,?,?,?,?,?)""",
				(datetime.now(timezone.utc).isoformat(), g["night_date"], site_id,
				 g["target"], g["filter"], g["n_subs"], g["star_count_median"],
				 g["star_count_trend"], g["bg_median"], g["transition"], None),
			)
		conn.commit()
	finally:
		conn.close()


if __name__ == "__main__":
	sys.exit(main())
