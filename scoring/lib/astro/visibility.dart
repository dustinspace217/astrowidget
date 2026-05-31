// lib/astro/visibility.dart
// Target visibility computation for astrophotography planning.
//
// Answers three key questions for a given night and observer location:
//   1. "When is it dark enough to image?" → astronomicalDarkWindow()
//   2. "What altitude will my target reach?" → altitudeCurve()
//   3. "How long can I image this target?" → observableWindow()
//
// All times are UTC DateTimes throughout this file.
// Observer coordinates follow the same convention used by the geoengine package:
//   - latitude:  degrees, positive = North
//   - longitude: degrees, positive = East (so US longitudes are negative)
//   - elevation: metres above sea level
//
// geoengine is used for Sun altitude searches and horizon coordinate transforms.
// The transit time calculation is pure Meeus arithmetic (no geoengine needed).
import 'package:geoengine/geoengine.dart' as geo;
import 'time_utils.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Data types
// ─────────────────────────────────────────────────────────────────────────────

/// One sample on an altitude curve: the position of a target at a specific time.
///
/// Built by [altitudeCurve] at regular intervals across the night.
class AltitudePoint {
	/// UTC DateTime for this sample.
	final DateTime time;

	/// Altitude above the horizon in degrees (-90..+90).
	/// Positive values are above the horizon; negative values are below.
	/// Includes atmospheric refraction correction from geoengine.
	final double altitude;

	/// Azimuth in degrees (0..360), measured clockwise from true North.
	/// North = 0°, East = 90°, South = 180°, West = 270°.
	final double azimuth;

	/// Creates an AltitudePoint.
	///
	/// Receives:
	/// - [time] — UTC DateTime of the sample
	/// - [altitude] — degrees above/below horizon (-90..+90)
	/// - [azimuth] — compass bearing in degrees (0..360)
	const AltitudePoint({
		required this.time,
		required this.altitude,
		required this.azimuth,
	});

	@override
	String toString() =>
		'AltitudePoint(time: $time, alt: ${altitude.toStringAsFixed(2)}°, '
		'az: ${azimuth.toStringAsFixed(2)}°)';
}

/// The span of astronomical darkness for one night.
///
/// Astronomical darkness begins when the Sun drops more than 18° below the
/// horizon (astronomical twilight ends) and ends when the Sun rises back
/// through -18° in the morning.  Imaging sessions must fall within this
/// window to avoid twilight sky glow.
class DarkWindow {
	/// UTC DateTime when astronomical darkness begins (Sun crosses -18° going down).
	/// Null if the Sun never reaches -18° on this date (e.g., summer at high latitude).
	final DateTime? start;

	/// UTC DateTime when astronomical darkness ends (Sun crosses -18° coming up).
	/// Null if no morning twilight is found in the search window.
	final DateTime? end;

	/// Creates a DarkWindow.
	///
	/// Receives:
	/// - [start] — evening -18° crossing (nullable)
	/// - [end] — morning -18° crossing (nullable)
	const DarkWindow({this.start, this.end});

	/// Duration of the dark window in hours, or null if either boundary is missing.
	double? get durationHours {
		if (start == null || end == null) return null;
		// difference() returns a Duration; inSeconds gives sub-minute precision.
		return end!.difference(start!).inSeconds / 3600.0;
	}

	/// True when astronomical darkness exists on this date at the queried location.
	/// False for polar summer (sun never reaches -18°) or if either boundary
	/// wasn't found within the search window.
	bool get isAvailable => start != null && end != null;

	@override
	String toString() =>
		'DarkWindow(start: $start, end: $end, '
		'duration: ${durationHours?.toStringAsFixed(2)}h)';
}

/// The window during which a target is both dark AND above a minimum altitude.
///
/// This is the actionable imaging window — it is the intersection of:
///   - The [DarkWindow] for that night (no twilight)
///   - Times when the target is above [minimumAltitude]
///
/// Also records the peak altitude and when it occurs, which helps the user
/// plan the best moment to start a sequence.
class ObservableWindow {
	/// UTC DateTime when the target first satisfies both conditions (dark + high
	/// enough), or null if no such moment exists.
	final DateTime? start;

	/// UTC DateTime when the target last satisfies both conditions, or null if
	/// no such moment exists.
	final DateTime? end;

	/// Highest altitude reached during the night, in degrees.
	/// Null if the target is never observable.
	final double? peakAltitude;

