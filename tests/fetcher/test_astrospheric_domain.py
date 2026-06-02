"""
Tests for the Astrospheric eligibility box and failure-code tagging that drive
the graceful-fallback feature: which sites attempt Astrospheric (derived from
lat/lon, no flag), and the stable codes the UI uses as dismissal keys.
"""

import astrowidget_fetch as fx


def test_in_astrospheric_domain_north_america():
	"""North-American imaging sites are in-domain (Astrospheric is attempted)."""
	assert fx._in_astrospheric_domain(47.6, -122.3)   # Pacific NW
	assert fx._in_astrospheric_domain(38.4, -120.8)   # Sierra, CA
	assert fx._in_astrospheric_domain(64.8, -147.7)   # Fairbanks, AK
	assert fx._in_astrospheric_domain(19.8, -155.5)   # Mauna Kea, HI
	assert fx._in_astrospheric_domain(25.7, -100.3)   # Monterrey, MX


def test_in_astrospheric_domain_excludes_rest_of_world():
	"""Sites outside North America are out-of-domain (free path, no warning)."""
	assert not fx._in_astrospheric_domain(-33.0, -70.0)   # Chile
	assert not fx._in_astrospheric_domain(-31.3, 149.0)   # Siding Spring, AU
	assert not fx._in_astrospheric_domain(28.3, -16.5)    # Teide, Canary Is. (east of box)
	assert not fx._in_astrospheric_domain(51.5, 0.0)      # London
	assert not fx._in_astrospheric_domain(-90.0, 0.0)     # South Pole


def test_astrospheric_fetch_error_carries_stable_code():
	"""AstrosphericFetchError exposes a stable .code (default 'error') — the UI
	uses <site_id>|<code> as the 'don't show again' dismissal key."""
	assert fx.AstrosphericFetchError("rejected", code="http_403").code == "http_403"
	assert fx.AstrosphericFetchError("oops").code == "error"


def test_in_astrospheric_domain_boundaries_are_inclusive():
	"""The box edges (lat 14–84°N, lon −170 to −50°W) are INCLUSIVE, and points
	just outside are excluded. The other domain tests use comfortably-interior and
	far-exterior points, so a flipped < / <= or a transposed bound would slip past
	them; these pin the four edges so a paid-tier user at the rim of the coverage
	still gets the Astrospheric feed they pay for."""
	# Exact edges — in-domain (inclusive bounds), the other coord held interior.
	assert fx._in_astrospheric_domain(14.0, -100.0)    # south edge
	assert fx._in_astrospheric_domain(84.0, -100.0)    # north edge
	assert fx._in_astrospheric_domain(40.0, -170.0)    # west edge
	assert fx._in_astrospheric_domain(40.0, -50.0)     # east edge
	# Just outside each edge — out of domain.
	assert not fx._in_astrospheric_domain(13.9, -100.0)
	assert not fx._in_astrospheric_domain(84.1, -100.0)
	assert not fx._in_astrospheric_domain(40.0, -170.1)
	assert not fx._in_astrospheric_domain(40.0, -49.9)
