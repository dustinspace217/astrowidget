// lib/scoring/scoring_engine.dart
// Composite scoring engine for astrophotography session planning.
//
// This is the brain of Plan 3 — it takes weather data, astronomical geometry,
// and rig specs, then produces scores, verdicts, and human-readable reasoning
// for both individual targets and entire locations.
//
// Two main entry points:
//   scoreTarget()   — "How good is tonight for imaging THIS target?"
//   scoreLocation() — "Is it worth going out tonight at THIS site?"
//
// All functions are pure — no HTTP, database, or framework deps.
// Plan 4 wraps these in Riverpod providers for the UI.
//
// Calibration data for all scoring thresholds is documented in
// docs/research/scoring-calibration-research.md — that document contains
// the empirical basis (atmospheric science literature, observatory data,
// astrophotography community surveys) for every constant in this file.
// Consult it before changing any scoring thresholds.
import 'dart:math';
import '../seeing/seeing_result.dart';
import '../visual/observing_intent.dart';
import '../weather/weather_models.dart';
import 'intents/visual_factors.dart';
import 'veto_evaluator.dart';
import '../weather/atmospheric_stability.dart';
import '../astro/visibility.dart';
import '../astro/moon_geometry.dart';
import 'sky_brightness.dart';
import 'target_type.dart';
import 'weight_profile.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Output types
// ─────────────────────────────────────────────────────────────────────────────

/// Overall quality verdict based on the composite score.
///
/// Thresholds (inclusive lower bound):
///   80-100 → Excellent, 60-79 → Good, 40-59 → Marginal,
///   20-39 → Poor, 0-19 → Don't Bother.
enum Verdict {
	/// 80-100: Outstanding conditions — go image.
	excellent,

	/// 60-79: Solid conditions — worth going out.
	good,

	/// 40-59: Compromised but usable — weigh effort vs reward.
	marginal,

	/// 20-39: Significantly degraded — only if desperate.
	poor,

	/// 0-19: Conditions are hostile — stay home.
	dontBother;

	/// Converts a numeric score (0-100) to a [Verdict].
	///
	/// Receives: [score] — composite score in the range 0-100.
	/// Returns: the corresponding [Verdict] enum value.
	static Verdict fromScore(int score) {
		if (score >= 80) return Verdict.excellent;
		if (score >= 60) return Verdict.good;
		if (score >= 40) return Verdict.marginal;
		if (score >= 20) return Verdict.poor;
		return Verdict.dontBother;
	}
}

/// Result of scoring one target for one night at one location.
///
/// Contains the composite score, verdict, per-factor breakdown,
/// the final adjusted weights (for transparency), and reasoning strings
/// that explain what helped or hurt.
class TargetScore {
	/// Composite score (0-100). Higher = better conditions.
	final int score;

	/// Overall quality verdict derived from [score].
	final Verdict verdict;

	/// Human-readable explanations of what factors helped or hurt.
	/// Populated for each significant factor — not raw numbers,
	/// but sentences like "Clear skies forecast, < 10% cloud cover."
	final List<String> reasons;

	/// Individual factor scores (0-100 each) keyed by factor name.
	/// Keys: 'cloud', 'stability', 'darkness', 'moon', 'altitude', 'rig', 'smoke'.
	final Map<String, int> factorScores;

	/// The final weight profile used for scoring (after object/rig/mode adjustments).
	/// Exposed for UI transparency — shows which factors were weighted how.
	final WeightProfile adjustedWeights;

	/// Rig-specific warnings, separate from weather reasoning.
	/// E.g., "Your 70mm scope can't resolve this target's fine detail."
	final List<String> rigWarnings;

	/// Creates a [TargetScore].
	const TargetScore({
		required this.score,
		required this.verdict,
		required this.reasons,
		required this.factorScores,
		required this.adjustedWeights,
		this.rigWarnings = const [],
	});
}

/// Result of scoring a location for general imaging tonight.
///
/// Simpler than [TargetScore] — no target-specific factors.
/// Used for "Which Site Tonight?" multi-location comparison.
class LocationScore {
	/// Composite score (0-100). Higher = better conditions.
	final int score;

	/// Overall quality verdict.
	final Verdict verdict;

	/// The best window within the night for imaging.
	/// Identifies the clearest, calmest stretch of hours.
	/// Null if conditions are uniformly bad.
	final TimeWindow? bestWindow;

	/// Human-readable explanations of the location's conditions.
	final List<String> reasons;

	/// Individual factor scores keyed by factor name.
	/// Keys: 'cloud', 'stability', 'darkness', 'moon'.
	final Map<String, int> factorScores;

	/// Creates a [LocationScore].
	const LocationScore({
		required this.score,
		required this.verdict,
		this.bestWindow,
		required this.reasons,
		required this.factorScores,
	});
}

// ─────────────────────────────────────────────────────────────────────────────
// Private scoring helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Linearly maps a value from one range to a 0-100 score.
///
/// When [value] equals [good], returns 100. When [value] equals [bad],
/// returns 0. Values beyond the range are clamped.
///
/// [good] and [bad] can be in either order — the function handles both
/// "lower is better" and "higher is better" semantics.
///
/// Receives:
/// - [value] — the input value to score
/// - [good] — the value that maps to score 100
/// - [bad] — the value that maps to score 0
///
/// Returns: an integer score clamped to 0-100.
int _linearScore(double value, {required double good, required double bad}) {
	if (good == bad) return 100;
	// Normalize to 0.0 (bad) → 1.0 (good).
	final t = (value - bad) / (good - bad);
	return (t.clamp(0.0, 1.0) * 100).round();
}

/// Computes the cloud cover factor score (0-100) from hourly weather data.
///
/// Total cloud cover is the primary signal (0% → 100, 100% → 0). Layer data
/// adds nuance — mid clouds (opaque blockers) and low clouds get extra penalty
/// when they're present. High cirrus is excluded here because it affects
/// transparency (captured separately in [_transparencyScore]).
///
/// The total-cloud floor ensures that 95% total cover doesn't score well
/// just because the layer breakdown is sparse: the per-layer score is capped
/// by the total-cloud score.
///
/// Averages the per-hour scores across the effective window.
///
/// Maps the cached derived-seeing result (if any) to a 0-100 score.
///
/// Returns null when derived seeing is unusable — in which case the
/// caller falls back to the atmospheric-stability proxy
/// ([StabilityAssessment.score]). "Unusable" is:
///   - null (legacy cache entry predating Phase E, or unknown JSON
///     discriminator from SeeingResult.fromJson's forward-compat guard)
///   - [SeeingResultUnavailable] (required inputs were missing, or the
///     pressure-level fetch failed — seeing cannot be computed)
///
/// Mapping from arcsec to 0-100:
///   - 1.0″ or better  → 100 (rare — excellent dark-site night)
///   - 2.5″ (typical middling night) → 50
///   - 4.0″ or worse   → 0   (poor seeing — planetary imaging hopeless)
/// The 1.0–4.0″ domain matches the calibrated seeing range in
/// DerivedSeeingCoefficients comments; the inversion is intentional
/// (smaller arcsec = better seeing).
///
/// Clamped to [0, 100] so a pathological input (e.g., a calibration
/// coefficient flip producing negative arcsec) can't push the
/// composite score out of range.
int? _derivedSeeingScore(WeatherForecast forecast) {
	final seeing = forecast.derivedSeeing;
	if (seeing is! SeeingResultAvailable) return null;
	// Reject non-finite inputs. A NaN or Infinity arcsec (from
	// corrupt cache, a buggy upstream coefficient, or a malformed JSON
	// round-trip) would break the arithmetic below — num.clamp on NaN
	// returns NaN, and .round() on NaN throws UnsupportedError. Caught
	// in Phase E Task 9 adversarial review. Returning null here lets
	// the caller fall back to the stability proxy, which is the same
	// graceful path used for null / SeeingResultUnavailable.
	if (!seeing.arcsec.isFinite) return null;
	// Linear remap: 1.0″ → 100, 4.0″ → 0. Simple is right for v1;
	// calibrated curve comes in Plan 6b from beta data.
	final raw = ((4.0 - seeing.arcsec) / 3.0) * 100.0;
	return raw.clamp(0, 100).round();
}

