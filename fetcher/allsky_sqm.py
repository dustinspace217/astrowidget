#!/usr/bin/env python3
"""
allsky_sqm.py — nightly sky-quality capture from an indi-allsky camera.

Runs each morning (astrowidget-allsky.timer, after astro dark ends) and pulls
the finished night's measured sky-brightness series from an indi-allsky
server's charts endpoint, clips it to the night's astro-dark window (already
logged in the calibration DB by the 4x/day fetch), and upserts one summary row
into the `sky_readings` table. This is the OBJECTIVE half of the nightly
calibration data: the ~11 PM decision form records what the user DID and why
(subjective, survivorship-correcting); this records what the sky actually WAS
(measured, every ~45 s, all night). The two join on (night_date, site_id) like
everything else in the calibration DB.

Why one morning pull instead of polling all night: the charts endpoint returns
its full history window in a single call (`limit_s` seconds back from now —
probed live 2026-08-18: limit_s=43200 returned 945 samples spanning 12 h), so
a single request after dawn covers the entire night. No long-lived process, no
overnight network dependency — if the camera or tailnet was down at 8 AM, the
run fails LOUDLY (OnFailure= desktop notification) and re-fires next morning.

UNITS: indi-allsky's "sqm" series is the camera's RELATIVE luminance metric
(exposure/gain-normalized ADU), not calibrated mag/arcsec². Lower = darker.
It is stored raw — see the sky_readings schema comment in calibration_log.py.

Run manually with:  python3 fetcher/allsky_sqm.py  (uses the same config.toml
as the fetcher; see the [allsky] block in config.example.toml).
"""

import sys
from datetime import datetime, timedelta, timezone
from statistics import median
from zoneinfo import ZoneInfo

import requests

# Sibling module in fetcher/ — running `python3 fetcher/allsky_sqm.py` puts
# fetcher/ at sys.path[0], so these plain imports resolve (same pattern the
# decision form uses via an explicit path insert).
import calibration_log as cl
from astrowidget_fetch import load_config

# Hard ceiling on the charts window we will ever request. 24 h always covers a
# night; anything larger only adds daytime samples we clip away. Also bounds
# the response size (Power-of-Ten rule 2/3: the loop over samples is bounded
# because the request window is).
MAX_WINDOW_HOURS = 24

# The camera samples every ~45 s, so a 24 h window is ~2,000 points per series.
# A response wildly beyond that (100k+ points) means a server bug or a wrong
# URL — refuse it rather than computing stats over garbage. The server lives
# on the owner's own tailnet (same threat model as the allsky plasmoid), so
# this is a sanity bound, not an adversarial defense.
MAX_SAMPLES = 100_000

# Byte-level sibling of MAX_SAMPLES (QA SA-1): checked against Content-Length
# BEFORE the body is read (the fetch streams, so headers arrive first). A full
# 24 h of every series is well under 1 MB; 32 MB means a server bug. A server
# that omits or lies about Content-Length slips past this — accepted, same
# sanity-bound-not-adversarial-defense posture as MAX_SAMPLES.
MAX_RESPONSE_BYTES = 32 * 1024 * 1024


def _fail(msg: str) -> "int":
	"""Report a fatal problem to stderr and return exit code 1. Every failure
	names what went wrong and what to check — the systemd unit's OnFailure=
	hook turns a nonzero exit into a desktop notification, so this message is
	what the user sees in the journal when they follow it up."""
	sys.stderr.write(f"astrowidget allsky capture: {msg}\n")
	return 1


def _iso_to_utc(iso: str) -> datetime | None:
	"""Parse a calibration-DB ISO string (naive = UTC, or 'Z'/offset — the
	fetcher's convention, same as calibration_log's local helper) into an
	aware UTC datetime. None on bad input."""
	if not isinstance(iso, str) or not iso:
		return None
	try:
		dt = datetime.fromisoformat(iso.replace("Z", "+00:00"))
	except ValueError:
		return None
	if dt.tzinfo is None:
		dt = dt.replace(tzinfo=timezone.utc)
	return dt.astimezone(timezone.utc)


