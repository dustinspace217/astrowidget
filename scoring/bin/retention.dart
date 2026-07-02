// scoring/bin/retention.dart
// astrowidget's OWN retention-v2 composite (NOT vendored). Spec:
// docs/superpowers/specs/2026-07-01-scoring-v2-retention-composite.md
//
// WHY this exists (Dustin's four-corner requirement, 2026-07-01): the score must be an
// AMALGAMATION of all effects that COMPOUNDS — moonless-cloudless best, fullmoon-cloudy
// worst. A weighted arithmetic mean cannot do that: three good factors vote a bad one back
// up (the dilution that let UDRO read BB 85 under a 98% moon — a ~30% measured depth loss
// showing up as ~6% of score). A worst-effect gate can't either: it throws away the second
// problem. So v2 multiplies RETENTIONS — each effect's surviving fraction of the night's
// imaging value, with typical-good ≈ 1.0 so nothing pads, and every real degradation
// multiplying the whole score down. score_band = 100 × Π(retention_i), and that identity is
// tested — the emitted audit block makes every score reconstructable by inspection.
//
// CALIBRATION PROVENANCE (all from Dustin's 9,931-sub library study,
// ~/Claude/astrowidget-moon-scan/ + /tmp/claude/{pass2_weather,calibrate_aod,fit_joint}.py):
//  - Cloud costs TIME, not per-sub depth: depth retention measured ~1.0 in EVERY ERA5
//    cloud bin (subs punch through gaps at full quality or don't exist). So cloud enters
//    as usable-time fraction and never double-counts the quality terms.
//  - Sky brightness (moon + light pollution + snow, flux-composited) costs DEPTH at
//    S = 0.25 per magnitude of brightening (BB depth bins fit ±3 pts).
//  - Narrowband sees L = 0.38 of the excess sky FLUX (fit ±2 pts). Effective, not the
//    theoretical 3nm ~0.05 — the library spans older/wider filters, halos, real optics.
//  - Transparency: measured depth-vs-AOD curve (monotonic, 4,543 moonless subs).
//  - Seeing: NOT calibratable yet (no 250 hPa history source — probed 2026-07-01);
//    principled gentle curve, the least-grounded term here, both bands share it.
import 'dart:math' as math;
import 'package:astrowidget_scoring/scoring/sky_brightness.dart';
import 'package:astrowidget_scoring/weather/weather_models.dart';

// ── Calibrated constants (do not tune casually — each traces to the fit above) ──

/// Depth lost per magnitude of sky brightening (S). BB moon-depth bins, joint fit.
const double depthPerMag = 0.25;

/// Effective narrowband leakage (L): fraction of excess sky FLUX the NB path sees.
/// Overridable per-run via the existing stdin `nb_leakage` knob (leakage=1 ⇒ NB==BB,
/// which keeps the composite-parity guard test meaningful).
const double nbEffectiveLeakage = 0.38;

/// Measured depth-retention vs window-mean AOD (calibrate_aod.py). Piecewise-linear.
const List<List<double>> _aodCurve = [
	[0.05, 1.00],
	[0.10, 0.99],
	[0.20, 0.96],
	[0.40, 0.78],
	[0.60, 0.65],
];

// Physics constants — same values as the vendored sky model (keep in sync).
const double _pristineSb = 21.85;
const double _defaultZenithSb = 20.5;
const double _moonMaxDeltaMag = 3.0;
const double _snowGain = 0.3;

// Floors. A retention of exactly 0 would make the composite blind to every OTHER effect
// (0 × anything = 0), so floors keep the product ordered even in the mud. The transparency
// floor is 0.15, NOT the curve's last measured point (0.65 at AOD 0.6): wildfire-grade
// AOD (1.5-5) is far beyond the measured range and physically devastating for imaging
// (AOD 2 ≈ e⁻² ≈ 13% transmission), so the extrapolation continues the measured slope
// down to 0.15 rather than flattening at 0.65-ish — a clear heavy-smoke night must read
// dontBother, not marginal (QA 2026-07-01, silent-failure-hunter). The fire dock
// multiplies SEPARATELY (below the floor is fine — the floor orders the AOD term only).
const double _timeRetFloor = 0.02;
const double _skyRetFloor = 0.05;
const double _transpRetFloor = 0.15;
const double _seeingRetFloor = 0.85;