/// Receives:
/// - [hours] — hourly weather data during the effective window
///
/// Returns: cloud score 0-100 (100 = perfectly clear, 0 = fully overcast).
int _cloudScore(List<HourlyWeather> hours) {
	// Empty hours means "no weather data for this window" — NOT "clear skies."
	// Return 50 (unknown/degraded) instead of 100 (excellent).
	// Bug fix: GitHub #49.
	if (hours.isEmpty) return 50;

	var total = 0.0;
	for (final h in hours) {
		// Total cloud cover score — the primary signal.
		// 0% cloud → 100, 100% cloud → 0.
		final totalScore = _linearScore(h.cloudCover, good: 0, bad: 100);

		// Layer-based nuance: mid and low clouds are hard blockers.
		// High cirrus is handled separately in _transparencyScore.
		final lowScore = _linearScore(h.cloudCoverLow, good: 0, bad: 100);
		final midScore = _linearScore(h.cloudCoverMid, good: 0, bad: 100);
		final layerScore = (lowScore * 0.45 + midScore * 0.55);

		// Blend layers with total; cap by total so sparse layer data
		// doesn't inflate the score when total cloud is high.
		final blendedScore = (totalScore * 0.6 + layerScore * 0.4);
		// The total score is the ceiling: 95% total can't score above 5.
		final hourScore = min(totalScore.toDouble(), blendedScore);
		total += hourScore;
	}
	return (total / hours.length).round();
}

/// Computes a sky transparency score (0-100) from high-altitude cirrus data.
///
/// Cirrus clouds (8+ km) don't physically block targets but destroy
/// transparency, seriously degrading faint-object (DSO) imaging while
/// barely affecting bright objects like planets.
///
/// This score feeds into the smoke/transparency factor so that DSO (weight 1.0)
/// is penalised more than planetary (weight 0.3) under the same cirrus.
///
/// When explicit air quality data is available, [_smokeScore] takes over and
/// this function's result is not used.
///
/// Receives:
/// - [hours] — hourly weather data during the effective window
///
/// Returns: transparency score 0-100 (100 = no cirrus), or null if all
/// hours report 0% high cloud (clear/no data — don't impose a penalty).
int? _cirrusTransparencyScore(List<HourlyWeather> hours) {
	if (hours.isEmpty) return null;

	// Only compute a cirrus penalty when at least one hour has measurable
	// high cloud cover. If every hour reports 0%, return null (no penalty).
	final hasCirrus = hours.any((h) => h.cloudCoverHigh > 0);
	if (!hasCirrus) return null;

	var total = 0.0;
	for (final h in hours) {
		// 0% cirrus → 100 (perfect), 35%+ cirrus → 0 (session-ruining for DSO).
		// Cirrus hurts more steeply than opaque clouds because it degrades
		// transparency while looking deceptively "clear." Threshold raised
		// from 35% to 50%: 35% was too punitive for moderate cirrus which
		// degrades but doesn't ruin sessions for anything except the faintest
		// low-surface-brightness objects. 50% cirrus still scores ~0.
		final hourScore = _linearScore(h.cloudCoverHigh, good: 0.0, bad: 50.0);
		total += hourScore;
	}
	return (total / hours.length).round();
}

/// Computes the darkness factor score (0-100).
///
/// Measures what proportion of the effective window falls within
/// astronomical darkness (sun below -18°).
///
/// Receives:
/// - [effectiveStart] — start of the effective scoring window (UTC)
/// - [effectiveEnd] — end of the effective scoring window (UTC)
/// - [darkWindow] — the night's astronomical dark window
///
/// Returns: darkness score 0-100 (100 = entire window is dark).
int _darknessScore(
	DateTime effectiveStart,
	DateTime effectiveEnd,
	DarkWindow darkWindow,
) {
	if (darkWindow.start == null || darkWindow.end == null) return 0;

	// Find overlap between effective window and dark window.
	final overlapStart = effectiveStart.isAfter(darkWindow.start!)
		? effectiveStart
		: darkWindow.start!;
	final overlapEnd = effectiveEnd.isBefore(darkWindow.end!)
		? effectiveEnd
		: darkWindow.end!;

	if (overlapEnd.isBefore(overlapStart) || overlapEnd == overlapStart) return 0;

	final effectiveDuration = effectiveEnd.difference(effectiveStart).inMinutes;
	if (effectiveDuration <= 0) return 0;

	final overlapDuration = overlapEnd.difference(overlapStart).inMinutes;
	return ((overlapDuration / effectiveDuration) * 100).round().clamp(0, 100);
}

/// Converts a [MoonSeverity] to a factor score (0-100).
///
/// Mapping: none → 100, low → 75, moderate → 40, severe → 5.
///
/// Moderate lowered from 50 → 40: sky background increase from moonlight
/// is non-linear (SNR degrades faster than the illumination percentage
/// suggests). A "moderate" moon impact is worse than 50% implies.
/// Severe lowered from 10 → 5: bright moon close to target is essentially
/// a session-killer for broadband DSO imaging.
///
/// Sources: AstroBackyard moon impact guide, Telescope Live moon article,
/// Astrodoc community consensus.
///
/// Receives: [severity] — from MoonImpactAssessment.
/// Returns: moon factor score.
int _moonScore(MoonSeverity severity) {
	return switch (severity) {
		MoonSeverity.none     => 100,
		MoonSeverity.low      => 75,
		MoonSeverity.moderate => 40,
		MoonSeverity.severe   => 5,
	};
}

/// Computes the altitude factor score (0-100) using a physics-calibrated
/// sin(altitude) curve plus a user preference bonus.
///
/// The sin curve matches real atmospheric physics:
/// - Extinction scales with airmass (1/sin(alt)) — Bouguer's law
/// - Seeing degrades as airmass^0.6 — Roddier 1981
/// - The curve is steep below 30° (escaping worst atmosphere) and gentle
///   above 60° (diminishing returns) — exactly what the community observes
///
/// The preference bonus (up to 20 points) nudges scores toward the user's
/// preferred minimum altitude without overriding the physics:
/// "The physics dominates, the preference nudges."
///
/// Blended 70/30 with duration (longer window = more integration time).
///
/// Calibrated against: sea-level k_V = 0.20-0.25 mag/airmass, Roddier
/// seeing formula, Cloudy Nights community surveys (2015-2026).
///
/// Receives:
/// - [peakAltitude] — highest altitude in degrees (nullable if never rises)
/// - [durationHours] — hours the target is observable (nullable)
/// - [userMinAltitude] — user's preferred minimum altitude in degrees (default 30)
///
/// Returns: altitude score 0-100.
int altitudeFactorScore({
	double? peakAltitude,
	double? durationHours,
	int userMinAltitude = 30,
}) {
	if (peakAltitude == null || durationHours == null) return 0;

	// Physics component: sin(altitude) maps naturally to atmospheric quality.
	// sin(90°) = 1.0 → 100, sin(30°) = 0.5 → 50, sin(15°) = 0.26 → 26.
	// This IS the airmass curve inverted: quality ∝ 1/airmass = sin(alt).
	final altRad = peakAltitude * (pi / 180.0);
	final physicsScore = sin(altRad) * 100.0;

	// User preference bonus: up to 12 points for reaching the user's preferred
	// minimum altitude. Capped at 12 (reduced from 20) to prevent the preference
	// from overriding the physics at extreme settings. At 20 points, a user with
	// pref=45° could get a score that exceeds sin(90°)=100, making the preference
	// dominate the physics. At 12 points, the physics still dominates.
	// "The physics dominates, the preference nudges."
	final double prefBonus;
	if (userMinAltitude <= 0) {
		prefBonus = 12.0;
	} else if (peakAltitude >= userMinAltitude) {
		prefBonus = 12.0;
	} else {
		prefBonus = (peakAltitude / userMinAltitude) * 12.0;
	}

	// Combine: physics score + preference bonus, capped at 100.
	final altComponent = min(100.0, physicsScore + prefBonus);

	// Duration component: 0h → 0, 4h+ → 100. Longer window = more subs.
	final durComponent = _linearScore(durationHours, good: 4.0, bad: 0.0);

	// Altitude matters more than duration for image quality (70/30 blend).
	return (altComponent * 0.7 + durComponent * 0.3).round().clamp(0, 100);
}

/// Computes the transparency bonus from site elevation using exponential
/// atmospheric extinction reduction.
///
/// Higher-altitude sites have less atmosphere above them, reducing extinction
/// (dimming) of starlight. The relationship is exponential because atmospheric
/// pressure drops exponentially with altitude: k_V(h) = 0.28 * exp(-h/6000).
///
/// Calibrated against real observatory measurements:
/// - Sea level: k_V = 0.28 mag/airmass → boost 0
/// - Cherry Springs (700m): k_V ~ 0.25 → boost ~2
/// - La Palma (2400m): k_V = 0.11 (measured, ING 20-year database) → boost ~5
/// - Mauna Kea (4200m): k_V = 0.11 (Krisciunas et al. 1987) → boost ~8
///
/// Sources: Patat et al. 2011 (Cerro Paranal), ING La Palma 20-year database,
/// Asterism.org atmospheric extinction reference.
///
/// Receives: [elevationMeters] — site elevation above sea level in metres.
/// Returns: bonus points (0-15) to add to the smoke/transparency factor.
int elevationTransparencyBoost(double elevationMeters) {
	if (elevationMeters <= 0) return 0;
	// Extinction coefficient at elevation h:
	// k_V(h) = 0.28 * exp(-h / 6000)
	// The 6000m effective scale height is a simplified combination of
	// Rayleigh scattering (H = 7996m) and aerosol scattering (H ~ 1500m).
	// The first 1-2km of elevation removes most aerosols (boundary layer),
	// giving the biggest improvement per meter gained.
	// Multiplier 16 calibrated so Mauna Kea (4200m) gets ~8 points,
	// La Palma (2400m) gets ~5, Cherry Springs (700m) gets ~2.
	final boost = (1.0 - exp(-elevationMeters / 6000.0)) * 16.0;
	return min(15, boost.round());
}

