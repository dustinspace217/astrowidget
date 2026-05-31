// lib/astro/constants.dart
// Fundamental astronomical constants used across the astronomy engine.
//
// Sources:
// - IAU 2012 System of Astronomical Constants
// - Meeus "Astronomical Algorithms" 2nd edition
// - USNO Circular 179
import 'dart:math';

/// All astronomical constants in one place.
/// Private constructor prevents instantiation — this is a namespace,
/// not a class meant to be created with `const AstroConstants()`.
class AstroConstants {
	AstroConstants._();

	// ── Distance & Scale ──

	/// Astronomical Unit in kilometres (IAU 2012 definition).
	static const double auKm = 149597870.7;

	/// Speed of light in km/s (exact by SI definition).
	static const double lightSpeedKmS = 299792.458;

	// ── Time ──

	/// Julian Date of J2000.0 epoch (2000 Jan 1.5 TT = noon on Jan 1 2000 UTC).
	/// Used as the zero point for daysSinceJ2000 and julianCentury.
	static const double j2000Jd = 2451545.0;

	/// Number of days in one Julian century (exactly 36525 days).
	/// Used in the julianCentury time argument T for precession/nutation.
	static const double daysPerJulianCentury = 36525.0;

	/// Number of days in one Julian year (exactly 365.25 days).
	static const double daysPerJulianYear = 365.25;

	// ── Angles ──

	/// Degrees to radians conversion factor (pi / 180).
	static const double deg2Rad = pi / 180.0;

	/// Radians to degrees conversion factor (180 / pi).
	static const double rad2Deg = 180.0 / pi;

	/// Arcseconds per radian (206264.806247″/rad).
	/// Used when converting small angles (parallax, nutation) between units.
	static const double arcsecPerRad = 206264.806247;

	/// Hours per radian — converts radian angles to hours of right ascension.
	static const double hoursPerRad = 12.0 / pi;

	// ── Earth ──

	/// Mean obliquity of the ecliptic at J2000.0 in degrees (Lieske 1977).
	/// The tilt between Earth's equatorial plane and the orbital plane.
	static const double j2000Obliquity = 23.439291111;

	/// Earth's equatorial radius in kilometres (WGS-84).
	static const double earthRadiusKm = 6378.137;

	// ── Sun ──

	/// Sun's mean angular radius in degrees at 1 AU distance.
	/// Used for horizon events (sunrise/sunset) and limb corrections.
	static const double sunAngularRadiusDeg = 0.2666;

	// ── Atmospheric Refraction ──

	/// Standard atmospheric refraction at the horizon in degrees (34').
	/// Applied when computing rise/set times to shift the geometric horizon.
	static const double standardRefractionDeg = 34.0 / 60.0;
}
