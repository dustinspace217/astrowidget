// lib/scoring/veto_evaluator.dart
// Safety veto system for imaging session scoring.
//
// Four independent vetoes that block a session with a specific reason:
//   1. Cloud — imaging is physically impossible (>95% total cloud)
//   2. Precipitation — equipment damage risk (user-configurable threshold)
//   3. Wind — tracking failure and equipment damage (user-configurable)
//   4. Condensation — optics/electronics damage (user-configurable dew spread)
//
// Extracted from scoring_engine.dart so each veto is independently testable
// and the veto contract is explicit. The scoring engine calls evaluateAll()
// and returns a zero-score if any veto fires.
//
// Each veto is a pure function: weather data + threshold → VetoResult?
// No veto depends on another — a clear sky with hurricane winds still vetoes.
//
// Bug fix: GitHub #35 (3/4 vetoes were untested).
import '../weather/weather_models.dart';

/// Result of a veto evaluation — returned when a veto fires.
///
/// Contains the reason string shown to the user explaining why the
/// session was vetoed and which veto fired.
class VetoResult {
	/// Which veto fired (cloud, precipitation, wind, condensation).
	final String vetoName;

	/// Human-readable reason string shown in the scoring UI.
	final String reason;

	/// Creates a [VetoResult].
	const VetoResult({required this.vetoName, required this.reason});
}

/// Evaluates safety vetoes against weather data.
///
/// Pure functions — no state, no side effects. Each takes hourly weather
/// data and user-configured thresholds, returns either a [VetoResult]
/// (session blocked) or null (veto does not fire).
///
/// Thresholds are user-configurable because different setups have different
/// tolerances:
/// - Remote/unattended setups need stricter precipitation thresholds
/// - Large telescopes are more wind-sensitive than small refractors
/// - Heated dew shields raise condensation tolerance
class VetoEvaluator {
	/// Evaluates all four vetoes in priority order.
	///
	/// Returns the FIRST veto that fires, or null if all pass.
	/// Order matters for UX — cloud first (most fundamental), then
	/// precipitation, wind, condensation.
	///
	/// Receives:
	/// - [cloudFactor] — the cloud score (0-100, from _cloudScore)
	/// - [effectiveHours] — weather data during the imaging window
	/// - [precipThreshold] — max acceptable precipitation probability (%)
	/// - [windThreshold] — max acceptable wind speed (km/h)
	/// - [dewSpreadThreshold] — min acceptable dew spread (°C)
	///
	/// Returns: the first [VetoResult] that fires, or null if none fire.
	static VetoResult? evaluateAll({
		required int cloudFactor,
		required List<HourlyWeather> effectiveHours,
		required double precipThreshold,
		required double windThreshold,
		required double dewSpreadThreshold,
	}) {
		return checkCloud(cloudFactor) ??
			checkPrecipitation(effectiveHours, precipThreshold) ??
			checkWind(effectiveHours, windThreshold) ??
			checkCondensation(effectiveHours, dewSpreadThreshold);
	}

	/// Veto 1: Cloud cover — imaging is physically impossible.
	///
	/// Fires when the cloud factor score is ≤ 5 (effectively >95% cover).
	/// This is a hard physical limit — no amount of good equipment or
	/// technique can image through a solid overcast layer.
	///
	/// Receives: [cloudFactor] — cloud score 0-100 from _cloudScore.
	/// Returns: [VetoResult] if cloud cover blocks imaging, null otherwise.
	static VetoResult? checkCloud(int cloudFactor) {
		if (cloudFactor <= 5) {
			return VetoResult(
				vetoName: 'cloud',
				reason: 'Total overcast — imaging not possible tonight.',
			);
		}
		return null;
	}