/// Returns an atmospheric dispersion warning string for planetary/lunar
/// targets at low altitudes, or null if no warning is needed.
///
/// Atmospheric dispersion is chromatic smearing: red light refracts less
/// than blue, so at low altitudes a planet looks like a tiny vertical
/// rainbow. This ONLY matters for high-magnification planetary/lunar
/// imaging (0.1-0.3 arcsec/pixel). DSO imaging at 1-2 arcsec/pixel is
/// unaffected because dispersion is below the pixel scale.
///
/// Dispersion values (400-650nm, sea level):
/// - 60 deg: ~0.7"  (below most amateur pixel scales)
/// - 45 deg: ~1.0-1.4"
/// - 30 deg: ~2.5"  (clearly visible in planetary imaging)
/// - 20 deg: ~4.0"  (severe, ADC strongly recommended)
/// - 15 deg: ~6+"   (unusable for planets without ADC)
///
/// Sources: Peach (BAA 2017), ICO Optics, Filippenko 1982 (PASP).
///
/// Receives:
/// - [peakAltitude] — target's peak altitude in degrees
/// - [isPlanetary] — true for planetary or lunar targets
///
/// Returns: warning string or null.
String? atmosphericDispersionWarning({
	required double peakAltitude,
	required bool isPlanetary,
}) {
	if (!isPlanetary || peakAltitude >= 30.0) return null;
	// Dispersion in arcseconds (400-650nm range) from Peach (BAA 2017):
	// Interpolated from measured values: 0.7" at 60°, 2.5" at 30°, 4" at 20°.
	// Using piecewise linear interpolation rather than a single tan formula
	// because the differential refraction coefficient is complex to derive.
	final double dispersionArcsec;
	if (peakAltitude >= 25) {
		// 25-30°: interpolate 1.5" to 2.5"
		dispersionArcsec = 2.5 - (peakAltitude - 25) * 0.2;
	} else if (peakAltitude >= 20) {
		// 20-25°: interpolate 4.0" to 1.5"
		dispersionArcsec = 4.0 - (peakAltitude - 20) * 0.5;
	} else if (peakAltitude >= 15) {
		// 15-20°: interpolate 6.0" to 4.0"
		dispersionArcsec = 6.0 - (peakAltitude - 15) * 0.4;
	} else {
		dispersionArcsec = 6.0;
	}
	return 'Atmospheric dispersion at ${peakAltitude.toStringAsFixed(0)}\u00b0 '
		'will cause ${dispersionArcsec.toStringAsFixed(1)}" chromatic smearing '
		'\u2014 consider an ADC.';
}

/// Computes the rig suitability factor score (0-100).
///
/// Checks three things:
/// 1. Dawes limit vs target size (can the scope resolve the target?)
/// 2. Pixel scale vs stability (is the rig matched to the atmosphere?)
/// 3. FOV vs target size (does the target fit the frame?)
///
/// Returns 100 (neutral) if no rig properties are provided.
///
/// Receives:
/// - [rigProps] — rig specifications (nullable)
/// - [objectProps] — target properties (nullable)
/// - [stabilityScore] — atmospheric stability (0-100)
/// - [rigWarnings] — mutable list to collect rig-specific warnings
///
/// Returns: rig factor score 0-100.
int _rigScore(
	RigProperties? rigProps,
	ObjectProperties? objectProps,
	int stabilityScore,
	List<String> rigWarnings,
) {
	if (rigProps == null) return 100;

	var score = 100;

	// 1. Dawes limit check: can the scope resolve the target's detail?
	// Dawes limit = 116 / aperture_mm (arcseconds).
	if (rigProps.apertureMm != null && objectProps?.angularSizeArcmin != null) {
		final dawesArcsec = 116.0 / rigProps.apertureMm!;
		final targetArcsec = objectProps!.angularSizeArcmin! * 60.0;
		// If target is less than 10x the Dawes limit, resolution is marginal.
		if (targetArcsec < dawesArcsec * 10) {
			final penalty = _linearScore(
				targetArcsec / dawesArcsec,
				good: 20.0,  // 20x Dawes → full score
				bad: 2.0,    // 2x Dawes → zero
			);
			score = min(score, penalty);
			if (penalty < 60) {
				rigWarnings.add(
					'Your ${rigProps.apertureMm!.round()}mm scope may not resolve '
					'this target\'s fine detail '
					'(Dawes limit: ${dawesArcsec.toStringAsFixed(1)}" vs '
					'target: ${targetArcsec.toStringAsFixed(0)}").',
				);
			}
		}
	}

	// 2. FOV vs target size: does the target fit the sensor?
	if (rigProps.fovWidthArcmin != null && objectProps?.angularSizeArcmin != null) {
		final fovMin = min(
			rigProps.fovWidthArcmin!,
			rigProps.fovHeightArcmin ?? rigProps.fovWidthArcmin!,
		);
		final targetSize = objectProps!.angularSizeArcmin!;
		final fillFraction = targetSize / fovMin;

		if (fillFraction < 0.05) {
			// Target is tiny compared to FOV — poor framing match.
			score = min(score, 40);
			rigWarnings.add(
				'Target fills only ${(fillFraction * 100).toStringAsFixed(1)}% '
				'of your sensor — consider longer focal length.',
			);
		} else if (fillFraction > 0.80) {
			// Target is large — may need mosaic. Note, don't penalize.
			rigWarnings.add(
				'Target fills ${(fillFraction * 100).toStringAsFixed(0)}% of '
				'your sensor — consider a mosaic for the full extent.',
			);
		}
	}

	return score;
}

/// Computes the smoke/AQI factor score (0-100) from air quality data.
///
/// Uses aerosol optical depth (AOD) as the primary metric — it measures
/// total column opacity, not just ground-level particles.
///
/// AOD scoring curve (from spec Section 3b):
///   < 0.05 → 100, 0.05-0.15 → 80, 0.15-0.30 → 50,
///   0.30-0.50 → 25, > 0.50 → 5.
///
/// Averages across the effective window hours.
///
/// Receives:
/// - [airQuality] — hourly air quality data (nullable; null = no data)
/// - [effectiveStart] — start of the effective window (UTC)
/// - [effectiveEnd] — end of the effective window (UTC)
///
/// Returns: smoke score 0-100, or null if no data available.
int? _smokeScore(
	List<AirQuality>? airQuality,
	DateTime effectiveStart,
	DateTime effectiveEnd,
) {
	if (airQuality == null || airQuality.isEmpty) return null;

	// Filter to hours within the effective window.
	final windowHours = airQuality.where((aq) =>
		!aq.time.isBefore(effectiveStart) && !aq.time.isAfter(effectiveEnd)
	).toList();

	if (windowHours.isEmpty) return null;

	var total = 0.0;
	var count = 0;
	for (final aq in windowHours) {
		if (aq.aerosolOpticalDepth == null) continue;
		final aod = aq.aerosolOpticalDepth!;
		// Piecewise linear scoring from the AOD table in the spec.
		final int hourScore;
		if (aod < 0.05) {
			hourScore = 100;
		} else if (aod < 0.15) {
			// 0.05→100, 0.15→80: linear interpolation.
			hourScore = _linearScore(aod, good: 0.05, bad: 0.15) * 20 ~/ 100 + 80;
		} else if (aod < 0.30) {
			// 0.15→80, 0.30→50: linear interpolation.
			hourScore = _linearScore(aod, good: 0.15, bad: 0.30) * 30 ~/ 100 + 50;
		} else if (aod < 0.50) {
			// 0.30→25, 0.50→5: linear interpolation.
			hourScore = _linearScore(aod, good: 0.30, bad: 0.50) * 20 ~/ 100 + 5;
		} else {
			hourScore = 5;
		}
		total += hourScore;
		count++;
	}

	if (count == 0) return null;
	return (total / count).round();
}

