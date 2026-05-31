// lib/weather/atmospheric_stability.dart
// Ground-level atmospheric stability proxy for astrophotography.
//
// Combines six weather indicators into a single stability assessment.
// This is a ROUGH ESTIMATE from surface conditions — explicitly labeled
// "Atmospheric Stability" (never "seeing"). The Premium tier feature.
// Pro tier (Plan 6) adds real seeing forecasts from Meteoblue.
//
// All scoring functions are pure — no framework, HTTP, or database deps.
import 'weather_models.dart';

/// Stability quality labels — broad categories for quick assessment.
///
/// These map directly to UI color coding:
/// good = green, fair = yellow, poor = red.
enum StabilityLabel {
	/// Score 70–100: conditions favorable for imaging.
	good,

	/// Score 40–69: conditions usable but compromised.
	fair,

	/// Score 0–39: conditions unfavorable for imaging.
	poor,
}

/// Assessment for one stability factor, used in reasoning strings.
class FactorAssessment {
	/// Score for this factor (0–100, higher = better conditions).
	final int score;

	/// Human-readable explanation of the score.
	final String description;

	/// Creates a [FactorAssessment].
	const FactorAssessment({required this.score, required this.description});
}

/// Complete stability assessment — composite score + per-factor breakdown.
///
/// The [factors] map lets the scoring engine and UI explain which
/// conditions are helping or hurting.
class StabilityAssessment {
	/// Composite stability score (0–100).
	final int score;

	/// Broad quality label derived from [score].
	final StabilityLabel label;

	/// Per-factor breakdown with individual scores and descriptions.
	/// Keys: 'dewRisk', 'wind', 'gustFactor', 'humidity', 'coolingRate', 'visibility'.
	final Map<String, FactorAssessment> factors;

	/// Creates a [StabilityAssessment].
	const StabilityAssessment({
		required this.score,
		required this.label,
		required this.factors,
	});
}

