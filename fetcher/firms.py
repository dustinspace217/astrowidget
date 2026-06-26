"""NASA FIRMS active-fire proximity for astrowidget.

WHAT: queries the NASA FIRMS Area CSV API for satellite-detected active fires
near a site and summarizes the nearest one, the count within a radius, and the
peak fire radiative power (FRP). This catches near-source wildfire smoke that the
coarse (45 km) CAMS aerosol model under-resolves — the 2026-06-25 UDRO miss,
where the forecast read "excellent transparency" during a real smoke night.

WHY a separate module: pure data acquisition + geometry, with no scoring and no
astrowidget_fetch coupling, so it is independently testable with synthetic CSV
(public-repo discipline: never a real coordinate in a test).

ERROR MODEL: a genuine fetch/HTTP failure raises FirmsError (so the caller can
flag meta.degraded); a clean "no fires nearby" returns None. The two are never
conflated into one ambiguous None. The caller (astrowidget_fetch.main) wraps the
call so the fetch run never aborts on a fire-data problem.

Dependencies: requests (already the fetcher's only external dep) + stdlib.
"""
import csv
import io
import math
from typing import Any

import requests


class FirmsError(Exception):
	"""A FIRMS fetch/parse GENUINELY failed (network, HTTP, unparseable body).

	Distinct from a clean "no fires nearby," which returns None. The caller
	catches FirmsError to flag meta.degraded, while a None result is a normal
	quiet-sky night that flags nothing — the two states must never collapse into
	one ambiguous None.
	"""


# FIRMS Area CSV endpoint. Path params: MAP_KEY / SOURCE / west,south,east,north /
# DAY_RANGE. DAY_RANGE=1 = most recent 24 h = "burning now".
FIRMS_AREA_URL = "https://firms.modaps.eosdis.nasa.gov/api/area/csv"
HTTP_TIMEOUT = 30
# Power-of-Ten rule 2/3: bound the parse. A 150 km box during a megafire could in
# principle return many rows; cap so a pathological response can't grow unbounded.
MAX_ROWS = 20000
# VIIRS confidence is l/n/h (low/nominal/high). Drop low-confidence detections.
_DROP_CONFIDENCE = {"l", "low"}


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
	east,north — exactly the order the FIRMS path expects.
	"""
	d_lat = radius_km / 111.0
	# Guard the pole singularity (cos→0). cos(89°)≈0.017; clamp keeps the box finite.
	d_lon = radius_km / (111.0 * max(0.01, math.cos(math.radians(lat))))
	return (lon - d_lon, lat - d_lat, lon + d_lon, lat + d_lat)


def _parse_detections(csv_text: str) -> list[dict[str, Any]]:
	"""Parse FIRMS CSV text into [{'latitude','longitude','frp'}] detections.

	Keeps only rows with a parseable lat/lon/frp and confidence not in the
	low-confidence set. Malformed rows are skipped (best-effort). Bounded at
	MAX_ROWS so a runaway response can't grow unbounded.
	"""
	out: list[dict[str, Any]] = []
	reader = csv.DictReader(io.StringIO(csv_text))
	for i, row in enumerate(reader):
		if i >= MAX_ROWS:
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
	    within radius, else None (no key, or no fires nearby). `asOf` is stamped by
	    the caller from now_utc so this stays wall-clock-free for tests.
	Raises: FirmsError on a genuine fetch/HTTP failure (None is reserved for the
	    clean no-fires case so the caller can tell the two apart).
	"""
	if not map_key:
		return None
	w, s, e, n = _bounding_box(lat, lon, radius_km)
	url = f"{FIRMS_AREA_URL}/{map_key}/{source}/{w:.4f},{s:.4f},{e:.4f},{n:.4f}/1"
	try:
		r = requests.get(url, timeout=HTTP_TIMEOUT)
		r.raise_for_status()
	except requests.RequestException as exc:
		# Genuine failure — surface it so the caller flags degraded. The run still
		# continues (the caller catches FirmsError); None stays reserved for no-fires.
		raise FirmsError(str(exc)) from exc
	detections = _parse_detections(r.text)
	agg = _aggregate(detections, lat, lon, radius_km)
	if agg is None:
		return None
	agg.update({"radiusKm": int(radius_km), "source": source})
	return agg
