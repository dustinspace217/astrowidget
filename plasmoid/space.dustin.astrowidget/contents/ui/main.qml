// main.qml — astrowidget root.
//
// Plasma 6 root is a PlasmoidItem (Plasma 5's `Item` no longer works as the
// root). Plasmoid.compactRepresentation and Plasmoid.fullRepresentation
// are Component-typed attached properties set here so the Plasma shell can
// instantiate the right view based on placement (panel = compact,
// desktop = full).
//
// StateModel is declared as a sibling QtObject so both representations can
// bind to the same instance. Both Components below reference `model` by id.
//
// The `pragma ComponentBehavior: Bound` ensures inline Components can see
// outer IDs like `model` — without it, Qt 6 raises an unqualified-access
// warning and the binding fails to resolve at runtime.
//
// Design spec §6.3.

pragma ComponentBehavior: Bound

import QtQuick
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore

PlasmoidItem {
	id: root

	// Single shared data source. Both representations bind through to it.
	StateModel { id: model }

	// Tooltip text shown on panel hover. The subText is reactive to model.
	toolTipMainText: "astrowidget"
	toolTipSubText: model.toolTipSummary

	// Surface a "needs attention" status when state.json is older than 8h.
	// The Plasma systray uses this to badge containerised plasmoids.
	Plasmoid.status: model.isStale
		? PlasmaCore.Types.NeedsAttentionStatus
		: PlasmaCore.Types.PassiveStatus

	// Right-click menu entry so the fetch can be triggered from the panel
	// without opening the popup. Calls the same StateModel.refresh() the header
	// button uses. Disabled while a fetch is in flight (refresh() also guards).
	// Plasma 6 shape verified against the installed systemmonitor plasmoid.
	Plasmoid.contextualActions: [
		PlasmaCore.Action {
			text: qsTr("Refresh now")
			icon.name: "view-refresh"
			enabled: !model.refreshing
			onTriggered: model.refresh()
		}
	]

	// compactRepresentation / fullRepresentation are item-valued properties on
	// the root PlasmoidItem (NOT Plasmoid.-prefixed, NOT Component-wrapped) —
	// this matches every installed Plasma 6 reference plasmoid (kdeconnect,
	// systemmonitor, vault). The shell instantiates them lazily on its own;
	// an explicit Component wrapper is wrong for Plasma 6.
	//
	// CompactRepresentation needs a handle to THIS PlasmoidItem to toggle the
	// popup (the bare `plasmoid` global was removed in Plasma 6), so we pass
	// `root` in as plasmoidItem.
	compactRepresentation: CompactRepresentation {
		stateModel: model
		plasmoidItem: root
	}

	fullRepresentation: FullRepresentation {
		stateModel: model
	}
}
