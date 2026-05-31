// CompactRepresentation.qml — panel-size view: per-site colored dots.
//
// `pragma ComponentBehavior: Bound` ensures Repeater delegate cells can
// reference outer ids like `compact.stateModel` without Qt 6 raising
// unqualified-access warnings. Same fix as main.qml.
//
// Shown when the plasmoid is placed in a Plasma panel (the most common
// placement). One small colored circle per configured site arranged
// horizontally, with the site's first-letter initial below it. Clicking
// anywhere expands the full representation as a popup.
//
// Color mapping (spec §8):
//   BB+NB     → positiveTextColor (green-ish in default theme)
//   NB only   → neutralTextColor  (yellow/amber-ish)
//   Neither   → negativeTextColor (red-ish)
//   Error     → disabledTextColor (grey)
//
// The colors come from the theme palette so the widget adapts automatically
// to light/dark/custom Plasma themes.

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.kirigami as Kirigami

MouseArea {
	id: compact

	// Passed in from main.qml. Read-only — we never mutate forecast data here.
	required property var stateModel

	// The root PlasmoidItem, passed in from main.qml. Plasma 6 removed the
	// bare lowercase `plasmoid` global that Plasma 5 plasmoids used to toggle
	// the popup, so the parent hands us an explicit reference instead.
	required property PlasmoidItem plasmoidItem

	// Sizing in a panel: width grows with number of sites, height matches
	// panel thickness. Each "cell" is ~24 px wide for icon + label.
	implicitWidth: row.implicitWidth + Kirigami.Units.smallSpacing * 2
	implicitHeight: row.implicitHeight + Kirigami.Units.smallSpacing

	// Click handler: toggle the full popup via the passed-in PlasmoidItem.
	// `plasmoidItem.expanded` is the Plasma 6 idiom (the Plasma 5 bare
	// `plasmoid.expanded` no longer resolves and would silently no-op).
	hoverEnabled: true
	onClicked: plasmoidItem.expanded = !plasmoidItem.expanded

	RowLayout {
		id: row
		anchors.centerIn: parent
		spacing: Kirigami.Units.smallSpacing

		Repeater {
			model: compact.stateModel.sites

			ColumnLayout {
				id: cell
				spacing: 2
				Layout.alignment: Qt.AlignVCenter

				// Under `pragma ComponentBehavior: Bound`, a Repeater delegate
				// must DECLARE modelData as a required property — the bound
				// behavior no longer injects a bare `modelData` into scope.
				// Without this declaration `modelData` resolves to undefined
				// and every dot renders as an error/grey. (Fix 2026-05-29.)
				required property var modelData
				// The site object (one entry of stateModel.sites).
				readonly property var site: modelData
				readonly property string recommendation: {
					if (site.status !== "ok" || !site.nights
					    || site.nights.length === 0) {
						return "Error";
					}
					return site.nights[0].recommendation || "Neither";
				}

				// Colored dot. Rectangle with radius = width/2 → circle.
				Rectangle {
					Layout.alignment: Qt.AlignHCenter
					Layout.preferredWidth: Kirigami.Units.iconSizes.small
					Layout.preferredHeight: Kirigami.Units.iconSizes.small
					radius: width / 2
					antialiasing: true
					color: {
						switch (cell.recommendation) {
						case "BB+NB":   return Kirigami.Theme.positiveTextColor;
						case "NB only": return Kirigami.Theme.neutralTextColor;
						case "Neither": return Kirigami.Theme.negativeTextColor;
						default:        return Kirigami.Theme.disabledTextColor;
						}
					}
					// Subtle outline for visibility against any background.
					border.width: 1
					border.color: Qt.alpha(Kirigami.Theme.textColor, 0.3)
				}

				// Site initial — first letter of the label, uppercase.
				Text {
					Layout.alignment: Qt.AlignHCenter
					text: (site.label || "?").charAt(0).toUpperCase()
					color: Kirigami.Theme.textColor
					font.pixelSize: Kirigami.Units.iconSizes.small * 0.5
					font.bold: true
				}
			}
		}

		// Stale indicator: small warning icon when state.json is old.
		Kirigami.Icon {
			source: "dialog-warning-symbolic"
			Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
			Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
			visible: compact.stateModel.isStale
			color: Kirigami.Theme.neutralTextColor
		}
	}
}
