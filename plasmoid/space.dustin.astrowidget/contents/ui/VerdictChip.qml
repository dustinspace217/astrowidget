// VerdictChip.qml — compact, clickable verdict indicator for a secondary site.
//
// Secondary sites (config `primary = false`) are ones the user checks rarely
// (e.g. the Australia / Spain iTelescope domes), so they collapse to a small
// chip instead of a full column. The chip shows the site label + tonight's
// recommendation, tinted by verdict color. Clicking it emits toggle() so the
// parent (FullRepresentation) can expand/collapse the full SiteColumn.
//
// Color is never the SOLE signal — the verdict text ("BB+NB" / "NB only" /
// "Neither" / "Error") rides alongside the colored dot, for accessibility and
// for night-vision mode where the palette desaturates to reds.

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents

MouseArea {
	id: chip

	// The site object (one entry of stateModel.secondarySites), passed in from
	// the Repeater delegate in FullRepresentation.
	required property var site
	// Which night column the popup is showing (0 = Tonight). The chip reflects
	// that night's verdict so it tracks the Tonight/+1/+2 tab.
	required property int nightIndex
	// Whether the parent currently shows this site's expanded column. Drives the
	// border highlight and the ▸/▾ affordance.
	property bool expanded: false
	// Emitted on click so the parent can flip `expanded` for this site's id.
	signal toggle()

	// Tonight's (or the selected night's) recommendation, mirroring the same
	// status/length guards SiteColumn and CompactRepresentation use.
	readonly property string recommendation: {
		if (!site || site.status !== "ok" || !site.nights
		    || site.nights.length <= nightIndex) {
			return "Error";
		}
		const n = site.nights[nightIndex];
		return n ? (n.recommendation || "Neither") : "Error";
	}

	implicitWidth: row.implicitWidth + Kirigami.Units.largeSpacing
	implicitHeight: row.implicitHeight + Kirigami.Units.smallSpacing
	hoverEnabled: true
	cursorShape: Qt.PointingHandCursor
	onClicked: chip.toggle()

	// Chip background — subtle fill, brighter on hover, accent border when open.
	Rectangle {
		anchors.fill: parent
		radius: Kirigami.Units.smallSpacing
		color: chip.containsMouse
			? Qt.alpha(Kirigami.Theme.highlightColor, 0.15)
			: Qt.alpha(Kirigami.Theme.textColor, 0.06)
		border.width: chip.expanded ? 2 : 1
		border.color: chip.expanded
			? Kirigami.Theme.highlightColor
			: Qt.alpha(Kirigami.Theme.textColor, 0.2)
	}

	RowLayout {
		id: row
		anchors.centerIn: parent
		spacing: Kirigami.Units.smallSpacing

		// Verdict-colored dot (same mapping as the compact panel + verdict pill).
		Rectangle {
			Layout.preferredWidth: Kirigami.Units.iconSizes.small * 0.7
			Layout.preferredHeight: Kirigami.Units.iconSizes.small * 0.7
			radius: width / 2
			antialiasing: true
			color: {
				switch (chip.recommendation) {
				case "BB+NB":   return Kirigami.Theme.positiveTextColor;
				case "NB only": return Kirigami.Theme.neutralTextColor;
				case "Neither": return Kirigami.Theme.negativeTextColor;
				default:        return Kirigami.Theme.disabledTextColor;
				}
			}
		}

		// 7Timer-down indicator. Secondary sites are the 7Timer-sourced ones, so
		// a small ⚠ signals the degradation on the collapsed chip without making
		// the user expand it. (Matches the badge in the expanded column.)
		PlasmaComponents.Label {
			visible: {
				// meta.degraded is a list of {source, ...} objects (was a bare
				// string list). Fire the ⚠ when a 7Timer entry is present. The
				// `d &&` guard skips a null/garbled element so a malformed
				// state.json can't throw and silently drop the indicator. The
				// Astrospheric-failure warning lives in the expanded column.
				const m = chip.site.meta;
				if (!m || !m.degraded) return false;
				for (let i = 0; i < m.degraded.length; i++) {
					const d = m.degraded[i];
					if (d && d.source === "7timer") return true;
				}
				return false;
			}
			text: "⚠"
			color: Kirigami.Theme.neutralTextColor
			font.pixelSize: Kirigami.Theme.smallFont.pixelSize
		}

		// Label + verdict text — the text carries the meaning, the dot reinforces.
		PlasmaComponents.Label {
			text: (chip.site.label || chip.site.id) + " · " + chip.recommendation
			font.pixelSize: Kirigami.Theme.smallFont.pixelSize
		}

		// Expand/collapse affordance.
		PlasmaComponents.Label {
			text: chip.expanded ? "▾" : "▸"
			opacity: 0.6
			font.pixelSize: Kirigami.Theme.smallFont.pixelSize
		}
	}
}
