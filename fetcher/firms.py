"""NASA FIRMS active-fire proximity for astrowidget.

WHAT: queries the NASA FIRMS Area CSV API for satellite-detected active fires
near a site and summarizes the nearest one, the count within a radius, and the
peak fire radiative power (FRP). This catches near-source wildfire smoke that the
coarse (45 km) CAMS aerosol model under-resolves — the 2026-06-25 UDRO miss,
where the forecast read "excellent transparency" during a real smoke night.

WHY a separate module: pure data acquisition + geometry, with no scoring and no
astrowidget_fetch coupling, so it is independently testable with synthetic CSV
(public-repo discipline: never a real coordinate in a test).

ERROR MODEL (decide "failure vs. no-fires" by CONTENT, not just HTTP status): a
genuine failure — network/HTTP error, a 200-OK body that is NOT fire-CSV (FIRMS
returns 200 + plain text for an invalid/expired MAP_KEY and for rate-limit
notices), or an unparseable body — raises FirmsError so the caller flags
meta.degraded. ONLY a real, validated, fire-CSV response with no detections in
range returns None. The two states are never conflated: a false "all clear" is
the worst outcome for a smoke-WARNING feature (QA 2026-06-26).

SECRET HYGIENE: the MAP_KEY goes in the URL PATH, so a requests exception string
(which includes the URL) would leak it to stderr/the journal. We therefore never
put the original exception text (or the URL) in a FirmsError — only the exception
TYPE — and break the cause chain with `from None`. Mirrors fetch_astrospheric.

Dependencies: requests (already the fetcher's only external dep) + stdlib.
"""
import csv
import io
import math
import sys
import urllib.parse
from typing import Any

import requests


class FirmsError(Exception):
	"""A FIRMS fetch/parse GENUINELY failed (network, HTTP, non-CSV/unparseable body).

	Distinct from a clean "no fires nearby," which returns None. The caller catches
	FirmsError to flag meta.degraded, while a None result is a normal quiet-sky night
	that flags nothing — the two states must never collapse into one ambiguous None.
	NEVER carries the request URL or original exception text (the URL holds the map
	key); only an exception-type name, so it is safe to write to stderr/the journal.
	"""


# FIRMS Area CSV endpoint. Path params: MAP_KEY / SOURCE / west,south,east,north /
# DAY_RANGE.
FIRMS_AREA_URL = "https://firms.modaps.eosdis.nasa.gov/api/area/csv"
HTTP_TIMEOUT = 30
# DAY_RANGE=2 (most recent ~48 h), NOT 1: VIIRS overpasses are ~twice daily and
# FIRMS bins detections by UTC acquisition date, so a 1-day window silently misses
# a currently-burning fire whose last detection landed on the PRIOR UTC day — which
# is most of the night, right after the UTC date rolls. Empirically (2026-06-25,
# ~23:30 PDT): a fire 54 km from UDRO, detected earlier that UTC day, was INVISIBLE
# at DAY_RANGE=1 and clearly present at 2. A fire active in the last 48 h is exactly
# the "smoke could be over me tonight" signal; the capped penalty + "verify with
# allsky" advisory absorb the small staleness risk.
FIRMS_DAY_RANGE = 2
# Power-of-Ten rule 2/3: bound the parse. A 150 km box during a megafire could in
# principle return many rows; cap so a pathological response can't grow unbounded.
MAX_ROWS = 20000
# VIIRS confidence is l/n/h (low/nominal/high). Drop low-confidence detections.
# NOTE: this assumes the VIIRS letter-code scale (the default source). A MODIS feed
# reports numeric 0-100 confidence; if `source` is ever overridden to MODIS this
# filter would need a numeric branch (tracked for v2 with the source config).
_DROP_CONFIDENCE = {"l", "low"}
# Columns every FIRMS fire-CSV row carries. Used to validate that a 200-OK body is
# actually fire data before an empty parse is trusted as "no fires" (see ERROR MODEL).
_REQUIRED_COLUMNS = {"latitude", "longitude"}


def _haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
	"""Great-circle distance in km between two lat/lon points (decimal degrees).

	Standard haversine on a spherical Earth (R=6371 km). Accurate to ~0.5% — far
	below the precision that matters for a "fire within 150 km" decision.
	"""
	r = 6371.0
	p1, p2 = math.radians(lat1), math.radians(lat2)
	dphi = math.radians(lat2 - lat1)
	dlmb = math.radians(lon2 - lon1)
	a = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dlmb / 2) ** 2
	return 2 * r * math.asin(math.sqrt(a))


def _bounding_box(
	lat: float, lon: float, radius_km: float
) -> tuple[float, float, float, float]:
	"""Square lat/lon box (west, south, east, north) covering radius_km around a point.

	The FIRMS Area API takes a bounding box, so we request the inscribing square
	then filter detections to the true circle in _aggregate. dLon widens with
	latitude (meridians converge) via /cos(lat). Returned ORDER is west,south,
	east,north — exactly the order the FIRMS path expects. (No antimeridian/pole
	normalization: no real astro site is within ~1.5° of ±180° lon or ±88° lat.)
	"""
	d_lat = radius_km / 111.0
	# Guard the pole singularity (cos→0). cos(89°)≈0.017; clamp keeps the box finite.
	d_lon = radius_km / (111.0 * max(0.01, math.cos(math.radians(lat))))
	return (lon - d_lon, lat - d_lat, lon + d_lon, lat + d_lat)