/// Upper-level "seeing" score (0-100) from the 250 hPa jet-stream wind.
///
/// Seeing — the atmospheric turbulence that smears stars — is driven mainly by
/// high-altitude wind shear, NOT surface weather. The prior model used a
/// surface-stability proxy alone, which is the wrong ALTITUDE (spec §5). We
/// average the 250 hPa wind across the window's hours that REPORT it and map low
/// wind → good seeing.
///
/// POLARITY (load-bearing): a null windSpeed250hPa is a DATA GAP and is skipped —
/// it is NOT a calm jet. Treating null as 0 would score a missing forecast as
/// ideal seeing. This mirrors the fetcher's _safe_optional handling.
///
/// `good: 15, bad: 100` km/h is a directional default (spec §5/§10): a near-calm
/// jet images sharp; a 100+ km/h jet stream ruins seeing. Returns null when NO
/// hour in the window reports 250 hPa wind, so the caller falls back to the
/// surface-stability proxy rather than scoring a phantom value.
///
/// Receives: [hours] — the window's hourly weather.
/// Returns: seeing score 0-100, or null if the window has no 250 hPa data.
int? _jetSeeingScore(List<HourlyWeather> hours) {
	var total = 0.0;
	var count = 0;
	for (final h in hours) {
		final jet = h.windSpeed250hPa;
		if (jet == null) continue; // data gap — NOT a calm jet (polarity)
		total += jet;
		count++;
	}
	if (count == 0) return null;
	final avgJet = total / count;
	return _linearScore(avgJet, good: 15.0, bad: 100.0);
}

/// Filters hourly weather data to only hours within the effective window.
///
/// Receives:
/// - [hours] — full forecast hourly data
/// - [start] — effective window start (UTC)
/// - [end] — effective window end (UTC)
///
/// Returns: list of [HourlyWeather] within [start, end].
List<HourlyWeather> _windowHours(
	List<HourlyWeather> hours,
	DateTime start,
	DateTime end,
) {
	return hours.where((h) =>
		!h.time.isBefore(start) && !h.time.isAfter(end)
	).toList();
}

/// Finds the best contiguous window of clear weather within the dark window.
///
/// Scans hourly data and identifies the longest stretch where cloud cover
/// is below [clearThreshold]. Returns null if no clear stretch is found.
///
/// Receives:
/// - [hours] — hourly weather data
/// - [darkWindow] — the night's dark window (limits search)
/// - [clearThreshold] — max cloud cover % considered "clear" (default 30)
///
/// Returns: [TimeWindow] of the best clear stretch, or null.
TimeWindow? _findBestWindow(
	List<HourlyWeather> hours,
	DarkWindow darkWindow, {
	double clearThreshold = 30.0,
}) {
	if (darkWindow.start == null || darkWindow.end == null) return null;

	final darkHours = hours.where((h) =>
		!h.time.isBefore(darkWindow.start!) && !h.time.isAfter(darkWindow.end!)
	).toList();

	if (darkHours.isEmpty) return null;

	DateTime? bestStart;
	DateTime? bestEnd;
	var bestLength = 0;

	DateTime? currentStart;
	var currentLength = 0;

	for (final h in darkHours) {
		if (h.cloudCover <= clearThreshold) {
			currentStart ??= h.time;
			currentLength++;
			if (currentLength > bestLength) {
				bestLength = currentLength;
				bestStart = currentStart;
				// End is one hour after the last clear hour (approximate).
				bestEnd = h.time.add(const Duration(hours: 1));
			}
		} else {
			currentStart = null;
			currentLength = 0;
		}
	}

	if (bestStart == null || bestEnd == null) return null;
	return TimeWindow(start: bestStart, end: bestEnd);
}

// ─────────────────────────────────────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────────────────────────────────────