/// Assesses atmospheric stability from a window of consecutive hourly data.
///
/// Requires at least 2 hours (needed for cooling rate calculation).
/// All six factors are scored 0–100, then combined via weighted average.
///
/// Receives: [hours] — consecutive HourlyWeather entries (≥ 2 required).
/// Returns: a [StabilityAssessment] with composite score and per-factor detail.
/// Throws [ArgumentError] if fewer than 2 hours are provided.
StabilityAssessment assessStability(List<HourlyWeather> hours) {
	if (hours.length < 2) {
		throw ArgumentError(
			'Need at least 2 hours for stability assessment (got ${hours.length})',
		);
	}

	// Use the most recent hour for point-in-time factors, and the full
	// window for rate-of-change factors (cooling rate).
	final current = hours.last;

	// ── NaN guard ────────────────────────────────────────────────────────
	// weather_models.dart (#32) defaults temperature/dewpoint to NaN when
	// the API field is missing. NaN arithmetic propagates silently, but
	// NaN.round() THROWS in Dart. Filter to hours with valid temp/dewpoint
	// for dew-related calculations. If current hour has NaN, use neutral
	// scores (50) for dew and humidity to avoid crashing.
	// Regression fix found by post-hardening review (SFH agent).
	final hasValidTemp = !current.temperature.isNaN && !current.dewpoint.isNaN;

	// ── Factor 1: Dew risk (temp − dewpoint spread) ──────────────────────
	// Large spread = dry optics (good). Small spread = fogging risk (bad).
	// Weight is low (0.3) because most astro setups have dew heaters.
	final dewSpread = hasValidTemp
		? current.temperature - current.dewpoint
		: 5.0; // neutral default when data missing — mid-range, no penalty/bonus
	// Thresholds adjusted for radiative cooling: telescope optics cool
	// 1-2°C below ambient via radiative emission to the cold sky. So a
	// 3°C ambient spread means optics may already be at/below dewpoint.
	// ESO closes telescopes at 1.5°C spread. Sources: ESO operational
	// rules, BAA "Dealing with Dew", BBC Sky at Night thermal guide.
	final dewScore = _linearScore(dewSpread, poorAt: 3.0, goodAt: 8.0);
	final dewDesc = dewSpread < 3.0
		? 'Dewpoint spread ${dewSpread.toStringAsFixed(1)}°C — high fog risk'
		: dewSpread < 6.0
			? 'Dewpoint spread ${dewSpread.toStringAsFixed(1)}°C — moderate dew risk'
			: 'Dewpoint spread ${dewSpread.toStringAsFixed(1)}°C — low dew risk';

	// ── Factor 2: Wind (monotonic — more = worse, dead calm = best) ──────
	// Threshold lowered from 30 to 25 km/h per community consensus: most
	// imagers give up at ~25 km/h (16 mph). The quality loss is steepest
	// 0-15 km/h (mount vibration onset), manageable 15-25, abandoned 25+.
	final windScore = _linearScore(current.windSpeed, poorAt: 25.0, goodAt: 0.0);
	final windDesc = current.windSpeed < 15.0
		? 'Wind ${current.windSpeed.toStringAsFixed(0)} km/h — light, good for tracking'
		: 'Wind ${current.windSpeed.toStringAsFixed(0)} km/h — may cause tracking errors';

	// ── Factor 3: Gust factor (gusts / sustained wind) ───────────────────
	// Gusty conditions are worse than steady wind for mount tracking.
	final gustRatio = current.windSpeed > 0
		? current.windGusts / current.windSpeed
		: 1.0; // No wind → no gusts → perfect ratio
	final gustScore = _linearScore(gustRatio, poorAt: 2.0, goodAt: 1.5);
	final gustDesc = gustRatio > 2.0
		? 'Gusts ${gustRatio.toStringAsFixed(1)}x sustained — very gusty'
		: 'Gusts ${gustRatio.toStringAsFixed(1)}x sustained — manageable';

	// ── Factor 4: Humidity ────────────────────────────────────────────────
	// Range widened: stability aspect of humidity is about extreme conditions
	// only. Transparency impact is captured by the smoke/AOD factor.
	// At 90%+: direct imaging problems (condensation, haze). Below 50%: fine.
	final humidityScore = _linearScore(current.humidity, poorAt: 90.0, goodAt: 50.0);
	final humidityDesc = current.humidity > 90.0
		? 'Humidity ${current.humidity.toStringAsFixed(0)}% — hazy, poor transparency'
		: 'Humidity ${current.humidity.toStringAsFixed(0)}%';

	// ── Factor 5: Cooling rate (°C/hr between consecutive hours) ─────────
	// Fast cooling = tube currents as optics lag the environment.
	// Guard NaN: if either hour has NaN temperature, use 0.0 (no cooling
	// penalty) — same neutral default as the dewSpread guard above.
	final prevTemp = hours[hours.length - 2].temperature;
	final coolingRate = (hasValidTemp && !prevTemp.isNaN)
		? (prevTemp - current.temperature).clamp(0.0, double.infinity)
		: 0.0; // Only penalize cooling, not warming; neutral when data missing
	final coolingScore = _linearScore(coolingRate, poorAt: 3.0, goodAt: 0.0);
	final coolingDesc = coolingRate > 3.0
		? 'Cooling ${coolingRate.toStringAsFixed(1)}°C/hr — significant tube currents likely'
		: coolingRate > 1.0
			? 'Cooling ${coolingRate.toStringAsFixed(1)}°C/hr — some thermal settling needed'
			: 'Temperature stable — good thermal equilibrium';

	// ── Factor 6: Visibility ─────────────────────────────────────────────
	// visibility is in metres; convert thresholds to metres for consistency.
	final visScore = _linearScore(
		current.visibility,
		poorAt: 5000.0,
		goodAt: 20000.0,
	);
	final visDesc = current.visibility < 5000.0
		? 'Visibility ${(current.visibility / 1000).toStringAsFixed(0)} km — poor transparency'
		: 'Visibility ${(current.visibility / 1000).toStringAsFixed(0)} km';

	// ── Composite ────────────────────────────────────────────────────────
	// Weighted average of the six factors. Weights calibrated from research:
	//
	// dewRisk (0.3): Low because most setups have dew heaters. Thresholds
	//   adjusted for radiative cooling (optics cool 1-2°C below ambient).
	// wind (1.0): Mount tracking is directly affected. Community consensus:
	//   most imagers give up at ~25 km/h.
	// gustFactor (0.7): Gusts are worse than steady wind for tracking.
	// humidity (0.8): Reduced from 1.5 — was double-counting with the
	//   smoke/transparency factor. Humidity affects transparency (captured
	//   there) more than turbulence (captured here). Only extreme humidity
	//   (>90%) causes direct stability problems.
	// coolingRate (0.8): Raised from 0.6 — rapid cooling is one of the
	//   strongest ground-layer seeing drivers. Tube currents + ground
	//   convection from temperature change degrade images significantly.
	// visibility (0.6): Reduced from 1.5 — visibility is primarily a
	//   transparency metric (atmospheric scattering), not a turbulence
	//   metric. The transparency signal is better captured by smoke/AOD.
	//   The weak correlation with seeing doesn't justify 1.5.
	//
	// Sources: ESO operational data, Cloudy Nights community surveys,
	// S&T seeing/transparency articles, BAA seeing guides.
	const weights = {
		'dewRisk': 0.3,
		'wind': 1.0,
		'gustFactor': 0.7,
		'humidity': 0.8,
		'coolingRate': 0.8,
		'visibility': 0.6,
	};

	final scores = {
		'dewRisk': dewScore,
		'wind': windScore,
		'gustFactor': gustScore,
		'humidity': humidityScore,
		'coolingRate': coolingScore,
		'visibility': visScore,
	};

	final descriptions = {
		'dewRisk': dewDesc,
		'wind': windDesc,
		'gustFactor': gustDesc,
		'humidity': humidityDesc,
		'coolingRate': coolingDesc,
		'visibility': visDesc,
	};

	// Weighted average: sum(weight * score) / sum(weight)
	var weightedSum = 0.0;
	var totalWeight = 0.0;
	for (final key in weights.keys) {
		weightedSum += weights[key]! * scores[key]!;
		totalWeight += weights[key]!;
	}
	final composite = (weightedSum / totalWeight).round();

	// Label from composite score.
	final label = composite >= 70
		? StabilityLabel.good
		: composite >= 40
			? StabilityLabel.fair
			: StabilityLabel.poor;

	// Build per-factor assessment map.
	final factors = <String, FactorAssessment>{};
	for (final key in scores.keys) {
		factors[key] = FactorAssessment(
			score: scores[key]!,
			description: descriptions[key]!,
		);
	}

	return StabilityAssessment(score: composite, label: label, factors: factors);
}

/// Linearly interpolates a value between [poorAt] and [goodAt] to a 0–100 score.
///
/// If [goodAt] < [poorAt], the scale is inverted (lower value = better).
/// Result is clamped to [0, 100].
int _linearScore(double value, {required double poorAt, required double goodAt}) {
	if (goodAt == poorAt) return 50;
	// Normalize: 0.0 at poorAt, 1.0 at goodAt.
	final normalized = (value - poorAt) / (goodAt - poorAt);
	return (normalized.clamp(0.0, 1.0) * 100).round();
}
