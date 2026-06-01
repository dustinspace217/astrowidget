import QtQuick
import QtCore

// StateModel.qml — single source of truth for forecast state in the standalone
// desktop app. Reads <cache>/astrowidget/state.json (written by the Python
// fetcher) and exposes it as bindable properties, polling every 30 s.
//
// FILE-READ MECHANISM: XMLHttpRequest on a file:// URL. The plasmoid version
// uses a Plasma5Support `cat` DataSource because plasmashell does NOT set
// QML_XHR_ALLOW_FILE_READ=1 (so QML XHR can't read local files there). This
// standalone app's launcher DOES set that env var, so XHR file reads work — and
// XHR is plain Qt, needing no Plasma dependency, so it's cross-platform.
//
// Mirrors the plasmoid StateModel's public surface (sites / primarySites /
// secondarySites / isStale / loadError / isFutureSchema) so the ported UI
// components bind to it unchanged.
QtObject {
	id: model

	// Cross-platform path to state.json. GenericCacheLocation is ~/.cache on
	// Linux and %LOCALAPPDATA% on Windows — the SAME place the fetcher must
	// write to. StandardPaths returns a file:// URL; strip the scheme for the
	// plain path, then we re-add file:// for the XHR call.
	readonly property string statePath: {
		const u = StandardPaths.writableLocation(
			StandardPaths.GenericCacheLocation).toString();
		return u.replace(/^file:\/\//, "") + "/astrowidget/state.json";
	}

	// Highest state.json schemaVersion this build understands.
	readonly property int knownSchemaVersion: 2

	// Whole parsed JSON. Empty default keeps bindings safe before the first read.
	property var state: ({ "schemaVersion": 2, "lastUpdated": null, "sites": [] })

	// Non-empty when the last read failed; surfaced in the window so failures
	// are never silent.
	property string loadError: ""

	readonly property var sites: state && state.sites ? state.sites : []
	// Split by the per-site `primary` flag (set by the fetcher). primary !== false
	// defaults missing/older state to PRIMARY (full column), matching the plasmoid.
	readonly property var primarySites: sites.filter(s => s.primary !== false)
	readonly property var secondarySites: sites.filter(s => s.primary === false)

	readonly property bool isFutureSchema:
		state && state.schemaVersion && state.schemaVersion > knownSchemaVersion

	// True when state.json is older than 8 hours (matches the fetcher's stale rule).
	readonly property bool isStale: {
		if (!state.lastUpdated) return true;
		const lastMs = Date.parse(state.lastUpdated);
		if (isNaN(lastMs)) return true;
		return (Date.now() - lastMs) > (8 * 60 * 60 * 1000);
	}

	// Re-read state.json via XHR. Called at startup and on the 30 s timer.
	function reload() {
		const xhr = new XMLHttpRequest();
		const url = "file://" + statePath;
		xhr.onreadystatechange = function() {
			if (xhr.readyState !== XMLHttpRequest.DONE)
				return;
			// Qt reports status 0 for a successful file:// read; treat empty
			// body as missing/unreadable rather than silently keeping stale state.
			if (!xhr.responseText || xhr.responseText.length === 0) {
				model.loadError = qsTr("Could not read state.json (empty / missing) at %1")
					.arg(model.statePath);
				return;
			}
			try {
				const parsed = JSON.parse(xhr.responseText);
				if (!parsed || typeof parsed !== "object") {
					model.loadError = qsTr("state.json is not a JSON object");
					return;
				}
				model.state = parsed;
				model.loadError = "";
			} catch (e) {
				model.loadError = qsTr("state.json parse error: %1").arg(e);
			}
		};
		try {
			xhr.open("GET", url);
			xhr.send();
		} catch (e) {
			model.loadError = qsTr("read failed: %1").arg(e);
		}
	}

	property Timer _pollTimer: Timer {
		interval: 30 * 1000
		running: true
		repeat: true
		onTriggered: model.reload()
	}

	Component.onCompleted: model.reload()
}
