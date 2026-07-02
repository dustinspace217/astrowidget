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
// (The narrowband moon response lives in retention.dart as of 2026-07-01 — see the note
// at the bottom of this file.)
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

/// A moon-free window shorter than this isn't a real broadband opportunity, and slicing the
/// seeing factor over a <1h window hits the engine's degenerate-stability sentinel (which made
/// Moon-free BB read a misleading 50 on a 15-min dawn gap — caught by running the real binary
/// 2026-06-29). 60 min ≈ a usable LRGB stint. freeFraction still reports the true proportion.
const int _minMoonFreeWindowMinutes = 60;

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
	// Close a run still open at the end against darkEnd, NOT samples.last: the 15-min grid
	// stops short of darkEnd (dark windows aren't 15-min multiples), so measuring a
	// moon-down-all-night run to the last sample undercounts it to freeFraction ≈ 0.96 < 1.0,
	// which defeats the freeFraction<1 guard and spuriously surfaces a redundant whole-night
	// "moon-free" window (QA 2026-06-30, found by adversarial-tester + code-reviewer).
	closeRun(darkEnd);

	final darkMs = darkEnd.difference(darkStart).inMilliseconds;
	final freeFraction =
		darkMs <= 0 ? 0.0 : (best.inMilliseconds / darkMs).clamp(0.0, 1.0);
	// Surface the window only for a genuine, USABLE partial gap: not the whole night
	// (freeFraction 0/1 → no gap / redundant with BB), and at least _minMoonFreeWindowMinutes
	// long (sub-hour slivers aren't imaging opportunities and degenerate the sliced seeing).
	final showWindow = bestStart != null &&
		freeFraction > 0.0 &&
		freeFraction < 1.0 &&
		best.inMinutes >= _minMoonFreeWindowMinutes;
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

// NOTE (2026-07-01): the score-space NB moon dock (narrowbandMoonAdjustedSky, 0.25
// coupling) that briefly lived here was SUPERSEDED by the retention-v2 composite
// (retention.dart): the narrowband response now comes from the calibrated effective flux
// leakage L=0.38 inside one unified sky model. Removed rather than kept dormant.