/// One band's retention set. `score` is ALWAYS round(100·product) — the audit identity.
class BandRetentions {
	final double timeCloud;
	final double sky;
	final double transparency;
	final double seeing;
	final double skyDeltaMag; // emitted for audit: the brightening the sky term saw
	const BandRetentions({
		required this.timeCloud,
		required this.sky,
		required this.transparency,
		required this.seeing,
		required this.skyDeltaMag,
	});
	double get product => timeCloud * sky * transparency * seeing;
	int get score => (100 * product).round().clamp(0, 100);

	/// Audit form for state.json (spec §4): retentions + the sky Δmag behind them.
	Map<String, dynamic> toJson() => {
		'retentions': {
			'timeCloud': _r3(timeCloud),
			'sky': _r3(sky),
			'transparency': _r3(transparency),
			'seeing': _r3(seeing),
		},
		'skyDeltaMag': _r3(skyDeltaMag),
	};
}

double _r3(double v) => (v * 1000).round() / 1000;

/// Both bands, composited from the same night inputs.
class NightRetentions {
	final BandRetentions broadband;
	final BandRetentions narrowband;
	const NightRetentions({required this.broadband, required this.narrowband});
}

/// Cloud = usable-TIME fraction (measured finding: cloud deletes minutes, not sub
/// quality). cloudFactor is the engine's existing 0-100 cloud factor over the window.
double timeRetention(int cloudFactor) =>
	(cloudFactor / 100.0).clamp(_timeRetFloor, 1.0);

/// Excess sky FLUX above pristine (ratio − 1) from light pollution + moon + snow.
/// Fluxes ADD physically (the engine's mag-space model subtracts mags, which multiplies
/// fluxes and overstates combined brightening — v2 composes in flux space; at the dark
/// sites where the calibration lives the two agree, which anchors S either way).
/// Snow reflects the moon+LP brightening back up (existing model's gain, flux-applied).
double _excessSkyFlux({
	required double avgBurden,
	int? bortle,
	double snowDepthM = 0.0,
}) {
	final baseSb = zenithSkyBrightness(bortle) ?? _defaultZenithSb;
	final lpExcessMag = (_pristineSb - baseSb).clamp(0.0, 5.0);
	final moonDeltaMag = avgBurden.clamp(0.0, 1.0) * _moonMaxDeltaMag;
	final lpFlux = math.pow(10, lpExcessMag / 2.5).toDouble() - 1.0;
	final moonFlux = math.pow(10, moonDeltaMag / 2.5).toDouble() - 1.0;
	final snowAmp = snowDepthM > 0.01 ? (1.0 + _snowGain) : 1.0;
	return (lpFlux + moonFlux) * snowAmp;
}

/// Flux excess → magnitudes of brightening.
double _fluxToDeltaMag(double excessFlux) =>
	2.5 * (math.log(1.0 + math.max(0.0, excessFlux)) / math.ln10);

/// Depth retention from sky brightening: the ONE calibrated sky constant.
double skyRetention(double deltaMag) =>
	(1.0 - depthPerMag * deltaMag).clamp(_skyRetFloor, 1.0);

/// Measured AOD curve (piecewise-linear, clamped flat below the first point, sloped to
/// the floor beyond the last) × the FIRMS fire dock. null AOD → the AOD term is 1.0
/// (multiplicative identity IS the omit-not-zero rule — absence of data must never read
/// as haze) but the FIRE term still docks: in a product it can never raise a score, and
/// the original smoke incident WAS a nearby fire with under-resolved AOD (spec deviation,
/// 2026-07-01).
double transparencyRetention(double? aodMean, int firePenalty) {
	double aodRet;
	if (aodMean == null || aodMean.isNaN) {
		// NaN guard: the wrapper's aodWindowMean strips NaN, but a direct caller must not
		// silently score NaN as "perfectly clear" via the fall-through init below.
		aodRet = 1.0;
	} else if (aodMean <= _aodCurve.first[0]) {
		aodRet = _aodCurve.first[1];
	} else if (aodMean >= _aodCurve.last[0]) {
		// Continue the last measured segment's slope down to the 0.15 floor — heavy smoke
		// keeps hurting past the measured range (see the floors comment above).
		final a = _aodCurve[_aodCurve.length - 2];
		final b = _aodCurve.last;
		final slope = (b[1] - a[1]) / (b[0] - a[0]);
		aodRet = (b[1] + slope * (aodMean - b[0])).clamp(_transpRetFloor, 1.0);
	} else {
		aodRet = 1.0;
		for (var i = 0; i < _aodCurve.length - 1; i++) {
			final a = _aodCurve[i];
			final b = _aodCurve[i + 1];
			if (aodMean >= a[0] && aodMean <= b[0]) {
				final t = (aodMean - a[0]) / (b[0] - a[0]);
				aodRet = a[1] + t * (b[1] - a[1]);
				break;
			}
		}
	}
	final fireRet = (1.0 - firePenalty.clamp(0, 100) / 100.0);
	return (aodRet * fireRet).clamp(0.0, 1.0);
}

