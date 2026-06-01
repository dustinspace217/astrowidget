#!/usr/bin/env bash
# astrowidget desktop — Linux launcher (uses the system Qt6 `qml` runtime).
# On Windows/macOS (or Linux without Qt6 dev tools), use run.py with PySide6.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The QML StateModel reads state.json via XMLHttpRequest on a file:// URL. Qt 6
# gates local-file XHR behind this env var (plasmashell never sets it — which is
# why the plasmoid uses a different mechanism — but a standalone app can set it).
export QML_XHR_ALLOW_FILE_READ=1

QML=""
for cand in qml-qt6 qml6 qml /usr/lib64/qt6/bin/qml; do
	if command -v "$cand" >/dev/null 2>&1; then QML="$cand"; break; fi
done
if [[ -z "$QML" ]]; then
	echo "astrowidget desktop: no Qt6 'qml' runtime found." >&2
	echo "  Fedora:  sudo dnf install qt6-qtdeclarative" >&2
	echo "  Or use:  pip install PySide6 && python3 run.py" >&2
	exit 1
fi
exec "$QML" "$DIR/qml/Main.qml"
