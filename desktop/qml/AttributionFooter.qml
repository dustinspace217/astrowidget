import QtQuick
import QtQuick.Layouts
import "."

// AttributionFooter.qml — Open-Meteo's CC-BY 4.0 licence requires attribution +
// a link. Desktop port of the plasmoid footer (Kirigami/PlasmaComponents →
// Theme + Text). Astrospheric is credited alongside for provenance.
RowLayout {
	id: footer
	spacing: Theme.smallSpacing

	Text {
		text: qsTr("Data:")
		color: Theme.textColor
		opacity: 0.6
		font.pixelSize: Theme.smallFontSize
	}

	Text {
		text: "<a href='https://www.astrospheric.com/'>Astrospheric</a>"
		textFormat: Text.RichText
		color: Theme.textColor
		linkColor: Theme.highlightColor
		font.pixelSize: Theme.smallFontSize
		onLinkActivated: (link) => Qt.openUrlExternally(link)
		MouseArea {
			anchors.fill: parent
			cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : Qt.ArrowCursor
			acceptedButtons: Qt.NoButton
		}
	}

	Text { text: "·"; color: Theme.textColor; opacity: 0.4 }

	Text {
		text: "<a href='https://open-meteo.com/'>Open-Meteo</a>"
			+ " (<a href='https://creativecommons.org/licenses/by/4.0/'>CC BY 4.0</a>)"
		textFormat: Text.RichText
		color: Theme.textColor
		linkColor: Theme.highlightColor
		font.pixelSize: Theme.smallFontSize
		onLinkActivated: (link) => Qt.openUrlExternally(link)
	}

	Item { Layout.fillWidth: true }
}
