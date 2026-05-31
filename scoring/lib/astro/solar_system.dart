// lib/astro/solar_system.dart
// Wrapper around the geoengine package for solar system ephemeris.
//
// This file is the ONLY place that imports geoengine. All other code in
// astroplan uses the types defined here (SolarSystemBody, BodyPosition,
// RiseSetTransit). If we ever swap geoengine for a different library,
// only this file needs to change.
//
// geoengine is a pure-Dart port of CosineKitty's Astronomy Engine:
// https://pub.dev/packages/geoengine
import 'package:geoengine/geoengine.dart' as geo;

/// Maps our domain's celestial bodies to geoengine's Body enum values.
///
/// We define our own enum so the rest of the codebase never touches
/// geoengine types directly. Each value carries a reference to the
/// corresponding geo.Body constant.
enum SolarSystemBody {
	sun(geo.Body.Sun),
	moon(geo.Body.Moon),
	mercury(geo.Body.Mercury),
	venus(geo.Body.Venus),
	mars(geo.Body.Mars),
	jupiter(geo.Body.Jupiter),
	saturn(geo.Body.Saturn),
	uranus(geo.Body.Uranus),
	neptune(geo.Body.Neptune);

	/// The geoengine Body enum value that this SolarSystemBody maps to.
	/// Used internally by SolarSystem methods when calling geoengine functions.
	final geo.Body geoBody;

	/// Creates a SolarSystemBody with a reference to its geoengine counterpart.
	///
	/// Receives: [geoBody] — the geo.Body enum value from the geoengine package.
	const SolarSystemBody(this.geoBody);
}

/// Holds the computed position of a celestial body at a specific time and
/// observer location.
///
/// Combines equatorial coordinates (RA/Dec), horizontal coordinates
/// (altitude/azimuth), and distance from the observer. All angles are
/// in degrees except RA which is in sidereal hours.
class BodyPosition {
	/// Right ascension in sidereal hours (0..24).
	/// This is the East-West coordinate on the celestial sphere,
	/// analogous to longitude on Earth. Comes from geoengine's equator()
	/// function using J2000 coordinates.
	final double ra;

	/// Declination in degrees (-90..+90).
	/// This is the North-South coordinate on the celestial sphere,
	/// analogous to latitude on Earth. Comes from geoengine's equator()
	/// function using J2000 coordinates.
	final double dec;

	/// Altitude in degrees above the horizon (-90..+90).
	/// Positive means the body is above the horizon; negative means below.
	/// Includes atmospheric refraction correction from geoengine.
	final double altitude;

	/// Azimuth in degrees (0..360), measured clockwise from true North.
	/// North = 0, East = 90, South = 180, West = 270.
	final double azimuth;

	/// Distance from the observer to the body in Astronomical Units (AU).
	/// 1 AU ≈ 149,597,870.7 km (the Earth–Sun distance).
	/// Comes from geoengine's equator() function (the .dist field).
	final double distanceAu;

	/// Creates a BodyPosition with all coordinate fields.
	///
	/// Receives:
	/// - [ra] — right ascension in hours (0..24)
	/// - [dec] — declination in degrees (-90..+90)
	/// - [altitude] — degrees above/below horizon (-90..+90)
	/// - [azimuth] — compass bearing in degrees (0..360)
	/// - [distanceAu] — distance in AU
	const BodyPosition({
		required this.ra,
		required this.dec,
		required this.altitude,
		required this.azimuth,
		required this.distanceAu,
	});

	@override
	String toString() =>
		'BodyPosition(ra: ${ra.toStringAsFixed(4)}h, '
		'dec: ${dec.toStringAsFixed(4)}°, '
		'alt: ${altitude.toStringAsFixed(2)}°, '
		'az: ${azimuth.toStringAsFixed(2)}°, '
		'dist: ${distanceAu.toStringAsFixed(6)} AU)';
}

/// Holds rise, transit (meridian crossing), and set times for a celestial body.
///
/// Any of these can be null — for example, at high latitudes the Sun may
/// not set during summer, or the Moon might not rise during a given day.
class RiseSetTransit {
	/// When the body rises above the horizon, or null if it doesn't rise
	/// in the search window. Found by geoengine's searchRiseSet(direction: +1).
	final DateTime? rise;

	/// When the body crosses the observer's meridian (highest point in the sky),
	/// or null if not found. Found by geoengine's searchHourAngle(hourAngle: 0).
	final DateTime? transit;

	/// When the body sets below the horizon, or null if it doesn't set
	/// in the search window. Found by geoengine's searchRiseSet(direction: -1).
	final DateTime? set;

	/// The body's altitude in degrees at the moment of meridian transit,
	/// or null if transit was not found. This tells you how high the body
	/// gets in the sky — useful for planning observation sessions.
	final double? transitAltitude;

	/// Creates a RiseSetTransit with optional times and transit altitude.
	///
	/// Receives:
	/// - [rise] — DateTime when the body rises (nullable)
	/// - [transit] — DateTime when the body transits the meridian (nullable)
	/// - [set] — DateTime when the body sets (nullable)
	/// - [transitAltitude] — altitude in degrees at transit (nullable)
	const RiseSetTransit({
		this.rise,
		this.transit,
		this.set,
		this.transitAltitude,
	});

	@override
	String toString() =>
		'RiseSetTransit(rise: $rise, transit: $transit, set: $set, '
		'transitAlt: ${transitAltitude?.toStringAsFixed(2)}°)';
}

