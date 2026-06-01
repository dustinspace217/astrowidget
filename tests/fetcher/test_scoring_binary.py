"""
Tests for invoke_scoring_binary — the subprocess interface to the Dart
scoring binary. All failure exits (4) must emit a notification per the
spec §6.1 "no silent failures" promise.
"""

import subprocess
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

import astrowidget_fetch as fx


def test_invoke_missing_binary_notifies_and_exits_4(tmp_path, monkeypatch):
	"""No binary at SCORING_BINARY → exit 4 + critical notification."""
	monkeypatch.setattr(fx, "SCORING_BINARY", tmp_path / "absent")
	with patch.object(fx, "_notify") as nf:
		with pytest.raises(SystemExit) as ei:
			fx.invoke_scoring_binary({"sites": []})
	assert ei.value.code == 4
	nf.assert_called_once()
	assert nf.call_args.kwargs.get("urgency") == "critical"


def test_invoke_timeout_notifies_and_exits_4(tmp_path, monkeypatch):
	"""Subprocess TimeoutExpired → exit 4 + critical notification."""
	binary = tmp_path / "fake"
	binary.touch()
	monkeypatch.setattr(fx, "SCORING_BINARY", binary)
	with patch.object(fx.subprocess, "run",
		side_effect=subprocess.TimeoutExpired(cmd="fake", timeout=10)):
		with patch.object(fx, "_notify") as nf:
			with pytest.raises(SystemExit) as ei:
				fx.invoke_scoring_binary({"sites": []})
	assert ei.value.code == 4
	nf.assert_called_once()
	assert "timed out" in nf.call_args.args[0].lower()


def test_invoke_nonzero_exit_notifies_and_exits_4(tmp_path, monkeypatch):
	"""CalledProcessError → exit 4 + critical notification."""
	binary = tmp_path / "fake"
	binary.touch()
	monkeypatch.setattr(fx, "SCORING_BINARY", binary)
	with patch.object(fx.subprocess, "run", side_effect=subprocess.CalledProcessError(
			returncode=99, cmd="fake")):
		with patch.object(fx, "_notify") as nf:
			with pytest.raises(SystemExit) as ei:
				fx.invoke_scoring_binary({"sites": []})
	assert ei.value.code == 4
	nf.assert_called_once()


def test_invoke_malformed_json_output_notifies_and_exits_4(tmp_path, monkeypatch):
	"""
	Binary exits 0 but stdout is not valid JSON → exit 4 + notification.
	(This path was previously silent — caught by silent-failure-hunter.)
	"""
	binary = tmp_path / "fake"
	binary.touch()
	monkeypatch.setattr(fx, "SCORING_BINARY", binary)
	mock_proc = MagicMock()
	mock_proc.stdout = b"this is not json"
	with patch.object(fx.subprocess, "run", return_value=mock_proc):
		with patch.object(fx, "_notify") as nf:
			with pytest.raises(SystemExit) as ei:
				fx.invoke_scoring_binary({"sites": []})
	assert ei.value.code == 4
	nf.assert_called_once()
	assert "malformed" in nf.call_args.args[0].lower()


def test_invoke_happy_path_returns_parsed_json(tmp_path, monkeypatch):
	"""Binary exits 0 with valid JSON → returns parsed dict."""
	binary = tmp_path / "fake"
	binary.touch()
	monkeypatch.setattr(fx, "SCORING_BINARY", binary)
	mock_proc = MagicMock()
	mock_proc.stdout = b'{"schema_version":1,"sites":[]}'
	with patch.object(fx.subprocess, "run", return_value=mock_proc):
		result = fx.invoke_scoring_binary({"sites": []})
	assert result == {"schema_version": 1, "sites": []}


def test_invoke_stderr_routes_to_sys_stderr_on_windows(tmp_path, monkeypatch):
	"""On Windows the scoring child's stderr is routed to sys.stderr (the log
	file under pythonw) so the Dart binary's diagnostics are preserved; on Linux
	it inherits the parent's stderr (None) → the systemd journal."""
	binary = tmp_path / "fake"
	binary.touch()
	monkeypatch.setattr(fx, "SCORING_BINARY", binary)
	mock_proc = MagicMock()
	mock_proc.stdout = b"{}"

	monkeypatch.setattr(fx.sys, "platform", "win32")
	with patch.object(fx.subprocess, "run", return_value=mock_proc) as run:
		fx.invoke_scoring_binary({"sites": []})
	assert run.call_args.kwargs["stderr"] is fx.sys.stderr

	monkeypatch.setattr(fx.sys, "platform", "linux")
	with patch.object(fx.subprocess, "run", return_value=mock_proc) as run:
		fx.invoke_scoring_binary({"sites": []})
	assert run.call_args.kwargs["stderr"] is None


def test_invoke_missing_binary_message_is_os_aware(tmp_path, monkeypatch, capsys):
	"""The 'binary not found' stderr names the OS-appropriate installer, not a
	hardcoded Linux command (a Windows user can't run install.sh)."""
	monkeypatch.setattr(fx, "SCORING_BINARY", tmp_path / "absent")
	monkeypatch.setattr(fx.sys, "platform", "win32")
	with patch.object(fx, "_notify"):
		with pytest.raises(SystemExit):
			fx.invoke_scoring_binary({"sites": []})
	assert "install.ps1" in capsys.readouterr().err
