"""
fits_metrics.py — per-sub FITS metrics for the astrowidget auto-grader (Phase 3).

Extracts, from one light frame, the settings-independent signals the grader needs
to grade a night's transparency (spec §6a): the capture time + filter, a robust
background level, and a **star-count proxy** that tracks how many stars punched
through — the ground truth where the cloud/transparency forecast fails (the
decisive May 30 vs May 31 Bode's comparison: ~17k vs ~3k, same field).

The numeric core (`star_proxy`, `median_background`) takes a numpy array, so it is
unit-tested with synthetic frames — no NAS/FITS needed in CI. `read_sub` is the
thin astropy wrapper that pulls a real file's header + data through that core.

Star-count proxy: count pixels brighter than `median + k·(1.4826·MAD)` — a
MAD-based ~k-sigma threshold (MAD·1.4826 ≈ the Gaussian sigma, robust to the bright
stars themselves, unlike the plain stdev). It is a PROXY (bright-pixel count, not a
deblended source count), which is all the grader needs: it is monotonic with
transparency and is only ever compared **within the same target + filter** (never
across targets — a sparse galaxy field and a Milky-Way field differ ~40x for
reasons that aren't weather). Source-deblending (photutils) is a later refinement.
"""

from __future__ import annotations

import os
import re
from typing import Any

import numpy as np

# MAD → Gaussian-sigma scale factor (for a normal distribution).
_MAD_TO_SIGMA = 1.4826


def median_background(data: np.ndarray) -> float:
	"""Robust background level = the median pixel value. (The sky dominates the
	pixel count, so the median sits in the background, unaffected by stars.)"""
	return float(np.median(data))


def star_proxy(data: np.ndarray, k: float = 5.0) -> int:
	"""Bright-pixel star-count proxy: the number of pixels above
	`median + k · 1.4826 · MAD`. Higher = more stars punched through = more
	transparent. Robust because MAD ignores the bright stars that would inflate a
	plain standard deviation. `k=5` ≈ a 5-sigma cut.

	Receives: [data] 2-D image array; [k] sigma threshold.
	Returns: count of bright pixels (int).
	"""
	med = np.median(data)
	mad = np.median(np.abs(data - med))
	if mad <= 0:  # a flat/degenerate frame — no usable threshold
		return 0
	threshold = med + k * _MAD_TO_SIGMA * mad
	return int(np.count_nonzero(data > threshold))


# NINA encodes the filter in the file name when the header lacks it, e.g.
# "Eon 70_Bode's Galaxy_2025-01-20_04-03-55_L_-10.00_180.00s_0000.fits" → "L".
# Match a 1-3 char filter token bracketed by underscores, before the temp/exposure.
_FILTER_RE = re.compile(r"_([A-Za-z]{1,3})_-?\d", )


def _filter_from(header: Any, path: str) -> str | None:
	"""Filter for a sub: the header FILTER if present, else parsed from the NINA
	file name, else None."""
	f = header.get("FILTER")
	if isinstance(f, str) and f.strip():
		return f.strip()
	m = _FILTER_RE.search(os.path.basename(path))
	return m.group(1) if m else None


def read_sub(path: str, k: float = 5.0) -> dict[str, Any]:
	"""Read one FITS light frame and return its grading metrics.

	Receives: [path] to a .fits file; [k] star-proxy sigma threshold.
	Returns: a dict with:
	    date_obs   — capture time (UTC ISO string from the header), or None
	    filter     — filter name (header or filename), or None
	    moonangl   — moon–target separation in degrees (header), or None
	    exptime    — exposure seconds, or None
	    median_bg  — median background level
	    star_proxy — bright-pixel star-count proxy
	    path       — the file path (for reference)
	memmap=False because NINA writes scaled (BZERO/BSCALE) 16-bit FITS that memmap
	mishandles — a lesson from the earlier hand-analysis this session.
	"""
	from astropy.io import fits  # local import: keep numpy-only callers astropy-free

	with fits.open(path, memmap=False) as hdul:
		header = hdul[0].header
		data = np.asarray(hdul[0].data, dtype=np.float32)

	moonangl = header.get("MOONANGL")
	exptime = header.get("EXPTIME")
	return {
		"date_obs": header.get("DATE-OBS"),
		"filter": _filter_from(header, path),
		"moonangl": float(moonangl) if isinstance(moonangl, (int, float)) else None,
		"exptime": float(exptime) if isinstance(exptime, (int, float)) else None,
		"median_bg": median_background(data),
		"star_proxy": star_proxy(data, k=k),
		"path": path,
	}
