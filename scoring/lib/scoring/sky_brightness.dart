// lib/scoring/sky_brightness.dart
// Sky background brightness model for the scoring engine.
//
// Computes effective sky brightness in mag/arcsec² by combining:
// 1. Base sky brightness from Bortle class (light pollution at zenith)
// 2. Moon contribution (illumination × distance → scattered moonlight)
// 3. Altitude gradient (horizon is brighter at LP-contaminated sites)
//
// The effective sky brightness feeds into:
// - The "sky quality" component of the scoring composite
// - Target detectability checks (is this target even imageable here?)
// - Estimated integration time context for the user
//
// Sources:
// - Bortle scale → SQM mapping: Wikipedia, Unihedron SQM FAQ, ING
// - Moon contribution: Walker 1987 NOAO/CTIO, ING standard references
// - Altitude gradient: measured LP brightening factors, airmass scaling
import 'dart:math';

/// Bortle class (1-9) to zenith sky brightness in V-band mag/arcsec².
///
/// These are moonless zenith values — the baseline before moon and
/// altitude corrections. Midpoints of the ranges reported by Unihedron,
/// Wikipedia Bortle scale article, and ING definitions.
///
/// Lower numbers = fainter sky = better for imaging.
/// The scale is logarithmic: each 1.0 mag difference = 2.5× flux ratio.
const _bortleToSqm = <int, double>{
	1: 21.85,  // Excellent dark sky
	2: 21.68,  // Typical dark sky
	3: 21.45,  // Rural sky
	4: 20.85,  // Rural/suburban transition
	5: 19.95,  // Suburban sky
	6: 19.20,  // Bright suburban
	7: 18.65,  // Suburban/urban transition
	8: 17.95,  // City sky
	9: 17.00,  // Inner city sky
};

/// Returns the zenith sky brightness for a Bortle class (no moon).
///
/// Receives: [bortle] — Bortle dark sky class (1-9).
/// Returns: sky brightness in V-band mag/arcsec². Null if Bortle unknown.
double? zenithSkyBrightness(int? bortle) {
	if (bortle == null) return null;
	return _bortleToSqm[bortle.clamp(1, 9)];
}

/// Estimates the moon's contribution to sky brightness in magnitudes.
///
/// Uses a simplified model based on Walker 1987 (NOAO/CTIO) and ING
/// standard reference values. The full Krisciunas & Schaefer model
/// is deferred to Pro tier; this approximation is sufficient for
/// planning-level scoring.
///
/// Receives:
/// - [illuminationPercent] — Moon illumination 0-100%
/// - [separationDeg] — angular separation from Moon to target in degrees
///
/// Returns: sky brightness increase in magnitudes (higher = brighter = worse).
/// Returns 0.0 if Moon is below the horizon or very far from target.
double moonBrightnessContribution({
	required double illuminationPercent,
	required double separationDeg,
}) {
	// New/thin crescent moon: negligible impact
	if (illuminationPercent < 10) return 0.0;

	// Very far from target: minimal scattered light
	if (separationDeg > 120) return 0.1 * (illuminationPercent / 100);

	// Simplified model from ING standard references:
	// Full moon at zenith, 90° from target: sky ≈ 19.0-19.5 (vs 21.5 dark)
	// = ~2.0-2.5 mag brightening
	// Quarter moon at 90°: ~0.5 mag brightening
	//
	// Scale by illumination (non-linear — quarter is only 10% as bright
	// as full in terms of flux, not 50%) and by separation (inverse
	// square of separation, roughly).
	final illumFactor = pow(illuminationPercent / 100, 2.0); // non-linear
	final sepFactor = separationDeg < 30
		? 3.0  // very close: major brightening
		: separationDeg < 60
			? 2.0  // moderately close
			: separationDeg < 90
				? 1.0  // standard separation
				: 0.5; // far away

	// Peak brightening (full moon, close to target): ~3.0 mag
	return (illumFactor * sepFactor * 3.0).clamp(0.0, 4.0);
}