/// Static utility class providing solar system ephemeris calculations.
///
/// All methods are static — there's no state to manage. This class is a
/// thin wrapper over geoengine that translates between our domain types
/// and geoengine's types.
///
/// This is the ONLY class that should import or interact with geoengine.
/// All other code uses SolarSystemBody, BodyPosition, and RiseSetTransit.
class SolarSystem {
	/// Private constructor — this class is a namespace for static methods,
	/// not something you instantiate.
	SolarSystem._();

	/// Converts a geoengine AstroTime to a proper UTC DateTime.
	///
	/// geoengine's AstroTime.date is created via
	/// DateTime.fromMillisecondsSinceEpoch() without isUtc:true, so the
	/// DateTime is tagged as local time even though the underlying
	/// millisecondsSinceEpoch value is correct (relative to Unix epoch).
	/// This helper re-creates the DateTime with isUtc:true so callers
	/// get proper UTC timestamps.
	///
	/// Receives: [astroTime] — a geoengine AstroTime object.
	/// Returns: a UTC DateTime representing the same instant.
	static DateTime _toUtc(geo.AstroTime astroTime) {
		return DateTime.fromMillisecondsSinceEpoch(
			astroTime.date.millisecondsSinceEpoch,
			isUtc: true,
		);
	}

	/// Computes the position of a celestial body as seen from a specific
	/// location on Earth at a specific time.
	///
	/// Combines equatorial coordinates (RA/Dec in J2000), horizontal
	/// coordinates (altitude/azimuth), and distance into one BodyPosition.
	///
	/// Receives:
	/// - [body] — which solar system body to compute (Sun, Moon, planet)
	/// - [dateTime] — UTC DateTime for the observation
	/// - [latitude] — observer's latitude in degrees (-90..+90, positive = North)
	/// - [longitude] — observer's longitude in degrees (-180..+180, positive = East)
	/// - [elevation] — observer's elevation above sea level in metres
	///
	/// Returns: a [BodyPosition] with all coordinate fields populated.
	static BodyPosition bodyPosition(
		SolarSystemBody body,
		DateTime dateTime,
		double latitude,
		double longitude,
		double elevation,
	) {
		// Create the geoengine observer. Height is in metres.
		final observer = geo.Observer(latitude, longitude, elevation);

		// bodyPosition returns a Dart record with ra, dec, azimuth, altitude.
		// RA and Dec are in J2000 coordinates; azimuth/altitude are horizontal
		// coordinates corrected for atmospheric refraction.
		final pos = geo.bodyPosition(body.geoBody, dateTime, observer);

		// bodyPosition doesn't include distance, so we call equator() separately.
		// ofdate=false gives J2000 coordinates; aberration=true corrects for
		// the finite speed of light.
		final equ = geo.equator(body.geoBody, dateTime, observer, false, true);

		return BodyPosition(
			ra: pos.ra,
			dec: pos.dec,
			altitude: pos.altitude,
			azimuth: pos.azimuth,
			distanceAu: equ.dist,
		);
	}

	/// Computes rise, transit (meridian crossing), and set times for a
	/// celestial body on a given day from a specific location.
	///
	/// Searches forward from [dateTime] for up to 2 days to find the next
	/// rise, set, and transit events. Any of these can be null if the event
	/// doesn't occur in the search window (e.g., circumpolar objects).
	///
	/// Receives:
	/// - [body] — which solar system body to compute
	/// - [dateTime] — UTC DateTime to start searching from
	/// - [latitude] — observer's latitude in degrees (-90..+90, positive = North)
	/// - [longitude] — observer's longitude in degrees (-180..+180, positive = East)
	/// - [elevation] — observer's elevation above sea level in metres
	///
	/// Returns: a [RiseSetTransit] with nullable rise/transit/set DateTimes
	/// and the transit altitude in degrees.
	static RiseSetTransit riseSetTransit(
		SolarSystemBody body,
		DateTime dateTime,
		double latitude,
		double longitude,
		double elevation,
	) {
		final observer = geo.Observer(latitude, longitude, elevation);

		// Search for rise: direction = +1.0 means rising.
		// limitDays = 2.0 gives a 2-day window to find the event.
		final riseTime = geo.searchRiseSet(
			body.geoBody, observer, 1.0, dateTime, 2.0,
		);

		// Search for set: direction = -1.0 means setting.
		final setTime = geo.searchRiseSet(
			body.geoBody, observer, -1.0, dateTime, 2.0,
		);

		// Search for meridian transit: hour angle 0.0 = body on the meridian.
		// searchHourAngle always returns a result (no null), because the
		// body must cross the meridian once per sidereal day.
		// The 'direction' named parameter defaults to 1 (forward in time).
		final transitEvent = geo.searchHourAngle(
			body.geoBody, observer, 0.0, dateTime,
		);

		return RiseSetTransit(
			// _toUtc converts geoengine's AstroTime.date to a proper UTC DateTime.
			// geoengine internally uses DateTime.fromMillisecondsSinceEpoch without
			// isUtc:true, so .date is tagged as local time even though the millis
			// are correct. We normalise to UTC here.
			rise: riseTime != null ? _toUtc(riseTime) : null,
			transit: _toUtc(transitEvent.time),
			set: setTime != null ? _toUtc(setTime) : null,
			// transitEvent.hor is HorizontalCoordinates with an .altitude field.
			transitAltitude: transitEvent.hor.altitude,
		);
	}
}
