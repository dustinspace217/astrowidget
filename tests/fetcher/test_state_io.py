"""
Tests for state.json read/write — including atomicity guarantees, file
permission restrictions, and corruption recovery for the prev state.
"""

import json
import stat
from pathlib import Path

import astrowidget_fetch as fx


def test_write_state_creates_cache_dir(tmp_path, monkeypatch):
	"""write_state creates the cache directory if it doesn't exist."""
	cache_dir = tmp_path / "cache" / "astrowidget"
	monkeypatch.setattr(fx, "CACHE_DIR", cache_dir)
	monkeypatch.setattr(fx, "STATE_PATH", cache_dir / "state.json")
	monkeypatch.setattr(fx, "PREV_STATE_PATH", cache_dir / "state.prev.json")
	fx.write_state({"schemaVersion": 1, "sites": []})
	assert cache_dir.is_dir()
	assert (cache_dir / "state.json").exists()


def test_write_state_uses_0600_permissions(tmp_path, monkeypatch):
	"""
	state.json must be 0600 to prevent local users from reading lat/lon
	from another user's home (multi-user box, bind-mounted container).
	"""
	cache_dir = tmp_path / "cache"
	monkeypatch.setattr(fx, "CACHE_DIR", cache_dir)
	state_path = cache_dir / "state.json"
	monkeypatch.setattr(fx, "STATE_PATH", state_path)
	monkeypatch.setattr(fx, "PREV_STATE_PATH", cache_dir / "state.prev.json")
	fx.write_state({"schemaVersion": 1, "sites": []})
	mode = stat.S_IMODE(state_path.stat().st_mode)
	assert mode == 0o600, f"state.json perms should be 0600, got {oct(mode)}"


def test_write_state_rotates_to_prev(tmp_path, monkeypatch):
	"""When called with existing state.json, the prior contents move to state.prev.json."""
	cache_dir = tmp_path / "cache"
	monkeypatch.setattr(fx, "CACHE_DIR", cache_dir)
	monkeypatch.setattr(fx, "STATE_PATH", cache_dir / "state.json")
	monkeypatch.setattr(fx, "PREV_STATE_PATH", cache_dir / "state.prev.json")
	fx.write_state({"schemaVersion": 1, "marker": "first"})
	fx.write_state({"schemaVersion": 1, "marker": "second"})
	current = json.loads((cache_dir / "state.json").read_text())
	prev = json.loads((cache_dir / "state.prev.json").read_text())
	assert current["marker"] == "second"
	assert prev["marker"] == "first"


def test_write_state_atomic_via_tmp_rename(tmp_path, monkeypatch):
	"""No state.json.tmp lingers after a successful write (rename completed)."""
	cache_dir = tmp_path / "cache"
	monkeypatch.setattr(fx, "CACHE_DIR", cache_dir)
	monkeypatch.setattr(fx, "STATE_PATH", cache_dir / "state.json")
	monkeypatch.setattr(fx, "PREV_STATE_PATH", cache_dir / "state.prev.json")
	fx.write_state({"schemaVersion": 1})
	assert not (cache_dir / "state.json.tmp").exists()
	assert (cache_dir / "state.json").exists()


def test_load_prev_state_returns_none_when_absent(tmp_path, monkeypatch):
	"""Missing state.prev.json → None (clean first-run behavior)."""
	monkeypatch.setattr(fx, "PREV_STATE_PATH", tmp_path / "absent.json")
	assert fx.load_prev_state() is None


def test_load_prev_state_removes_corrupt_file(tmp_path, monkeypatch):
	"""
	Malformed prev state → log + remove + return None.
	(Silent swallow flagged by silent-failure-hunter.)
	"""
	prev = tmp_path / "prev.json"
	prev.write_text("this is not json", encoding="utf-8")
	monkeypatch.setattr(fx, "PREV_STATE_PATH", prev)
	result = fx.load_prev_state()
	assert result is None
	# Corrupt file is removed so the next run starts cleanly.
	assert not prev.exists()


def test_slice_hourly_for_night_returns_window_hours():
	"""Only hours inside [start, end] of the dark window are returned."""
	hourly = [
		{"time": "2026-05-29T03:00:00", "cloud_cover": 10},  # before
		{"time": "2026-05-29T05:00:00", "cloud_cover": 20},  # inside
		{"time": "2026-05-29T07:00:00", "cloud_cover": 30},  # inside
		{"time": "2026-05-29T13:00:00", "cloud_cover": 40},  # after
	]
	dw = {"start": "2026-05-29T04:00:00Z", "end": "2026-05-29T11:00:00Z"}
	sliced = fx.slice_hourly_for_night(hourly, dw)
	assert len(sliced) == 2
	assert sliced[0]["cloud_cover"] == 20
	assert sliced[1]["cloud_cover"] == 30


def test_slice_hourly_empty_when_no_dark_window():
	"""Polar summer / missing dark window → empty slice, no exception."""
	assert fx.slice_hourly_for_night([{"time": "2026-05-29T05:00:00"}], None) == []
	assert fx.slice_hourly_for_night([], {"start": "X", "end": "Y"}) == []