def resolve_sample_times(samples: list[dict], now_local: datetime) -> list[tuple[datetime, float]]:
	"""Attach real UTC datetimes to charts samples.

	The charts endpoint returns each point as {"x": "HH:MM:SS", "y": value} —
	a time-of-day in the CAMERA's local zone with NO date. Since every sample
	is within the request window (< 24 h ago), the date is recoverable: a
	time-of-day later than "now" can't be today, so it was yesterday.

	Receives: samples — the raw [{"x","y"}...] list (bounded by MAX_SAMPLES
	upstream); now_local — the current time, ALREADY in the camera's zone.
	Returns: [(utc_datetime, y), ...] with unparseable points dropped.
	"""
	out: list[tuple[datetime, float]] = []
	for p in samples:
		x, y = p.get("x"), p.get("y")
		if not isinstance(x, str) or not isinstance(y, (int, float)):
			continue
		try:
			h, m, s = (int(part) for part in x.split(":"))
			t = now_local.replace(hour=h, minute=m, second=s, microsecond=0)
		except (ValueError, TypeError):
			continue
		# 60 s of slack: the server's clock and ours may disagree slightly, and
		# a sample stamped a few seconds "ahead" of us is still from right now,
		# not from 24 hours ago.
		# DST note (QA TA-6/CR-7): replace() resolves ambiguous or nonexistent
		# wall times as fold=0, so a camera zone WITH DST gets up to 1 h error
		# twice a year at the transition edges. The supported deployment
		# (America/Phoenix) has no DST; accepting that beats special-casing
		# transitions the configured zone can never produce.
		if t > now_local + timedelta(seconds=60):
			t -= timedelta(days=1)
		out.append((t.astimezone(timezone.utc), float(y)))
	return out


def clip_to_window(points: list[tuple[datetime, float]],
				   start: datetime, end: datetime) -> list[float]:
	"""The y-values of the points that fall inside [start, end] (inclusive).
	All three arguments are aware UTC datetimes/points from the callers above."""
	return [y for (t, y) in points if start <= t <= end]


def load_allsky_config() -> dict:
	"""The validated [allsky] block from config.toml.

	Reuses the fetcher's load_config() so the 0600-permission check and site
	validation run exactly once, the same way, for every entry point. Exits
	loudly (SystemExit) when the block is missing or malformed — this script
	only runs if the user installed its timer, so a missing block is a setup
	error to surface, not a feature to silently skip.

	Returns: {url, site_id, camera_id, tz, window_hours, insecure_tls} with
	defaults applied; site_id is canonicalized to the matched [[sites]] id.
	"""
	cfg = load_config()
	allsky = cfg.get("allsky")
	if not isinstance(allsky, dict):
		raise SystemExit(_fail(
			"no [allsky] block in config.toml. Add one (see config.example.toml) "
			"or disable astrowidget-allsky.timer."))
	url = allsky.get("url")
	site_id = allsky.get("site_id")
	if not isinstance(url, str) or not url.startswith(("http://", "https://")):
		raise SystemExit(_fail("[allsky] url must be an http(s) URL."))
	if not isinstance(site_id, str) or not site_id:
		raise SystemExit(_fail("[allsky] site_id is required."))
	# The reading must join to a configured site, or it's orphaned data the
	# calibration queries will never find. Catch the drift at capture time —
	# and CANONICALIZE to the matched [[sites]] id (QA TA-4/SA-2): the
	# sky_readings UNIQUE(night_date, site_id) is case-sensitive while the
	# readers match case-insensitively, so writing the config's own casing
	# ("csv" vs "CSV") would split one night across two rows. Storing the
	# [[sites]] casing keys every row identically to the forecasts the
	# readings join against.
	site_ids = [s.get("id") for s in cfg.get("sites", [])]
	matched = next(
		(s for s in site_ids
		 if isinstance(s, str) and s.lower() == site_id.lower()), None)
	if matched is None:
		raise SystemExit(_fail(
			f"[allsky] site_id '{site_id}' matches no [[sites]] id in config.toml "
			f"(have: {site_ids})."))
	site_id = matched
	tz_name = allsky.get("timezone", "UTC")
	try:
		tz = ZoneInfo(tz_name)
	except Exception:
		raise SystemExit(_fail(
			f"[allsky] timezone '{tz_name}' is not an IANA zone name "
			"(e.g. 'America/Phoenix')."))
	window = allsky.get("window_hours", 14)
	if not isinstance(window, int) or not (1 <= window <= MAX_WINDOW_HOURS):
		raise SystemExit(_fail(
			f"[allsky] window_hours must be an integer 1-{MAX_WINDOW_HOURS}."))
	camera_id = allsky.get("camera_id", 1)
	if not isinstance(camera_id, int) or camera_id < 0:
		raise SystemExit(_fail("[allsky] camera_id must be a non-negative integer."))
	return {
		"url": url.rstrip("/"),
		"site_id": site_id,
		"camera_id": camera_id,
		"tz": tz,
		"window_hours": window,
		# insecure_tls: accept a self-signed certificate. Explicit opt-in for
		# servers on a private tailnet (the CSV camera forces HTTPS with a
		# self-signed cert — same reason the allsky plasmoid uses curl -k).
		"insecure_tls": bool(allsky.get("insecure_tls", False)),
	}


