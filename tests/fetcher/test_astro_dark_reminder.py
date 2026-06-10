"""
Tests for the astro_dark_start_reminder notification rule.

This rule fires once per dark-window-per-site when:
- the feature is enabled,
- tonight's verdict is NB only or BB+NB (GO state),
- current time is at or past dark_window.start,
- we haven't already notified for this specific dark_window.start.

The state.json carries astroDarkNotifiedFor (site_id → ISO timestamp)
so the next run knows which windows have already been alerted.
"""

import json
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

import astrowidget_fetch as fx


def test_marker_persists_across_runs_via_main_tail_sequence(tmp_path, monkeypatch):
	"""Pins the marker-persistence contract behind the main() tail reorder
	(QA 2026-06-09): prev is the LAST run's state.json (not state.prev.json,
	which at read time held the state from TWO runs back), notifications are
	emitted BEFORE the state write (the old write-then-emit order discarded
	the freshly-set astroDarkNotifiedFor marker every run), and a second run
	therefore sees the marker and does NOT re-fire. With the old code either
	half regresses this test: PREV-file reads give run 2 a None prev (refire),
	and write-then-emit never persists the marker (refire)."""
	monkeypatch.setattr(fx, "CACHE_DIR", tmp_path)
	monkeypatch.setattr(fx, "STATE_PATH", tmp_path / "state.json")
	monkeypatch.setattr(fx, "PREV_STATE_PATH", tmp_path / "state.prev.json")
	now = datetime.now(timezone.utc)
	dark_start = (now - timedelta(hours=1)).isoformat().replace("+00:00", "Z")
	dark_end = (now + timedelta(hours=4)).isoformat().replace("+00:00", "Z")

	# Run 1 — the exact main() tail sequence: prev → emit (mutates) → write.
	state = _state_with_dark("BB+NB", dark_start, dark_end)
	with patch.object(fx, "_notify") as nf:
		prev = fx.load_prev_state()
		fx.emit_notifications(prev, state, _cfg())
		fx.write_state(state)
	nf.assert_called_once()
	on_disk = json.loads((tmp_path / "state.json").read_text())
	assert on_disk.get("astroDarkNotifiedFor", {}).get("site_a") == dark_start, (
		"the fired-once marker must be SERIALIZED — emit must precede write"
	)

	# Run 2 — same dark window: the persisted marker must suppress a re-fire.
	state2 = _state_with_dark("BB+NB", dark_start, dark_end)
	with patch.object(fx, "_notify") as nf2:
		prev2 = fx.load_prev_state()
		fx.emit_notifications(prev2, state2, _cfg())
		fx.write_state(state2)
	nf2.assert_not_called()


def _state_with_dark(rec: str, dark_start: str, dark_end: str) -> dict:
	"""Builds a state.json-shaped dict with one site, tonight only."""
	return {
		"sites": [
			{
				"id": "site_a",
				"label": "Site A",
				"status": "ok",
				"nights": [
					{
						"label": "Tonight",
						"recommendation": rec,
						"dark_window": {"start": dark_start, "end": dark_end},
					},
				],
			}
		]
	}


def _cfg(**kw) -> dict:
	notif = {
		"upward_transitions": False,  # isolate the dark-start rule
		"downward_transitions_day_of": False,
		"astro_dark_start_reminder": True,
	}
	notif.update(kw)
	return {"notifications": notif}


def test_dark_start_fires_when_dark_already_started():
	"""now > dark_start, GO verdict, no prior notification → fires once."""
	# dark started 1h ago
	now = datetime.now(timezone.utc)
	dark_start = (now - timedelta(hours=1)).isoformat().replace("+00:00", "Z")
	dark_end = (now + timedelta(hours=4)).isoformat().replace("+00:00", "Z")
	state = _state_with_dark("BB+NB", dark_start, dark_end)
	with patch.object(fx, "_notify") as nf:
		fx.emit_notifications(None, state, _cfg())
	nf.assert_called_once()
	# astroDarkNotifiedFor should have been written into the state.
	assert state["astroDarkNotifiedFor"]["site_a"] == dark_start


def test_dark_start_does_not_fire_before_window_starts():
	"""now < dark_start → no notification, no state update."""
	now = datetime.now(timezone.utc)
	dark_start = (now + timedelta(hours=4)).isoformat().replace("+00:00", "Z")
	dark_end = (now + timedelta(hours=10)).isoformat().replace("+00:00", "Z")
	state = _state_with_dark("BB+NB", dark_start, dark_end)
	with patch.object(fx, "_notify") as nf:
		fx.emit_notifications(None, state, _cfg())
	nf.assert_not_called()
	assert state["astroDarkNotifiedFor"].get("site_a") != dark_start


def test_dark_start_does_not_fire_on_neither_verdict():
	"""Neither verdict → no reminder even though dark has started."""
	now = datetime.now(timezone.utc)
	dark_start = (now - timedelta(hours=1)).isoformat().replace("+00:00", "Z")
	dark_end = (now + timedelta(hours=4)).isoformat().replace("+00:00", "Z")
	state = _state_with_dark("Neither", dark_start, dark_end)
	with patch.object(fx, "_notify") as nf:
		fx.emit_notifications(None, state, _cfg())
	nf.assert_not_called()


def test_dark_start_does_not_fire_twice_for_same_window():
	"""Second run with same dark_start → no second notification (one-shot)."""
	now = datetime.now(timezone.utc)
	dark_start = (now - timedelta(hours=1)).isoformat().replace("+00:00", "Z")
	dark_end = (now + timedelta(hours=4)).isoformat().replace("+00:00", "Z")
	state = _state_with_dark("BB+NB", dark_start, dark_end)
	prev = {"astroDarkNotifiedFor": {"site_a": dark_start}}
	with patch.object(fx, "_notify") as nf:
		fx.emit_notifications(prev, state, _cfg())
	nf.assert_not_called()


def test_dark_start_fires_for_new_window():
	"""New night's dark_start ≠ prev's → fires again (new window)."""
	now = datetime.now(timezone.utc)
	yesterday_start = "2026-05-27T04:00:00Z"
	tonight_start = (now - timedelta(hours=1)).isoformat().replace("+00:00", "Z")
	tonight_end = (now + timedelta(hours=4)).isoformat().replace("+00:00", "Z")
	state = _state_with_dark("NB only", tonight_start, tonight_end)
	prev = {"astroDarkNotifiedFor": {"site_a": yesterday_start}}
	with patch.object(fx, "_notify") as nf:
		fx.emit_notifications(prev, state, _cfg())
	nf.assert_called_once()
	assert state["astroDarkNotifiedFor"]["site_a"] == tonight_start


def test_dark_start_suppressed_when_disabled():
	"""astro_dark_start_reminder=false → never fires regardless of state."""
	now = datetime.now(timezone.utc)
	dark_start = (now - timedelta(hours=1)).isoformat().replace("+00:00", "Z")
	dark_end = (now + timedelta(hours=4)).isoformat().replace("+00:00", "Z")
	state = _state_with_dark("BB+NB", dark_start, dark_end)
	with patch.object(fx, "_notify") as nf:
		fx.emit_notifications(None, state, _cfg(astro_dark_start_reminder=False))
	nf.assert_not_called()
