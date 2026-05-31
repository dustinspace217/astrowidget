// AttributionFooter.qml — required by Open-Meteo's CC-BY 4.0 license.
//
// Open-Meteo's data licence (https://open-meteo.com/en/licence) requires
// attribution and a link. We satisfy that with one row at the bottom of
// the full representation. Astrospheric is credited alongside as a matter
// of courtesy and to make data provenance visible to the user.

import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents

RowLayout {
	id: footer

	spacing: Kirigami.Units.smallSpacing

	PlasmaComponents.Label {
		text: qsTr("Data:")
		opacity: 0.6
		font.pixelSize: Kirigami.Theme.smallFont.pixelSize
	}

	PlasmaComponents.Label {
		text: "<a href='https://www.astrospheric.com/'>Astrospheric</a>"
		textFormat: Text.RichText
		font.pixelSize: Kirigami.Theme.smallFont.pixelSize
		onLinkActivated: (link) => Qt.openUrlExternally(link)
		MouseArea {
			anchors.fill: parent
			cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : Qt.ArrowCursor
			acceptedButtons: Qt.NoButton
		}
	}

	PlasmaComponents.Label {
		text: "·"
		opacity: 0.4
	}

	PlasmaComponents.Label {
		text: "<a href='https://open-meteo.com/'>Open-Meteo</a>"
			+ " <span style='opacity:0.7'>("
			+ "<a href='https://creativecommons.org/licenses/by/4.0/'>CC BY 4.0</a>"
			+ ")</span>"
		textFormat: Text.RichText
		font.pixelSize: Kirigami.Theme.smallFont.pixelSize
		onLinkActivated: (link) => Qt.openUrlExternally(link)
	}

	Item { Layout.fillWidth: true }
}
