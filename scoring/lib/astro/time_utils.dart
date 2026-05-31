// lib/astro/time_utils.dart
// Julian Date and epoch conversion utilities.
//
// Julian Dates are the standard way to express time in astronomy —
// a continuous count of days since noon on January 1, 4713 BCE.
// J2000.0 (JD 2451545.0) is the modern reference epoch used for
// planet positions, precession, nutation, and most other calculations.
import 'constants.dart';

/// Convert a Dart DateTime (UTC) to Julian Date.
///
/// Uses the algorithm from Meeus "Astronomical Algorithms" Ch. 7.
/// Only valid for dates after the Gregorian reform (1582 Oct 15).
///
/// Receives: [dateTime] — a UTC DateTime to convert.
/// Returns: Julian Date as a double (e.g., 2451545.0 for J2000.0).
double dateTimeToJulianDate(DateTime dateTime) {
	// Force UTC — Dart DateTime can hold local time, so we normalise first.
	final utc = dateTime.toUtc();

	// Year and month are adjusted: Meeus treats Jan/Feb as months 13/14 of
	// the previous year so the formula's integer divisions work uniformly.
	int y = utc.year;
	int m = utc.month;
	if (m <= 2) {
		y -= 1;
		m += 12;
	}

	// Build the fractional day: integer day plus sub-day time components.
	final day = utc.day +
		utc.hour / 24.0 +
		utc.minute / 1440.0 +           // 1440 = 24*60 minutes per day
		utc.second / 86400.0 +          // 86400 = 24*60*60 seconds per day
		utc.millisecond / 86400000.0;   // 86400000 milliseconds per day

	// Gregorian calendar correction. 'a' is the century number;
	// 'b' is the Gregorian reform offset (0 for Julian, non-zero for Gregorian).
	final a = (y / 100).floor();
	final b = 2 - a + (a / 4).floor();

	// Meeus formula (equation 7.1). The constants 4716 and 1524.5 shift
	// the origin to the start of the Julian Day count.
	return (365.25 * (y + 4716)).floor() +
		(30.6001 * (m + 1)).floor() +
		day +
		b -
		1524.5;
}

/// Convert Julian Date back to a Dart DateTime (UTC).
///
/// Inverse of [dateTimeToJulianDate]. Uses the algorithm from
/// Meeus "Astronomical Algorithms" Ch. 7.
///
/// Receives: [jd] — Julian Date to convert.
/// Returns: UTC DateTime with seconds precision.
DateTime julianDateToDateTime(double jd) {
	// Split at the JD noon boundary: z = integer part, f = fractional day.
	// Adding 0.5 converts from the JD epoch (noon) to a midnight-anchored value.
	final z = (jd + 0.5).floor();
	final f = (jd + 0.5) - z;

	// Gregorian correction: dates before JD 2299161 (1582 Oct 15) use the
	// Julian calendar; after that date use the Gregorian calendar.
	int a;
	if (z < 2299161) {
		a = z;
	} else {
		final alpha = ((z - 1867216.25) / 36524.25).floor();
		a = z + 1 + alpha - (alpha / 4).floor();
	}

	// Intermediate variables from Meeus table 7.b.
	final b = a + 1524;
	final c = ((b - 122.1) / 365.25).floor();
	final d = (365.25 * c).floor();
	final e = ((b - d) / 30.6001).floor();

	// dayFraction is the day-of-month plus the fractional time within the day.
	final dayFraction = b - d - (30.6001 * e).floor() + f;
	final day = dayFraction.floor();
	final timeFraction = dayFraction - day;  // 0.0 = midnight, 0.5 = noon

	// Recover month: Meeus uses e to distinguish Jan/Feb (months 1/2) from
	// months 3–12, because Jan/Feb were treated as months 13/14 of prior year.
	final month = (e < 14) ? e - 1 : e - 13;
	final year = (month > 2) ? c - 4716 : c - 4715;

	// Convert fractional day to h/m/s, rounding to avoid floating-point drift.
	final totalSeconds = (timeFraction * 86400.0).round();
	final hours = totalSeconds ~/ 3600;          // ~/ is integer division in Dart
	final minutes = (totalSeconds % 3600) ~/ 60;
	final seconds = totalSeconds % 60;

	return DateTime.utc(year, month, day, hours, minutes, seconds);
}

/// Days elapsed since J2000.0 epoch (2000 Jan 1.5 TT ≈ noon UTC Jan 1 2000).
///
/// Positive for dates after 2000, negative for dates before.
/// This is the 'd' or 'D' argument used in simplified solar/lunar formulas.
///
/// Receives: [dateTime] — UTC DateTime.
/// Returns: Days since J2000.0 (can be negative for dates before 2000).
double daysSinceJ2000(DateTime dateTime) {
	// AstroConstants.j2000Jd = 2451545.0 — the JD of the J2000.0 epoch.
	return dateTimeToJulianDate(dateTime) - AstroConstants.j2000Jd;
}

/// Julian centuries since J2000.0.
///
/// One Julian century = 36525 days. This is the time argument T used in
/// polynomial series for precession, nutation, and planetary positions.
/// T = 0 at J2000.0, T = 1 at J2100.0, T = -1 at J1900.0.
///
/// Receives: [dateTime] — UTC DateTime.
/// Returns: Julian centuries since J2000.0.
double julianCentury(DateTime dateTime) {
	// AstroConstants.daysPerJulianCentury = 36525.0
	return daysSinceJ2000(dateTime) / AstroConstants.daysPerJulianCentury;
}
