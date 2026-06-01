pragma Singleton
import QtQuick

// Theme.qml — the standalone desktop app's replacement for KDE's Kirigami.Theme
// and Kirigami.Units. The plasmoid inherited colours + metrics from the running
// Plasma theme; a cross-platform Qt6 app has no Plasma, so we define a
// self-contained dark palette here (Breeze-Dark-ish) plus the night-vision red
// palette, and the handful of spacing/font metrics the UI uses.
//
// `nightVision` flips the whole palette to red-on-near-black to preserve dark
// adaptation near a telescope — same intent (and same colour values) as the
// plasmoid's FullRepresentation night-vision overrides.
//
// Registered as a singleton via qmldir so every component can reference
// `Theme.textColor` etc. after `import "."`.
QtObject {
	id: theme

	// Driven by a toggle in Main.qml.
	property bool nightVision: false

	// ── Metrics (replacing Kirigami.Units) ───────────────────────────────
	readonly property int gridUnit: 18
	readonly property int smallSpacing: 4
	readonly property int largeSpacing: 8
	readonly property int iconSmall: 16
	readonly property int iconSmallMedium: 22
	readonly property int iconHuge: 64

	// ── Fonts (replacing Kirigami.Theme.*Font.pixelSize) ─────────────────
	readonly property int fontSize: 14
	readonly property int smallFontSize: 11
	readonly property int headingSize: 20

	// ── Colours (replacing Kirigami.Theme.*Color) ────────────────────────
	// Two palettes; nightVision selects the red one (same hex values the
	// plasmoid used for its night-vision override).
	readonly property color textColor:         nightVision ? "#ff5b5b" : "#fcfcfc"
	readonly property color backgroundColor:   nightVision ? "#0a0000" : "#2a2e34"
	readonly property color highlightColor:    nightVision ? "#cc2222" : "#3daee9"
	readonly property color positiveTextColor: nightVision ? "#ff7b7b" : "#27ae60"
	readonly property color neutralTextColor:  nightVision ? "#cc4444" : "#f67400"
	readonly property color negativeTextColor: nightVision ? "#7a1010" : "#da4453"
	readonly property color disabledTextColor: nightVision ? "#803030" : "#7f8c8d"
}