/// Scores one target for one time window at one location.
///
/// This is the primary scoring function — takes all available data about
/// weather, astronomy, and equipment, then produces a composite score,
/// verdict, and human-readable reasoning.
///
/// Receives:
/// - [forecast] — hourly weather data for the location
/// - [stability] — atmospheric stability assessment
/// - [observableWindow] — from Plan 2 visibility engine (when target is dark + above horizon)
/// - [moonImpact] — from Plan 2 moon geometry
/// - [darkWindow] — the night's astronomical dark window
/// - [targetType] — what kind of object (DSO, planetary, etc.)
/// - [objectProperties] — angular size, surface brightness, magnitude (optional)
/// - [rigProperties] — aperture, focal length, pixel scale, FOV (optional)
/// - [userWindow] — user's availability (optional; defaults to full dark window)
/// - [travelMinutes] — drive time to site (optional; for departure messaging)
/// - [currentTime] — "now" for travel time calculations (optional; for testability)
/// - [imagingMode] — broadband/narrowband/dualband (optional; overrides moon/darkness weights)
/// - [weightProfileOverride] — when non-null, replaces the base
///   target-type profile and SKIPS the adjustForObject/adjustForRig
///   passes. Used by [scoreTargetByIntent] to inject visual-intent
///   weights (lib/scoring/intents/visual_factors.dart). When null
///   (the default) scoring proceeds as before — imaging-only
///   behavior is unchanged. Phase F Task 5.
///
/// Returns: a [TargetScore] with score, verdict, reasoning, and factor breakdown.
TargetScore scoreTarget({
	required WeatherForecast forecast,
	required StabilityAssessment stability,
	required ObservableWindow observableWindow,
	required MoonImpactAssessment moonImpact,
	required DarkWindow darkWindow,
	required TargetType targetType,
	ObjectProperties? objectProperties,
	RigProperties? rigProperties,
	TimeWindow? userWindow,
	int? travelMinutes,
	DateTime? currentTime,
	ImagingMode? imagingMode,
	int userMinAltitude = 30,
	double siteElevation = 0.0,
	double precipitationVetoThreshold = 70.0,
	double windVetoThreshold = 25.0,
	double dewSpreadVetoThreshold = 2.0,
	int? siteBortle,
	WeightProfile? weightProfileOverride,
}) {
	final reasons = <String>[];
	final rigWarnings = <String>[];

	// ── Step 0: NaN/Infinity guard on critical inputs (GitHub #8) ────────
	// If any upstream computation produced NaN (e.g., division by zero in
	// the astro engine), the weighted average would produce NaN and crash
	// on .round(). Guard here to fail gracefully instead of propagating.
	// NaN/Infinity guard on critical floating-point inputs.
	// stability.score is int — int.isNaN is always false in Dart, so the
	// previous guard on it was dead code. Removed. The double fields from
	// moonImpact are the real risk (division by zero in astro engine).
	// Bug fix: GitHub #28.
	if (moonImpact.illuminationPercent.isNaN ||
		moonImpact.illuminationPercent.isInfinite ||
		moonImpact.distanceDeg.isNaN ||
		moonImpact.distanceDeg.isInfinite) {
		return TargetScore(
			score: 0,
			verdict: Verdict.dontBother,
			reasons: ['Scoring data contains invalid values — results unavailable.'],
			factorScores: {'cloud': 0, 'stability': 0, 'darkness': 0,
				'moon': 0, 'altitude': 0, 'rig': 0, 'smoke': 0},
			adjustedWeights: targetType.baseWeightProfile,
			rigWarnings: [],
		);
	}

	// ── Step 1: Determine effective time window ──────────────────────────
	// Intersection of: user window (or full dark window) + observable window.

	// Default user window to full dark window if not specified.
	final userStart = userWindow?.start ?? darkWindow.start;
	final userEnd = userWindow?.end ?? darkWindow.end;

	// If observable window doesn't exist, target never rises high enough.
	if (!observableWindow.isObservable || userStart == null || userEnd == null) {
		return TargetScore(
			score: 0,
			verdict: Verdict.dontBother,
			reasons: ['Target is not observable tonight — never rises above minimum altitude.'],
			factorScores: {'cloud': 0, 'stability': 0, 'darkness': 0,
				'moon': 0, 'altitude': 0, 'rig': 0, 'smoke': 0},
			adjustedWeights: targetType.baseWeightProfile,
			rigWarnings: rigWarnings,
		);
	}

	// Effective window = intersection of user window and observable window.
	final effectiveStart = userStart.isAfter(observableWindow.start!)
		? userStart : observableWindow.start!;
	final effectiveEnd = userEnd.isBefore(observableWindow.end!)
		? userEnd : observableWindow.end!;

	// No overlap between user window and observable window.
	if (effectiveEnd.isBefore(effectiveStart) || effectiveEnd == effectiveStart) {
		reasons.add(
			'Target is not observable during your available window '
			'— it\'s above the horizon from '
			'${_formatUtcTime(observableWindow.start!)} to '
			'${_formatUtcTime(observableWindow.end!)}.',
		);
		return TargetScore(
			score: 0,
			verdict: Verdict.dontBother,
			reasons: reasons,
			factorScores: {'cloud': 0, 'stability': 0, 'darkness': 0,
				'moon': 0, 'altitude': 0, 'rig': 0, 'smoke': 0},
			adjustedWeights: targetType.baseWeightProfile,
			rigWarnings: rigWarnings,
		);
	}

	// ── Travel time: departure urgency (not window shrinking) ────────────
	if (travelMinutes != null && travelMinutes > 0) {
		final now = currentTime ?? DateTime.now().toUtc();
		final travelDuration = Duration(minutes: travelMinutes);
		final arrivalTime = now.add(travelDuration);

		if (arrivalTime.isAfter(effectiveEnd)) {
			// Can't arrive before window closes.
			reasons.add(
				'By the time you arrive (${travelMinutes}min drive), '
				'the observing window has closed.',
			);
			return TargetScore(
				score: 0,
				verdict: Verdict.dontBother,
				reasons: reasons,
				factorScores: {'cloud': 0, 'stability': 0, 'darkness': 0,
					'moon': 0, 'altitude': 0, 'rig': 0, 'smoke': 0},
				adjustedWeights: targetType.baseWeightProfile,
				rigWarnings: rigWarnings,
			);
		}

		// Departure time to arrive when window opens.
		final departBy = effectiveStart.subtract(travelDuration);

		if (now.isAfter(departBy) && now.isBefore(effectiveEnd)) {
			// Should have left already or should leave now.
			final remainingAfterArrival = effectiveEnd.difference(arrivalTime);
			final remainingHours = remainingAfterArrival.inMinutes / 60.0;
			if (remainingHours < 0.5) {
				reasons.add(
					'Tight window — with a ${travelMinutes}min drive, '
					'you\'d arrive with only ${remainingAfterArrival.inMinutes} '
					'minutes remaining.',
				);
			} else {
				reasons.add(
					'Leave now! With a ${travelMinutes}min drive, '
					'you\'ll arrive with ${remainingHours.toStringAsFixed(1)} '
					'hours remaining.',
				);
			}
		} else if (now.isBefore(departBy)) {
			// There's still time — tell them when to leave.
			reasons.add(
				'Leave by ${_formatUtcTime(departBy)} '
				'(${travelMinutes}min drive) to arrive when the window opens.',
			);
		}
	}

	// ── Step 2: Compute seven factor scores ──────────────────────────────
	final effectiveHours = _windowHours(forecast.hours, effectiveStart, effectiveEnd);

	final cloudFactor = _cloudScore(effectiveHours);

	// Seeing factor. Phase E §10.2: when forecast.derivedSeeing is
	// SeeingResultAvailable, it's the higher-quality signal (Astroplan's
	// Antoniazzi-parameterized derivation on commercial-tier Open-Meteo
	// pressure-level data) and should supersede the existing atmospheric-
	// stability proxy. When unavailable, null, or SeeingResultUnavailable,
	// we fall back to the proxy — this happens for Free/Premium tiers
	// (no commercial API key), legacy cache entries that predate Phase E,
	// or transient pressure-level fetch failures. The factor-score key is
	// deliberately kept as 'stability' so external consumers
	// (FactorBreakdownTable, score-reasoning code paths, existing
	// scoring tests) don't need to change in lockstep — the meaning of
	// the 'stability' score evolves to "best available atmospheric-
	// conditions score" rather than a narrow turbulence proxy.
	// Plan 6b may re-split these into distinct factors after calibration
	// data lands; for v1 the unified slot is the minimum viable
	// integration.
	final stabilityFactor = _derivedSeeingScore(forecast) ?? stability.score;
	final darknessFactor = _darknessScore(effectiveStart, effectiveEnd, darkWindow);
	final moonFactor = _moonScore(moonImpact.severity);
	final altitudeFactor = altitudeFactorScore(
		peakAltitude: observableWindow.peakAltitude,
		durationHours: observableWindow.durationHours,
		userMinAltitude: userMinAltitude,
	);
	final rigFactor = _rigScore(rigProperties, objectProperties, stabilityFactor, rigWarnings);

	// ── Safety vetoes ────────────────────────────────────────────────
	// Delegated to VetoEvaluator (veto_evaluator.dart) for independent
	// testability. Each veto is a pure function: weather + threshold → result.
	// Extracted from this file in GitHub #35 (3/4 vetoes were untested).
	final veto = VetoEvaluator.evaluateAll(
		cloudFactor: cloudFactor,
		effectiveHours: effectiveHours,
		precipThreshold: precipitationVetoThreshold,
		windThreshold: windVetoThreshold,
		dewSpreadThreshold: dewSpreadVetoThreshold,
	);
	if (veto != null) {
		if (veto.vetoName == 'cloud') {
			final cloudReasons = <String>[];
			_addCloudReason(cloudReasons, cloudFactor, effectiveHours);
			reasons.addAll(cloudReasons);
		}
		reasons.add(veto.reason);
		return TargetScore(
			score: 0,
			verdict: Verdict.dontBother,
			reasons: reasons,
			factorScores: {'cloud': cloudFactor, 'stability': stabilityFactor,
				'darkness': darknessFactor, 'moon': moonFactor,
				'altitude': altitudeFactor, 'rig': 0, 'smoke': 0},
			adjustedWeights: targetType.baseWeightProfile,
			rigWarnings: rigWarnings,
		);
	}

	// Smoke score from explicit air quality data.
	// When AQ data is present it takes priority over cirrus estimation.
	// When null: fall back to cirrus-based transparency penalty so that
	// DSO (smoke weight 1.0) is hurt more by thin cirrus than planetary (0.3).
	final smokeResult = forecast.airQuality != null
		? _smokeScore(forecast.airQuality, effectiveStart, effectiveEnd)
		: _cirrusTransparencyScore(effectiveHours);
	// Apply site elevation bonus to the smoke/transparency factor.
	// Higher-altitude sites have less atmospheric extinction and better
	// transparency. The boost is exponential (biggest gain in first 1-2km
	// escaping the boundary layer). Capped at +15 points.
	final elevBoost = elevationTransparencyBoost(siteElevation);
	final smokeFactor = min(100, (smokeResult ?? 0) + elevBoost);
	final hasAirQuality = smokeResult != null;

	// ── Step 3: Get adjusted weight profile ──────────────────────────────
	// Either use the caller-provided override (visual intent via
	// scoreTargetByIntent) or derive from the target type. When
	// overriding we SKIP adjustForObject/adjustForRig because those
	// helpers were calibrated against imaging-intent weights — their
	// size / Dawes / pixel-scale heuristics don't apply when the
	// profile represents visual weighting. Plan 5.5's eyepiece-aware
	// scoring will introduce the visual analogs.
	var weights = weightProfileOverride ?? targetType.baseWeightProfile;

	if (weightProfileOverride == null) {
		// Adjust for object properties (angular size, surface brightness).
		weights = adjustForObject(weights, objectProps: objectProperties);

		// Adjust for rig properties (Dawes limit, pixel scale, FOV).
		weights = adjustForRig(
			weights,
			rigProps: rigProperties,
			targetAngularSizeArcmin: objectProperties?.angularSizeArcmin,
		);
	}

	// Apply imaging mode overrides (moon, darkness, and altitude weights).
	// Narrowband Ha/SII: less sensitive to low altitude and moonlight.
	// Planetary: MORE sensitive to low altitude (dispersion + seeing).
	// Skipped when a weight override is in play — imaging modes only
	// make sense for the imaging intent.
	if (imagingMode != null && weightProfileOverride == null) {
		weights = weights.copyWith(
			moon: imagingMode.moonWeight,
			darkness: imagingMode.darknessWeight,
			altitude: weights.altitude * imagingMode.altitudeWeightModifier,
		);
	}

	// If no air quality data, set smoke weight to 0 (omit factor).
	// Intent-aware guard (Phase F Task 12 fix): when a
	// weightProfileOverride is active, the override already set
	// smoke to `visualWeights.transparency` so cirrus degrades
	// visual scoring even without a separate AQ fetch. Zeroing it
	// here would silently defeat the visual transparency axis for
	// every Free-tier user (who typically lacks air-quality data).
	// Caught in cross-agent QA review (code-reviewer M3).
	if (!hasAirQuality && weightProfileOverride == null) {
		weights = weights.copyWith(smoke: 0.0);
	}

	// ── Sky brightness context (informational, not a separate scored factor).
	// Computes effective sky brightness from Bortle + moon + altitude for
	// reasoning strings and target detectability context. The existing
	// moon and darkness factors already capture most of this; the sky
	// brightness model adds LP integration and altitude gradient.
	if (siteBortle != null && observableWindow.peakAltitude != null) {
		final sb = effectiveSkyBrightness(
			bortle: siteBortle,
			moonIllumination: moonImpact.illuminationPercent,
			moonSeparation: moonImpact.distanceDeg,
			targetAltitude: observableWindow.peakAltitude!,
		);
		if (sb != null) {
			final sbScore = skyBrightnessScore(sb);
			if (sbScore < 30) {
				reasons.add(
					'Sky background very bright (${sb.toStringAsFixed(1)} mag/arcsec²) '
					'— light pollution and/or moonlight significantly limit faint targets.',
				);
			} else if (sbScore < 60) {
				reasons.add(
					'Sky background moderate (${sb.toStringAsFixed(1)} mag/arcsec²) '
					'— suburban-level conditions.',
				);
			}
		}
	}

	// ── Step 4: Composite score (weighted average) ───────────────────────
	final scores = {
		'cloud': cloudFactor,
		'stability': stabilityFactor,
		'darkness': darknessFactor,
		'moon': moonFactor,
		'altitude': altitudeFactor,
		'rig': rigFactor,
		'smoke': smokeFactor,
	};

	final weightValues = {
		'cloud': weights.cloud,
		'stability': weights.stability,
		'darkness': weights.darkness,
		'moon': weights.moon,
		'altitude': weights.altitude,
		'rig': weights.rig,
		'smoke': weights.smoke,
	};

	var weightedSum = 0.0;
	var totalWeight = 0.0;
	for (final key in scores.keys) {
		final w = weightValues[key]!;
		weightedSum += w * scores[key]!;
		totalWeight += w;
	}

	final compositeScore = totalWeight > 0
		? (weightedSum / totalWeight).round().clamp(0, 100)
		: 0;

	// ── Step 5: Verdict ──────────────────────────────────────────────────
	final verdict = Verdict.fromScore(compositeScore);

	// ── Step 6: Build reasoning strings ──────────────────────────────────
	_addCloudReason(reasons, cloudFactor, effectiveHours);
	_addMoonReason(reasons, moonImpact, imagingMode);
	_addAltitudeReason(reasons, observableWindow);
	_addStabilityReason(reasons, stability);
	_addSmokeReason(reasons, smokeResult, forecast.airQuality, effectiveStart, effectiveEnd);
	// When smoke score came from cirrus fallback (no AQ data), _addSmokeReason
	// won't fire because airQuality is null. Add cirrus-specific reasoning instead.
	if (forecast.airQuality == null && smokeResult != null && smokeResult < 80) {
		final avgCirrus = effectiveHours.map((h) => h.cloudCoverHigh).reduce((a, b) => a + b) / effectiveHours.length;
		reasons.add(
			'High cirrus (${avgCirrus.toStringAsFixed(0)}%) reducing transparency '
			'— affects faint extended objects most.',
		);
	}

	// Atmospheric dispersion warning for planetary/lunar targets below 30 deg.
	// This is a reasoning string, not a score change — the altitude factor
	// already penalizes low altitudes. The warning tells the user WHY it matters
	// specifically for their target type and suggests an ADC.
	final dispWarning = atmosphericDispersionWarning(
		peakAltitude: observableWindow.peakAltitude ?? 0,
		isPlanetary: targetType == TargetType.planetary,
	);
	if (dispWarning != null) rigWarnings.add(dispWarning);

	// Elevation bonus reasoning.
	if (elevBoost >= 2) {
		reasons.add(
			'Site elevation (${siteElevation.round()}m) improves transparency '
			'by reducing atmospheric extinction.',
		);
	} else if (siteElevation <= 0 && siteBortle != null && siteBortle > 3) {
		// No elevation set and not at a pristine dark site — hint that
		// setting elevation could improve their transparency score.
		// Only show for Bortle > 3 where extinction actually matters.
		// Bug fix: GitHub #51.
		reasons.add(
			'Site elevation not set — if your site is above ~500m, '
			'setting elevation in Location settings improves transparency scoring.',
		);
	}

	return TargetScore(
		score: compositeScore,
		verdict: verdict,
		reasons: reasons,
		factorScores: scores,
		adjustedWeights: weights,
		rigWarnings: rigWarnings,
	);
}