	/// UTC DateTime when the peak altitude is reached, or null if never observable.
	final DateTime? peakTime;

	/// Creates an ObservableWindow.
	///
	/// Receives:
	/// - [start] — first moment target is observable (nullable)
	/// - [end] — last moment target is observable (nullable)
	/// - [peakAltitude] — highest altitude in degrees (nullable)
	/// - [peakTime] — UTC DateTime of peak altitude (nullable)
	const ObservableWindow({
		this.start,
		this.end,
		this.peakAltitude,
		this.peakTime,
	});

	/// True if the target is above [minimumAltitude] during the dark window.
	/// False if the target is never observable (too low, or no dark window).
	bool get isObservable => start != null && end != null;

	/// Duration of the observable window in hours, or null if not observable.
	double? get durationHours {
		if (start == null || end == null) return null;
		return end!.difference(start!).inSeconds / 3600.0;
	}

	@override
	String toString() =>
		'ObservableWindow(start: $start, end: $end, '
		'peak: ${peakAltitude?.toStringAsFixed(2)}° at $peakTime, '
		'duration: ${durationHours?.toStringAsFixed(2)}h)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Private helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Converts a geoengine AstroTime to a proper UTC DateTime.
///
/// geoengine creates its AstroTime.date without the isUtc flag, so the
/// DateTime object is tagged as local time even though its
/// millisecondsSinceEpoch value is the correct UTC-based Unix timestamp.
/// Rebuilding it with isUtc:true fixes the tag without altering the instant.
///
/// Receives: [astroTime] — a geoengine AstroTime object.
/// Returns: a UTC DateTime representing the same instant.
DateTime _toUtc(geo.AstroTime astroTime) {
	return DateTime.fromMillisecondsSinceEpoch(
		astroTime.date.millisecondsSinceEpoch,
		isUtc: true,
	);
}


// ─────────────────────────────────────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────────────────────────────────────

/// Finds the span of astronomical darkness for the night that begins on [date].
///
/// Astronomical darkness = Sun more than 18° below the horizon.
/// The function searches forward from solar noon UTC on [date]:
///   - Evening: sun descends through -18° (direction = -1.0)
///   - Morning: sun ascends through -18° (direction = +1.0)
///
/// This covers the entire overnight span in a single call.  The search limit
/// is 1.0 day (24 hours) for each crossing, so summer nights at high latitudes
/// where the Sun never reaches -18° will return null boundaries.
///
/// Receives:
/// - [date] — the calendar date of the night (UTC); time-of-day is ignored
/// - [latitude] — observer's latitude in degrees (positive = North)
/// - [longitude] — observer's longitude in degrees (positive = East)
/// - [elevation] — observer's elevation above sea level in metres (default 0)
///
/// Returns: a [DarkWindow] with UTC start/end times and computed duration.
DarkWindow astronomicalDarkWindow(
	DateTime date, {
	required double latitude,
	required double longitude,
	double elevation = 0.0,
}) {
	// Astronomical darkness = Sun more than 18° below the horizon. Delegates
	// to the shared evening-descend / morning-ascend crossing finder.
	return _sunCrossingWindow(
		date,
		latitude: latitude,
		longitude: longitude,
		elevation: elevation,
		targetAltitudeDeg: -18.0,
	);
}

/// Finds the sunset→sunrise span (Sun below the geometric horizon, 0°) for the
/// night beginning on [date]. Same evening-descend / morning-ascend search as
/// [astronomicalDarkWindow] but at the 0° horizon rather than -18°, so the
/// window is wider and brackets the whole night including twilight.
///
/// Added 2026-05-28 for astrowidget's equipment-protection precipitation veto:
/// the scope is physically uncovered (and exposed to rain) from sunset to
/// sunrise, which is a wider window than the astronomical-dark imaging window.
/// See ~/Claude/astrowidget/docs/superpowers/specs/2026-05-28-astrowidget-design.md.
///
/// Receives/returns the same parameters and [DarkWindow] shape as
/// [astronomicalDarkWindow]; here `start` is sunset and `end` is sunrise.
DarkWindow horizonWindow(
	DateTime date, {
	required double latitude,
	required double longitude,
	double elevation = 0.0,
}) {
	return _sunCrossingWindow(
		date,
		latitude: latitude,
		longitude: longitude,
		elevation: elevation,
		targetAltitudeDeg: 0.0,
	);
}

/// Shared implementation for [astronomicalDarkWindow] (-18°) and
/// [horizonWindow] (0°). Searches forward from solar noon UTC on [date] for the
/// evening descending crossing of [targetAltitudeDeg] then the following
/// morning ascending crossing. Returns null boundaries when the Sun never
/// reaches the target altitude (e.g. polar summer for -18°).
DarkWindow _sunCrossingWindow(
	DateTime date, {
	required double latitude,
	required double longitude,
	required double elevation,
	required double targetAltitudeDeg,
}) {
	// Build the geoengine Observer from our location parameters.
	// geo.Observer takes (latitude, longitude, elevation) with the same sign
	// conventions we use throughout astroplan.
	final observer = geo.Observer(latitude, longitude, elevation);

	// Start the search at noon UTC so the evening crossing is always found first.
	final searchStart = DateTime.utc(date.year, date.month, date.day, 12, 0, 0);

	// Evening: Sun is descending (direction = -1.0) through the target boundary.
	// limitDays = 1.0 means search up to 24 hours forward from searchStart.
	final startCrossing = geo.searchAltitude(
		geo.Body.Sun,
		observer,
		-1.0,                 // descending
		searchStart,
		1.0,                  // search limit in days
		targetAltitudeDeg,    // -18° (astro dark) or 0° (sunset/sunrise)
	);

	// Morning: Sun is ascending (direction = +1.0) through the target boundary.
	// We search from the start time if found, otherwise from searchStart.
	// This avoids accidentally finding the previous morning's crossing.
	final morningSearchStart = startCrossing != null
		? _toUtc(startCrossing)
		: searchStart;

	final endCrossing = geo.searchAltitude(
		geo.Body.Sun,
		observer,
		1.0,                  // ascending
		morningSearchStart,
		1.0,
		targetAltitudeDeg,
	);

	return DarkWindow(
		start: startCrossing != null ? _toUtc(startCrossing) : null,
		end: endCrossing != null ? _toUtc(endCrossing) : null,
	);
}

/// Generates an altitude curve for a fixed sky target over one night.
///
/// Computes the target's horizontal coordinates at each [intervalMinutes]
/// step across the local observing night. The window is centered on local
/// midnight (approximated as noon UTC minus the longitude offset), spanning
/// 18 hours total to catch the full evening-through-morning window at any
/// longitude.
///
/// Previous versions hardcoded 18:00-12:00 UTC which missed half the
/// observing night for Asia/Australia/Pacific observers. This version
/// derives the start from the observer's longitude so it works globally.
///
/// Receives:
/// - [raHours] — target right ascension in hours (0..24)
/// - [decDeg] — target declination in degrees (-90..+90)
/// - [date] — the calendar date for the night (UTC); time-of-day is ignored
/// - [latitude] — observer's latitude in degrees (positive = North)
/// - [longitude] — observer's longitude in degrees (positive = East)
/// - [elevation] — observer's elevation in metres (default 0)
/// - [intervalMinutes] — time step between samples in minutes (default 5)
///
/// Returns: a List of [AltitudePoint] objects, one per interval step,
/// ordered chronologically.
List<AltitudePoint> altitudeCurve({
	required double raHours,
	required double decDeg,
	required DateTime date,
	required double latitude,
	required double longitude,
	double elevation = 0.0,
	int intervalMinutes = 5,
}) {
	final observer = geo.Observer(latitude, longitude, elevation);

	// Approximate local noon UTC: subtract longitude/15 hours from 12:00 UTC.
	// longitude +135 (Japan UTC+9) → local noon ≈ 03:00 UTC
	// longitude -105 (Denver UTC-7) → local noon ≈ 19:00 UTC
	// Start 9 hours before local noon (≈ local 3 PM) to catch early evening,
	// end 9 hours after (≈ local 9 AM) to catch late morning. 18h total.
	//
	// For extreme eastern longitudes (e.g., +180), local noon is at 00:00 UTC
	// so the start is at 15:00 UTC the PREVIOUS day. Without adjusting the
	// date, we'd miss the early evening. Bug fix: GitHub #45.
	final localNoonUtcHour = (12.0 - longitude / 15.0) % 24.0;
	final startHour = ((localNoonUtcHour - 9.0) % 24.0).floor();
	// If the start hour is in the afternoon UTC (>= 12) but local noon is
	// in the early UTC hours (< 6), the curve window needs to start the
	// previous UTC day to cover the local evening.
	final dateAdjust = (startHour >= 12 && localNoonUtcHour < 6) ? -1 : 0;
	var current = DateTime.utc(
		date.year, date.month, date.day + dateAdjust, startHour, 0, 0,
	);
	final end = current.add(const Duration(hours: 18));

	final points = <AltitudePoint>[];

	while (current.isBefore(end)) {
		// HorizontalCoordinates.horizon() converts fixed RA/Dec (equatorial) to
		// altitude/azimuth (horizontal) at the given instant and location.
		// RefractionType.normal applies standard atmospheric refraction correction.
		final hor = geo.HorizontalCoordinates.horizon(
			current,
			observer,
			raHours,
			decDeg,
			geo.RefractionType.normal,
		);

		points.add(AltitudePoint(
			time: current,
			altitude: hor.altitude,
			azimuth: hor.azimuth,
		));

		// Advance by the requested interval.
		current = current.add(Duration(minutes: intervalMinutes));
	}

	return points;
}

/// Computes the window during which a target is both astronomically dark
/// AND above a minimum altitude from the given observer location.
///
/// Steps:
///   1. Find the [DarkWindow] for the night (Sun below -18°).
///      Pass a pre-computed [darkWindow] to skip this expensive step when
///      scoring many targets at the same location (saves ~2 searchAltitude
///      calls per target — the single biggest performance optimization).
///   2. Generate a fine-resolution (5-minute) altitude curve for the target.
///   3. Keep only the points that fall inside the dark window AND are at or
///      above [minimumAltitude].
///   4. The first and last qualifying points define the window.
///
/// Also tracks the peak altitude across the entire night (regardless of
/// darkness), stored in [ObservableWindow.peakAltitude].
///
/// Receives:
/// - [raHours] — target right ascension in hours (0..24)
/// - [decDeg] — target declination in degrees (-90..+90)
/// - [date] — the calendar date for the night (UTC)
/// - [latitude] — observer's latitude in degrees (positive = North)
/// - [longitude] — observer's longitude in degrees (positive = East)
/// - [elevation] — observer's elevation in metres (default 0)
/// - [minimumAltitude] — lowest acceptable altitude in degrees (default 30°)
/// - [darkWindow] — pre-computed DarkWindow (optional). When provided, skips
///   the internal astronomicalDarkWindow() call. Pass this when computing
///   observableWindow for many targets at the same location/date.
///
/// Returns: an [ObservableWindow].  Check [ObservableWindow.isObservable]
/// before using start/end/peak values.
/// Optional output holder for the altitude curve computed internally.
///
/// When [observableWindow] computes its altitude curve, callers that also
/// need the curve (e.g., the target detail screen's fl_chart) can pass a
/// [CurveOutput] to capture it — avoiding a redundant second computation
/// that generates 216 geoengine coordinate transforms.
/// Bug fix: GitHub #55 (altitude curve computed twice on detail screen).
class CurveOutput {
	/// The altitude curve points, filled by [observableWindow].
	List<AltitudePoint>? points;
}

ObservableWindow observableWindow({
	required double raHours,
	required double decDeg,
	required DateTime date,
	required double latitude,
	required double longitude,
	double elevation = 0.0,
	double minimumAltitude = 30.0,
	DarkWindow? darkWindow,
	CurveOutput? curveOut,
}) {
	// Step 1: use pre-computed dark window if provided, otherwise compute.
	// When scoring many targets at the same location, the caller should
	// compute the dark window once and pass it in — saves ~26,000 solar
	// altitude root-finding operations for a 13K-target catalog.
	final dark = darkWindow ?? astronomicalDarkWindow(
		date,
		latitude: latitude,
		longitude: longitude,
		elevation: elevation,
	);

	// Step 2: fine-resolution altitude curve (5-minute steps by default).
	final curve = altitudeCurve(
		raHours: raHours,
		decDeg: decDeg,
		date: date,
		latitude: latitude,
		longitude: longitude,
		elevation: elevation,
		intervalMinutes: 5,
	);

	// Expose the curve to callers who need it (e.g., the detail screen's
	// fl_chart) — avoids a redundant second altitudeCurve() call.
	if (curveOut != null) curveOut.points = curve;

	// Track the overall peak altitude (used for informational display even if
	// the target never satisfies both conditions simultaneously).
	AltitudePoint? peakPoint;
	for (final point in curve) {
		if (peakPoint == null || point.altitude > peakPoint.altitude) {
			peakPoint = point;
		}
	}

	// Step 3: filter to points that are dark AND above the minimum altitude.
	// If the dark window has no boundaries, no point will pass the dark check.
	final qualifying = curve.where((point) {
		// Must be within the astronomical dark window.
		final inDark = dark.start != null &&
			dark.end != null &&
			!point.time.isBefore(dark.start!) &&
			!point.time.isAfter(dark.end!);
		// Must be at or above the minimum altitude.
		final highEnough = point.altitude >= minimumAltitude;
		return inDark && highEnough;
	}).toList();

	// Step 4: first and last qualifying points define the observable window.
	if (qualifying.isEmpty) {
		// Target is never in a state where both conditions are met.
		return ObservableWindow(
			peakAltitude: peakPoint?.altitude,
			peakTime: peakPoint?.time,
		);
	}

	return ObservableWindow(
		start: qualifying.first.time,
		end: qualifying.last.time,
		peakAltitude: peakPoint?.altitude,
		peakTime: peakPoint?.time,
	);
}

/// Computes the UTC time when a DSO transits (crosses the meridian) on [date].
///
/// Transit = the moment when the object's right ascension equals the local
/// sidereal time, meaning it is due South (or North from the Southern Hemisphere)
/// and at its highest altitude.  This is pure Meeus arithmetic — no geoengine
/// call needed.
///
/// Algorithm (Meeus Ch. 12):
///   1. Compute GMST at 0h UT for the given date.
///   2. Transit UTC hour = (RA − GMST − longitude/15) / 1.00273790935
///   3. The divisor 1.00273790935 converts mean solar time to sidereal time.
///
/// Receives:
/// - [raHours] — target right ascension in hours (0..24)
/// - [date] — the calendar date (UTC); time-of-day is ignored
/// - [longitude] — observer's longitude in degrees (positive = East;
///   US locations are negative)
///
/// Returns: UTC DateTime of the meridian transit on [date], or null if the
/// calculation produces an out-of-range result (should not happen in practice).
DateTime? dsoTransitTime({
	required double raHours,
	required DateTime date,
	required double longitude,
}) {
	// Midnight (0h UT) Julian Date for this date.
	// Uses the shared Meeus Ch. 7 algorithm from time_utils.dart.
	final jd = dateTimeToJulianDate(
		DateTime.utc(date.year, date.month, date.day),
	);

	// T = Julian centuries from J2000.0.  J2000.0 is JD 2451545.0.
	// (Meeus eq. 12.1)
	final t = (jd - 2451545.0) / 36525.0;

	// GMST at 0h UT in hours.  The Meeus polynomial gives GMST in hours.
	// (Meeus eq. 12.4, simplified form)
	var gmst0 = 6.697374558 +
		2400.0513369 * t +
		0.0000258622 * t * t;
	// Normalise to [0, 24) — the raw value can be large.
	gmst0 = gmst0 % 24.0;
	if (gmst0 < 0) gmst0 += 24.0;

	// Local Sidereal Time at transit = RA of the target.
	// LST = GMST + longitude/15  (east longitude adds sidereal time)
	// Transit UTC hour = (RA − GMST − longitude/15) / 1.00273790935
	// The divisor converts the sidereal interval to mean solar time.
	var hours = (raHours - gmst0 - longitude / 15.0) / 1.00273790935;

	// Normalise to [0, 24) — the result can go negative or exceed 24.
	hours = hours % 24.0;
	if (hours < 0) hours += 24.0;

	// Convert the fractional hours to a full UTC DateTime on the given date.
	// Use floor (not round) for seconds to prevent overflow to 60, which
	// relies on undocumented DateTime.utc overflow behavior.
	final totalSeconds = (hours * 3600.0).floor();
	final wholeHours = totalSeconds ~/ 3600;
	final wholeMinutes = (totalSeconds % 3600) ~/ 60;
	final wholeSeconds = totalSeconds % 60;

	return DateTime.utc(
		date.year,
		date.month,
		date.day,
		wholeHours,
		wholeMinutes,
		wholeSeconds,
	);
}
