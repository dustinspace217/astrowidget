"""
Tests for the cross-platform path resolvers: _generic_cache_dir (the location
where the fetcher and the Qt desktop app must agree on state.json) and
_score_exe_name (the scoring binary's per-OS filename). Both are pure functions
of sys.platform + environment, so every branch is exercised on Linux by
monkeypatching — these are the paths the Linux-only suite would otherwise never
cover, and getting them wrong breaks the app on Windows/macOS silently.
"""

from pathlib import Path

import astrowidget_fetch as fx


# ── _generic_cache_dir: mirrors Qt's QStandardPaths::GenericCacheLocation ─────


def test_cache_dir_windows_with_localappdata(monkeypatch):
	"""win32 → %LOCALAPPDATA%\\cache (Qt's GenericCacheLocation on Windows)."""
	monkeypatch.setattr(fx.sys, "platform", "win32")
	monkeypatch.setenv("LOCALAPPDATA", r"C:\Users\u\AppData\Local")
	assert fx._generic_cache_dir() == Path(r"C:\Users\u\AppData\Local") / "cache"


def test_cache_dir_windows_localappdata_absent(monkeypatch):
	"""win32 fallback when LOCALAPPDATA is unset → ~/AppData/Local/cache."""
	monkeypatch.setattr(fx.sys, "platform", "win32")
	monkeypatch.delenv("LOCALAPPDATA", raising=False)
	assert fx._generic_cache_dir() == Path.home() / "AppData" / "Local" / "cache"


def test_cache_dir_macos(monkeypatch):
	"""darwin → ~/Library/Caches (Qt's GenericCacheLocation on macOS)."""
	monkeypatch.setattr(fx.sys, "platform", "darwin")
	assert fx._generic_cache_dir() == Path.home() / "Library" / "Caches"


def test_cache_dir_linux_honors_absolute_xdg(monkeypatch):
	"""linux → $XDG_CACHE_HOME when set to an absolute path (matches Qt)."""
	monkeypatch.setattr(fx.sys, "platform", "linux")
	monkeypatch.setenv("XDG_CACHE_HOME", "/custom/cache")
	assert fx._generic_cache_dir() == Path("/custom/cache")


def test_cache_dir_linux_default(monkeypatch):
	"""linux → ~/.cache when XDG_CACHE_HOME is unset."""
	monkeypatch.setattr(fx.sys, "platform", "linux")
	monkeypatch.delenv("XDG_CACHE_HOME", raising=False)
	assert fx._generic_cache_dir() == Path.home() / ".cache"


def test_cache_dir_linux_ignores_relative_xdg(monkeypatch):
	"""A RELATIVE XDG_CACHE_HOME is ignored (XDG spec) → ~/.cache, so the fetcher
	and desktop app can't desync under different working directories."""
	monkeypatch.setattr(fx.sys, "platform", "linux")
	monkeypatch.setenv("XDG_CACHE_HOME", "relative/cache")
	assert fx._generic_cache_dir() == Path.home() / ".cache"


def test_cache_dir_linux_empty_xdg(monkeypatch):
	"""An empty-string XDG_CACHE_HOME is falsy → ~/.cache (never Path(''))."""
	monkeypatch.setattr(fx.sys, "platform", "linux")
	monkeypatch.setenv("XDG_CACHE_HOME", "")
	assert fx._generic_cache_dir() == Path.home() / ".cache"


# ── _score_exe_name: the scoring binary filename per platform ─────────────────


def test_score_exe_name_windows():
	"""Windows scoring binary has the .exe suffix (CreateProcess needs it)."""
	assert fx._score_exe_name("win32") == "astrowidget-score.exe"


def test_score_exe_name_posix():
	"""Linux/macOS scoring binary has no suffix."""
	assert fx._score_exe_name("linux") == "astrowidget-score"
	assert fx._score_exe_name("darwin") == "astrowidget-score"
