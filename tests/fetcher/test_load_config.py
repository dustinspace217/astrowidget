"""
Tests for configuration loading and validation.

The fetcher refuses to start if the config file is missing, world-readable,
malformed, or has placeholder values. All failures emit a notify-send so
users see misconfiguration immediately.
"""

import os
import textwrap
from pathlib import Path
from unittest.mock import patch

import pytest

import astrowidget_fetch as fx


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────


def _write_config(tmp_path: Path, content: str, mode: int = 0o600) -> Path:
	"""Writes a config.toml to tmp and returns the path."""
	path = tmp_path / "config.toml"
	path.write_text(textwrap.dedent(content), encoding="utf-8")
	os.chmod(path, mode)
	return path


VALID_CONFIG = """
[api]
astrospheric_key = "fake-key-for-tests"
astrospheric_daily_credit_budget = 100

[open_meteo]
models = ["gfs_seamless"]

[[sites]]
id = "site_a"
label = "Test Site"
lat = 47.0
lon = -122.0
timezone = "UTC"
"""


# ─────────────────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────────────────


def test_load_config_happy_path(tmp_path, monkeypatch):
	"""Valid config loads without error, returns parsed dict."""
	cfg_path = _write_config(tmp_path, VALID_CONFIG, mode=0o600)
	monkeypatch.setattr(fx, "CONFIG_PATH", cfg_path)
	with patch.object(fx, "_notify"):
		cfg = fx.load_config()
	assert cfg["api"]["astrospheric_key"] == "fake-key-for-tests"
	assert cfg["sites"][0]["id"] == "site_a"


def test_load_config_missing_file_exits_2(tmp_path, monkeypatch):
	"""No config file → exit 2 with a notify-send."""
	monkeypatch.setattr(fx, "CONFIG_PATH", tmp_path / "nonexistent.toml")
	with patch.object(fx, "_notify") as nf:
		with pytest.raises(SystemExit) as ei:
			fx.load_config()
	assert ei.value.code == 2
	# The notify-send must have fired with critical urgency.
	nf.assert_called_once()
	assert "critical" in nf.call_args.kwargs.get("urgency", "")


def test_load_config_world_readable_rejected(tmp_path, monkeypatch):
	"""chmod 644 → exit 2 with a permission-specific notification.
	(test-analyzer flagged that only exit code was asserted; a regression
	flipping the perm check into a 'parse error' notification would have
	passed silently. Now asserts the title mentions permissions.)"""
	cfg_path = _write_config(tmp_path, VALID_CONFIG, mode=0o644)
	monkeypatch.setattr(fx, "CONFIG_PATH", cfg_path)
	with patch.object(fx, "_notify") as nf:
		with pytest.raises(SystemExit) as ei:
			fx.load_config()
	assert ei.value.code == 2
	nf.assert_called_once()
	title = nf.call_args.args[0]
	assert "permission" in title.lower() or "perms" in title.lower(), \
		f"expected permission-specific notification title, got: {title!r}"


def test_load_config_skips_perm_check_on_windows(tmp_path, monkeypatch):
	"""On Windows the 0600 perm check is skipped — st_mode permission bits are a
	POSIX concept and os.stat reports synthetic bits there, so the 0o077 test
	would reject every config. A 'world-readable' config must load instead of
	being rejected, or the fetcher could never start on Windows."""
	cfg_path = _write_config(tmp_path, VALID_CONFIG, mode=0o644)
	monkeypatch.setattr(fx, "CONFIG_PATH", cfg_path)
	monkeypatch.setattr(fx.sys, "platform", "win32")
	with patch.object(fx, "_notify"):
		cfg = fx.load_config()  # must NOT raise SystemExit on perms
	assert cfg["api"]["astrospheric_key"] == "fake-key-for-tests"


def test_load_config_missing_api_key_now_accepted(tmp_path, monkeypatch):
	"""The Astrospheric key is OPTIONAL now: an empty (or absent) key loads fine.
	In-domain sites surface a dismissable 'no key' notice and use the free
	sources; the key was previously a hard requirement even for free-only configs."""
	cfg = VALID_CONFIG.replace('"fake-key-for-tests"', '""')
	cfg_path = _write_config(tmp_path, cfg, mode=0o600)
	monkeypatch.setattr(fx, "CONFIG_PATH", cfg_path)
	with patch.object(fx, "_notify"):
		loaded = fx.load_config()  # must NOT raise
	assert loaded["sites"][0]["id"] == "site_a"


