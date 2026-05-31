"""
Tests for the Astrospheric raw -> human label mappers.

The single most important property here is POLARITY: seeing (0-5) and
transparency (0-27+) run in opposite directions. A regression that treated
transparency as a 0-5 "higher is better" scale would render the widget
backwards — these tests pin the documented buckets.
"""

import astrowidget_fetch as fx


# ── Seeing: 0-5, HIGHER is better ─────────────────────────────────────────────

def test_seeing_label_buckets():
	assert fx.seeing_label(0) == "Cloudy"
	assert fx.seeing_label(1) == "Poor"
	assert fx.seeing_label(2) == "Below Average"
	assert fx.seeing_label(3) == "Average"
	assert fx.seeing_label(4) == "Above Average"
	assert fx.seeing_label(5) == "Excellent"


def test_seeing_label_rounds():
	"""Averaged seeing (e.g. 3.4) rounds to the nearest bucket."""
	assert fx.seeing_label(3.4) == "Average"
	assert fx.seeing_label(3.6) == "Above Average"


def test_seeing_label_none():
	assert fx.seeing_label(None) == "—"


def test_seeing_label_clamps_out_of_range():
	"""Defensive: values outside 0-5 clamp rather than KeyError."""
	assert fx.seeing_label(7) == "Excellent"
	assert fx.seeing_label(-2) == "Cloudy"


# ── Transparency: 0-27+, LOWER is better (0-5 = Excellent) ────────────────────

def test_transparency_label_buckets():
	assert fx.transparency_label(0) == "Excellent"
	assert fx.transparency_label(5) == "Excellent"
	assert fx.transparency_label(6) == "Above Average"
	assert fx.transparency_label(9) == "Above Average"
	assert fx.transparency_label(10) == "Average"
	assert fx.transparency_label(13) == "Average"
	assert fx.transparency_label(14) == "Below Average"
	assert fx.transparency_label(23) == "Below Average"
	assert fx.transparency_label(24) == "Poor"
	assert fx.transparency_label(27) == "Poor"
	assert fx.transparency_label(40) == "Cloudy"


def test_transparency_polarity_is_inverted_vs_seeing():
	"""
	The cross-check that catches a polarity regression: a LOW transparency
	raw value is GOOD, while a LOW seeing raw value is BAD.
	"""
	assert fx.transparency_label(2) == "Excellent"   # low raw = good
	assert fx.seeing_label(2) == "Below Average"      # low raw = bad


def test_transparency_label_none():
	assert fx.transparency_label(None) == "—"
