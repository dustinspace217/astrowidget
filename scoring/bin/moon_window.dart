// scoring/bin/moon_window.dart
// astrowidget's OWN per-night moon geometry + narrowband moon calibration (NOT vendored).
//
// WHY this exists (2026-06-29 calibration, 9,931 real subs — see
// ~/Claude/astrowidget-moon-scan/FINDINGS.md):
//  - AVERAGING: within a night, sky background tracks the moon's INSTANTANEOUS altitude at
//    r=0.96 (broadband). So a night's moon impact is the integral over the real rise/set
//    track, NOT the peak. The wrapper used to penalize by the peak altitude, which
//    over-charged every partial-moon night. `computeMoonGeometry` returns the time-averaged
//    burden basis (avgSinAlt) the wrapper feeds to the scorers via `effectiveMoonAltitudeDeg`.
//  - MOON-FREE WINDOW: the contiguous below-horizon gap is the broadband-usable window to
//    surface (and to score Moon-free BB over).
//  - NB MOON CALIBRATION: narrowband loses ~0.25× of broadband's moon depth-hit (measured).
//    `narrowbandMoonAdjustedSky` docks that in SCORE space — see its doc for why a magnitude
//    coupling fails (the score curve clamps at 21.5 mag, eating small NB brightenings).
import 'dart:math' as math;
import 'package:astrowidget_scoring/weather/weather_models.dart';

/// One moon-altitude sample at a point in the dark window.
class MoonSample {
	final DateTime time;
	final double altitudeDeg;
	const MoonSample({required this.time, required this.altitudeDeg});
}

/// The per-night moon geometry summary the wrapper needs.
class MoonNightGeometry {
	final double avgSinAlt;            // mean of max(0,sin(alt)) — the averaged burden basis
	final double maxAltDeg;            // peak altitude (display: max_alt_during_dark)
	final TimeWindow? moonFreeWindow;  // longest contiguous below-horizon run, else null
	final double freeFraction;         // moonFreeDuration / darkDuration, 0..1
	const MoonNightGeometry({
		required this.avgSinAlt,
		required this.maxAltDeg,
		required this.moonFreeWindow,
		required this.freeFraction,
	});
}

/// Summarize the moon's night from its 15-min altitude samples (pure; the wrapper does the
/// geoengine sampling). [samples] is bounded (dark window / 15 min ≈ ≤ ~100). [darkStart]/
/// [darkEnd] bound the moon-free fraction denominator.
///
/// avgSinAlt = mean of max(0,sin(alt)) (moon-down samples count 0). moonFreeWindow = the
/// LONGEST contiguous run of below-horizon samples (boundaries on the sample grid), surfaced
/// ONLY when it is a genuine partial gap (0 < freeFraction < 1) — a moon up all night has no
/// gap, and a moon down all night makes Moon-free BB == BB (redundant). freeFraction =
/// that run's duration / dark-window duration.
MoonNightGeometry computeMoonGeometry(
	List<MoonSample> samples,
	DateTime darkStart,
	DateTime darkEnd,
) {
	if (samples.isEmpty) {
		return const MoonNightGeometry(
			avgSinAlt: 0, maxAltDeg: -90, moonFreeWindow: null, freeFraction: 0);
	}
	var sumSin = 0.0;
	var maxAlt = -90.0;
	// Longest contiguous below-horizon (alt<0) run on the sample grid.
	DateTime? runStart;
	DateTime? bestStart;
	DateTime? bestEnd;
	var best = Duration.zero;
	void closeRun(DateTime end) {
		if (runStart != null) {
			final d = end.difference(runStart!);
			if (d > best) {
				best = d;
				bestStart = runStart;
				bestEnd = end;
			}
			runStart = null;
		}
	}

	for (final s in samples) {
		final sinAlt = math.sin(s.altitudeDeg * math.pi / 180);
		sumSin += sinAlt > 0 ? sinAlt : 0.0;
		if (s.altitudeDeg > maxAlt) maxAlt = s.altitudeDeg;
		if (s.altitudeDeg < 0) {
			runStart ??= s.time; // open a below-horizon run
		} else {
			closeRun(s.time); // moon rose → close the run at this sample
		}
	}
	closeRun(samples.last.time); // close a run that reaches the window end

	final darkMs = darkEnd.difference(darkStart).inMilliseconds;
	final freeFraction =
		darkMs <= 0 ? 0.0 : (best.inMilliseconds / darkMs).clamp(0.0, 1.0);
	// Surface the window only for the genuine partial case (see doc above).
	final showWindow =
		bestStart != null && freeFraction > 0.0 && freeFraction < 1.0;
	return MoonNightGeometry(
		avgSinAlt: sumSin / samples.length,
		maxAltDeg: maxAlt,
		moonFreeWindow:
			showWindow ? TimeWindow(start: bestStart!, end: bestEnd!) : null,
		freeFraction: freeFraction,
	);
}

/// Invert sin so `moonBurden(illum, this) == illum × avgSinAlt` (the averaged burden). The
/// scorers take a single altitude and compute burden internally; passing this effective
/// altitude makes them use the time-AVERAGE without any engine signature change.
double effectiveMoonAltitudeDeg(double avgSinAlt) =>
	math.asin(avgSinAlt.clamp(0.0, 1.0)) * 180 / math.pi;

/// Empirical narrowband MOON coupling (2026-06-29 calibration, 9,931 subs): narrowband loses
/// 0.25× of broadband's moon depth-hit.
const double nbMoonCouplingDefault = 0.25;

/// Narrowband sky sub-score with the moon docked in SCORE space.
///
/// WHY score-space and not a magnitude coupling inside narrowbandSkyScore: the score curve
/// clamps at 21.5 mag (any darker sky → 100). Narrowband's sky is ~pristine (21.85), so it
/// sits AT the clamp; a small magnitude coupling spends its first ~0.35 mag getting from
/// pristine to 21.5 before any of it registers as a score drop — collapsing the realized
/// NB/BB drop ratio to ~0.1 (worse at dark sites). Docking in score space avoids the clamp.
///
/// `nbSky = nbSkyNoMoon − coupling × (bbSkyNoMoon − bbSkyMoon)`. Reproduces the measured 0.25
/// drop ratio at every site, and preserves NB ≥ BB: nbSkyNoMoon ≥ bbSkyNoMoon (NB rejects
/// LP/snow) and coupling·drop ≤ drop, so the result ≥ bbSkyMoon.
///
/// Receives: [nbSkyNoMoon] narrowbandSkyScore with the moon OFF (LP/snow only); [bbSkyNoMoon]
/// locationSkyBrightnessScore with the moon OFF; [bbSkyMoon] the engine's BB sky (with the
/// averaged moon); [coupling] the calibrated 0.25. Returns: 0–100.
int narrowbandMoonAdjustedSky(
	int nbSkyNoMoon,
	int bbSkyNoMoon,
	int bbSkyMoon, {
	double coupling = nbMoonCouplingDefault,
}) {
	final bbMoonDrop = bbSkyNoMoon - bbSkyMoon; // ≥ 0 (moon never brightens)
	return (nbSkyNoMoon - coupling * bbMoonDrop).round().clamp(0, 100);
}