/// Window-mean aerosol optical depth — the transparency retention's input.
///
/// Receives: [airQuality] hourly rows (nullable — many sites have no air-quality feed);
/// the window bounds. Returns: the mean of the non-null, non-NaN AOD readings inside the
/// window, or null when there are none. The CALLER decides what null means: for the
/// headline night it should warn on stderr when a feed exists but yielded nothing (a
/// degraded feed silently reading "clear" during a smoke event is the failure mode this
/// project exists to prevent); for a sub-window slice it should fall back to the night
/// mean (data known at the night level must not vanish in the slice).
double? aodWindowMean(
	List<AirQuality>? airQuality,
	DateTime start,
	DateTime end,
) {
	if (airQuality == null || airQuality.isEmpty) return null;
	var total = 0.0;
	var count = 0;
	for (final aq in airQuality) {
		if (aq.time.isBefore(start) || aq.time.isAfter(end)) continue;
		final aod = aq.aerosolOpticalDepth;
		if (aod == null || aod.isNaN) continue;
		total += aod;
		count++;
	}
	return count == 0 ? null : total / count;
}

/// Seeing: gentle and least-grounded (see header). Typical (≥60) = 1.0; the worst
/// surface/jet blend costs 15% — seeing hurts resolution more than the depth this
/// score tracks. Recalibrate when a 250 hPa history source exists.
double seeingRetention(int stabilityFactor) {
	if (stabilityFactor >= 60) return 1.0;
	return (1.0 - 0.15 * (60 - stabilityFactor) / 60.0)
		.clamp(_seeingRetFloor, 1.0);
}

/// The v2 composite: both bands from one set of night inputs.
///
/// Receives: [cloudFactor]/[stabilityFactor] — the engine's existing 0-100 factors over
/// the scored window; [avgBurden] — illumination × mean(sin alt) from the moon-window
/// geometry; [bortle] site class (null → default baseline); [snowDepthM] window-mean snow;
/// [aodMean] window-mean AOD or null; [firePenalty] the engine's FIRMS dock (0-25);
/// [nbLeakage] the NB flux leakage (config-overridable; default the calibrated 0.38).
/// Returns: [NightRetentions]; each band's `score` == round(100 × Π retentions).
NightRetentions compositeRetentions({
	required int cloudFactor,
	required double avgBurden,
	required int? bortle,
	required double snowDepthM,
	required double? aodMean,
	required int firePenalty,
	required int stabilityFactor,
	double nbLeakage = nbEffectiveLeakage,
}) {
	final excess = _excessSkyFlux(
		avgBurden: avgBurden, bortle: bortle, snowDepthM: snowDepthM);
	final dmagBB = _fluxToDeltaMag(excess);
	final dmagNB = _fluxToDeltaMag(nbLeakage.clamp(0.0, 1.0) * excess);
	final time = timeRetention(cloudFactor);
	final transp = transparencyRetention(aodMean, firePenalty);
	final seeing = seeingRetention(stabilityFactor);
	return NightRetentions(
		broadband: BandRetentions(
			timeCloud: time, sky: skyRetention(dmagBB),
			transparency: transp, seeing: seeing, skyDeltaMag: dmagBB),
		narrowband: BandRetentions(
			timeCloud: time, sky: skyRetention(dmagNB),
			transparency: transp, seeing: seeing, skyDeltaMag: dmagNB),
	);
}
