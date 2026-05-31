// lib/astro/moon_geometry.dart
// Moon phase, illumination, and angular distance from imaging targets.
//
// This is the core "will moonlight ruin my image?" module.
// It wraps geoengine's moonPhase() and equator() functions, combines them
// with our own angularSeparation() helper, and produces a plain-language
// severity assessment for any target in the sky.
//
// geoengine is imported here (in addition to solar_system.dart) because
// moonPhase() and the geocentric equator() call are not exposed through
// the SolarSystem wrapper — they don't need observer position.
import 'dart:math';
import 'package:geoengine/geoengine.dart' as geo;
import 'solar_system.dart';
import 'coordinates.dart';

// ── Severity enum ─────────────────────────────────────────────────────────────

/// Describes how much the Moon is expected to interfere with an astrophoto session.
///
/// Used as the primary decision signal in [MoonImpactAssessment].
/// Ordered from no impact (none) to session-ruining (severe).
enum MoonSeverity {
	/// Illumination < 10%, or Moon is very far away and dim — no meaningful impact.
	none,

	/// Moon is present but bright enough or close enough to cause minor sky glow.
	/// Narrow-band filters or careful framing can mitigate the effect.
	low,

	/// Moon is noticeably bright and/or moderately close to the target.
	/// Broadband imaging will suffer; consider narrowband or a different target.
	moderate,

	/// Bright Moon (> 50% illuminated) and less than 30° from the target.
	/// Imaging this target tonight is not recommended.
	severe,
}

// ── Impact assessment result ──────────────────────────────────────────────────

/// Summarises how much moonlight will affect imaging a particular target tonight.
///
/// All fields are computed at the time passed to [moonImpact].
/// Callers (UI and session-planning logic) should read [severity] first,
/// then [description] for a ready-to-display string.
class MoonImpactAssessment {
	/// How seriously the Moon interferes with this target.
	/// Used for colour coding and go/no-go decisions in the UI.
	final MoonSeverity severity;

	/// Angular distance from the Moon's centre to the target, in degrees (0–180).
	/// Comes from [moonAngularDistance].
	final double distanceDeg;

	/// Fraction of the lunar disk that is lit, as a percentage (0–100).
	/// Comes from [moonIllumination].
	final double illuminationPercent;

	/// Human-readable one-line summary of the impact, e.g.
	/// "Moon 45° away, 72% illuminated — moderate interference expected."
	final String description;

	/// Creates a [MoonImpactAssessment] with all fields.
	///
	/// Receives:
	/// - [severity] — computed severity level
	/// - [distanceDeg] — angular separation from Moon to target in degrees
	/// - [illuminationPercent] — Moon brightness as 0–100%
	/// - [description] — ready-to-display summary string
	const MoonImpactAssessment({
		required this.severity,
		required this.distanceDeg,
		required this.illuminationPercent,
		required this.description,
	});

	@override
	String toString() =>
		'MoonImpactAssessment(severity: $severity, '
		'dist: ${distanceDeg.toStringAsFixed(1)}°, '
		'illumination: ${illuminationPercent.toStringAsFixed(1)}%, '
		'desc: "$description")';
}

// ── Phase angle ───────────────────────────────────────────────────────────────

/// Returns the Moon's current phase angle in degrees (0–360).
///
/// The phase angle is the difference in geocentric ecliptic longitude
/// between the Moon and the Sun:
/// - 0° = new moon (Sun and Moon aligned)
/// - 90° = first quarter (waxing)
/// - 180° = full moon (Sun and Moon opposite)
/// - 270° = third quarter (waning)
///
/// Delegates directly to geoengine's [geo.moonPhase], which accepts a
/// plain [DateTime] as its dynamic [date] parameter.
///
/// Receives: [dateTime] — UTC DateTime for the calculation.
/// Returns: phase angle in degrees, range [0, 360).
double moonPhaseAngle(DateTime dateTime) {
	// geo.moonPhase accepts a dynamic date — it can be a DateTime, AstroTime,
	// or numeric Julian date. Passing a DateTime is the simplest form.
	return geo.moonPhase(dateTime);
}

// ── Illumination ──────────────────────────────────────────────────────────────

/// Returns the fraction of the Moon's disk that is illuminated, as a percentage.
///
/// Uses the standard cosine formula from the phase angle φ (in radians):
///   illumination = ((1 − cos(φ)) / 2) × 100
///
/// At φ=0 (new): (1−1)/2 = 0%
/// At φ=π (full): (1−(−1))/2 = 100%
///
/// Receives: [dateTime] — UTC DateTime for the calculation.
/// Returns: illumination percentage, range [0.0, 100.0].
double moonIllumination(DateTime dateTime) {
	// Get the phase angle (0–360°) from geoengine.
	final angleDeg = moonPhaseAngle(dateTime);
	// Convert degrees → radians for the cosine formula.
	// dart:math's cos() operates in radians.
	final angleRad = angleDeg * (pi / 180.0);
	return ((1.0 - cos(angleRad)) / 2.0) * 100.0;
}

// ── Moon position ─────────────────────────────────────────────────────────────

