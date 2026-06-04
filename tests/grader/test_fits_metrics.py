"""
Tests for grader/fits_metrics.py — the per-sub FITS metric core.

The numeric functions take numpy arrays, so they're tested with SYNTHETIC frames
(no NAS / FITS files needed). read_sub (the astropy wrapper) is exercised against
real subs in a separate, opt-in validation, not here.
"""

import numpy as np

import fits_metrics as fm


def test_median_background_is_the_sky_level():
	data = np.full((100, 100), 500.0, dtype=np.float32)
	assert fm.median_background(data) == 500.0


def test_star_proxy_counts_injected_bright_pixels():
	rng = np.random.default_rng(0)
	data = (500 + rng.normal(0, 10, (200, 200))).astype(np.float32)
	# Inject 50 unambiguously-bright pixels (5000 >> the ~500±10 background).
	ys, xs = rng.integers(0, 200, 50), rng.integers(0, 200, 50)
	data[ys, xs] = 5000.0
	n = fm.star_proxy(data, k=5.0)
	# ~50 (some injected pixels may collide; a rare noise pixel may cross 5σ).
	assert 40 <= n <= 60


def test_star_proxy_flat_frame_is_zero():
	# MAD = 0 on a perfectly flat frame → no threshold → 0 (guards div-by-zero too).
	assert fm.star_proxy(np.full((50, 50), 100.0, dtype=np.float32)) == 0


def test_star_proxy_more_stars_higher_count():
	"""The core property the grader relies on: a more-transparent (more stars)
	frame yields a higher proxy than a sparser one, same background."""
	rng = np.random.default_rng(1)
	base = (500 + rng.normal(0, 10, (300, 300))).astype(np.float32)
	sparse = base.copy()
	sparse[rng.integers(0, 300, 30), rng.integers(0, 300, 30)] = 6000.0
	dense = base.copy()
	dense[rng.integers(0, 300, 400), rng.integers(0, 300, 400)] = 6000.0
	assert fm.star_proxy(dense) > fm.star_proxy(sparse)


def test_filter_from_header_wins():
	hdr = {"FILTER": "Ha"}
	path = "Eon 70_Bode's Galaxy_2025-01-20_04-03-55_L_-10.00_180.00s_0000.fits"
	assert fm._filter_from(hdr, path) == "Ha"


def test_filter_from_filename_when_header_absent():
	# NINA encodes the filter as "_L_-10.00..." when the header lacks FILTER.
	path = "Eon 70_Bode's Galaxy_2025-01-20_04-03-55_L_-10.00_180.00s_0000.fits"
	assert fm._filter_from({}, path) == "L"


def test_filter_none_when_unparseable():
	assert fm._filter_from({}, "random_file.fits") is None
