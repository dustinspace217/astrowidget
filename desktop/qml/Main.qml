// Main.qml — root window of the standalone cross-platform desktop app (Windows,
// Linux, macOS). Replaces the plasmoid's PlasmoidItem + compact/full
// representations with a single resizable ApplicationWindow that shows the
// per-site columns + expandable secondary chips. Reuses the ported SiteColumn /
// VerdictChip / AttributionFooter and the Theme singleton.

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtCore
import "."

ApplicationWindow {
	id: win
	visible: true
	width: 980
	height: 640
	minimumWidth: 420
	minimumHeight: 360
	title: qsTr("astrowidget")
	color: Theme.backgroundColor

	StateModel { id: stateModel }

	// ── Dismissed degradation warnings (persisted across restarts) ───────
	// QtCore.Settings is QML's QSettings wrapper: it reads at startup and
	// writes on change to a per-platform store (~/.config/astrowidget/
	// astrowidget.conf on Linux, the registry on Windows — see the org/app
	// name set in run.py). Stored as a JSON string because Settings has no
	// list type. Independent of the plasmoid's Plasmoid.configuration store
	// by design (a dismissal in one UI doesn't carry to the other).
	Settings {
		id: appSettings
		property string dismissedWarningsJson: "[]"
	}

	// Parsed dismissal keys ("<siteId>|<code>"); re-derived whenever the
	// stored JSON changes, so a write flows straight back into every
	// SiteColumn's dismissedKeys and hides the just-dismissed warning.
	readonly property var dismissedWarnings: {
		try {
			const v = JSON.parse(appSettings.dismissedWarningsJson || "[]");
			// Coerce a non-array (e.g. the literal "null" or "{}", which parse
			// without throwing) to []; otherwise it reaches dismissedKeys and
			// the .indexOf() in astroWarningVisible throws, silently hiding the
			// warning this feature exists to show.
			return Array.isArray(v) ? v : [];
		} catch (e) {
			// Malformed store → "nothing dismissed" rather than throwing. Logged
			// so a corrupted store is diagnosable instead of silently swallowed.
			console.warn("astrowidget: dismissedWarnings unreadable, treating as empty:", e);
			return [];
		}
	}

	// Append a dismissal key and persist it (idempotent). The write updates
	// appSettings.dismissedWarningsJson, re-firing the binding above.
	function dismissWarning(key) {
		const list = dismissedWarnings.slice();
		if (list.indexOf(key) < 0) {
			list.push(key);
			appSettings.dismissedWarningsJson = JSON.stringify(list);
		}
	}

	// 0 = Tonight, 1 = +1 night, 2 = +2 nights.
	property int selectedNight: 0

	// Expanded secondary-site ids. Reassigned (not mutated) on toggle so bindings
	// re-evaluate — same pattern as the plasmoid FullRepresentation.
	property var expandedSecondary: []
	function isSecondaryExpanded(id) { return expandedSecondary.indexOf(id) >= 0; }
	function toggleSecondary(id) {
		const next = expandedSecondary.slice();
		const i = next.indexOf(id);
		if (i >= 0) next.splice(i, 1); else next.push(id);
		expandedSecondary = next;
	}

	ColumnLayout {
		anchors.fill: parent
		anchors.margins: Theme.largeSpacing
		spacing: Theme.largeSpacing

		// ── Header: title + night tabs + freshness + night-vision toggle ──
		RowLayout {
			Layout.fillWidth: true
			spacing: Theme.largeSpacing

			Text {
				text: "astrowidget"
				color: Theme.textColor
				font.bold: true
				font.pixelSize: Theme.headingSize
			}

			TabBar {
				id: nightTabs
				Layout.fillWidth: true
				currentIndex: win.selectedNight
				onCurrentIndexChanged: win.selectedNight = currentIndex
				TabButton { text: qsTr("Tonight") }
				TabButton { text: qsTr("+1 night") }
				TabButton { text: qsTr("+2 nights") }
			}

			Text {
				text: stateModel.state.lastUpdated
					? qsTr("Updated %1").arg(
						Qt.formatDateTime(new Date(stateModel.state.lastUpdated), "HH:mm"))
					: qsTr("No data yet")
				color: stateModel.isStale ? Theme.neutralTextColor : Theme.textColor
				opacity: 0.7
				font.pixelSize: Theme.smallFontSize
			}

			Button {
				text: Theme.nightVision ? qsTr("Night vision ✓") : qsTr("Night vision")
				onClicked: Theme.nightVision = !Theme.nightVision
			}
		}

		// Error / load banner.
		Text {
			Layout.fillWidth: true
			visible: stateModel.loadError !== ""
			text: qsTr("⚠ %1").arg(stateModel.loadError)
			color: Theme.negativeTextColor
			wrapMode: Text.WordWrap
			font.pixelSize: Theme.smallFontSize
		}

		// ── Scrollable body: per-site columns + secondary chips ──────────
		// Vertical scroll only; columns share the width (shrink to fit) rather
		// than scrolling sideways.
		ScrollView {
			id: scroll
			Layout.fillWidth: true
			Layout.fillHeight: true
			clip: true
			ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

			ColumnLayout {
				width: scroll.availableWidth
				spacing: Theme.largeSpacing

				RowLayout {
					Layout.fillWidth: true
					spacing: Theme.largeSpacing

					// Primary sites — full columns, always shown.
					Repeater {
						model: stateModel.primarySites
						delegate: SiteColumn {
							required property var modelData
							Layout.fillWidth: true
							Layout.preferredWidth: Theme.gridUnit * 14
							Layout.alignment: Qt.AlignTop
							site: modelData
							nightIndex: win.selectedNight
							dismissedKeys: win.dismissedWarnings
							onRequestDismiss: (key) => win.dismissWarning(key)
						}
					}

					// Expanded secondary columns (visible when their chip is open).
					Repeater {
						model: stateModel.secondarySites
						delegate: SiteColumn {
							required property var modelData
							visible: win.isSecondaryExpanded(modelData.id)
							Layout.fillWidth: true
							Layout.preferredWidth: Theme.gridUnit * 14
							Layout.alignment: Qt.AlignTop
							site: modelData
							nightIndex: win.selectedNight
							dismissedKeys: win.dismissedWarnings
							onRequestDismiss: (key) => win.dismissWarning(key)
						}
					}

					// Empty state when no data has loaded yet.
					ColumnLayout {
						visible: stateModel.sites.length === 0
						Layout.fillWidth: true
						spacing: Theme.largeSpacing
						Text {
							Layout.alignment: Qt.AlignHCenter
							text: "🌙"
							font.pixelSize: Theme.iconHuge
						}
						Text {
							Layout.alignment: Qt.AlignHCenter
							horizontalAlignment: Text.AlignHCenter
							text: qsTr("No forecast data yet.\nRun the fetcher to populate.")
							color: Theme.textColor
						}
					}
				}

				// Secondary sites as collapsed chips (click to expand a column).
				Flow {
					Layout.fillWidth: true
					visible: stateModel.secondarySites.length > 0
					spacing: Theme.smallSpacing

					Text {
						text: qsTr("Other sites:")
						color: Theme.textColor
						font.bold: true
						opacity: 0.7
						font.pixelSize: Theme.smallFontSize
					}
					Repeater {
						model: stateModel.secondarySites
						delegate: VerdictChip {
							required property var modelData
							site: modelData
							nightIndex: win.selectedNight
							expanded: win.isSecondaryExpanded(modelData.id)
							onToggle: win.toggleSecondary(modelData.id)
						}
					}
				}
			}
		}

		// ── Attribution footer (CC-BY 4.0 for Open-Meteo) ────────────────
		AttributionFooter {
			Layout.fillWidth: true
		}
	}
}
