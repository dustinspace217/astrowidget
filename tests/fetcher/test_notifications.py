"""
Tests for the diff-based notification logic.

The fetcher compares prev state.json vs. new state.json and fires
notify-send on tonight-verdict transitions per spec §9.
"""

from unittest.mock import patch

import astrowidget_fetch as fx


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────


def _state(*recommendations: str) -> dict:
	"""Builds a state.json-shaped dict with the given tonight verdicts."""
	return {
		"sites": [
			{
				"id": f"site_{i}",
				"label": f"Site {i}",
				"status": "ok",
				"nights": [
					{"label": "Tonight", "recommendation": rec},
					{"label": "+1 night", "recommendation": "Neither"},
					{"label": "+2 nights", "recommendation": "Neither"},
				],
			}
			for i, rec in enumerate(recommendations, start=1)
		]
	}


def _default_cfg(**overrides) -> dict:
	"""Default notification config — all rules on except suppress."""
	notif = {
		"upward_transitions": True,
		"downward_transitions_day_of": True,
		"astro_dark_start_reminder": True,
		"suppress_during_astro_dark": False,
	}
	notif.update(overrides)
	return {"notifications": notif}


# ─────────────────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────────────────


def test_first_run_no_notifications():
	"""prev is None (first run ever) → never notify, even on Excellent."""
	with patch.object(fx, "_notify") as nf:
		fx.emit_notifications(None, _state("BB+NB"), _default_cfg())
	nf.assert_not_called()


def test_no_change_no_notifications():
	"""prev and new have identical tonight verdicts → no notifications."""
	state = _state("BB+NB")
	with patch.object(fx, "_notify") as nf:
		fx.emit_notifications(state, state, _default_cfg())
	nf.assert_not_called()


def test_upward_transition_fires():
	"""Neither → BB+NB fires a notification when upward_transitions=True."""
	prev = _state("Neither")
	new = _state("BB+NB")
	with patch.object(fx, "_notify") as nf:
		fx.emit_notifications(prev, new, _default_cfg())
	nf.assert_called_once()
	# Title should include the site label, body should mention improvement.
	args = nf.call_args.args
	assert "Site 1" in args[0]
	assert "BB+NB" in args[0]


def test_upward_transition_suppressed_when_disabled():
	"""upward_transitions=False → no notification on improvement."""
	prev = _state("Neither")
	new = _state("BB+NB")
	cfg = _default_cfg(upward_transitions=False)
	with patch.object(fx, "_notify") as nf:
		fx.emit_notifications(prev, new, cfg)
	nf.assert_not_called()


def test_downward_transition_fires_with_critical_urgency():
	"""BB+NB → Neither (downward, day-of) fires with urgency=critical."""
	prev = _state("BB+NB")
	new = _state("Neither")
	with patch.object(fx, "_notify") as nf:
		fx.emit_notifications(prev, new, _default_cfg())
	nf.assert_called_once()
	# Urgency is a kwarg on _notify.
	assert nf.call_args.kwargs.get("urgency") == "critical"


def test_intermediate_upward_transition_fires():
	"""NB only → BB+NB is also an upward transition."""
	prev = _state("NB only")
	new = _state("BB+NB")
	with patch.object(fx, "_notify") as nf:
		fx.emit_notifications(prev, new, _default_cfg())
	nf.assert_called_once()


def test_multi_site_each_fires_independently():
	"""Two sites both transitioning fire two notifications."""
	prev = _state("Neither", "BB+NB")
	new = _state("BB+NB", "Neither")
	with patch.object(fx, "_notify") as nf:
		fx.emit_notifications(prev, new, _default_cfg())
	assert nf.call_count == 2


def test_error_site_skipped():
	"""A site in 'error' status is not diffed (the error itself was notified)."""
	prev = _state("BB+NB")
	new = {
		"sites": [
			{
				"id": "site_1",
				"label": "Site 1",
				"status": "error",
				"error": "DNS resolution failed",
			}
		]
	}
	with patch.object(fx, "_notify") as nf:
		fx.emit_notifications(prev, new, _default_cfg())
	nf.assert_not_called()