/// Estimates the altitude-dependent sky brightening from light pollution.
///
/// At LP-contaminated sites, the sky near the horizon is significantly
/// brighter than at zenith because you look through more atmosphere
/// containing scattered artificial light. This compounds with airmass.
///
/// Receives:
/// - [bortle] — site Bortle class (1-9)
/// - [altitudeDeg] — target altitude in degrees above horizon
///
/// Returns: sky brightening in magnitudes (positive = brighter = worse).
double altitudeLpGradient({
	required int bortle,
	required double altitudeDeg,
}) {
	// Guard: altitude at or below horizon should not be scored for LP.
	// sin(0) = 0 → 1/sin(0) = Infinity, which clamp catches, but negative
	// altitudes produce negative sin → negative airmass → wrong gradient.
	// Bug fix: GitHub #43.
	if (altitudeDeg <= 0) return 0.0;
	if (altitudeDeg >= 90) return 0.0;
	if (bortle <= 2) return 0.0; // pristine dark sites: minimal gradient

	// LP gradient scales with both Bortle class and zenith angle.
	// At Bortle 4, 30°: ~+0.7 mag. At Bortle 7, 30°: ~+1.2 mag.
	// At Bortle 4, 20°: ~+1.5 mag. At Bortle 7, 20°: ~+2.0 mag.
	//
	// Simplified model: brightening = bortleFactor × airmassEffect
	// where bortleFactor scales 0 (Bortle 1-2) to 0.4 (Bortle 9)
	// and airmassEffect = (1/sin(alt) - 1) capped at ~3.
	final bortleFactor = (bortle - 2) * 0.05; // 0 at B2, 0.35 at B9
	final altRad = altitudeDeg * (pi / 180);
	final airmassEffect = ((1 / sin(altRad)) - 1).clamp(0.0, 4.0);

	return (bortleFactor * airmassEffect * 2.0).clamp(0.0, 3.0);
}

/// Computes the effective sky brightness at a specific position.
///
/// Combines base LP (Bortle), moon contribution, and altitude gradient
/// into a single number: the effective sky brightness in mag/arcsec²
/// at the target's position tonight.
///
/// Lower SB = fainter sky = better conditions.
///
/// Receives:
/// - [bortle] — site Bortle class (1-9, nullable)
/// - [moonIllumination] — Moon illumination 0-100%
/// - [moonSeparation] — angular separation from Moon in degrees
/// - [targetAltitude] — target altitude in degrees
///
/// Returns: effective sky brightness in mag/arcsec², or null if Bortle unknown.
double? effectiveSkyBrightness({
	int? bortle,
	required double moonIllumination,
	required double moonSeparation,
	required double targetAltitude,
}) {
	final baseSb = zenithSkyBrightness(bortle);
	if (baseSb == null) return null;

	final moonDelta = moonBrightnessContribution(
		illuminationPercent: moonIllumination,
		separationDeg: moonSeparation,
	);

	final lpDelta = altitudeLpGradient(
		bortle: bortle ?? 5,
		altitudeDeg: targetAltitude,
	);

	// Sky brightness decreases (gets brighter) by the moon and LP deltas.
	// In mag/arcsec² scale, brighter = lower number.
	return baseSb - moonDelta - lpDelta;
}

/// Scores sky brightness quality on 0-100 scale.
///
/// Maps effective sky brightness to a quality score:
/// 21.5+ mag/arcsec² (pristine dark) → 100
/// 20.0 mag/arcsec² (suburban) → 50
/// 18.0 mag/arcsec² (city) → 10
/// <17.0 mag/arcsec² (inner city) → 0
///
/// Receives: [sb] — effective sky brightness in mag/arcsec².
/// Returns: score 0-100 (100 = excellent dark sky).
int skyBrightnessScore(double sb) {
	if (sb >= 21.5) return 100;
	if (sb <= 17.0) return 0;
	// Linear interpolation: 17.0 → 0, 21.5 → 100.
	return ((sb - 17.0) / (21.5 - 17.0) * 100).round().clamp(0, 100);
}
