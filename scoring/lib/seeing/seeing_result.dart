// lib/seeing/seeing_result.dart
//
// Sealed class for derived seeing computation outputs. Distinguishes
// a valid estimate from a "couldn't compute" state — so UI can render
// "Seeing: 1.2 arcsec" vs "Seeing unavailable (missing: ...)" without
// magic sentinel values (NaN, -1, null) leaking past the service
// boundary.
//
// The two variants map directly to the availability classifier's
// output (§10.2): required inputs missing → Unavailable; otherwise
// Available (possibly with missingOptionalTerms notes for UI surfacing
// a small-print caveat).
//
// Why sealed rather than a simple nullable double: the UI treats
// "unavailable" differently from "available" — different copy, different
// icon, an "About this estimate" link only on Available. Exhaustive
// pattern matching on the sealed type is the compile-time guarantee
// that new call sites can't forget either branch.

import '../logging/app_logger.dart';

/// Result of deriving seeing from pressure-level weather data. Either
/// a numeric estimate ([SeeingResultAvailable]) or a structured
/// "can't compute" reason ([SeeingResultUnavailable]).
sealed class SeeingResult {
	const SeeingResult();

	/// Constructs an Available result with a numeric arcsec value and
	/// a list of optional inputs that were missing (informs UI copy
	/// like "based on partial atmospheric data").
	const factory SeeingResult.available({
		required double arcsec,
		required List<String> missingOptionalTerms,
	}) = SeeingResultAvailable;

	/// Constructs an Unavailable result carrying the list of required
	/// inputs that were missing. Caller surfaces these in the UI so a
	/// user can distinguish "no weather data" from "partial data."
	const factory SeeingResult.unavailable({
		required List<String> missingRequiredTerms,
	}) = SeeingResultUnavailable;

	/// Serializes this result to a JSON-compatible map for cache storage.
	///
	/// The `kind` key is the sealed-class discriminator — `fromJson`
	/// switches on it to pick the right variant. We use human-readable
	/// strings ('available' / 'unavailable') rather than an int enum so
	/// cache dumps stay legible when debugging and so a future variant
	/// (e.g. 'computing') doesn't collide with an old int value.
	Map<String, dynamic> toJson();

	/// Deserializes from a JSON map produced by [toJson].
	///
	/// Returns null for unknown/missing `kind` values AND for malformed
	/// known-kind payloads (e.g., missing `arcsec`, non-numeric arcsec,
	/// list containing non-strings). Defensive handling for four
	/// scenarios:
	///   (a) a future variant ships, old-app reads new cache after
	///       upgrade (forward-compat)
	///   (b) cache corruption or external tampering
	///   (c) a mid-write crash leaving a partial JSON object
	///   (d) a cross-version rollback where the schema drifted
	/// All four are better surfaced as "no seeing data" than a crash —
	/// callers get a nullable [SeeingResult] and null propagates
	/// through [WeatherForecast.derivedSeeing] the same way "never
	/// computed" does. We log a warning with the discriminator so a
	/// systemic problem is visible in diagnostics exports, rather than
	/// silently degrading.
	///
	/// Phase E Task 9 fix: previously a malformed known-kind payload
	/// (e.g., `{kind: 'available', arcsec: null}`) threw TypeError
	/// mid-`WeatherForecast.fromJson` and took down the whole weather
	/// provider, not just the seeing field. Caught by cross-agent
	/// consensus (test/security/adversarial/silent-failure agents).
	static SeeingResult? fromJson(Map<String, dynamic> json) {
		final kind = json['kind'];
		try {
			switch (kind) {
				case 'available':
					final rawArcsec = json['arcsec'];
					if (rawArcsec is! num) {
						logger.warning(
							'seeing',
							'SeeingResult.fromJson: kind=available but '
								'arcsec is ${rawArcsec.runtimeType} — returning null',
						);
						return null;
					}
					return SeeingResultAvailable(
						arcsec: rawArcsec.toDouble(),
						missingOptionalTerms:
							((json['missingOptionalTerms'] as List?) ?? const [])
								// whereType, not cast: silently skip non-string
								// entries rather than throwing on them.
								.whereType<String>()
								.toList(),
					);
				case 'unavailable':
					return SeeingResultUnavailable(
						missingRequiredTerms:
							((json['missingRequiredTerms'] as List?) ?? const [])
								.whereType<String>()
								.toList(),
					);
				default:
					logger.warning(
						'seeing',
						'SeeingResult.fromJson: unknown kind '
							'"${kind ?? '<missing>'}" — returning null',
					);
					return null;
			}
		} catch (e, s) {
			// Final safety net for shapes we didn't anticipate. Emits at
			// warning (not error) because user impact is "seeing missing
			// for one cache row," not an app-wide failure.
			logger.warning(
				'seeing',
				'SeeingResult.fromJson: malformed payload for kind '
					'"$kind" — returning null',
				error: e,
				stackTrace: s,
			);
			return null;
		}
	}
}

/// Formula produced a numeric estimate. [arcsec] is the total derived
/// seeing in arcseconds (smaller is better). [missingOptionalTerms]
/// lists any optional inputs that were absent so UI can disclose the
/// caveat.
class SeeingResultAvailable extends SeeingResult {
	/// Derived seeing in arcseconds. Typical good sites: 1.0–1.5″.
	final double arcsec;

	/// Optional Open-Meteo inputs that were missing (humidity, 850 hPa
	/// wind). An empty list means the full-precision formula ran.
	final List<String> missingOptionalTerms;

	const SeeingResultAvailable({
		required this.arcsec,
		required this.missingOptionalTerms,
	});

	/// Serializes to a JSON-compatible map. When arcsec is non-finite
	/// (NaN or Infinity — should not happen with a correct formula but
	/// can land here if a future coefficient change overflows), we
	/// downgrade to an Unavailable shape rather than serializing a
	/// non-standard JSON token. jsonEncode(double.nan) emits the bare
	/// token `NaN` which: (a) is not valid JSON per RFC 8259, so a
	/// future export/sync path parsing our cache with a strict parser
	/// would crash; (b) round-trips through jsonDecode as a double.nan
	/// that then crashes [_derivedSeeingScore] on .round(). This guard
	/// keeps the cache honest — if we can't produce a real number, we
	/// say so explicitly. Caught in Phase E Task 9 adversarial review.
	@override
	Map<String, dynamic> toJson() {
		if (!arcsec.isFinite) {
			return const {
				'kind': 'unavailable',
				'missingRequiredTerms': ['non_finite_arcsec'],
			};
		}
		return {
			'kind': 'available',
			'arcsec': arcsec,
			'missingOptionalTerms': missingOptionalTerms,
		};
	}
}

/// Formula could not produce an estimate because one or more required
/// inputs were null. [missingRequiredTerms] names them so the UI can
/// render "Seeing unavailable (missing: wind_speed_250hPa, ...)".
class SeeingResultUnavailable extends SeeingResult {
	/// Required Open-Meteo inputs that were missing. Non-empty by
	/// construction — an empty list would imply the result should
	/// have been Available.
	final List<String> missingRequiredTerms;

	const SeeingResultUnavailable({required this.missingRequiredTerms});

	@override
	Map<String, dynamic> toJson() => {
		'kind': 'unavailable',
		'missingRequiredTerms': missingRequiredTerms,
	};
}
