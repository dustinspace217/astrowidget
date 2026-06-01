"""
Tests for the per-OS notification delivery backends (the _notify dispatch).

The diff logic that DECIDES when to notify lives in test_notifications.py;
this file covers HOW a notification is delivered on each platform. The Windows
toast path can't actually run on the Linux dev/CI box, so its script-building
and base64 (-EncodedCommand) delivery are exercised as pure functions instead —
that testable seam is exactly why _windows_toast_script() is split out.
"""

import base64
from unittest.mock import patch

import astrowidget_fetch as fx


def test_dispatch_routes_per_platform():
	"""_notify sends to the right backend based on sys.platform."""
	with (
		patch.object(fx, "_notify_windows") as win,
		patch.object(fx, "_notify_macos") as mac,
		patch.object(fx, "_notify_linux") as lin,
	):
		with patch.object(fx.sys, "platform", "win32"):
			fx._notify("T", "B", "critical")
		with patch.object(fx.sys, "platform", "darwin"):
			fx._notify("T", "B")
		with patch.object(fx.sys, "platform", "linux"):
			fx._notify("T", "B", "normal")
	win.assert_called_once_with("T", "B")
	mac.assert_called_once_with("T", "B")
	# urgency is forwarded only to the Linux backend (the one with the concept).
	lin.assert_called_once_with("T", "B", "normal")


def test_missing_notifier_degrades_to_stderr(capsys):
	"""A backend raising FileNotFoundError must not crash the fetch — it logs."""
	with (
		patch.object(fx, "_notify_windows", side_effect=FileNotFoundError("powershell")),
		patch.object(fx.sys, "platform", "win32"),
	):
		fx._notify("Cfg error", "bad config")  # must return normally
	assert "notifier unavailable" in capsys.readouterr().err


def test_xml_escape_replaces_ampersand_first():
	"""& is escaped before < > so the ampersands it introduces aren't re-escaped."""
	assert fx._xml_escape("a & b < c > d") == "a &amp; b &lt; c &gt; d"
	assert fx._xml_escape("&<>") == "&amp;&lt;&gt;"


def test_windows_toast_script_escapes_content():
	"""User text is XML-escaped, and single quotes are doubled for the PS literal."""
	script = fx._windows_toast_script("Bainbridge & SRO", "It's <clear>")
	assert "ToastGeneric" in script
	assert "&amp;" in script                  # XML-escaped &
	assert "&lt;clear&gt;" in script          # XML-escaped <clear>
	assert "It''s" in script                  # PS single-quote doubled
	assert "ToastNotificationManager" in script


def test_windows_notify_uses_encodedcommand():
	"""_notify_windows ships the script via -EncodedCommand + -Sta, base64 UTF-16LE."""
	with patch.object(fx.subprocess, "run") as run:
		fx._notify_windows("Title", "Body")
	cmd = run.call_args.args[0]
	assert cmd[0] == "powershell"
	assert "-Sta" in cmd
	assert "-EncodedCommand" in cmd
	# The encoded payload decodes (UTF-16LE) back to the toast script.
	enc = cmd[cmd.index("-EncodedCommand") + 1]
	decoded = base64.b64decode(enc).decode("utf-16-le")
	assert "ToastNotificationManager" in decoded
	assert "Title" in decoded and "Body" in decoded


def test_macos_notify_escapes_double_quotes():
	"""_notify_macos passes an escaped 'display notification' command to osascript."""
	with patch.object(fx.subprocess, "run") as run:
		fx._notify_macos('he said "go"', "body")
	args = run.call_args.args[0]
	assert args[0] == "osascript"
	assert args[1] == "-e"
	assert args[2].startswith("display notification")
	assert r'\"go\"' in args[2]  # embedded double-quotes backslash-escaped


def test_sanitize_notify_text_strips_control_chars():
	"""Newlines collapse to spaces and other control chars (C0 + DEL) drop. This
	is what prevents a newline in a site label from injecting a second AppleScript
	statement on macOS, or breaking the toast XML on Windows."""
	assert fx._sanitize_notify_text("a\nb\r\nc") == "a b  c"
	assert fx._sanitize_notify_text("x\x00\x07\x1f\x7fy") == "xy"
	assert fx._sanitize_notify_text("clean & <ok>") == "clean & <ok>"


def test_notify_sanitizes_before_dispatch():
	"""_notify strips control characters before any backend sees the text."""
	with patch.object(fx, "_notify_linux") as lin:
		with patch.object(fx.sys, "platform", "linux"):
			fx._notify("Title\nwith newline", "body\x07bell", "normal")
	title, body, urgency = lin.call_args.args
	assert title == "Title with newline"
	assert "\x07" not in body and body == "bodybell"
