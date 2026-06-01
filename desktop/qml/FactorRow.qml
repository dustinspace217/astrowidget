import QtQuick
import QtQuick.Layouts
import "."

// FactorRow.qml — one labeled value row (label left, value right). Desktop port
// of the plasmoid FactorRow: Kirigami.Units/Theme → the Theme singleton,
// PlasmaComponents.Label → plain Text (with an explicit color, since Text
// defaults to black on every platform).
RowLayout {
	id: row

	required property string label
	required property string value

	Layout.fillWidth: true
	spacing: Theme.smallSpacing

	Text {
		text: row.label
		color: Theme.textColor
		opacity: 0.7
		Layout.fillWidth: false
		Layout.preferredWidth: Theme.gridUnit * 5
		font.pixelSize: Theme.smallFontSize
	}
	Text {
		text: row.value
		color: Theme.textColor
		font.bold: true
		Layout.fillWidth: true
		elide: Text.ElideRight
	}
}
