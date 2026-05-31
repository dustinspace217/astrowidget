// StateModel.qml — single source of truth for forecast state.
//
// Reads ~/.cache/astrowidget/state.json (written by the Python fetcher) and
// exposes its contents as bindable QML properties, polling every 30 s.
//
// FILE-READ MECHANISM (changed 2026-05-29): reads via the Plasma5Support
// "executable" DataSource running `cat`, NOT via XMLHttpRequest.
// Qt 6 firewalls QML XMLHttpRequest from reading local file:// URLs unless
// the session sets QML_XHR_ALLOW_FILE_READ=1 (which plasmashell does not),
// so the original XHR approach silently never completed inside the panel —
// the widget showed "No forecast data yet" even with a valid state.json.
// Verified empirically with qml-qt6: XHR file read times out without the
// env gate; the executable DataSource returns the file contents in
// data["stdout"]. This is the idiomatic Plasma mechanism (the same engine
// command-output widgets use) and needs no session/env changes.
//
// Why not QFileSystemWatcher? Plasma 6 QML doesn't expose it without a C++
// plugin. The fetcher writes 4×/day so a 30 s `cat` poll is plenty.

import QtQuick
import QtCore
import org.kde.plasma.plasma5support as P5Support

QtObject {
	id: model

	// Absolute filesystem path to state.json. StandardPaths returns a url
	// ("file:///home/.../.cache"); we strip the scheme to get a plain path
	// suitable for the `cat` command. GenericCacheLocation maps to
	// $XDG_CACHE_HOME or ~/.cache — the directory the fetcher writes to.
	readonly property string statePath: {
		const u = StandardPaths.writableLocation(
			StandardPaths.GenericCacheLocation).toString();
		const base = u.replace(/^file:\/\//, "");
		return base + "/astrowidget/state.json";
	}

	// Executable DataSource used to `cat` state.json. connectSource() runs the
	// command; the result arrives in onNewData as data["stdout"]; we
	// disconnect immediately so each reload() re-runs cleanly (run-once).
	property P5Support.DataSource _reader: P5Support.DataSource {
		engine: "executable"
		connectedSources: []
		onNewData: (sourceName, data) => {
			disconnectSource(sourceName); // run-once per reload
			model._consumeCat(data["stdout"]);
		}
	}

	// Parses cat's stdout into the state object. Empty stdout => the file is
	// missing or unreadable (cat printed nothing) => surface a loadError
	// rather than silently keeping stale state.
	function _consumeCat(stdout) {
		if (!stdout || stdout.length === 0) {
			model.loadError = qsTr("Could not read state.json (empty / missing)");
			return;
		}
		try {
			const parsed = JSON.parse(stdout);
			if (!parsed || typeof parsed !== "object") {
				model.loadError = qsTr("state.json is not a JSON object");
				return;
			}
			model.state = parsed;
			model.loadError = "";
		} catch (e) {
			model.loadError = qsTr("state.json parse error: %1").arg(e);
		}
	}

	// Highest state.json schemaVersion this widget build understands. The
	// fetcher bumped 1 -> 2 when nights gained displayFactors. If a newer
	// fetcher writes a higher version, isFutureSchema surfaces a warning
	// rather than silently rendering a shape we don't grok.
	readonly property int knownSchemaVersion: 2

	// The whole parsed JSON object. Empty default keeps bindings from
	// throwing during the initial pre-reload moment.
	property var state: ({
		"schemaVersion": 2,
		"lastUpdated": null,
		"sites": []
	})

	// Convenience accessor: array of site objects.
	readonly property var sites: state && state.sites ? state.sites : []

	// Split sites by the per-site `primary` flag (set by the fetcher from the
	// config). Primary sites render as full columns; secondary sites render as
	// collapsed, click-to-expand verdict chips. We test `primary !== false` so a
	// missing flag (older state.json, or a config that never set one) defaults to
	// PRIMARY — a pre-7-site state still shows every site as a full column.
	readonly property var primarySites: sites.filter(s => s.primary !== false)
	readonly property var secondarySites: sites.filter(s => s.primary === false)

	// User-visible error state. Non-empty when the last read of state.json
	// failed (file missing, malformed JSON, version mismatch). The plasmoid
	// surfaces this via tooltip / popup so failures aren't silent.
	property string loadError: ""

	// Set true when state.json schemaVersion is newer than this widget knows
	// how to render. Lets the QML show a "widget out of date" warning rather
	// than silently rendering broken / blank UI.
	readonly property bool isFutureSchema:
		state && state.schemaVersion && state.schemaVersion > knownSchemaVersion

	// True when state.json is older than 8 hours (spec §6.3 stale rule).
	readonly property bool isStale: {
		if (!state.lastUpdated) {
			return true;
		}
		const lastMs = Date.parse(state.lastUpdated);
		if (isNaN(lastMs)) {
			return true;
		}
		return (Date.now() - lastMs) > (8 * 60 * 60 * 1000);
	}

	// One-liner summary for the panel tooltip. Includes the loadError if set
	// so failures show up in the panel without having to open the popup.
	readonly property string toolTipSummary: {
		if (loadError) {
			return qsTr("Error: %1").arg(loadError);
		}
		if (isFutureSchema) {
			return qsTr("state.json schema is newer than this widget — please upgrade.");
		}
		if (sites.length === 0) {
			return qsTr("No data yet — fetcher hasn't run.");
		}
		const parts = [];
		for (let i = 0; i < sites.length; i++) {
			const s = sites[i];
			if (s.status !== "ok" || !s.nights || s.nights.length === 0) {
				const detail = s.error ? (": " + s.error) : "";
				parts.push(s.label + qsTr(": Error") + detail);
				continue;
			}
			const tonight = s.nights[0];
			parts.push(s.label + ": " + (tonight.recommendation || "?"));
		}
		return parts.join(" · ");
	}

	// Force a re-read of state.json via `cat` through the executable engine.
	// Called on a 30 s timer and at startup. The result is handled in the
	// DataSource's onNewData → _consumeCat, which sets loadError on failure.
	// The path is double-quoted to tolerate spaces in an unusual XDG cache dir.
	function reload() {
		_reader.connectSource("cat \"" + statePath + "\"");
	}

	// Background poll. 30 s cadence is plenty given the fetcher's 4×/day write.
	property Timer _pollTimer: Timer {
		interval: 30 * 1000
		running: true
		repeat: true
		onTriggered: model.reload()
	}

	Component.onCompleted: model.reload()
}
