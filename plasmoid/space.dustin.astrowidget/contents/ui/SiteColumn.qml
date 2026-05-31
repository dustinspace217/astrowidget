// SiteColumn.qml — one column of the full popup, scoped to a single site.
//
// Shows:
//   - Header: site label + verdict pill (BB+NB / NB only / Neither / Error)
//   - Astro dark window (start → end, duration)
//   - Weather readout rows from night.displayFactors (the fetcher-computed,
//     dark-window-averaged values): Transparency, Seeing (from Astrospheric),
//     Cloud, Wind, Dew spread, Precip, Visibility, Moon.
//   - Scoring breakdown: BB / NB composite scores (from the Dart engine).
//   - Meteogram strip: hourly cloud cover across the dark window.
//
// Two distinct data sources, deliberately kept separate:
//   - night.displayFactors  → human weather readout (incl. paid Astrospheric
//                             seeing/transparency). schemaVersion 2+.
//   - night.broadband.factors → the engine's 0-100 sub-scores (cloud/
//                             stability/darkness/moon) behind the verdict.
// nightIndex selects which night (0 = Tonight, 1 = +1, 2 = +2).

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents

ColumnLayout {
	id: col

	// Passed in from FullRepresentation.qml. modelData is one site object.
	required property var site
	required property int nightIndex

	spacing: Kirigami.Units.smallSpacing

	// Convenience accessors. Defensive against missing data — error state
	// gets handled in the header rendering.
	readonly property var night: {
		if (site.status !== "ok" || !site.nights
		    || site.nights.length <= nightIndex) {
			return null;
		}
		return site.nights[nightIndex];
	}
	readonly property string recommendation:
		night ? (night.recommendation || "Neither") : "Error"
	// Engine sub-scores (0-100) behind the verdict.
	readonly property var factors: night && night.broadband
		? night.broadband.factors
		: null
	// Human weather readout (schemaVersion 2). May be null on older state or
	// a night with no dark window.
	readonly property var df: night ? (night.displayFactors || null) : null

	// ── Header: site label + verdict pill ────────────────────────────────
	RowLayout {
		Layout.fillWidth: true
		spacing: Kirigami.Units.smallSpacing

		PlasmaComponents.Label {
			text: col.site.label || col.site.id
			font.bold: true
			font.pixelSize: Kirigami.Theme.defaultFont.pixelSize * 1.1
			Layout.fillWidth: true
			elide: Text.ElideRight
		}

		// Verdict pill — rounded rect with theme-tinted fill and contrasting
		// text. Always carries text label so color is never the sole signal.
		Rectangle {
			Layout.preferredHeight: pillText.implicitHeight
				+ Kirigami.Units.smallSpacing
			Layout.preferredWidth: pillText.implicitWidth
				+ Kirigami.Units.largeSpacing * 1.5
			radius: height / 2
			color: {
				switch (col.recommendation) {
				case "BB+NB":   return Kirigami.Theme.positiveTextColor;
				case "NB only": return Kirigami.Theme.neutralTextColor;
				case "Neither": return Kirigami.Theme.negativeTextColor;
				default:        return Kirigami.Theme.disabledTextColor;
				}
			}
			PlasmaComponents.Label {
				id: pillText
				anchors.centerIn: parent
				text: col.recommendation
				color: Kirigami.Theme.backgroundColor
				font.bold: true
				font.pixelSize: Kirigami.Theme.smallFont.pixelSize
			}
		}
	}

	// Error placeholder — surfaces the per-site error message from the
	// fetcher / scoring binary so failures aren't silently masked as
	// just "Neither". This explicit display is the fix for the silent
	// failure flagged in the QA review.
	PlasmaComponents.Label {
		visible: !col.night
		text: col.site.error
			? qsTr("Error: %1").arg(col.site.error)
			: qsTr("No forecast for this night.")
		color: Kirigami.Theme.negativeTextColor
		wrapMode: Text.WordWrap
		Layout.fillWidth: true
		font.pixelSize: Kirigami.Theme.smallFont.pixelSize
	}

	// Astro dark window line — visible only when we have valid data.
	PlasmaComponents.Label {
		visible: col.night && col.night.dark_window
		text: {
			if (!col.night || !col.night.dark_window) return "";
			const dw = col.night.dark_window;
			const start = Qt.formatTime(new Date(dw.start), "HH:mm");
			const end = Qt.formatTime(new Date(dw.end), "HH:mm");
			const hrs = Math.floor(dw.duration_minutes / 60);
			const mins = dw.duration_minutes % 60;
			return qsTr("Astro dark: %1 → %2 (%3h %4m)").arg(start).arg(end)
				.arg(hrs).arg(mins);
		}
		font.pixelSize: Kirigami.Theme.smallFont.pixelSize
		opacity: 0.85
		Layout.fillWidth: true
		elide: Text.ElideRight
	}

	// Spacer
	Item { Layout.preferredHeight: Kirigami.Units.smallSpacing }

	// ── 7Timer-unavailable badge ─────────────────────────────────────────
	// International sites get seeing/transparency from the free 7Timer service.
	// When it's down, the fetcher sets meta.degraded = ["7timer"] so we can say
	// so explicitly instead of leaving a silent "—" that looks identical to "no
	// notable data". The site still has a verdict (it scores on Open-Meteo
	// cloud) — only the astro-quality readout below is missing. This is the
	// "every system that can error should tell the user what went wrong" rule.
	Rectangle {
		Layout.fillWidth: true
		visible: {
			const m = col.site.meta;
			return !!(m && m.degraded && m.degraded.indexOf("7timer") >= 0);
		}
		Layout.preferredHeight: degradedLabel.implicitHeight
			+ Kirigami.Units.smallSpacing
		radius: Kirigami.Units.smallSpacing
		color: Qt.alpha(Kirigami.Theme.neutralTextColor, 0.15)

		PlasmaComponents.Label {
			id: degradedLabel
			anchors.fill: parent
			anchors.leftMargin: Kirigami.Units.smallSpacing
			anchors.rightMargin: Kirigami.Units.smallSpacing
			verticalAlignment: Text.AlignVCenter
			wrapMode: Text.WordWrap
			text: qsTr("⚠ 7Timer unavailable — seeing/transparency not shown")
			color: Kirigami.Theme.neutralTextColor
			font.pixelSize: Kirigami.Theme.smallFont.pixelSize
		}
	}

	// ── Weather readout (from night.displayFactors) ──────────────────────
	// These are the dark-window-averaged values the user asked to see per
	// site. Transparency + Seeing come from the paid Astrospheric Pro feed;
	// the rest from Open-Meteo. Each shows a human label / unit, not a
	// "/100" engine score — those live in the Scoring breakdown below.
	GridLayout {
		visible: col.night !== null
		// Single column: a 2-column split left the value cell ~15px wide, so
		// every value elided to one character ("C…"). Full-width rows give the
		// value room for labels like "Below Average" / "96% illum. · 20° alt".
		columns: 1
		columnSpacing: Kirigami.Units.largeSpacing
		rowSpacing: 4
		Layout.fillWidth: true

		// Astrospheric transparency — raw scale is inverted (low = good); we
		// show the documented label so the user never has to remember that.
		FactorRow {
			label: qsTr("Transparency")
			value: col.df && col.df.transparency
				? col.df.transparency.label
				: "—"
		}

		// Astrospheric seeing — 0-5, higher = better, shown as its label.
		FactorRow {
			label: qsTr("Seeing")
			value: col.df && col.df.seeing
				? col.df.seeing.label
				: "—"
		}

		FactorRow {
			label: qsTr("Cloud")
			value: col.df && col.df.cloudPct !== undefined && col.df.cloudPct !== null
				? col.df.cloudPct + "%"
				: "—"
		}

		FactorRow {
			label: qsTr("Moon")
			value: {
				if (!col.night || !col.night.moon) return "—";
				const m = col.night.moon;
				let s = Math.round(m.illumination_pct) + "% illum.";
				// Show max altitude during dark when available (schemaVersion 2).
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
				? col.df.dewSpreadC + "°C"
				: "—"
		}

		FactorRow {
			label: qsTr("Precip")
			value: col.df && col.df.precipPct !== undefined && col.df.precipPct !== null
				? col.df.precipPct + "%"
				: "—"
		}

		FactorRow {
			label: qsTr("Visibility")
			value: col.df && col.df.visibilityKm !== undefined && col.df.visibilityKm !== null
				? col.df.visibilityKm + " km"
				: "—"
		}
	}

	// ── Scoring breakdown (the engine's verdict math) ────────────────────
	// Kept visually distinct from the weather readout. BB/NB composite scores
	// plus the four engine sub-scores. NOTE: the verdict is computed from
	// Open-Meteo-derived inputs; Astrospheric seeing/transparency above are
	// shown for the user to weigh but do NOT (yet) feed the score — see the
	// spec's DEF-V2-02. The earlier comment here that claimed the engine
	// "combines transparency + seeing" was false and has been removed.
	GridLayout {
		visible: col.night !== null
		columns: 1
		columnSpacing: Kirigami.Units.largeSpacing
		rowSpacing: 4
		Layout.fillWidth: true
		Layout.topMargin: Kirigami.Units.smallSpacing

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
	// The user's "each model and the convergences" request. Shown when the
	// multi-model fetch succeeded (night.displayFactors.cloudConvergence).
	// Compact: per-model dark-window mean cloud % + agreement label.
	Column {
		visible: col.df && col.df.cloudConvergence
		Layout.fillWidth: true
		spacing: 2
		Layout.topMargin: Kirigami.Units.smallSpacing

		PlasmaComponents.Label {
			// Numeric spread (max − min of the per-model dark-window means)
			// replaced the old strong/moderate/weak "agreement" bucket: the
			// buckets used arbitrary thresholds, while the raw spread lets the
			// user judge model agreement directly (small % = concord, large % =
			// the models disagree, so trust the verdict less).
			text: col.df && col.df.cloudConvergence
				? qsTr("Cloud models — %1% spread").arg(col.df.cloudConvergence.spread)
				: ""
			font.bold: true
			font.pixelSize: Kirigami.Theme.smallFont.pixelSize
			opacity: 0.85
		}
		PlasmaComponents.Label {
			// Render each model's mean as "Cloud Sense 14% · GFS 11% · ECMWF 17%".
			text: {
				if (!col.df || !col.df.cloudConvergence) return "";
				const m = col.df.cloudConvergence.models;
				// Friendly per-model labels. The ensemble keys are internal:
				// cloudsense/gfs/ecmwf/icon are the scoring models, as_gfs/as_nam
				// are the display-only Astrospheric extras. An earlier
				// `key.split("_")[0]` collapsed BOTH as_gfs and as_nam to "as"
				// (a duplicate, ambiguous entry) and showed "cloudsense" raw —
				// this map keeps every model distinct and readable.
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
			wrapMode: Text.WordWrap
			font.pixelSize: Kirigami.Theme.smallFont.pixelSize
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

		PlasmaComponents.Label {
			text: qsTr("Vetoes:")
			font.bold: true
			color: Kirigami.Theme.negativeTextColor
		}
		Repeater {
			model: col.night && col.night.broadband
				? col.night.broadband.vetoes
				: []
			PlasmaComponents.Label {
				// Required under `pragma ComponentBehavior: Bound` — without
				// it modelData is undefined and the veto reads "• undefined".
				required property var modelData
				text: "• " + (modelData.reason || modelData.name)
				wrapMode: Text.WordWrap
				color: Kirigami.Theme.negativeTextColor
				font.pixelSize: Kirigami.Theme.smallFont.pixelSize
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
			PlasmaComponents.Label {
				// Required under `pragma ComponentBehavior: Bound` (model is an
				// array of strings; bare modelData would be undefined).
				required property var modelData
				text: modelData
				wrapMode: Text.WordWrap
				font.pixelSize: Kirigami.Theme.smallFont.pixelSize
				opacity: 0.85
				width: col.width
			}
		}
	}

	// Fills remaining vertical space so the meteogram pins to the bottom
	// uniformly across all columns.
	Item { Layout.fillHeight: true }

	// ── Meteogram strip ──────────────────────────────────────────────────
	Meteogram {
		Layout.fillWidth: true
		Layout.preferredHeight: Kirigami.Units.gridUnit * 2
		visible: col.night !== null
		site: col.site
		nightIndex: col.nightIndex
	}
}