/// Scores a location overall for "tonight" — not target-specific.
///
/// Simpler than [scoreTarget] — uses only weather, darkness, and moon
/// to answer "Is it worth going out tonight?" before the user picks targets.
///
/// Receives:
/// - [forecast] — hourly weather data for the location
/// - [darkWindow] — the night's astronomical dark window
/// - [moonIlluminationPercent] — Moon brightness (0-100%)
/// - [userWindow] — user's availability (optional; defaults to full dark window)
///
/// Returns: a [LocationScore] with score, verdict, best window, and reasoning.
LocationScore scoreLocation({
	required WeatherForecast forecast,
	required DarkWindow darkWindow,
	required double moonIlluminationPercent,
	TimeWindow? userWindow,
	// ── Phase-1 redesign params (all optional → existing callers still compile) ──
	// siteBortle: light-pollution class 1–9, or null (→ default sky-brightness
	//   baseline, so the moon penalty still applies). moonAltitude: the moon's
	//   altitude (deg) at the window — drives the geometry-aware moon burden; null
	//   → burden 0 (no penalty). The wrapper ALWAYS supplies it in production.
	// (The HOME/REMOTE `managed` distinction lives in the WRAPPER's veto policy —
	// the engine scores uniformly. See score_location.dart.)
	int? siteBortle,
	double? moonAltitude,
}) {
	final reasons = <String>[];

	// Determine the scoring window.
	final windowStart = userWindow?.start ?? darkWindow.start;
	final windowEnd = userWindow?.end ?? darkWindow.end;

	if (windowStart == null || windowEnd == null) {
		return LocationScore(
			score: 0,
			verdict: Verdict.dontBother,
			reasons: ['No astronomical darkness tonight.'],
			// Phase-1 factor set: no more 'darkness'/'moon' keys (darkness was a
			// constant inflation; moon is folded into skyBrightness). Absent factors
			// are OMITTED, never zero-filled (fix 2).
			factorScores: {'cloud': 0, 'stability': 0},
		);
	}

	final windowHrs = _windowHours(forecast.hours, windowStart, windowEnd);

	// Cloud score: average over the window.
	final cloudFactor = _cloudScore(windowHrs);

	// Veto: a near-zero cloud score is ~95%+ solid overcast — no imaging anywhere
	// (there are no sucker holes in true overcast), so this hard-stops in BOTH
	// modes. This does NOT violate the spec's "partial cloud never a hard gate" for
	// HOME: 95% overcast is not "partial". PARTIAL cloud (a workable-with-gaps
	// night) has cloudFactor > 5 and flows into the composite below, where the
	// best-window captures the gaps — that is where HOME's gambling nuance lives. A
	// weighted MEAN cannot let one bad factor veto a clear-but-otherwise-good night
	// (a clear sky floors the composite ~67), so without this hard stop a rural
	// HOME site could read "green" under 95% overcast — the exact dishonesty this
	// redesign removes. The HOME/REMOTE split is the PRECIP veto (wrapper), not this.
	if (cloudFactor <= 5) {
		return LocationScore(
			score: cloudFactor,
			verdict: Verdict.dontBother,
			reasons: ['Overcast — cloud cover too thick for imaging.'],
			factorScores: {'cloud': cloudFactor, 'stability': 0},
		);
	}

	// ── Seeing (atmospheric stability) factor ──
	// Surface-stability proxy (the prior sole input). 50 is a degenerate sentinel
	// when there are too few hours to assess — NOT a real measurement.
	final int surfaceStability =
		windowHrs.length >= 2 ? assessStability(windowHrs).score : 50;
	// Blend with the 250 hPa jet score, the physically-correct seeing driver
	// (spec §5). Correction 3: when stability is the degenerate sentinel, use the
	// jet ALONE rather than averaging a real jet halfway to a meaningless 50.
	final jetSeeing = _jetSeeingScore(windowHrs); // null when no 250 hPa data
	final int stabilityFactor;
	if (jetSeeing != null && windowHrs.length >= 2) {
		stabilityFactor = ((jetSeeing + surfaceStability) / 2).round();
	} else if (jetSeeing != null) {
		stabilityFactor = jetSeeing;             // stability degenerate → jet alone
	} else {
		stabilityFactor = surfaceStability;      // no jet → surface proxy
	}

	// ── Sky-brightness factor (Bortle baseline + geometry-aware moon) ──
	// Replaces the old illumination-only moon term AND the removed darkness factor.
	// ALWAYS present: locationSkyBrightnessScore never returns null (default
	// baseline on null Bortle, fix 1), so the moon penalty applies at every site —
	// including Bainbridge, which has no Bortle. A null moonAltitude yields burden
	// 0 (no penalty); the wrapper supplies the real altitude in production.
	final skyBrightnessFactor = locationSkyBrightnessScore(
		bortle: siteBortle,
		moonIlluminationPercent: moonIlluminationPercent,
		moonAltitudeDeg: moonAltitude ?? 0.0,
	);

	// ── Transparency (AOD) factor — present ONLY when air-quality data exists ──
	// _smokeScore returns null when there's no usable AOD in the window. fix 2: we
	// OMIT it from the map in that case (never write 0 — absence ≠ worst haze).
	final transparencyFactor =
		_smokeScore(forecast.airQuality, windowStart, windowEnd);

	// ── Composite: null-aware weighted mean over the PRESENT factors (fix 2) ──
	// An absent factor contributes neither score nor weight; it is never scored as
	// zero (a zero would tank the composite AND, via the wrapper's NB reweight,
	// flip NB below BB — the exact bug the verifiers caught). cloud/stability/
	// skyBrightness are always present; transparency is conditional. Weights are
	// the directional BB weights from spec §5 (Dustin reviews at the commit
	// boundary; physics-default, re-tune later).
	final scores = <String, int>{
		'cloud': cloudFactor,
		'stability': stabilityFactor,
		'skyBrightness': skyBrightnessFactor,
	};
	if (transparencyFactor != null) {
		scores['transparency'] = transparencyFactor;
	}
	const weights = <String, double>{
		'cloud': 1.0,
		'stability': 0.6,
		'skyBrightness': 0.8,
		'transparency': 0.9,
	};
	var weightedSum = 0.0;
	var totalWeight = 0.0;
	for (final key in scores.keys) {
		final w = weights[key]!;
		weightedSum += w * scores[key]!;
		totalWeight += w;
	}
	final weightedMean = weightedSum / totalWeight;
	// CLOUD GATE (spec §1: cloud must GATE, not just average). A weighted mean lets
	// a good stability/sky/transparency out-vote bad cloud — which is exactly how
	// 89% cloud read "good" (cloudFactor ~11, but only weight 1.0 of ~3.3). Cap the
	// composite at the cloud factor: the verdict can never exceed what the cloud
	// allows — you cannot have a better-than-X night when only X% of the sky is
	// imageable. This is a SOFT ceiling, NOT a hard veto (spec §4): partial cloud
	// still flows (a ~50% night caps at ~marginal, NOT Neither) and the best-window
	// still surfaces the gaps, so HOME's gamble-on-holes nuance survives. Clear
	// nights (cloudFactor ~90-100) are untouched. Both modes — nobody images through
	// cloud. The wrapper applies the SAME cap to narrowband (cloud blocks emission
	// lines too). This is the half of the incident fix the weighted mean missed.
	final compositeScore =
		min(weightedMean, cloudFactor.toDouble()).round().clamp(0, 100);
	final verdict = Verdict.fromScore(compositeScore);

	// Find best window within the night.
	final bestWindow = _findBestWindow(forecast.hours, darkWindow);

	// Reasoning.
	if (cloudFactor >= 80) {
		reasons.add('Clear skies forecast — excellent transparency.');
	} else if (cloudFactor >= 50) {
		reasons.add('Partly cloudy — some breaks expected.');
	} else {
		reasons.add('Mostly cloudy — limited imaging opportunities.');
	}

	// Narrowband suggestion fires only when the moon is actually UP and bright —
	// a 95%-illuminated moon BELOW the horizon is a dark sky (spec §5a), so
	// suggesting narrowband for it would be the same dishonesty the redesign fixes.
	final moonUp = (moonAltitude ?? 0.0) > 0;
	if (moonUp && moonIlluminationPercent > 70) {
		reasons.add(
			'Moon ${moonIlluminationPercent.toStringAsFixed(0)}% illuminated '
			'and up — consider narrowband imaging.',
		);
	} else if (moonIlluminationPercent < 15) {
		reasons.add('Dark moon — excellent for faint DSOs.');
	}

	if (bestWindow != null) {
		reasons.add(
			'Best window: ${_formatUtcTime(bestWindow.start)} to '
			'${_formatUtcTime(bestWindow.end)}.',
		);
	}

	return LocationScore(
		score: compositeScore,
		verdict: verdict,
		bestWindow: bestWindow,
		reasons: reasons,
		// factorScores carries ONLY the present factors (fix 2) — downstream
		// (fetcher enrich + QML) treat this map as opaque, and the wrapper's NB
		// reweight iterates the present keys.
		factorScores: scores,
	);
}