def _parse_detections(csv_text: str) -> list[dict[str, Any]]:
	"""Parse FIRMS CSV text into [{'latitude','longitude','frp'}] detections.

	Raises FirmsError when the body is not FIRMS fire-CSV — the header lacks the
	required columns (an invalid-key/rate-limit/error page served as HTTP 200), so
	an empty parse is NOT silently trusted as "no fires" (the false-all-clear this
	feature exists to prevent). Otherwise keeps rows with a parseable lat/lon/frp
	and confidence not in the low set; malformed rows are skipped (best-effort).
	Bounded at MAX_ROWS, which is logged when hit (silent truncation could
	under-report the nearest/most-intense fire during a megafire).
	"""
	reader = csv.DictReader(io.StringIO(csv_text))
	fields = set(reader.fieldnames or [])
	if not _REQUIRED_COLUMNS.issubset(fields):
		raise FirmsError(
			"FIRMS response is not fire-CSV (missing lat/lon header columns)"
		)
	out: list[dict[str, Any]] = []
	for i, row in enumerate(reader):
		if i >= MAX_ROWS:
			sys.stderr.write(
				f"astrowidget: FIRMS row cap ({MAX_ROWS}) hit — nearest/peak fire "
				"may be under-reported this run\n"
			)
			break
		conf = str(row.get("confidence", "")).strip().lower()
		if conf in _DROP_CONFIDENCE:
			continue
		try:
			lat = float(row["latitude"])
			lon = float(row["longitude"])
			frp = float(row.get("frp", 0.0) or 0.0)
		except (KeyError, TypeError, ValueError):
			continue
		out.append({"latitude": lat, "longitude": lon, "frp": frp})
	return out


def _aggregate(
	detections: list[dict[str, Any]], lat: float, lon: float, radius_km: float
) -> dict[str, Any] | None:
	"""Summarize detections within radius_km of (lat, lon).

	Returns {'count','nearestKm','maxFrp'} for fires inside the true circle, or
	None when none are within radius (so the caller emits null, not a zero-fire
	object that would read as 'data present, all clear').
	"""
	nearest: float | None = None
	max_frp = 0.0
	count = 0
	for d in detections:
		dist = _haversine_km(lat, lon, d["latitude"], d["longitude"])
		if dist > radius_km:
			continue
		count += 1
		if nearest is None or dist < nearest:
			nearest = dist
		if d["frp"] > max_frp:
			max_frp = d["frp"]
	if count == 0 or nearest is None:
		return None
	return {
		"count": count,
		"nearestKm": round(nearest, 1),
		"maxFrp": round(max_frp, 1),
	}


def fetch_fires_nearby(
	lat: float,
	lon: float,
	map_key: str,
	radius_km: float = 150.0,
	source: str = "VIIRS_NOAA20_NRT",
) -> dict[str, Any] | None:
	"""Fetch + summarize active fires near a site.

	Receives: site lat/lon (decimal degrees), a FIRMS map_key (free), the search
	    radius_km, and the FIRMS source feed.
	Returns: {'count','nearestKm','maxFrp','radiusKm','source'} when fires are
	    within radius, else None (no key, or a VALIDATED no-fires response). `asOf`
	    is stamped by the caller from now_utc so this stays wall-clock-free for tests.
	Raises: FirmsError on ANY genuine failure — network/HTTP, a non-CSV 200 body, or
	    an unparseable body — so the caller flags meta.degraded. None is reserved for
	    a validated no-fires response; the two are never conflated. The raised message
	    never contains the URL or original exception text (it holds the map key).
	"""
	if not map_key:
		return None
	w, s, e, n = _bounding_box(lat, lon, radius_km)
	# URL-encode the key so a stray character can't malform the path; safe="" so '/'
	# is escaped too. The key is still a secret in the URL — see SECRET HYGIENE.
	safe_key = urllib.parse.quote(map_key, safe="")
	url = (f"{FIRMS_AREA_URL}/{safe_key}/{source}/"
	       f"{w:.4f},{s:.4f},{e:.4f},{n:.4f}/{FIRMS_DAY_RANGE}")
	try:
		# allow_redirects=False: the host is a fixed HTTPS constant; a redirect would
		# only re-send the key-bearing request elsewhere, so refuse it.
		r = requests.get(url, timeout=HTTP_TIMEOUT, allow_redirects=False)
		r.raise_for_status()
		# _parse_detections validates the body is fire-CSV and may raise FirmsError;
		# it runs INSIDE the try so a csv.Error (NUL byte / oversized field) cannot
		# escape as a raw exception and abort the whole fetch run (best-effort, §7).
		detections = _parse_detections(r.text)
	except FirmsError:
		raise  # already scrubbed + intentional; don't double-wrap
	except requests.RequestException as exc:
		# Scrub: the exception string contains the key-bearing URL — never log it.
		raise FirmsError(f"FIRMS request failed ({type(exc).__name__})") from None
	except (csv.Error, ValueError) as exc:
		raise FirmsError(
			f"FIRMS response unparseable ({type(exc).__name__})"
		) from None
	agg = _aggregate(detections, lat, lon, radius_km)
	if agg is None:
		return None
	agg.update({"radiusKm": int(radius_km), "source": source})
	return agg
