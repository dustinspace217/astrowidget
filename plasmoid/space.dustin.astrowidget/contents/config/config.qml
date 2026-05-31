// config.qml — declares the tabs of the right-click Configure dialog.
//
// Single General tab in v1. Future iterations may add a Theming tab
// (background modes, opacity slider) and an Advanced tab (cache path
// override). Background-mode chooser is a deferred item — see
// docs/superpowers/specs/2026-05-28-astrowidget-design.md §10.1.

import org.kde.plasma.configuration

ConfigModel {
	ConfigCategory {
		name: i18n("General")
		icon: "configure"
		source: "ConfigGeneral.qml"
	}
}