// ─────────────────────────────────────────────────────────────────────────────
// Reasoning string builders
// ─────────────────────────────────────────────────────────────────────────────

/// Adds cloud-related reasoning to the reasons list.
///
/// Receives:
/// - [reasons] — mutable list to append reasoning strings to
/// - [cloudScore] — computed cloud factor score (0-100)
/// - [hours] — hourly weather data for the effective window
void _addCloudReason(List<String> reasons, int cloudScore, List<HourlyWeather> hours) {
	if (hours.isEmpty) return;

	// Average cloud cover for the message.
	final avgCloud = hours.map((h) => h.cloudCover).reduce((a, b) => a + b) / hours.length;

	if (cloudScore >= 90) {
		reasons.add('Clear skies forecast, < 10% cloud cover.');
	} else if (cloudScore >= 70) {
		reasons.add('Mostly clear — average ${avgCloud.toStringAsFixed(0)}% cloud cover.');
	} else if (cloudScore >= 40) {
		reasons.add('Partly cloudy — ${avgCloud.toStringAsFixed(0)}% average cloud cover.');
	} else {
		reasons.add('Heavy cloud cover (${avgCloud.toStringAsFixed(0)}%) — poor visibility expected.');
	}
}

/// Adds moon-related reasoning, including narrowband suggestion when appropriate.
///
/// Receives:
/// - [reasons] — mutable list to append reasoning strings to
/// - [moonImpact] — moon impact assessment (severity, distance, illumination)
/// - [imagingMode] — optional imaging filter mode (affects whether narrowband tip fires)
void _addMoonReason(
	List<String> reasons,
	MoonImpactAssessment moonImpact,
	ImagingMode? imagingMode,
) {
	if (moonImpact.severity == MoonSeverity.none) return;

	reasons.add(moonImpact.description);

	// If moon is bright and user is on broadband (or no mode set), suggest narrowband.
	if (moonImpact.severity == MoonSeverity.severe ||
	    (moonImpact.severity == MoonSeverity.moderate && moonImpact.illuminationPercent > 60)) {
		if (imagingMode == null || imagingMode == ImagingMode.broadband) {
			reasons.add(
				'Consider narrowband filters — they reject ~99% of moonlight.',
			);
		}
	}
}

/// Adds altitude-related reasoning.
///
/// Receives:
/// - [reasons] — mutable list to append reasoning strings to
/// - [window] — the observable window for the target
void _addAltitudeReason(List<String> reasons, ObservableWindow window) {
	if (!window.isObservable) return;
	// Guard against edge case where start/end are set but peak data is null.
	if (window.peakAltitude == null || window.durationHours == null) return;

	reasons.add(
		'Target transits at ${window.peakAltitude!.toStringAsFixed(0)}° altitude '
		'with a ${window.durationHours!.toStringAsFixed(1)}-hour window above minimum.',
	);
}

/// Adds stability-related reasoning.
///
/// Receives:
/// - [reasons] — mutable list to append reasoning strings to
/// - [stability] — the atmospheric stability assessment
void _addStabilityReason(List<String> reasons, StabilityAssessment stability) {
	final label = switch (stability.label) {
		StabilityLabel.good => 'Good atmospheric stability',
		StabilityLabel.fair => 'Fair atmospheric stability',
		StabilityLabel.poor => 'Poor atmospheric stability',
	};

	// Find the worst factor for a useful explanation.
	String? worstFactor;
	var worstScore = 101;
	for (final entry in stability.factors.entries) {
		if (entry.value.score < worstScore) {
			worstScore = entry.value.score;
			worstFactor = entry.key;
		}
	}

	if (worstFactor != null && worstScore < 50) {
		final factorLabel = switch (worstFactor) {
			'dewRisk'     => 'dew risk',
			'wind'        => 'wind',
			'gustFactor'  => 'gusty conditions',
			'humidity'    => 'high humidity',
			'coolingRate' => 'rapid cooling',
			'visibility'  => 'low visibility',
			_             => worstFactor,
		};
		reasons.add('$label — limited by $factorLabel.');
	} else {
		reasons.add('$label — conditions favorable for imaging.');
	}
}

