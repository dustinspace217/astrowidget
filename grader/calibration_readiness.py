#!/usr/bin/env python3
"""
calibration_readiness.py — how close is the dataset to a scoring re-tune (Phase 3 Part 4)?

A re-tune needs JOINABLE nights: a logged forecast paired with what actually happened —
a FITS grade (you imaged → star-count is the transparency truth) or a recorded decision
(you skipped → why). The catch is that a forecast is forward-looking and astrowidget only
started logging forecasts recently, so the historical FITS grades have NO forecast to pair
with and don't count. This tool counts the joinable nights for the calibration site,
checks the SPREAD of conditions (you want clear AND marginal AND cloudy nights, not 20
identical clear ones), and prints a readiness verdict.

It's the bridge to Part 4: instead of guessing when there's enough data, run this — and a
weekly systemd timer can run it with --notify to ping you the moment it's worth a pass.

    python grader/calibration_readiness.py [--site Bainbridge] [--min-nights 12] [--notify]

Re-tuning itself stays MANUAL and human-reviewed (it changes the verdicts you act on, so a
human approves the weight changes) — this only tells you WHEN to ask.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any

# calibration_log lives in fetcher/; add it to the path for the shared DB helpers.
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "fetcher"))
import calibration_log as cl  # noqa: E402


def _band(cloud_score: int | None) -> str:
	"""Coarse condition band from the forecast's CLOUD FACTOR SCORE (0-100, where HIGH
	is clear and LOW is cloudy — it is a score, not a cloud percentage). The re-tune
	wants a spread across bands, so readiness checks how many are populated."""
	if cloud_score is None:
		return "unknown"
	if cloud_score >= 70:
		return "clear"
	if cloud_score >= 40:
		return "marginal"
	return "cloudy"


def assess(conn, site_id: str = "Bainbridge",
		   min_nights: int = 12, min_bands: int = 3) -> dict[str, Any]:
	"""Summarize the joinable calibration data for a site.

	A night is joinable when it has BOTH a logged 'Tonight' forecast AND an outcome:
	a FITS grade (imaged), or a recorded decision (skipped, or imaged-but-not-yet-graded).
	Returns the per-night detail, counts, the condition spread, and a `ready` flag
	(enough joinable nights AND across enough condition bands). Pure (takes an open
	conn) so it's unit-tested without a GUI or the real DB."""
	forecasts = {r[0]: r[1] for r in conn.execute(
		"""SELECT night_date, MAX(cloud) FROM forecasts
		   WHERE site_id = ? AND night_label = 'Tonight' GROUP BY night_date""",
		(site_id,))}
	graded = {r[0] for r in conn.execute(
		"SELECT DISTINCT night_date FROM fits_grades WHERE site_id = ?", (site_id,))}
	skipped = {r[0] for r in conn.execute(
		"SELECT DISTINCT night_date FROM decisions WHERE site_id = ? AND imaged = 0", (site_id,))}
	imaged = {r[0] for r in conn.execute(
		"SELECT DISTINCT night_date FROM decisions WHERE site_id = ? AND imaged = 1", (site_id,))}

	rows: list[dict[str, Any]] = []
	for nd in sorted(forecasts):
		if nd in graded:
			outcome = "imaged · graded"
		elif nd in skipped:
			outcome = "skipped"
		elif nd in imaged:
			outcome = "imaged · grade pending"
		else:
			continue  # a forecast with no outcome yet → not joinable
		rows.append({"night": nd, "cloud": forecasts[nd],
					 "band": _band(forecasts[nd]), "outcome": outcome})

	bands = sorted({r["band"] for r in rows if r["band"] != "unknown"})
	return {
		"site": site_id, "rows": rows, "n": len(rows), "bands": bands,
		"min_nights": min_nights, "min_bands": min_bands,
		"n_graded": sum(1 for r in rows if "graded" in r["outcome"]),
		"n_skipped": sum(1 for r in rows if r["outcome"] == "skipped"),
		"ready": len(rows) >= min_nights and len(bands) >= min_bands,
	}


def format_report(a: dict[str, Any]) -> str:
	"""Render an assess() result as a readable report."""
	lines = [
		f"Calibration readiness — {a['site']}",
		f"  joinable nights: {a['n']}  "
		f"(graded {a['n_graded']} · skipped {a['n_skipped']})  — need {a['min_nights']}",
		f"  condition spread: {', '.join(a['bands']) or 'none'}  — need {a['min_bands']} bands",
	]
	for r in a["rows"]:
		c = f"{r['cloud']}" if r["cloud"] is not None else "—"
		lines.append(f"    {r['night']}  cloud-score {c:>3} [{r['band']}]  → {r['outcome']}")
	lines.append("  → " + (
		"READY — reload astrowidget and ask Claude for a calibration pass"
		if a["ready"] else "not yet — keep collecting"))
	return "\n".join(lines)


def main() -> int:
	ap = argparse.ArgumentParser(description="astrowidget calibration-readiness check")
	ap.add_argument("--site", default="Bainbridge",
					help="the calibration site (where forecasts, grades + decisions align)")
	ap.add_argument("--min-nights", type=int, default=12,
					help="joinable nights needed to call it ready (default 12)")
	ap.add_argument("--min-bands", type=int, default=3,
					help="distinct condition bands needed (clear/marginal/cloudy; default 3)")
	ap.add_argument("--notify", action="store_true",
					help="fire a desktop notification ONLY when ready (for the weekly timer)")
	args = ap.parse_args()

	conn = cl.connect()
	try:
		a = assess(conn, args.site, args.min_nights, args.min_bands)
	finally:
		conn.close()
	print(format_report(a))

	if args.notify and a["ready"]:
		# Only pings when ready, so the weekly timer is silent until it matters.
		import subprocess
		subprocess.run(
			["notify-send", "-u", "normal", "-a", "astrowidget",
			 "astrowidget: calibration data ready",
			 f"{a['n']} joinable nights across {len(a['bands'])} conditions — "
			 "reload astrowidget and ask Claude for a re-tune."],
			check=False)
	return 0


if __name__ == "__main__":
	sys.exit(main())
