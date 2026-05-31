"""
Tests for per-site veto threshold validation in load_config.

Adversarial review flagged that negative or absurd threshold values
silently produce "Neither" for every hour. Validation rejects them
up front with a clear error.
"""

import os
import textwrap
from pathlib import Path
from unittest.mock import patch

import pytest

import astrowidget_fetch as fx


VALID_BASE = """
[api]
astrospheric_key = "fake"

[[sites]]
id = "site_a"
label = "A"
lat = 47.0
lon = -122.0
timezone = "UTC"
"""


def _write_config(tmp_path: Path, content: str) -> Path:
	path = tmp_path / "config.toml"
	path.write_text(textwrap.dedent(content), encoding="utf-8")
	os.chmod(path, 0o600)
	return path


def test_negative_wind_threshold_rejected(tmp_path, monkeypatch):
	"""wind_max_kmh = -5 → exit 2 (would otherwise veto every hour silently)."""
	cfg = VALID_BASE + "\n[thresholds.site_a]\nwind_max_kmh = -5\n"
	monkeypatch.setattr(fx, "CONFIG_PATH", _write_config(tmp_path, cfg))
	with patch.object(fx, "_notify"):
		with pytest.raises(SystemExit) as ei:
			fx.load_config()
	assert ei.value.code == 2


def test_oversized_wind_threshold_rejected(tmp_path, monkeypatch):
	"""wind_max_kmh = 500 (above plausible) → exit 2."""
	cfg = VALID_BASE + "\n[thresholds.site_a]\nwind_max_kmh = 500\n"
	monkeypatch.setattr(fx, "CONFIG_PATH", _write_config(tmp_path, cfg))
	with patch.object(fx, "_notify"):
		with pytest.raises(SystemExit) as ei:
			fx.load_config()
	assert ei.value.code == 2


def test_negative_precip_threshold_rejected(tmp_path, monkeypatch):
	"""precip_max_pct = -10 → exit 2."""
	cfg = VALID_BASE + "\n[thresholds.site_a]\nprecip_max_pct = -10\n"
	monkeypatch.setattr(fx, "CONFIG_PATH", _write_config(tmp_path, cfg))
	with patch.object(fx, "_notify"):
		with pytest.raises(SystemExit) as ei:
			fx.load_config()
	assert ei.value.code == 2


def test_precip_threshold_above_100_rejected(tmp_path, monkeypatch):
	"""precip_max_pct = 150 (percentages cap at 100) → exit 2."""
	cfg = VALID_BASE + "\n[thresholds.site_a]\nprecip_max_pct = 150\n"
	monkeypatch.setattr(fx, "CONFIG_PATH", _write_config(tmp_path, cfg))
	with patch.object(fx, "_notify"):
		with pytest.raises(SystemExit) as ei:
			fx.load_config()
	assert ei.value.code == 2


def test_valid_thresholds_pass(tmp_path, monkeypatch):
	"""Sensible thresholds load without error."""
	cfg = VALID_BASE + """
[thresholds.site_a]
wind_max_kmh = 40
precip_max_pct = 30
dew_spread_min_c = 1.5
"""
	monkeypatch.setattr(fx, "CONFIG_PATH", _write_config(tmp_path, cfg))
	with patch.object(fx, "_notify"):
		loaded = fx.load_config()
	assert loaded["thresholds"]["site_a"]["wind_max_kmh"] == 40


def test_non_numeric_threshold_rejected(tmp_path, monkeypatch):
	"""wind_max_kmh = 'fast' (string) → exit 2."""
	cfg = VALID_BASE + '\n[thresholds.site_a]\nwind_max_kmh = "fast"\n'
	monkeypatch.setattr(fx, "CONFIG_PATH", _write_config(tmp_path, cfg))
	with patch.object(fx, "_notify"):
		with pytest.raises(SystemExit) as ei:
			fx.load_config()
	assert ei.value.code == 2
