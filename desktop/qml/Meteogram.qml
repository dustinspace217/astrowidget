// Meteogram.qml — per-site hourly cloud-cover strip (desktop port).
//
// Filled area chart drawn with QML Canvas. X-axis = astro dark start→end;
// Y-axis = cloud cover 0–100%. Identical to the plasmoid version except the
// theme colors come from the Theme singleton instead of Kirigami.Theme.

import QtQuick
import "."

Canvas {
	id: meteo

	required property var site
	required property int nightIndex

	// Cloud-area color, pulled at draw time so the chart re-renders on a
	// night-vision toggle (Theme.highlightColor flips with it).
	property color cloudColor: Theme.highlightColor

	onSiteChanged: requestPaint()
	onNightIndexChanged: requestPaint()
	onCloudColorChanged: requestPaint()

	onPaint: {
		const ctx = getContext("2d");
		ctx.clearRect(0, 0, width, height);

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

		const start = Date.parse(night.dark_window.start);
		const end = Date.parse(night.dark_window.end);
		if (isNaN(start) || isNaN(end) || end <= start) {
			drawEmpty(ctx, qsTr("Bad dark window"));
			return;
		}

		const hours = night.hourly || site.hourly || [];
		const span = end - start;

		// Subtle horizontal grid at 0/50/100%.
		ctx.strokeStyle = Qt.alpha(Theme.textColor, 0.15);
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

		ctx.fillStyle = Qt.alpha(cloudColor, 0.6);
		ctx.beginPath();
		ctx.moveTo(0, height);

		let drewAny = false;
		for (let i = 0; i < hours.length; i++) {
			const h = hours[i];
			// Open-Meteo hourly timestamps carry NO timezone; dark_window.start/end
			// are UTC ("...Z"). Normalize the hourly time to UTC before comparing,
			// or every hour falls outside the window.
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

	// Faint background + a short reason so a blank chart is never silent.
	function drawEmpty(ctx, reason) {
		ctx.fillStyle = Qt.alpha(Theme.textColor, 0.08);
		ctx.fillRect(0, 0, width, height);
		if (reason) {
			ctx.fillStyle = Qt.alpha(Theme.textColor, 0.55);
			ctx.font = "11px sans-serif";
			ctx.textAlign = "center";
			ctx.textBaseline = "middle";
			ctx.fillText(reason, width / 2, height / 2);
		}
	}
}