/// Adds smoke/AQI-related reasoning.
///
/// Receives:
/// - [reasons] — mutable list to append reasoning strings to
/// - [smokeScore] — computed smoke factor score (null = no air quality data)
/// - [airQuality] — raw air quality data list (used for average AOD/AQI display)
/// - [effectiveStart] — start of the effective window (UTC)
/// - [effectiveEnd] — end of the effective window (UTC)
void _addSmokeReason(
	List<String> reasons,
	int? smokeScore,
	List<AirQuality>? airQuality,
	DateTime effectiveStart,
	DateTime effectiveEnd,
) {
	if (smokeScore == null || airQuality == null) return;

	// Find average AOD during the window for the message.
	final windowAq = airQuality.where((aq) =>
		!aq.time.isBefore(effectiveStart) && !aq.time.isAfter(effectiveEnd) &&
		aq.aerosolOpticalDepth != null
	).toList();

	if (windowAq.isEmpty) return;

	final avgAod = windowAq
		.map((aq) => aq.aerosolOpticalDepth!)
		.reduce((a, b) => a + b) / windowAq.length;

	// Find average AQI for user-friendly display.
	final avgAqi = windowAq.map((aq) => aq.usAqi).reduce((a, b) => a + b) ~/ windowAq.length;

	if (smokeScore >= 90) {
		reasons.add('Clear air quality — excellent transparency expected.');
	} else if (smokeScore >= 60) {
		reasons.add(
			'Slight haze (AOD ${avgAod.toStringAsFixed(2)}, AQI $avgAqi) '
			'— faintest targets may be affected.',
		);
	} else if (smokeScore >= 30) {
		reasons.add(
			'Moderate haze/smoke (AOD ${avgAod.toStringAsFixed(2)}, AQI $avgAqi) '
			'— transparency degraded for faint targets.',
		);
	} else {
		reasons.add(
			'Heavy smoke/haze (AOD ${avgAod.toStringAsFixed(2)}, AQI $avgAqi) '
			'— broadband imaging substantially impaired.',
		);
	}
}

/// Scores a single target for each requested [ObservingIntent] and
/// returns the results as an intent-keyed map. Phase F Task 5 —
/// introduces the `Map<ObservingIntent, TargetScore>` API contract
/// that the dual-score UI (Task 9), per-intent rationale (Task 10),
/// intent-aware notifications (Task 11), and favorites score-cache writes
/// (Task 7) all consume.
///
/// Implementation: calls [scoreTarget] once per intent, passing an
/// intent-appropriate weight profile. The imaging call uses the
/// existing target-type base profile (no override); the visual call
/// overrides with [visualWeightProfileFor] which maps the 6-column
/// visual weights to the 7-column [WeightProfile] shape. Every input
/// apart from the weights is shared, so the per-intent results
/// differ only in the weighted composite — correct semantically if
/// not yet optimal computationally.
///
/// DEF-F-01 (deferred to Plan 5.5 / Plan 6b): the plan's original
/// Task 5 design hoisted intent-invariant subresults (cloud /
/// darkness / moon severity / altitude / stability / smoke /
/// elevation) into a compute-once helper so dual-intent scoring
/// costs <1.15× single-intent. The wrapper approach here costs
/// ~2× for dual-intent. For tens-of-targets-per-location-per-tick
/// (Plan 5 scope) this is sub-100ms and well within the user-
/// visible budget; at multi-location scoring scale (Plan 7) it
/// needs the refactor. Deferring until the 10-column Plan 5.5
/// weight shape is known so we don't extract-now, rewrite-later.
///
/// Receives:
/// - [intents] — which intents to score. Empty set is a caller bug
///   (return value would be an empty map, and no UI branch expects
///   that) — throws ArgumentError.
/// - all other parameters are forwarded to [scoreTarget] unchanged,
///   with one caveat: [imagingMode] applies ONLY to the imaging-
///   intent result. For visual intent the override path skips
///   imaging-mode adjustments (narrowband Hα weighting doesn't make
///   sense at an eyepiece). Pass [imagingMode] freely — it silently
///   no-ops on the visual result rather than raising.
///
/// Returns: a map with one entry per requested intent. Iteration
/// order matches the set's iteration order; the UI should not depend
/// on map order.
Map<ObservingIntent, TargetScore> scoreTargetByIntent({
	required Set<ObservingIntent> intents,
	required WeatherForecast forecast,
	required StabilityAssessment stability,
	required ObservableWindow observableWindow,
	required MoonImpactAssessment moonImpact,
	required DarkWindow darkWindow,
	required TargetType targetType,
	ObjectProperties? objectProperties,
	RigProperties? rigProperties,
	TimeWindow? userWindow,
	int? travelMinutes,
	DateTime? currentTime,
	ImagingMode? imagingMode,
	int userMinAltitude = 30,
	double siteElevation = 0.0,
	double precipitationVetoThreshold = 70.0,
	double windVetoThreshold = 25.0,
	double dewSpreadVetoThreshold = 2.0,
	int? siteBortle,
}) {
	if (intents.isEmpty) {
		throw ArgumentError(
			'scoreTargetByIntent: intents set must be non-empty — '
			'an empty set would produce an empty map which no UI '
			'surface handles',
		);
	}

	final result = <ObservingIntent, TargetScore>{};
	for (final intent in intents) {
		// For visual intent, override the weight profile with the
		// visual-weighted 6→7 column mapping. For imaging, pass
		// null so scoreTarget uses its existing targetType-based
		// derivation (identical to pre-Phase-F behavior).
		final override = intent == ObservingIntent.visual
			? visualWeightProfileFor(targetType)
			: null;
		result[intent] = scoreTarget(
			forecast: forecast,
			stability: stability,
			observableWindow: observableWindow,
			moonImpact: moonImpact,
			darkWindow: darkWindow,
			targetType: targetType,
			objectProperties: objectProperties,
			rigProperties: rigProperties,
			userWindow: userWindow,
			travelMinutes: travelMinutes,
			currentTime: currentTime,
			imagingMode: imagingMode,
			userMinAltitude: userMinAltitude,
			siteElevation: siteElevation,
			precipitationVetoThreshold: precipitationVetoThreshold,
			windVetoThreshold: windVetoThreshold,
			dewSpreadVetoThreshold: dewSpreadVetoThreshold,
			siteBortle: siteBortle,
			weightProfileOverride: override,
		);
	}
	return result;
}

/// Returns location-level scores keyed by [ObservingIntent]. Phase F
/// Task 6 — ships the Map-return API contract that Plan 6 cross-
/// location ranking depends on (spec §9.2 bounds the ranking to one
/// primary-intent score per location, run in a background isolate,
/// so a Map-keyed output is the stable shape).
///
/// Phase F note: location-level factors (cloud, stability, darkness,
/// moon) aggregate a forecast window's conditions — they don't have
/// a target or eyepiece to diverge against, so the returned
/// [LocationScore] is intent-invariant in this phase. Every requested
/// intent maps to the same underlying [LocationScore] computed from
/// the shared inputs. Plan 5.5 / Plan 6b can add per-intent location
/// weighting when:
///   (a) visual observing introduces location-level Bortle emphasis
///       that imaging doesn't weight the same way, OR
///   (b) equipment-aware factors (eyepiece inventory per location)
///       affect the location verdict.
/// Until then, Map<Intent, LocationScore> with identical values per
/// key is the right API shape for the callers (dual-intent dashboard,
/// intent-aware notifications).
///
/// Signature is isolate-safe: no Ref reads, no singletons, every
/// dependency is passed in. Plan 6 cross-location ranking can ship
/// this into an isolate without refactoring.
Map<ObservingIntent, LocationScore> scoreLocationByIntent({
	required Set<ObservingIntent> intents,
	required WeatherForecast forecast,
	required DarkWindow darkWindow,
	required double moonIlluminationPercent,
	TimeWindow? userWindow,
}) {
	if (intents.isEmpty) {
		throw ArgumentError(
			'scoreLocationByIntent: intents set must be non-empty',
		);
	}
	final shared = scoreLocation(
		forecast: forecast,
		darkWindow: darkWindow,
		moonIlluminationPercent: moonIlluminationPercent,
		userWindow: userWindow,
	);
	return {for (final intent in intents) intent: shared};
}

/// Formats a UTC DateTime as a short time string (e.g., "10:30pm").
///
/// Note: this shows UTC hours directly. Plan 4 (UI) will convert to
/// local time for display. This is sufficient for scoring engine reasoning.
///
/// Receives: [utc] — a UTC DateTime to format.
/// Returns: a string like "10:30pm UTC" or "12am UTC".
/// The "UTC" suffix prevents confusion — these times are not local time.
/// Plan 6 can add proper timezone-aware formatting.
String _formatUtcTime(DateTime utc) {
	final hour = utc.hour;
	final minute = utc.minute;
	final period = hour >= 12 ? 'pm' : 'am';
	final displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
	final minuteStr = minute == 0 ? '' : ':${minute.toString().padLeft(2, '0')}';
	return '$displayHour$minuteStr$period UTC';
}
