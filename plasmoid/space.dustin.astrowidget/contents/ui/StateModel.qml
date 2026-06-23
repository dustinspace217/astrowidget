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

	// Second executable DataSource, dedicated to the manual-refresh trigger.
	// Runs `systemctl --user start astrowidget-fetch.service` — the SAME unit
	// the timer activates (timer → service → astrowidget_fetch.py). systemctl
	// start on a Type=oneshot unit BLOCKS until the fetch finishes and returns
	// its exit code, so onNewData fires once on completion. Kept separate from
	// _reader so its stdout/exit-code payload never reaches the JSON parser.
	// Verified exit-code key against plasma5support executable.cpp:
	// setData(QStringLiteral("exit code"), exitCode) — note the space.
	property P5Support.DataSource _refresher: P5Support.DataSource {
		engine: "executable"
		connectedSources: []
		onNewData: (sourceName, data) => {
			// Clear UI state FIRST: the spinner/disabled-button is the highest
			// blast-radius thing to leave wedged, so it must not depend on any
			// line below succeeding.
			model.refreshing = false;
			model._refreshWatchdog.stop();
			disconnectSource(sourceName); // run-once per refresh
			// Exit-code key + int type verified against plasma5support
			// executable.cpp (setData(QStringLiteral("exit code"), exitCode)),
			// so `=== 0` is correct for the happy path. We still handle a
			// MISSING code explicitly rather than mislabel a possibly-successful
			// fetch as "exit undefined".
			const code = data["exit code"];
			if (code === 0) {
				// Success → clear any stale error (e.g. a "timed out" banner a
				// watchdog set on a late completion) and re-read state.json. The
				// fetcher writes atomically (.tmp + os.replace), so this cat
				// can't see a torn file; a genuine read failure surfaces via
				// loadError (→ toolTipSummary), not silently.
				model.refreshError = "";
				model.reload();
			} else if (code === undefined || code === null) {
				// Completion signalled with no exit code — we cannot tell
				// success from failure. Re-read anyway (the fetch may have
				// written) and tell the user how to check.
				model.refreshError = qsTr(
					"Refresh finished without an exit status — verify: systemctl --user status astrowidget-fetch.service");
				model.reload();
				console.warn("astrowidget: manual refresh completed with no exit code; data keys:",
					Object.keys(data));
			} else {
				// Non-zero exit → show stderr if present, else the exit code plus
				// the same diagnostic command the watchdog suggests, so "exit 5"
				// alone is never the whole story.
				const err = (data["stderr"] || "").trim();
				model.refreshError = err.length > 0
					? err
					: qsTr("Refresh failed (systemctl exit %1) — check: systemctl --user status astrowidget-fetch.service").arg(code);
				console.warn("astrowidget: manual refresh failed:", code, err);
			}
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

	// ── Manual refresh state ─────────────────────────────────────────────
	// True while a manual fetch is running (systemctl start blocking on the
	// oneshot unit). Drives the header button's disabled/busy state and guards
	// refresh() against double-launch.
	property bool refreshing: false

	// Last manual-refresh trigger error ("" when clear). Distinct from
	// loadError (which is about READING state.json) — this is about TRIGGERING
	// the fetch. Surfaced inline in the popup header AND in toolTipSummary (so a
	// failure from the right-click action, with the popup closed, is still
	// visible) per the project "every error tells the user what went wrong"
	// standard. Cleared at the start of the next refresh() and on success.
	property string refreshError: ""

	// The manual-refresh command. Single source of truth so refresh() (which
	// connects it) and the watchdog (which must disconnect this EXACT source
	// string on timeout, so a later refresh re-running the same command isn't
	// coalesced into the stale connection) always agree on the string.
	readonly property string _refreshCommand:
		"systemctl --user start astrowidget-fetch.service"

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
		// A failed manual refresh (especially from the right-click action, with
		// the popup closed) surfaces here too — otherwise it'd be visible only
		// in the open popup. The messages are self-describing, so no prefix.
		if (refreshError) {
			return refreshError;
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

	// Trigger a manual fetch via the systemd user service. Guards on refreshing
	// (a second click while one is in flight is a no-op), clears any prior
	// error, arms the watchdog, then connects the systemctl source. The command
	// is static (no user input) so it needs no quoting. Result handled in
	// _refresher.onNewData.
	function refresh() {
		// Guard: a second trigger while one is in flight is a no-op. Safe
		// without a lock because this check-and-set is atomic in QML's single-
		// threaded event loop — do NOT insert an await / Qt.callLater between
		// the check and the set, which would open a TOCTOU window.
		if (model.refreshing) {
			return;
		}
		model.refreshError = "";
		model.refreshing = true;
		model._refreshWatchdog.restart();
		model._refresher.connectSource(model._refreshCommand);
	}

	// Background poll. 30 s cadence is plenty given the fetcher's 4×/day write.
	property Timer _pollTimer: Timer {
		interval: 30 * 1000
		running: true
		repeat: true
		onTriggered: model.reload()
	}

	// Watchdog bounding the external wait. Fires ONLY if no completion signal
	// arrives from _refresher (e.g. the executable engine drops the job). The
	// fetch itself is already bounded by the service's TimeoutStartSec=120, so
	// 130 s leaves headroom for systemd's own SIGKILL + teardown to report back.
	// On fire: clear the stuck spinner and tell the user how to investigate.
	property Timer _refreshWatchdog: Timer {
		interval: 130 * 1000
		repeat: false
		onTriggered: {
			// The completion never arrived. Release the still-connected source
			// so a later refresh() re-running the SAME command string isn't
			// coalesced into / blocked by this stale connection, then clear the
			// spinner and tell the user how to investigate.
			model._refresher.disconnectSource(model._refreshCommand);
			model.refreshing = false;
			model.refreshError = qsTr(
				"Refresh timed out — check: systemctl --user status astrowidget-fetch.service");
			console.warn("astrowidget: manual refresh watchdog fired");
		}
	}

	Component.onCompleted: model.reload()
}
