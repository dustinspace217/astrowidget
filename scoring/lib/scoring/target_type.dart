// lib/scoring/target_type.dart
// Target type classification and base weight profiles for scoring.
//
// Each target type (DSO, planetary, etc.) has a base weight profile that
// determines how much each scoring factor matters. For example, DSO imaging
// cares deeply about darkness (weight 1.0) but planetary imaging doesn't
// (weight 0.3) because planets are bright enough to image in moonlight.
//
// ImagingMode (broadband/narrowband/dualband) overrides the moon and
// darkness weights when the user specifies their filter setup.
import 'weight_profile.dart';

/// The six categories of astronomical observation targets.
///
/// Each type has fundamentally different sensitivity to weather, darkness,
/// and atmospheric conditions. The scoring engine uses the type to select
/// the appropriate base weight profile.
enum TargetType {
	/// Deep-sky objects: galaxies, nebulae, star clusters.
	/// Most demanding — needs dark skies, good stability, and transparency.
	dso,

	/// Planets: Jupiter, Saturn, Mars, Venus.
	/// Very demanding on stability (high magnification), less on darkness.
	planetary,

	/// The Moon itself as an imaging target.
	/// Doesn't need dark skies (it IS the light source) or moon avoidance.
	lunar,

	/// The Sun (with proper solar filters).
	/// Uses daytime window (sunrise–sunset), not astronomical darkness.
	solar,

	/// Comets: periodic and non-periodic.
	/// Mix of DSO and planetary concerns — diffuse coma needs dark skies,
	/// but short-period comets can be quite bright.
	comet,

	/// Aurora borealis/australis.
	/// Placeholder in Plan 3 — actual aurora scoring needs NOAA SWPC data
	/// (Bz, Kp, hemispheric power, CME alerts) from Plan 6.
	aurora,
}

/// Extension on TargetType providing the base weight profile.
///
/// Weights are 0.0 (irrelevant) to 1.0 (critical) for each scoring factor.
/// These are starting defaults — refined by per-parameter research and
/// further adjusted per-object by the WeightProfile.adjust() method.
extension TargetTypeProfile on TargetType {
	/// Returns the base weight profile for this target type.
	///
	/// Seven factors: cloud, stability, darkness, moon, altitude, rig, smoke.
	/// See the design spec Section 7 for the rationale behind each weight.
	WeightProfile get baseWeightProfile => switch (this) {
		TargetType.dso => const WeightProfile(
			cloud: 1.0, stability: 0.6, darkness: 1.0,
			moon: 1.0, altitude: 1.0, rig: 0.8, smoke: 1.0,
		),
		TargetType.planetary => const WeightProfile(
			cloud: 1.0, stability: 1.0, darkness: 0.3,
			moon: 0.0, altitude: 1.0, rig: 0.8, smoke: 0.3,
		),
		TargetType.lunar => const WeightProfile(
			cloud: 1.0, stability: 0.7, darkness: 0.0,
			moon: 0.0, altitude: 0.0, rig: 0.5, smoke: 0.1,
		),
		TargetType.solar => const WeightProfile(
			cloud: 1.0, stability: 0.8, darkness: 0.0,
			moon: 0.0, altitude: 0.0, rig: 0.5, smoke: 0.3,
		),
		TargetType.comet => const WeightProfile(
			cloud: 1.0, stability: 0.4, darkness: 0.8,
			moon: 0.7, altitude: 1.0, rig: 0.6, smoke: 0.8,
		),
		TargetType.aurora => const WeightProfile(
			cloud: 1.0, stability: 0.0, darkness: 1.0,
			moon: 0.3, altitude: 0.5, rig: 0.0, smoke: 0.5,
		),
	};
}

/// Filter configuration that changes how moon and darkness affect scoring.
///
/// Narrowband filters reject ~99% of moonlight and sky glow, making
/// imaging possible during bright moon phases. Broadband shooters are
/// fully exposed to both.
enum ImagingMode {
	/// L/R/G/B or unfiltered — full sensitivity to moon and sky glow.
	broadband,

	/// Ha/OIII/SII (3–7nm bandwidth) — near-immune to moonlight.
	narrowband,

	/// Dual-narrowband (e.g., L-eXtreme, L-eNhance) — reduced sensitivity.
	dualband,
}

/// Extension on ImagingMode providing weight overrides for moon, darkness,
/// and altitude factors.
///
/// Research-calibrated modifiers:
/// - Narrowband (Ha/SII at 656/672nm): extinction k=0.10-0.14 mag/airmass
///   (vs broadband V k=0.20-0.25), sky glow rejected by 3-7nm filter.
///   Moon impact minimal. Community routinely images at 20 deg+ with narrowband.
/// - Dualband (OIII component at 501nm): k=0.16-0.22, blue-green scatters more.
///   OIII moderately sensitive to moonlight. Intermediate between NB and BB.
/// - Broadband: full sensitivity to extinction, sky glow, moonlight.
///
/// Sources: Bouguer's law, Rayleigh lambda^(-4.08) scaling, Cloudy Nights
/// community surveys on narrowband at low altitude.
extension ImagingModeWeights on ImagingMode {
	/// Moon distance weight override for this imaging mode.
	/// Narrowband Ha/SII rejects ~99% of moonlight; OIII is intermediate.
	double get moonWeight => switch (this) {
		ImagingMode.broadband => 1.0,
		ImagingMode.narrowband => 0.3,   // Ha/SII routinely used at 80%+ illumination
		ImagingMode.dualband => 0.7,     // OIII component moderately sensitive
	};

	/// Darkness weight override for this imaging mode.
	double get darknessWeight => switch (this) {
		ImagingMode.broadband => 1.0,
		ImagingMode.narrowband => 0.1,
		ImagingMode.dualband => 0.3,
	};

	/// Altitude factor weight modifier for this imaging mode.
	/// Narrowband is less sensitive to low altitude because:
	/// 1. Lower extinction at red wavelengths (Ha k=0.10 vs V k=0.25)
	/// 2. Sky glow from LP rejected by narrow bandpass
	/// 3. Community successfully images at 20 deg with narrowband
	///
	/// Planetary is MORE sensitive because:
	/// 1. Atmospheric dispersion causes chromatic smearing (2.5" at 30 deg)
	/// 2. Seeing degradation matters at high magnification (0.1-0.3"/px)
	///
	/// Applied as a multiplier on the altitude factor WEIGHT in the composite.
	double get altitudeWeightModifier => switch (this) {
		ImagingMode.broadband => 1.0,
		ImagingMode.narrowband => 0.7,   // 30% less altitude sensitivity
		ImagingMode.dualband => 0.85,    // OIII component still somewhat sensitive
	};
}
