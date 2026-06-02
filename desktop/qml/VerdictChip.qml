// VerdictChip.qml — compact, clickable verdict indicator for a secondary site.
// Desktop port of the plasmoid VerdictChip (Kirigami/PlasmaComponents → Theme +
// Text). Behaviour identical: a colored dot + label + verdict text + ▸/▾, with
// a ⚠ when the site's 7Timer source is down. Color is never the sole signal.

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import "."

MouseArea {
	id: chip

	required property var site
	required property int nightIndex
	property bool expanded: false
	signal toggle()

	readonly property string recommendation: {
		if (!site || site.status !== "ok" || !site.nights
		    || site.nights.length <= nightIndex) {
			return "Error";
		}
		const n = site.nights[nightIndex];
		return n ? (n.recommendation || "Neither") : "Error";
	}

	implicitWidth: row.implicitWidth + Theme.largeSpacing
	implicitHeight: row.implicitHeight + Theme.smallSpacing
	hoverEnabled: true
	cursorShape: Qt.PointingHandCursor
	onClicked: chip.toggle()

	Rectangle {
		anchors.fill: parent
		radius: Theme.smallSpacing
		color: chip.containsMouse
			? Qt.alpha(Theme.highlightColor, 0.15)
			: Qt.alpha(Theme.textColor, 0.06)
		border.width: chip.expanded ? 2 : 1
		border.color: chip.expanded
			? Theme.highlightColor
			: Qt.alpha(Theme.textColor, 0.2)
	}

	RowLayout {
		id: row
		anchors.centerIn: parent
		spacing: Theme.smallSpacing

		// Verdict-colored dot.
		Rectangle {
			Layout.preferredWidth: Theme.iconSmall * 0.7
			Layout.preferredHeight: Theme.iconSmall * 0.7
			radius: width / 2
			antialiasing: true
			color: {
				switch (chip.recommendation) {
				case "BB+NB":   return Theme.positiveTextColor;
				case "NB only": return Theme.neutralTextColor;
				case "Neither": return Theme.negativeTextColor;
				default:        return Theme.disabledTextColor;
				}
			}
		}

		// 7Timer-down indicator (secondary sites are the 7Timer-sourced ones).
		Text {
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
			color: Theme.neutralTextColor
			font.pixelSize: Theme.smallFontSize
		}

		Text {
			text: (chip.site.label || chip.site.id) + " · " + chip.recommendation
			color: Theme.textColor
			font.pixelSize: Theme.smallFontSize
		}

		Text {
			text: chip.expanded ? "▾" : "▸"
			color: Theme.textColor
			opacity: 0.6
			font.pixelSize: Theme.smallFontSize
		}
	}
}