	/// Veto 2: Precipitation — equipment damage risk.
	///
	/// Fires when average precipitation probability across the effective
	/// window exceeds the user's threshold. Default threshold is 70%,
	/// but remote/unattended operators may set as low as 30%.
	///
	/// Receives:
	/// - [hours] — hourly weather data during the imaging window
	/// - [threshold] — user's max acceptable precipitation probability (%)
	///
	/// Returns: [VetoResult] if precipitation risk is too high, null otherwise.
	static VetoResult? checkPrecipitation(
		List<HourlyWeather> hours, double threshold,
	) {
		if (hours.isEmpty) return null;
		// Skip NaN hours (absent data): precipitationProbability's absent
		// default became NaN on 2026-06-09 (see weather_models.dart). Without
		// this filter, one missing hour NaN-poisons the average and silently
		// DISABLES this veto for any scoreTarget/evaluateAll consumer. The
		// astrowidget wrapper never calls this path (it peak-checks instead),
		// but the vendored engine must stay internally NaN-safe — same guard
		// pattern as checkCondensation's temp/dewpoint handling (GitHub #32).
		final valid = hours
			.map((h) => h.precipitationProbability)
			.where((p) => !p.isNaN)
			.toList();
		if (valid.isEmpty) return null;
		final avgPrecipProb = valid.reduce((a, b) => a + b) / valid.length;
		if (avgPrecipProb > threshold) {
			return VetoResult(
				vetoName: 'precipitation',
				reason: 'Precipitation probability ${avgPrecipProb.toStringAsFixed(0)}% '
					'exceeds your ${threshold.toStringAsFixed(0)}% threshold '
					'— protect your equipment.',
			);
		}
		return null;
	}

	/// Veto 3: Wind — equipment damage and tracking failure.
	///
	/// Fires when average wind speed exceeds the user's threshold.
	/// Default 25 km/h — larger scopes should use lower thresholds
	/// (a 14" f/4 Newtonian is a sail at 15 km/h).
	///
	/// Receives:
	/// - [hours] — hourly weather data during the imaging window
	/// - [threshold] — user's max acceptable wind speed (km/h)
	///
	/// Returns: [VetoResult] if wind is too strong, null otherwise.
	static VetoResult? checkWind(
		List<HourlyWeather> hours, double threshold,
	) {
		if (hours.isEmpty) return null;
		final avgWind = hours
			.map((h) => h.windSpeed)
			.reduce((a, b) => a + b) / hours.length;
		if (avgWind > threshold) {
			return VetoResult(
				vetoName: 'wind',
				reason: 'Wind ${avgWind.toStringAsFixed(0)} km/h exceeds your '
					'${threshold.toStringAsFixed(0)} km/h threshold '
					'— tracking and equipment safety at risk.',
			);
		}
		return null;
	}

	/// Veto 4: Condensation — optics and electronics damage.
	///
	/// Fires when the average dew point spread (temperature - dewpoint)
	/// falls below the threshold. A spread near 0°C means condensation
	/// is forming; the ESO 1.5°C rule is a common professional standard.
	///
	/// Skips the check if any temperature or dewpoint value is NaN (missing
	/// data — the weather_models.dart defaults changed from 0.0 to NaN in
	/// GitHub #32 to prevent false vetoes on absent data).
	///
	/// Receives:
	/// - [hours] — hourly weather data during the imaging window
	/// - [threshold] — minimum acceptable dew spread (°C)
	///
	/// Returns: [VetoResult] if condensation risk is too high, null otherwise.
	static VetoResult? checkCondensation(
		List<HourlyWeather> hours, double threshold,
	) {
		if (hours.isEmpty) return null;
		// Filter out hours with NaN temp/dewpoint (missing data from #32 fix).
		// NaN arithmetic propagates: NaN - NaN = NaN, and NaN < threshold is
		// always false in Dart, so this is a belt-and-suspenders check.
		final validHours = hours.where(
			(h) => !h.temperature.isNaN && !h.dewpoint.isNaN,
		).toList();
		if (validHours.isEmpty) return null;

		final avgDewSpread = validHours
			.map((h) => h.temperature - h.dewpoint)
			.reduce((a, b) => a + b) / validHours.length;
		if (avgDewSpread < threshold) {
			return VetoResult(
				vetoName: 'condensation',
				reason: 'Dew point spread ${avgDewSpread.toStringAsFixed(1)}°C is below your '
					'${threshold.toStringAsFixed(1)}°C threshold '
					'— condensation will form on optics and electronics.',
			);
		}
		return null;
	}
}
