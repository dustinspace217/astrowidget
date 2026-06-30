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

	// ── Degradation-warning plumbing ─────────────────────────────────────
	// Dismissed "<siteId>|<code>" keys, passed down from Main.qml (which owns
	// the Settings store). Defaults to empty so the column degrades safely to
	// "show all warnings" if a parent ever forgets to bind it.
	property var dismissedKeys: []
	// Emitted when the user clicks "Don't show this again". Main.qml appends the
	// key to Settings; the updated dismissedKeys flows back and hides the block.
	signal requestDismiss(string key)

	// The Astrospheric-failure entry the fetcher recorded in meta.degraded, or
	// null. Shape: {source:"astrospheric", reason:<human>, code:<stable>}. Only
	// IN-coverage sites whose Astrospheric fetch failed get one; out-of-coverage
	// sites use the free 7Timer+Open-Meteo path silently and never carry it.
	readonly property var astroFailure: {
		const m = site.meta;
		if (!m || !m.degraded) return null;
		for (let i = 0; i < m.degraded.length; i++) {
			const d = m.degraded[i];
			// `d &&` skips a null/garbled element so a malformed or partially
			// written state.json can't throw here (a throw would evaluate the
			// binding to undefined and silently drop the warning).
			if (d && d.source === "astrospheric") return d;
		}
		return null;
	}
	// Stable dismissal key <siteId>|<code>. Keyed on the CODE, not the human
	// reason, so "Don't show again" hides only this failure mode — a different
	// Astrospheric failure later (an outage after a 403, say) still surfaces.
	readonly property string astroFailureKey:
		astroFailure ? (site.id + "|" + (astroFailure.code || "error")) : ""
	// Show the red warning unless the user dismissed THIS site + THIS code.
	readonly property bool astroWarningVisible:
		astroFailure !== null && dismissedKeys.indexOf(astroFailureKey) < 0

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

		// REMOTE/dome badge — shown for `managed` (hosted, weatherproof dome) sites.
		// Signals that this site auto-gates to clear and its precip equipment veto is
		// OFF (the dome self-protects), so its verdict is a clean go/no-go rather than
		// the gamble-on-gaps HOME framing. `managed` is per-night but constant for a
		// site, so reading it off the displayed night is fine.
		Rectangle {
			visible: col.night && col.night.managed === true
			Layout.preferredHeight: domeText.implicitHeight + Theme.smallSpacing
			Layout.preferredWidth: domeText.implicitWidth + Theme.smallSpacing * 2
			radius: Theme.smallSpacing
			color: "transparent"
			border.width: 1
			border.color: Qt.alpha(Theme.textColor, 0.4)
			Text {
				id: domeText
				anchors.centerIn: parent
				text: qsTr("REMOTE")
				color: Theme.textColor
				opacity: 0.8
				font.pixelSize: Theme.smallFontSize * 0.85
			}
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

	// Best clear-sky window line — the HOME-mode gamble aid (spec §4). Shown ONLY
	// when there is a clear stretch (best_window != null) AND it is meaningfully
	// SHORTER than the whole dark window — i.e. the night is partly cloudy and THIS
	// is the gap worth shooting. On a fully-clear night best_window ≈ the dark
	// window, so the "Astro dark" line above already conveys it and this stays
	// hidden to avoid redundant clutter. Green tint: it's the good news on an
	// otherwise-compromised night.
	Text {
		visible: {
			if (!col.night || !col.night.best_window
			    || !col.night.dark_window) return false;
			const bw = col.night.best_window;
			const dwMin = col.night.dark_window.duration_minutes || 0;
			const bwMin = (new Date(bw.end) - new Date(bw.start)) / 60000;
			return dwMin > 0 && bwMin < dwMin * 0.85;
		}
		text: {
			if (!col.night || !col.night.best_window) return "";
			const bw = col.night.best_window;
			const startDate = new Date(bw.start);
			const start = Qt.formatTime(startDate, "HH:mm");
			const end = Qt.formatTime(new Date(bw.end), "HH:mm");
			const tz = Qt.formatDateTime(startDate, "t");
			const totalMin = Math.round((new Date(bw.end) - startDate) / 60000);
			const hrs = Math.floor(totalMin / 60);
			const mins = totalMin % 60;
			return qsTr("Best clear: %1 → %2 %5 (%3h %4m)").arg(start).arg(end)
				.arg(hrs).arg(mins).arg(tz);
		}
		color: Theme.positiveTextColor
		font.pixelSize: Theme.smallFontSize
		opacity: 0.9
		Layout.fillWidth: true
		elide: Text.ElideRight
	}

	// Moon-free window line (2026-06-29) — the broadband-usable gap on a partial-moon
	// night, with the broadband score achievable in it. Present ONLY when there's a usable
	// (≥1h) gap; moonFreeBroadband is null on full-moon / no-moon / sub-hour nights.
	// Distinct from "Best clear" above (cloud gap vs moon gap) — accent tint, not green.
	Text {
		visible: !!(col.night && col.night.moonFreeBroadband)
		text: {
			if (!col.night || !col.night.moonFreeBroadband) return "";
			const mf = col.night.moonFreeBroadband;
			const startDate = new Date(mf.window.start);
			const start = Qt.formatTime(startDate, "HH:mm");
			const end = Qt.formatTime(new Date(mf.window.end), "HH:mm");
			const tz = Qt.formatDateTime(startDate, "t");
			return qsTr("Moon-free: %1 → %2 %4 (BB %3)").arg(start).arg(end)
				.arg(mf.score).arg(tz);
		}
		color: Theme.highlightColor
		font.pixelSize: Theme.smallFontSize
		opacity: 0.9
		Layout.fillWidth: true
		elide: Text.ElideRight
	}

	// ── Astrospheric-failure warning (red, dismissable) ──────────────────
	// Shown ONLY for sites inside Astrospheric's coverage whose Astrospheric
	// fetch failed (no key / rejected key / outage / bad data). The site still
	// has a full verdict — it transparently fell back to the free 7Timer +
	// Open-Meteo path — so this explains the downgrade instead of letting the
	// paid seeing/transparency silently vanish. Out-of-coverage sites use the
	// free path WITHOUT this warning. "Don't show this again" suppresses this
	// site + THIS failure code only (see astroFailureKey).
	Rectangle {
		Layout.fillWidth: true
		visible: col.astroWarningVisible
		Layout.preferredHeight: asWarnCol.implicitHeight + Theme.smallSpacing * 2
		radius: Theme.smallSpacing
		// Tinted (not solid) negative color: reads as an error at a glance
		// while keeping the text legible over the fill.
		color: Qt.alpha(Theme.negativeTextColor, 0.15)

		ColumnLayout {
			id: asWarnCol
			anchors.fill: parent
			anchors.margins: Theme.smallSpacing
			spacing: Theme.smallSpacing

			// Headline — matches the wording the user specified.
			Text {
				Layout.fillWidth: true
				wrapMode: Text.WordWrap
				color: Theme.negativeTextColor
				font.bold: true
				font.pixelSize: Theme.smallFontSize
				text: qsTr("⚠ Astrospheric data failed — using Open-Meteo data.")
			}
			// Detail — the fetcher's scrubbed reason string (already API-key-safe).
			// On its own line so the headline stays clean; e.g. "Astrospheric
			// returned HTTP 403 (details suppressed to protect API key)" or
			// "No Astrospheric API key configured".
			Text {
				Layout.fillWidth: true
				visible: text.length > 0
				wrapMode: Text.WordWrap
				color: Theme.negativeTextColor
				opacity: 0.85
				font.pixelSize: Theme.smallFontSize
				text: col.astroFailure ? col.astroFailure.reason : ""
			}
			// Primitive "Don't show this again" button — Rectangle + Text +
			// MouseArea, matching this file's Controls-free style (the verdict
			// pill above is built the same way). Avoids importing QtQuick.Controls
			// here just for one button.
			Rectangle {
				Layout.alignment: Qt.AlignRight
				Layout.preferredHeight: dismissText.implicitHeight + Theme.smallSpacing * 2
				Layout.preferredWidth: dismissText.implicitWidth + Theme.largeSpacing * 2
				radius: Theme.smallSpacing
				// Stronger fill than the panel so it reads as actionable; darkens
				// while pressed for click feedback.
				color: dismissMouse.pressed
					? Qt.alpha(Theme.negativeTextColor, 0.45)
					: Qt.alpha(Theme.negativeTextColor, 0.28)

				Text {
					id: dismissText
					anchors.centerIn: parent
					text: qsTr("Don't show this again")
					color: Theme.textColor
					font.pixelSize: Theme.smallFontSize
				}
				MouseArea {
					id: dismissMouse
					anchors.fill: parent
					cursorShape: Qt.PointingHandCursor
					onClicked: col.requestDismiss(col.astroFailureKey)
				}
			}
		}
	}

	Item { Layout.preferredHeight: Theme.smallSpacing }

	// ── 7Timer-unavailable badge ─────────────────────────────────────────
	Rectangle {
		Layout.fillWidth: true
		visible: {
			// meta.degraded is now a list of {source, reason?, code?} objects
			// (was a bare string list). The 7Timer badge fires when any entry's
			// source is "7timer"; the Astrospheric warning above keys off the
			// "astrospheric" source the same way, so a site whose paid feed AND
			// free seeing source both failed shows both notices.
			const m = col.site.meta;
			if (!m || !m.degraded) return false;
			for (let i = 0; i < m.degraded.length; i++) {
				const d = m.degraded[i];
				if (d && d.source === "7timer") return true;
			}
			return false;
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

		// Smoke / air quality (2026-06-25). AOD is the column-aerosol transparency
		// driver; AQI is the surface cross-check. Both from night.smoke. The ⚠
		// active-fire advisory rides the reasons list below, so it is not duplicated
		// here. "—" when no smoke data (a non-US site has no AQI; AOD may still show).
		FactorRow {
			label: qsTr("Smoke / AQI")
			value: {
				if (!col.night || !col.night.smoke) return "—";
				const s = col.night.smoke;
				let parts = [];
				if (s.aodMean !== undefined && s.aodMean !== null)
					parts.push("AOD " + s.aodMean.toFixed(2));
				if (s.usAqi !== undefined && s.usAqi !== null)
					parts.push("AQI " + s.usAqi);
				return parts.length ? parts.join(" · ") : "—";
			}
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
