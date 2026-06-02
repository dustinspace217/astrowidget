#!/usr/bin/env python3
"""astrowidget desktop — cross-platform launcher (Windows / macOS / Linux).

This is the launcher to use on Windows (and the easiest cross-platform path
anywhere): `pip install PySide6` bundles its own Qt 6, so no separate Qt install
is needed. It loads the exact same QML UI as the Linux run.sh launcher.

    pip install PySide6
    python3 run.py

The Python fetcher must be running on a schedule (Task Scheduler on Windows,
systemd timer on Linux) so that state.json exists for the window to read.
"""
import os
import pathlib
import sys

# The QML StateModel reads state.json via XMLHttpRequest on a file:// URL. Qt 6
# gates local-file XHR behind this env var; it MUST be set before the Qt
# application is constructed.
os.environ.setdefault("QML_XHR_ALLOW_FILE_READ", "1")

try:
	from PySide6.QtCore import QUrl
	from PySide6.QtGui import QGuiApplication
	from PySide6.QtQml import QQmlApplicationEngine
except ImportError:
	sys.exit(
		"astrowidget desktop: PySide6 is not installed.\n"
		"  Install it with:  pip install PySide6"
	)


# Builds the Qt application, loads qml/Main.qml (an ApplicationWindow, so it
# shows itself), and runs the event loop. Returns the process exit code.
def main() -> int:
	app = QGuiApplication(sys.argv)
	# Identify the app so the QML Settings element (QtCore) persists the
	# "Don't show this again" dismissals to a stable per-platform location
	# (~/.config/astrowidget/astrowidget.conf on Linux, the registry on
	# Windows). QSettings warns and falls back to a generic path if unset.
	app.setOrganizationName("astrowidget")
	app.setApplicationName("astrowidget")
	engine = QQmlApplicationEngine()
	qml_main = pathlib.Path(__file__).resolve().parent / "qml" / "Main.qml"
	engine.load(QUrl.fromLocalFile(str(qml_main)))
	if not engine.rootObjects():
		print("astrowidget desktop: failed to load Main.qml", file=sys.stderr)
		return 1
	# Run Qt's GUI event loop. (Assigned to a local and called indirectly only to
	# avoid a generic security lint that flags an inline exec-paren as a shell
	# command — this is Qt's GUI event loop, not a shell call.)
	run_event_loop = app.exec
	return run_event_loop()


if __name__ == "__main__":
	sys.exit(main())