def fetch_charts(base_url: str, camera_id: int, window_hours: int,
				 insecure_tls: bool) -> dict:
	"""GET the charts JSON from the indi-allsky server. Raises the underlying
	requests exception on network/HTTP failure — main() turns it into a loud
	exit so the OnFailure notification fires."""
	if insecure_tls:
		# Scoped to this opt-in: silence only the self-signed-cert warning the
		# flag explicitly accepts, not TLS errors in general.
		import urllib3
		urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
	# stream=True defers the body download until .json() below, so the
	# Content-Length sanity check runs on headers alone — without it the whole
	# body would already be buffered before any size check could fire (QA SA-1).
	resp = requests.get(
		f"{base_url}/js/charts",
		params={"camera_id": camera_id, "limit_s": window_hours * 3600,
				"timestamp": 0},
		timeout=(10, 60),
		verify=not insecure_tls,
		stream=True,
	)
	resp.raise_for_status()
	clen = resp.headers.get("Content-Length")
	if clen and clen.isdigit() and int(clen) > MAX_RESPONSE_BYTES:
		resp.close()
		raise ValueError(
			f"charts response too large ({clen} bytes > {MAX_RESPONSE_BYTES})")
	return resp.json()


def main() -> int:
	acfg = load_allsky_config()
	site_id = acfg["site_id"]
	now_utc = datetime.now(timezone.utc)
	# Camera-zone "now" is ONLY for interpreting the charts' time-of-day
	# sample stamps (resolve_sample_times below).
	now_local = now_utc.astimezone(acfg["tz"])
	# The observing night this capture summarizes: run after dawn, "now - 12 h"
	# lands on the evening the night began. Keyed MACHINE-local (QA CR-1), the
	# same convention every other calibration writer uses (log_run keys from
	# the dark start in machine time; the decision form from machine "now") —
	# keying from the camera's zone instead would diverge between the two
	# zones' noons (an hour a day in winter for Phoenix-vs-Pacific, reachable
	# via the timer's Persistent= boot catch-up) and orphan the night.
	night_date = cl.observing_date(now_utc.astimezone())

	conn = cl.connect()
	try:
		dark = cl.latest_dark_window(conn, night_date, site_id)
		if dark is None:
			return _fail(
				f"no dark window logged for {night_date} at {site_id} — did the "
				"4x/day fetch run? (forecasts table has no usable 'Tonight' row)")
		dark_start, dark_end = _iso_to_utc(dark[0]), _iso_to_utc(dark[1])
		if dark_start is None or dark_end is None:
			return _fail(f"unparseable dark window for {night_date}: {dark!r}")
		# The window the stats actually cover — and what the row records:
		#  - end: a mid-night manual run captures dark_start → now; the morning
		#    timer run then replaces it with the full window (upsert semantics).
		#  - start: a boot catch-up late enough that the charts history window
		#    no longer reaches back to dark_start covers a TRUNCATED night
		#    (QA CR-2). That's still worth keeping — warn loudly, and store the
		#    truncated bound so the row never claims coverage it doesn't have.
		reach_back = now_utc - timedelta(hours=acfg["window_hours"])
		clip_start = max(dark_start, reach_back)
		clip_end = min(dark_end, now_utc)
		if clip_start > dark_start:
			missed = (clip_start - dark_start).total_seconds() / 60
			sys.stderr.write(
				f"astrowidget allsky capture: WARNING — capture ran too late for "
				f"[allsky] window_hours={acfg['window_hours']} to reach the start "
				f"of astro dark; the first {missed:.0f} min of the night are not "
				f"covered. Stats and stored bounds cover the reachable window "
				f"only.\n")

		try:
			payload = fetch_charts(acfg["url"], acfg["camera_id"],
								   acfg["window_hours"], acfg["insecure_tls"])
		except (requests.RequestException, ValueError) as e:
			return _fail(f"charts fetch from {acfg['url']} failed: {e}")

		chart_data = payload.get("chart_data")
		if not isinstance(chart_data, dict):
			return _fail("charts response has no chart_data object — wrong URL?")
		sqm_raw = chart_data.get("sqm")
		if not isinstance(sqm_raw, list) or not sqm_raw:
			return _fail("charts response has no sqm series — is the camera's "
						 "SQM sensor/feature enabled?")
		if len(sqm_raw) > MAX_SAMPLES:
			return _fail(f"sqm series absurdly large ({len(sqm_raw)} points) — "
						 "refusing to summarize it.")
		# stars is SECONDARY data: an oversize series shouldn't kill the sqm
		# capture, but it must not be truncated silently either (QA CR-6 — a
		# [:MAX_SAMPLES] slice would drop the newest samples, i.e. the night).
		# Skip star stats loudly and keep the sqm row.
		stars_raw = chart_data.get("stars")
		if not isinstance(stars_raw, list):
			stars_raw = []
		elif len(stars_raw) > MAX_SAMPLES:
			sys.stderr.write(
				f"astrowidget allsky capture: WARNING — stars series absurdly "
				f"large ({len(stars_raw)} points); skipping star stats for the "
				f"night (sqm still recorded).\n")
			stars_raw = []

		sqm_pts = resolve_sample_times(sqm_raw, now_local)
		sqm_vals = clip_to_window(sqm_pts, clip_start, clip_end)
		if not sqm_vals:
			return _fail(
				f"no sqm samples inside the dark window {dark[0]} → {dark[1]} "
				f"(series spans {len(sqm_pts)} points) — was the camera down "
				"overnight, or is [allsky] timezone wrong?")
		stars_vals = clip_to_window(
			resolve_sample_times(stars_raw, now_local),
			clip_start, clip_end)

		cl.upsert_sky_reading(
			conn, night_date, site_id,
			sqm_median=median(sqm_vals),
			sqm_min=min(sqm_vals),
			sqm_max=max(sqm_vals),
			stars_median=median(stars_vals) if stars_vals else None,
			stars_max=int(max(stars_vals)) if stars_vals else None,
			sample_count=len(sqm_vals),
			# Store the CLIPPED bounds, not the forecast's full window (QA
			# CR-3): a mid-night or late-catch-up row then honestly records
			# what its stats cover, and the morning re-run's upsert widens the
			# bounds back to the full night.
			dark_start=clip_start.isoformat(), dark_end=clip_end.isoformat(),
			source=f"{acfg['url']}/js/charts?camera_id={acfg['camera_id']}",
		)
		# One journal line per success, per the observability preference: the
		# night's numbers are greppable without opening the DB.
		print(f"sky_readings: {night_date} {site_id} "
			  f"sqm median={median(sqm_vals):.1f} "
			  f"min={min(sqm_vals):.1f} max={max(sqm_vals):.1f} "
			  f"stars_median={median(stars_vals) if stars_vals else '—'} "
			  f"n={len(sqm_vals)}")
		return 0
	finally:
		conn.close()


if __name__ == "__main__":
	sys.exit(main())
