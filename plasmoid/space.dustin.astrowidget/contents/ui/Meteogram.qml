// Meteogram.qml — per-site hourly cloud-cover strip.
//
// Filled area chart drawn with QML Canvas. X-axis = hours from astro dark
// start to astro dark end; Y-axis = cloud cover 0–100%. Single accent
// color (theme-driven). No third-party charting library — keeps the
// plasmoid lightweight and avoids licensing surface for KDE Store.

import QtQuick
import org.kde.kirigami as Kirigami

Canvas {
	id: meteo

	// Inputs.
	required property var site
	required property int nightIndex

	// Theme color used for the cloud area. Pulled at draw time so the
	// chart re-renders if the user switches Plasma themes.
	property color cloudColor: Kirigami.Theme.highlightColor

	// Recomputed list of (x_frac, cloud_pct) tuples for the dark window.
	// QML doesn't auto-trigger paint on canvas reassignment, so we requestPaint()
	// when inputs change.
	onSiteChanged: requestPaint()
	onNightIndexChanged: requestPaint()
	onCloudColorChanged: requestPaint()

	onPaint: {
		const ctx = getContext("2d");
		ctx.clearRect(0, 0, width, height);

		// Defensive: bail if no data.
		if (!site || site.status !== "ok" || !site.nights
		    || site.nights.length <= nightIndex) {
			drawEmpty(ctx, qsTr("Site error"));
			return;
		}
		const night = site.nights[nightIndex];
		if (!night || !night.dark_window) {
			drawEmpty(ctx, qsTr("No astro dark"));
			return;
		}

		// Find hourly entries that fall inside the dark window. The fetcher
		// passes a flat hourly array per night via the state.json; the dark
		// window's start/end are ISO timestamps we compare against each
		// hour's timestamp.
		const start = Date.parse(night.dark_window.start);
		const end = Date.parse(night.dark_window.end);
		if (isNaN(start) || isNaN(end) || end <= start) {
			drawEmpty(ctx, qsTr("Bad dark window"));
			return;
		}

		// Pull hourly data from the raw site forecast. In v1 the scoring
		// binary doesn't echo hourly cloud back, so we look at the
		// scoring input that the fetcher attached. If absent, draw empty.
		const hours = night.hourly || site.hourly || [];
		const span = end - start;

		// Background — subtle horizontal grid lines at 0/50/100%.
		ctx.strokeStyle = Qt.alpha(Kirigami.Theme.textColor, 0.15);
		ctx.lineWidth = 1;
		ctx.beginPath();
		ctx.moveTo(0, height); ctx.lineTo(width, height);
		ctx.moveTo(0, height / 2); ctx.lineTo(width, height / 2);
		ctx.moveTo(0, 0); ctx.lineTo(width, 0);
		ctx.stroke();

		if (hours.length === 0) {
			drawEmpty(ctx, qsTr("No hourly data"));
			return;
		}

		// Filled area: walk hours that fall within [start, end], plot.
		ctx.fillStyle = Qt.alpha(cloudColor, 0.6);
		ctx.beginPath();
		ctx.moveTo(0, height);

		let drewAny = false;
		for (let i = 0; i < hours.length; i++) {
			const h = hours[i];
			// Open-Meteo hourly timestamps carry NO timezone ("2026-05-30T07:00"),
			// which Date.parse treats as LOCAL time — but dark_window.start/end
			// are UTC ("...Z"). Comparing the two directly excluded every hour
			// (local 07:00 = 14:00 UTC, outside the window) → "No hours in
			// window". Normalize the hourly time to UTC before comparing.
			const tstr = (h.time && h.time.indexOf("Z") < 0 && h.time.indexOf("+") < 0)
				? (h.time + "Z") : h.time;
			const t = Date.parse(tstr);
			if (isNaN(t) || t < start || t > end) continue;
			const xFrac = (t - start) / span;
			const x = xFrac * width;
			const cloudPct = Math.max(0, Math.min(100, h.cloud_cover || 0));
			const y = height - (cloudPct / 100.0) * height;
			ctx.lineTo(x, y);
			drewAny = true;
		}
		if (drewAny) {
			ctx.lineTo(width, height);
			ctx.closePath();
			ctx.fill();
		} else {
			drawEmpty(ctx, qsTr("No hours in window"));
		}
	}

	// Renders a faint background with a short reason so a blank chart is
	// never silent. Distinguishes "no astro dark tonight" from "missing
	// data" — different causes call for different responses from the user.
	function drawEmpty(ctx, reason) {
		ctx.fillStyle = Qt.alpha(Kirigami.Theme.textColor, 0.08);
		ctx.fillRect(0, 0, width, height);
		if (reason) {
			ctx.fillStyle = Qt.alpha(Kirigami.Theme.textColor, 0.55);
			ctx.font = "11px sans-serif";
			ctx.textAlign = "center";
			ctx.textBaseline = "middle";
			ctx.fillText(reason, width / 2, height / 2);
		}
	}
}
