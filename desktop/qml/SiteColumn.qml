// SiteColumn.qml — one column of the desktop window, scoped to a single site.
// Desktop port of the plasmoid SiteColumn: Kirigami.Units/Theme → the Theme
// singleton, PlasmaComponents.Label → Text (explicit colors). Layout + logic
// are identical (header pill, astro-dark line, 7Timer badge, weather readout,
// scoring breakdown, convergence, vetoes, reasons, meteogram).

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import "."

ColumnLayout {
	id: col

	required property var site
	required property int nightIndex

	spacing: Theme.smallSpacing

	readonly property var night: {
		if (site.status !== "ok" || !site.nights
		    || site.nights.length <= nightIndex) {
			return null;
		}
		return site.nights[nightIndex];
	}
	readonly property string recommendation:
		night ? (night.recommendation || "Neither") : "Error"
	readonly property var factors: night && night.broadband
		? night.broadband.factors
		: null
	readonly property var df: night ? (night.displayFactors || null) : null

	// ── Header: site label + verdict pill ────────────────────────────────
	RowLayout {
		Layout.fillWidth: true
		spacing: Theme.smallSpacing

		Text {
			text: col.site.label || col.site.id
			color: Theme.textColor
			font.bold: true
			font.pixelSize: Theme.fontSize * 1.1
			Layout.fillWidth: true
			elide: Text.ElideRight
		}

		// Verdict pill — text always present so color is never the sole signal.
		Rectangle {
			Layout.preferredHeight: pillText.implicitHeight + Theme.smallSpacing
			Layout.preferredWidth: pillText.implicitWidth + Theme.largeSpacing * 1.5
			radius: height / 2
			color: {
				switch (col.recommendation) {
				case "BB+NB":   return Theme.positiveTextColor;
				case "NB only": return Theme.neutralTextColor;
				case "Neither": return Theme.negativeTextColor;
				default:        return Theme.disabledTextColor;
				}
			}
			Text {
				id: pillText
				anchors.centerIn: parent
				text: col.recommendation
				color: Theme.backgroundColor
				font.bold: true
				font.pixelSize: Theme.smallFontSize
			}
		}
	}

	// Error placeholder — surfaces the per-site error so failures aren't masked.
	Text {
		visible: !col.night
		text: col.site.error
			? qsTr("Error: %1").arg(col.site.error)
			: qsTr("No forecast for this night.")
		color: Theme.negativeTextColor
		wrapMode: Text.WordWrap
		Layout.fillWidth: true
		font.pixelSize: Theme.smallFontSize
	}

	// Astro dark window line (local time + zone label).
	Text {
		visible: col.night && col.night.dark_window
		text: {
			if (!col.night || !col.night.dark_window) return "";
			const dw = col.night.dark_window;
			const startDate = new Date(dw.start);
			// Qt converts the UTC dark_window to the machine's LOCAL time, so every
			// site reads on the user's own clock. We add the zone label (Qt "t" →
			// "PDT") so it's unmistakably local.
			const start = Qt.formatTime(startDate, "HH:mm");
			const end = Qt.formatTime(new Date(dw.end), "HH:mm");
			const tz = Qt.formatDateTime(startDate, "t");
			const hrs = Math.floor(dw.duration_minutes / 60);
			const mins = dw.duration_minutes % 60;
			return qsTr("Astro dark: %1 → %2 %5 (%3h %4m)").arg(start).arg(end)
				.arg(hrs).arg(mins).arg(tz);
		}
		color: Theme.textColor
		font.pixelSize: Theme.smallFontSize
		opacity: 0.85
		Layout.fillWidth: true
		elide: Text.ElideRight
	}

	Item { Layout.preferredHeight: Theme.smallSpacing }

	// ── 7Timer-unavailable badge ─────────────────────────────────────────
	Rectangle {
		Layout.fillWidth: true
		visible: {
			const m = col.site.meta;
			return !!(m && m.degraded && m.degraded.indexOf("7timer") >= 0);
		}
		Layout.preferredHeight: degradedLabel.implicitHeight + Theme.smallSpacing
		radius: Theme.smallSpacing
		color: Qt.alpha(Theme.neutralTextColor, 0.15)

		Text {
			id: degradedLabel
			anchors.fill: parent
			anchors.leftMargin: Theme.smallSpacing
			anchors.rightMargin: Theme.smallSpacing
			verticalAlignment: Text.AlignVCenter
			wrapMode: Text.WordWrap
			text: qsTr("⚠ 7Timer unavailable — seeing/transparency not shown")
			color: Theme.neutralTextColor
			font.pixelSize: Theme.smallFontSize
		}
	}

	// ── Weather readout (from night.displayFactors) ──────────────────────
	GridLayout {
		visible: col.night !== null
		columns: 1
		columnSpacing: Theme.largeSpacing
		rowSpacing: 4
		Layout.fillWidth: true

		FactorRow {
			label: qsTr("Transparency")
			value: col.df && col.df.transparency ? col.df.transparency.label : "—"
		}
		FactorRow {
			label: qsTr("Seeing")
			value: col.df && col.df.seeing ? col.df.seeing.label : "—"
		}
		FactorRow {
			label: qsTr("Cloud")
			value: col.df && col.df.cloudPct !== undefined && col.df.cloudPct !== null
				? col.df.cloudPct + "%" : "—"
		}
		FactorRow {
			label: qsTr("Moon")
			value: {
				if (!col.night || !col.night.moon) return "—";
				const m = col.night.moon;
				let s = Math.round(m.illumination_pct) + "% illum.";
				if (m.max_alt_during_dark !== undefined && m.max_alt_during_dark !== null) {
					s += " · " + Math.round(m.max_alt_during_dark) + "° alt";
				}
				return s;
			}
		}
		FactorRow {
			label: qsTr("Wind")
			value: col.df && col.df.windKmh !== undefined && col.df.windKmh !== null
				? col.df.windKmh + " km/h" +
					(col.df.gustsKmh ? " (g " + col.df.gustsKmh + ")" : "")
				: "—"
		}
		FactorRow {
			label: qsTr("Dew spread")
			value: col.df && col.df.dewSpreadC !== undefined && col.df.dewSpreadC !== null
				? col.df.dewSpreadC + "°C" : "—"
		}
		FactorRow {
			label: qsTr("Precip")
			value: col.df && col.df.precipPct !== undefined && col.df.precipPct !== null
				? col.df.precipPct + "%" : "—"
		}
		FactorRow {
			label: qsTr("Visibility")
			value: col.df && col.df.visibilityKm !== undefined && col.df.visibilityKm !== null
				? col.df.visibilityKm + " km" : "—"
		}
	}

	// ── Scoring breakdown (the engine's verdict math) ────────────────────
	GridLayout {
		visible: col.night !== null
		columns: 1
		columnSpacing: Theme.largeSpacing
		rowSpacing: 4
		Layout.fillWidth: true
		Layout.topMargin: Theme.smallSpacing

		FactorRow {
			label: qsTr("Broadband")
			value: col.night && col.night.broadband
				? col.night.broadband.score + "/100 (" + col.night.broadband.verdict + ")"
				: "—"
		}
		FactorRow {
			label: qsTr("Narrowband")
			value: col.night && col.night.narrowband
				? col.night.narrowband.score + "/100 (" + col.night.narrowband.verdict + ")"
				: "—"
		}
	}

	// ── Cloud-model convergence ──────────────────────────────────────────
	Column {
		visible: col.df && col.df.cloudConvergence
		Layout.fillWidth: true
		spacing: 2
		Layout.topMargin: Theme.smallSpacing

		Text {
			text: col.df && col.df.cloudConvergence
				? qsTr("Cloud models — %1% spread").arg(col.df.cloudConvergence.spread)
				: ""
			color: Theme.textColor
			font.bold: true
			font.pixelSize: Theme.smallFontSize
			opacity: 0.85
		}
		Text {
			// "Cloud Sense 14% · GFS 11% · ECMWF 17%". Friendly per-model labels;
			// keeps as_gfs / as_nam / cloudsense distinct and readable.
			text: {
				if (!col.df || !col.df.cloudConvergence) return "";
				const m = col.df.cloudConvergence.models;
				const labels = {
					"cloudsense": "Cloud Sense", "gfs": "GFS", "ecmwf": "ECMWF",
					"icon": "ICON", "as_gfs": "AS-GFS", "as_nam": "AS-NAM",
				};
				const parts = [];
				for (const key in m) {
					parts.push((labels[key] || key) + " " + m[key] + "%");
				}
				return parts.join(" · ");
			}
			color: Theme.textColor
			wrapMode: Text.WordWrap
			font.pixelSize: Theme.smallFontSize
			opacity: 0.7
			width: col.width
		}
	}

	// Vetoes block — bright red, only when present.
	Column {
		visible: col.night && col.night.broadband
			&& col.night.broadband.vetoes
			&& col.night.broadband.vetoes.length > 0
		Layout.fillWidth: true
		spacing: 2

		Text {
			text: qsTr("Vetoes:")
			font.bold: true
			color: Theme.negativeTextColor
			font.pixelSize: Theme.smallFontSize
		}
		Repeater {
			model: col.night && col.night.broadband
				? col.night.broadband.vetoes
				: []
			Text {
				required property var modelData
				text: "• " + (modelData.reason || modelData.name)
				wrapMode: Text.WordWrap
				color: Theme.negativeTextColor
				font.pixelSize: Theme.smallFontSize
				width: col.width
			}
		}
	}

	// Reasons block — engine-generated narrative.
	Column {
		visible: col.night && col.night.reasons
			&& col.night.reasons.length > 0
		Layout.fillWidth: true
		spacing: 2

		Repeater {
			model: col.night ? col.night.reasons : []
			Text {
				required property var modelData
				text: modelData
				color: Theme.textColor
				wrapMode: Text.WordWrap
				font.pixelSize: Theme.smallFontSize
				opacity: 0.85
				width: col.width
			}
		}
	}

	// Fills remaining vertical space so the meteogram pins to the bottom.
	Item { Layout.fillHeight: true }

	// ── Meteogram strip ──────────────────────────────────────────────────
	Meteogram {
		Layout.fillWidth: true
		Layout.preferredHeight: Theme.gridUnit * 2
		visible: col.night !== null
		site: col.site
		nightIndex: col.nightIndex
	}
}
