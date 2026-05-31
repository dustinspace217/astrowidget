// FullRepresentation.qml — popup view: per-site columns + meteogram.
//
// Shown when the user clicks the panel icon. Lays out:
//   - Top bar: title + tabs (Tonight / +1 / +2 night) + last-updated text.
//   - Per-site columns: verdict pill, astro dark window, factors.
//   - Per-site hourly cloud meteogram strip across the bottom.
//   - Attribution footer (CC-BY 4.0 requirement for Open-Meteo).
//
// Width and height are tuned to fit the spec's 3-column layout for 1–3
// sites without horizontal scrolling. For 1 site the popup is narrower.

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasmoid

Item {
	id: full

	// Passed in from main.qml.
	required property var stateModel

	// 0 = Tonight, 1 = +1 night, 2 = +2 nights. Initialized from the
	// user's configured default tab and editable via the TabBar.
	property int selectedNight: Plasmoid.configuration.defaultNightTab

	// Which secondary-site ids are expanded into a full column (beside the
	// primaries). A plain array, REASSIGNED on every toggle — QML re-evaluates
	// dependent bindings on identity change, so we never mutate it in place.
	property var expandedSecondary: []

	// True when the given secondary site id is currently expanded.
	function isSecondaryExpanded(id) {
		return expandedSecondary.indexOf(id) >= 0;
	}

	// Flip a secondary site between chip-only and expanded-column. Assigns a NEW
	// array so the column-visibility and width bindings re-evaluate.
	function toggleSecondary(id) {
		const next = expandedSecondary.slice();
		const i = next.indexOf(id);
		if (i >= 0) {
			next.splice(i, 1);
		} else {
			next.push(id);
		}
		expandedSecondary = next;
	}

	// How many secondary columns are currently expanded (drives popup width).
	// Counts only ids that still correspond to a real secondary site.
	readonly property int expandedSecondaryCount: {
		let c = 0;
		const sec = stateModel.secondarySites;
		for (let i = 0; i < sec.length; i++) {
			if (isSecondaryExpanded(sec[i].id)) {
				c++;
			}
		}
		return c;
	}

	// Night-vision: when enabled in config, override the Kirigami theme to a
	// red-on-near-black palette so the popup doesn't wreck dark adaptation if
	// it's open near a scope. Setting Kirigami.Theme on this root propagates
	// to all child items (SiteColumn, labels, pills).
	//
	// CRITICAL: the OFF branch MUST assign `undefined`, NOT a color literal.
	// Kirigami.Theme color properties use setCustom*/RESET semantics — ANY
	// valid QColor (including "transparent" = QColor(0,0,0,0)) sets a real
	// custom override; only `undefined` fires the RESET that restores the
	// normal theme. An earlier "transparent" fallback here blanked the whole
	// popup in the default (NV-off) mode. (Verified against Kirigami
	// platformtheme RESET semantics, 2026-05-28.)
	readonly property bool nightVision: Plasmoid.configuration.nightVisionMode
	Kirigami.Theme.inherit: !nightVision
	Kirigami.Theme.textColor: nightVision ? "#ff5b5b" : undefined
	Kirigami.Theme.backgroundColor: nightVision ? "#0a0000" : undefined
	Kirigami.Theme.highlightColor: nightVision ? "#cc2222" : undefined
	Kirigami.Theme.positiveTextColor: nightVision ? "#ff7b7b" : undefined
	Kirigami.Theme.neutralTextColor: nightVision ? "#cc4444" : undefined
	Kirigami.Theme.negativeTextColor: nightVision ? "#7a1010" : undefined
	Kirigami.Theme.disabledTextColor: nightVision ? "#803030" : undefined

	// Solid backdrop so the night-vision near-black fills the popup (the
	// popup's own background is themed but a dedicated rect guarantees the
	// dark field behind transparent labels). Only painted in NV mode.
	Rectangle {
		anchors.fill: parent
		visible: full.nightVision
		color: "#0a0000"
		z: -1
	}

	// Sizing — width scales with the number of VISIBLE columns (primary sites
	// plus any expanded secondary columns); height stays fixed so the popup never
	// overflows vertically (expanding a secondary widens it, never lengthens it).
	readonly property int columnWidth: Kirigami.Units.gridUnit * 14
	readonly property int shownColumns: Math.max(
		stateModel.primarySites.length + expandedSecondaryCount, 1)
	implicitWidth: Math.max(
		columnWidth * shownColumns + Kirigami.Units.largeSpacing * 4,
		Kirigami.Units.gridUnit * 24
	)
	implicitHeight: Kirigami.Units.gridUnit * 26
	Layout.preferredWidth: implicitWidth
	Layout.preferredHeight: implicitHeight

	ColumnLayout {
		anchors.fill: parent
		anchors.margins: Kirigami.Units.largeSpacing
		spacing: Kirigami.Units.largeSpacing

		// ── Header row: title + tabs + freshness indicator ───────────────
		RowLayout {
			Layout.fillWidth: true
			spacing: Kirigami.Units.largeSpacing

			PlasmaExtras.Heading {
				level: 2
				text: "astrowidget"
				Layout.fillWidth: false
			}

			// Tab strip: Tonight / +1 / +2.
			QQC2.TabBar {
				id: nightTabs
				Layout.fillWidth: true
				currentIndex: full.selectedNight
				onCurrentIndexChanged: full.selectedNight = currentIndex

				QQC2.TabButton { text: qsTr("Tonight") }
				QQC2.TabButton { text: qsTr("+1 night") }
				QQC2.TabButton { text: qsTr("+2 nights") }
			}

			PlasmaComponents.Label {
				text: full.stateModel.state.lastUpdated
					? qsTr("Updated %1").arg(
						Qt.formatDateTime(
							new Date(full.stateModel.state.lastUpdated),
							"HH:mm"
						))
					: qsTr("No data yet")
				opacity: 0.7
				color: full.stateModel.isStale
					? Kirigami.Theme.neutralTextColor
					: Kirigami.Theme.textColor
			}
		}

		// ── Per-site columns ─────────────────────────────────────────────
		RowLayout {
			Layout.fillWidth: true
			Layout.fillHeight: true
			spacing: Kirigami.Units.largeSpacing

			// Primary sites — full columns, always shown.
			Repeater {
				model: full.stateModel.primarySites
				delegate: SiteColumn {
					// Under `pragma ComponentBehavior: Bound`, the Repeater
					// delegate must DECLARE modelData as required — bound
					// behavior no longer injects a bare `modelData`. Without
					// this, `site: modelData` was undefined and every column
					// rendered "Site error" on perfectly valid data.
					// (Root cause of the 2026-05-29 "Site error" bug.)
					required property var modelData
					Layout.fillWidth: true
					Layout.fillHeight: true
					Layout.preferredWidth: full.columnWidth
					site: modelData
					nightIndex: full.selectedNight
				}
			}

			// Expanded secondary columns — a secondary site the user clicked
			// open appears here, beside the primaries. Collapsed ones are
			// `visible: false`, which QtQuick.Layouts excludes from the row, so
			// they take no space until expanded.
			Repeater {
				model: full.stateModel.secondarySites
				delegate: SiteColumn {
					// Required under `pragma ComponentBehavior: Bound`.
					required property var modelData
					visible: full.isSecondaryExpanded(modelData.id)
					Layout.fillWidth: true
					Layout.fillHeight: true
					Layout.preferredWidth: full.columnWidth
					site: modelData
					nightIndex: full.selectedNight
				}
			}

			// Fallback when no data has loaded yet (first run before
			// fetcher completes). Centers a helpful message.
			Item {
				visible: full.stateModel.sites.length === 0
				Layout.fillWidth: true
				Layout.fillHeight: true

				ColumnLayout {
					anchors.centerIn: parent
					spacing: Kirigami.Units.largeSpacing

					Kirigami.Icon {
						Layout.alignment: Qt.AlignHCenter
						source: "weather-clear-night"
						Layout.preferredWidth: Kirigami.Units.iconSizes.huge
						Layout.preferredHeight: Kirigami.Units.iconSizes.huge
					}
					PlasmaComponents.Label {
						Layout.alignment: Qt.AlignHCenter
						text: qsTr("No forecast data yet.\nRun the fetcher to populate.")
						horizontalAlignment: Text.AlignHCenter
					}
					PlasmaComponents.Label {
						Layout.alignment: Qt.AlignHCenter
						text: qsTr("systemctl --user start astrowidget-fetch.service")
						font.family: "monospace"
						opacity: 0.7
					}
				}
			}
		}

		// ── Secondary sites: collapsed verdict chips ────────────────────
		// Sites the user marked non-primary (the rarely-checked Australia /
		// Spain iTelescope domes) live here as compact chips instead of full
		// columns. Clicking a chip expands that site's column above, beside the
		// primaries (the secondary Repeater in the columns row). The Flow wraps
		// the chips to the popup width.
		Flow {
			Layout.fillWidth: true
			visible: full.stateModel.secondarySites.length > 0
			spacing: Kirigami.Units.smallSpacing

			PlasmaComponents.Label {
				text: qsTr("Other sites:")
				font.bold: true
				opacity: 0.7
				font.pixelSize: Kirigami.Theme.smallFont.pixelSize
			}

			Repeater {
				model: full.stateModel.secondarySites
				delegate: VerdictChip {
					// Required under `pragma ComponentBehavior: Bound`.
					required property var modelData
					site: modelData
					nightIndex: full.selectedNight
					expanded: full.isSecondaryExpanded(modelData.id)
					onToggle: full.toggleSecondary(modelData.id)
				}
			}
		}

		// ── Attribution footer (CC-BY 4.0 required for Open-Meteo) ───────
		AttributionFooter {
			Layout.fillWidth: true
		}
	}
}
