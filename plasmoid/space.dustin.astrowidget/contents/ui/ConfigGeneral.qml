// ConfigGeneral.qml — the General tab of the Configure dialog.
//
// Two settings in v1: night-vision mode toggle, default night tab. The
// values are persisted by KConfig per the schema in config/main.xml; the
// plasmoid reads them via plasmoid.configuration.<key>.
//
// The "cfg_<name>" prefix on properties is a Plasma convention: any
// property named cfg_X is auto-bound to the configuration entry X and
// flushed when the user clicks Apply / OK.

import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Kirigami.FormLayout {
	id: page

	// Auto-bound to nightVisionMode in main.xml.
	property bool cfg_nightVisionMode

	// Auto-bound to defaultNightTab in main.xml.
	property int cfg_defaultNightTab

	QQC2.CheckBox {
		Kirigami.FormData.label: i18n("Night-vision mode:")
		text: i18n("Use red-only palette (preserves dark adaptation)")
		checked: page.cfg_nightVisionMode
		onCheckedChanged: page.cfg_nightVisionMode = checked
	}

	QQC2.ComboBox {
		Kirigami.FormData.label: i18n("Default tab:")
		model: [i18n("Tonight"), i18n("+1 night"), i18n("+2 nights")]
		currentIndex: page.cfg_defaultNightTab
		onCurrentIndexChanged: page.cfg_defaultNightTab = currentIndex
		Layout.preferredWidth: Kirigami.Units.gridUnit * 12
	}

	// Helpful informational text — points users at the README and the
	// config.toml so they know where to set the API key and sites.
	Item {
		Kirigami.FormData.isSection: true
	}

	QQC2.Label {
		Kirigami.FormData.label: i18n("Configuration:")
		text: i18n("API key and sites live in ~/.config/astrowidget/config.toml")
		wrapMode: Text.WordWrap
		Layout.fillWidth: true
		Layout.preferredWidth: Kirigami.Units.gridUnit * 20
	}

	QQC2.Label {
		text: i18n("Manual refresh: systemctl --user start astrowidget-fetch.service")
		font.family: "monospace"
		font.pixelSize: Kirigami.Theme.smallFont.pixelSize
		opacity: 0.7
		wrapMode: Text.WordWrap
		Layout.fillWidth: true
		Layout.preferredWidth: Kirigami.Units.gridUnit * 20
	}
}