/// Returns the Moon's position (RA, Dec, altitude, azimuth, distance) as seen
/// from the given observer location at [dateTime].
///
/// Delegates to [SolarSystem.bodyPosition] — this is purely a convenience
/// wrapper so callers that only need the Moon don't have to reference
/// [SolarSystemBody.moon] directly.
///
/// Receives:
/// - [dateTime] — UTC DateTime for the observation
/// - [latitude] — observer latitude in degrees (-90..+90, positive = North)
/// - [longitude] — observer longitude in degrees (-180..+180, positive = East)
/// - [elevation] — observer elevation above sea level in metres (default 0)
///
/// Returns: a [BodyPosition] with equatorial and horizontal coordinates.
BodyPosition getMoonPosition(
	DateTime dateTime, {
	required double latitude,
	required double longitude,
	double elevation = 0.0,
}) {
	// Delegate to the SolarSystem wrapper, which calls geoengine under the hood.
	// SolarSystem.bodyPosition takes positional parameters, not named ones.
	return SolarSystem.bodyPosition(
		SolarSystemBody.moon,
		dateTime,
		latitude,
		longitude,
		elevation,
	);
}

// ── Angular distance ──────────────────────────────────────────────────────────

/// Returns the angular distance between the Moon and a sky target, in degrees.
///
/// Uses the Moon's geocentric equatorial coordinates (RA/Dec) so that the
/// result is independent of observer location. Moon parallax is < 1°, which
/// is within our tolerance for interference assessment.
///
/// Gets the Moon's RA/Dec from [geo.equator] with Observer(0,0,0), then
/// calls our own [angularSeparation] function from coordinates.dart.
///
/// Receives:
/// - [dateTime] — UTC DateTime for the calculation
/// - [targetRaHours] — target's right ascension in hours (0–24)
/// - [targetDecDeg] — target's declination in degrees (-90..+90)
///
/// Returns: angular separation in degrees, range [0.0, 180.0].
double moonAngularDistance(
	DateTime dateTime, {
	required double targetRaHours,
	required double targetDecDeg,
}) {
	// geo.equator returns geocentric equatorial coordinates for any body.
	// Parameters:
	//   body       — which body (Moon here)
	//   date       — observation DateTime
	//   observer   — Observer(lat, lon, elevM); (0,0,0) = geocentre
	//   ofdate     — false = J2000, true = current epoch. We use false (J2000)
	//                so RA/Dec are in the same frame as catalog coordinates.
	//   aberration — true corrects for the finite speed of light.
	final moonEq = geo.equator(
		geo.Body.Moon,
		dateTime,
		geo.Observer(0, 0, 0),
		false, // ofdate: use J2000 frame (matches star catalog coordinates)
		true,  // aberration correction: yes
	);

	// moonEq.ra is in hours (0–24); moonEq.dec is in degrees.
	// angularSeparation is imported from coordinates.dart.
	return angularSeparation(
		ra1Hours: moonEq.ra,
		dec1Deg: moonEq.dec,
		ra2Hours: targetRaHours,
		dec2Deg: targetDecDeg,
	);
}

// ── Impact assessment ─────────────────────────────────────────────────────────

/// Produces a complete [MoonImpactAssessment] for an imaging target at [dateTime].
///
/// Severity rules (applied in priority order — first match wins):
/// 1. Illumination < 10% → [MoonSeverity.none] (dark moon, no impact)
/// 2. Distance > 90° AND illumination < 50% → [MoonSeverity.none]
/// 3. Distance < 30° AND illumination > 50% → [MoonSeverity.severe]
/// 4. Distance 30–60° → [MoonSeverity.moderate]
/// 5. Distance > 60° → [MoonSeverity.low]
///
/// Receives:
/// - [dateTime] — UTC DateTime for the assessment
/// - [targetRaHours] — target's right ascension in hours (0–24)
/// - [targetDecDeg] — target's declination in degrees (-90..+90)
///
/// Returns: a [MoonImpactAssessment] with severity, distance, illumination,
/// and a human-readable description.
MoonImpactAssessment moonImpact(
	DateTime dateTime, {
	required double targetRaHours,
	required double targetDecDeg,
}) {
	// Compute the two key quantities: how bright the Moon is, and how close.
	final illumination = moonIllumination(dateTime);
	final distance = moonAngularDistance(
		dateTime,
		targetRaHours: targetRaHours,
		targetDecDeg: targetDecDeg,
	);

	// Determine severity using the priority-ordered rules from the spec.
	final MoonSeverity severity;

	if (illumination < 10.0) {
		// Rule 1: Moon is too dim to matter regardless of position.
		severity = MoonSeverity.none;
	} else if (distance > 90.0 && illumination < 50.0) {
		// Rule 2: Moon is far enough away and not fully bright — effectively dark sky.
		severity = MoonSeverity.none;
	} else if (distance < 30.0 && illumination > 50.0) {
		// Rule 3: Bright Moon very close to target — session-ruining conditions.
		severity = MoonSeverity.severe;
	} else if (distance <= 60.0) {
		// Rule 4: Moderately close (30–60°) regardless of brightness.
		severity = MoonSeverity.moderate;
	} else {
		// Rule 5: Moon is more than 60° away — present but manageable.
		severity = MoonSeverity.low;
	}

	// Build a one-line description for display in the UI.
	// Formats: "Moon X° away, Y% illuminated — <severity label> interference."
	final distStr = distance.toStringAsFixed(1);
	final illumStr = illumination.toStringAsFixed(1);
	final severityLabel = switch (severity) {
		MoonSeverity.none     => 'no',
		MoonSeverity.low      => 'low',
		MoonSeverity.moderate => 'moderate',
		MoonSeverity.severe   => 'severe',
	};
	final description =
		'Moon $distStr° away, $illumStr% illuminated — '
		'$severityLabel interference expected.';

	return MoonImpactAssessment(
		severity: severity,
		distanceDeg: distance,
		illuminationPercent: illumination,
		description: description,
	);
}