def test_load_config_no_sites_rejected(tmp_path, monkeypatch):
	"""Missing [[sites]] block → exit 2."""
	cfg = """
	[api]
	astrospheric_key = "k"
	"""
	cfg_path = _write_config(tmp_path, cfg, mode=0o600)
	monkeypatch.setattr(fx, "CONFIG_PATH", cfg_path)
	with patch.object(fx, "_notify"):
		with pytest.raises(SystemExit) as ei:
			fx.load_config()
	assert ei.value.code == 2


def test_load_config_null_island_rejected(tmp_path, monkeypatch):
	"""Placeholder coords (0.0, 0.0) → exit 2 to prevent wasted API credits."""
	cfg = VALID_CONFIG.replace("lat = 47.0", "lat = 0.0").replace(
		"lon = -122.0", "lon = 0.0"
	)
	cfg_path = _write_config(tmp_path, cfg, mode=0o600)
	monkeypatch.setattr(fx, "CONFIG_PATH", cfg_path)
	with patch.object(fx, "_notify"):
		with pytest.raises(SystemExit) as ei:
			fx.load_config()
	assert ei.value.code == 2


def test_load_config_malformed_toml_rejected(tmp_path, monkeypatch):
	"""Syntax error in TOML → exit 2 with parse-error message."""
	cfg_path = _write_config(tmp_path, "this is not = valid = toml", mode=0o600)
	monkeypatch.setattr(fx, "CONFIG_PATH", cfg_path)
	with patch.object(fx, "_notify"):
		with pytest.raises(SystemExit) as ei:
			fx.load_config()
	assert ei.value.code == 2


# ── Per-site source/visibility flags (7-site expansion) ──────────────────────


def test_load_config_primary_defaults_true(tmp_path, monkeypatch):
	"""A site with no `primary` flag defaults to True (a full always-on column).
	Astrospheric eligibility is now derived from lat/lon, not a flag."""
	cfg_path = _write_config(tmp_path, VALID_CONFIG, mode=0o600)
	monkeypatch.setattr(fx, "CONFIG_PATH", cfg_path)
	with patch.object(fx, "_notify"):
		cfg = fx.load_config()
	assert cfg["sites"][0]["primary"] is True


def test_load_config_rejects_non_bool_primary(tmp_path, monkeypatch):
	"""primary = 1 (an INTEGER) must be rejected — only the TOML boolean is
	valid. (bool is an int subclass, so the guard must reject a real int.)"""
	cfg = VALID_CONFIG + "\nprimary = 1\n"
	cfg_path = _write_config(tmp_path, cfg, mode=0o600)
	monkeypatch.setattr(fx, "CONFIG_PATH", cfg_path)
	with patch.object(fx, "_notify") as nf:
		with pytest.raises(SystemExit) as ei:
			fx.load_config()
	assert ei.value.code == 2
	assert "primary" in nf.call_args.args[0]


def test_load_config_nb_leakage_valid(tmp_path, monkeypatch):
	"""A valid per-site nb_leakage (0 < x ≤ 1) is accepted and floated through to the
	scoring payload (DEF-V2-03 narrowband filter override)."""
	cfg = VALID_CONFIG + "\nnb_leakage = 0.04\n"
	cfg_path = _write_config(tmp_path, cfg, mode=0o600)
	monkeypatch.setattr(fx, "CONFIG_PATH", cfg_path)
	with patch.object(fx, "_notify"):
		loaded = fx.load_config()
	assert loaded["sites"][0]["nb_leakage"] == 0.04


def test_load_config_nb_leakage_absent_defaults_none(tmp_path, monkeypatch):
	"""No nb_leakage → None (the Dart binary then uses the calibrated 0.38 — retention-v2)."""
	cfg_path = _write_config(tmp_path, VALID_CONFIG, mode=0o600)
	monkeypatch.setattr(fx, "CONFIG_PATH", cfg_path)
	with patch.object(fx, "_notify"):
		loaded = fx.load_config()
	assert loaded["sites"][0]["nb_leakage"] is None


@pytest.mark.parametrize("bad", ["0", "1.5", '"x"', "true"])
def test_load_config_rejects_bad_nb_leakage(tmp_path, monkeypatch, bad):
	"""nb_leakage outside (0, 1], non-numeric, or a bool is rejected loudly (exit 2) —
	a typo would otherwise mis-score every narrowband verdict."""
	cfg = VALID_CONFIG + f"\nnb_leakage = {bad}\n"
	cfg_path = _write_config(tmp_path, cfg, mode=0o600)
	monkeypatch.setattr(fx, "CONFIG_PATH", cfg_path)
	with patch.object(fx, "_notify"):
		with pytest.raises(SystemExit) as ei:
			fx.load_config()
	assert ei.value.code == 2
