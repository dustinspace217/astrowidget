// lib/astro/coordinates.dart
// Coordinate transform utilities for astronomical calculations.
//
// Key systems:
// - Equatorial (RA/Dec): "sky coordinates" — right ascension in hours,
//   declination in degrees. The standard system for star catalogs.
// - Ecliptic (longitude/latitude): relative to Earth's orbital plane.
// - Horizontal (altitude/azimuth): relative to the observer's horizon.
import 'dart:math';
import 'constants.dart';

/// Ecliptic coordinates result.
/// A Dart record type — a lightweight, immutable named tuple.
/// Access fields as `result.longitude` and `result.latitude`.
typedef EclipticCoords = ({double longitude, double latitude});

/// Compute the angular separation between two points on the celestial sphere.
///
/// Uses the spherical law of cosines:
///   cos(d) = sin(dec1)*sin(dec2) + cos(dec1)*cos(dec2)*cos(ra1 - ra2)
///
/// Receives:
/// - [ra1Hours] / [ra2Hours]: right ascension of each object, in hours (0–24)
/// - [dec1Deg] / [dec2Deg]: declination of each object, in degrees (−90 to +90)
///
/// Returns: angular separation in degrees (0–180).
///
/// The result is clamped before acos to guard against floating-point values
/// just outside [−1, 1] that would produce NaN.
double angularSeparation({
	required double ra1Hours,
	required double dec1Deg,
	required double ra2Hours,
	required double dec2Deg,
}) {
	// Convert RA from hours to radians (1h = 15°, 1° = deg2Rad)
	final ra1 = ra1Hours * 15.0 * AstroConstants.deg2Rad;
	final ra2 = ra2Hours * 15.0 * AstroConstants.deg2Rad;
	// Convert declinations from degrees to radians
	final dec1 = dec1Deg * AstroConstants.deg2Rad;
	final dec2 = dec2Deg * AstroConstants.deg2Rad;
	// Spherical law of cosines — cosine of the angular distance
	final cosD = sin(dec1) * sin(dec2) +
		cos(dec1) * cos(dec2) * cos(ra1 - ra2);
	// Clamp to [−1, 1] to prevent domain errors from floating-point rounding
	final clamped = cosD.clamp(-1.0, 1.0);
	// acos returns radians; convert to degrees for the return value
	return acos(clamped) * AstroConstants.rad2Deg;
}

/// Convert equatorial coordinates (RA/Dec) to ecliptic coordinates
/// (longitude λ, latitude β) using the standard rotation by the obliquity ε.
///
/// Receives:
/// - [raHours]: right ascension in hours (0–24)
/// - [decDeg]: declination in degrees (−90 to +90)
/// - [obliquityDeg]: axial tilt of Earth in degrees; defaults to J2000.0 value
///   (23.439291111°) from [AstroConstants.j2000Obliquity]
///
/// Returns: an [EclipticCoords] record with:
/// - `longitude`: ecliptic longitude λ in degrees (0–360)
/// - `latitude`: ecliptic latitude β in degrees (−90 to +90)
///
/// Formulas from Meeus "Astronomical Algorithms" §13.
EclipticCoords equatorialToEcliptic({
	required double raHours,
	required double decDeg,
	double obliquityDeg = AstroConstants.j2000Obliquity,
}) {
	// Convert all angles to radians for trig functions
	final ra  = raHours * 15.0 * AstroConstants.deg2Rad;
	final dec = decDeg * AstroConstants.deg2Rad;
	final eps = obliquityDeg * AstroConstants.deg2Rad; // obliquity ε

	// Ecliptic latitude β: sin(β) = sin(δ)cos(ε) − cos(δ)sin(ε)sin(α)
	final sinBeta = sin(dec) * cos(eps) - cos(dec) * sin(eps) * sin(ra);
	final beta = asin(sinBeta.clamp(-1.0, 1.0)); // latitude in radians

	// Ecliptic longitude λ: computed via atan2 for correct quadrant
	// y = sin(α)cos(ε) + tan(δ)sin(ε)
	// x = cos(α)
	final y = sin(ra) * cos(eps) + tan(dec) * sin(eps);
	final x = cos(ra);
	var lambda = atan2(y, x); // longitude in radians, range (−π, π)
	// Normalize to [0, 2π) so the returned degree value is always 0–360
	if (lambda < 0) lambda += 2 * pi;

	// Return as a named Dart record — callers access .longitude and .latitude
	return (
		longitude: lambda * AstroConstants.rad2Deg,
		latitude:  beta   * AstroConstants.rad2Deg,
	);
}

/// Convert right ascension hours (0–24) to degrees (0–360).
/// 1 hour of RA = 15 degrees (the sky rotates 360° in 24 hours).
///
/// Receives: [hours] — RA value in hours.
/// Returns: equivalent angle in degrees.
double hoursToDegrees(double hours) => hours * 15.0;

/// Convert degrees (0–360) to right ascension hours (0–24).
/// Inverse of [hoursToDegrees].
///
/// Receives: [degrees] — angle in degrees.
/// Returns: equivalent RA in hours.
double degreesToHours(double degrees) => degrees / 15.0;
