// FactorRow.qml — one labeled value row used by SiteColumn's factor grid.
//
// Two-column layout: label on the left, value on the right. Used many times
// in a column so factoring it out keeps SiteColumn readable.

import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents

RowLayout {
	id: row

	required property string label
	required property string value

	Layout.fillWidth: true
	spacing: Kirigami.Units.smallSpacing

	PlasmaComponents.Label {
		text: row.label
		opacity: 0.7
		Layout.fillWidth: false
		Layout.preferredWidth: Kirigami.Units.gridUnit * 5
		font.pixelSize: Kirigami.Theme.smallFont.pixelSize
	}
	PlasmaComponents.Label {
		text: row.value
		font.bold: true
		Layout.fillWidth: true
		elide: Text.ElideRight
	}
}
