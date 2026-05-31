// lib/scoring/weight_profile.dart
// Weight profiles for the composite scoring engine.
//
// A WeightProfile holds seven weights (0.0–1.0) that determine how much
// each scoring factor matters. Base profiles come from TargetType; the
// adjust functions shift weights based on specific object and rig properties.
//
// The class is immutable — adjust functions return new instances.
import 'dart:math';

/// Seven weights controlling how much each scoring factor contributes
/// to the composite score. Values range from 0.0 (irrelevant) to 1.0 (critical).
///
/// The scoring engine computes: sum(weight_i * score_i) / sum(weight_i).
class WeightProfile {
	/// Cloud cover factor weight.
	final double cloud;

	/// Atmospheric stability factor weight.
	final double stability;

	/// Sky darkness factor weight.
	final double darkness;

	/// Moon distance/interference factor weight.
	final double moon;

	/// Target altitude factor weight.
	final double altitude;

	/// Rig suitability factor weight.
	final double rig;

	/// Smoke/AQI factor weight.
	final double smoke;

	/// Creates a [WeightProfile] with all seven weights.
	const WeightProfile({
		required this.cloud,
		required this.stability,
		required this.darkness,
		required this.moon,
		required this.altitude,
		required this.rig,
		required this.smoke,
	});

	/// Creates a copy with specific weights overridden.
	///
	/// Unchanged weights retain their current values.
	/// Weights are NOT clamped — callers (adjustForObject, adjustForRig)
	/// use min/max to keep values in range. The constructor trusts its
	/// callers for performance (this is called in hot scoring loops).
	WeightProfile copyWith({
		double? cloud,
		double? stability,
		double? darkness,
		double? moon,
		double? altitude,
		double? rig,
		double? smoke,
	}) {
		return WeightProfile(
			cloud: cloud ?? this.cloud,
			stability: stability ?? this.stability,
			darkness: darkness ?? this.darkness,
			moon: moon ?? this.moon,
			altitude: altitude ?? this.altitude,
			rig: rig ?? this.rig,
			smoke: smoke ?? this.smoke,
		);
	}
}

/// Properties of a specific astronomical object that affect weight adjustment.
///
/// All fields are nullable — null means the data is unknown, and the
/// corresponding adjustment is skipped (base weight unchanged).
class ObjectProperties {
	/// Angular size of the object in arcminutes (major axis).
	/// Small objects (< 1') need more stability; large objects (> 30') are forgiving.
	final double? angularSizeArcmin;

	/// Surface brightness in mag/arcmin².
	/// Higher values = fainter. Low-SB objects need darker skies.
	final double? surfaceBrightness;

	/// Visual magnitude.
	/// Dim objects need better conditions overall.
	final double? magnitude;

	/// Creates [ObjectProperties].
	const ObjectProperties({
		this.angularSizeArcmin,
		this.surfaceBrightness,
		this.magnitude,
	});
}

/// Properties of the user's rig that affect weight adjustment.
///
/// All fields are nullable — null means the rig data is unavailable.
class RigProperties {
	/// Telescope aperture in millimeters.
	/// Used to compute Dawes limit (116 / D_mm arcsec).
	final double? apertureMm;

	/// Effective focal length in millimeters.
	final double? focalLengthMm;

	/// Image scale in arcseconds per pixel.
	/// Compared to stability estimate for sampling assessment.
	final double? pixelScaleArcsec;

	/// Sensor field of view width in arcminutes.
	final double? fovWidthArcmin;

	/// Sensor field of view height in arcminutes.
	final double? fovHeightArcmin;

	/// Creates [RigProperties].
	const RigProperties({
		this.apertureMm,
		this.focalLengthMm,
		this.pixelScaleArcsec,
		this.fovWidthArcmin,
		this.fovHeightArcmin,
	});
}

/// Adjusts a weight profile based on object-specific properties.
///
/// Within DSO and comet types, the target's physical characteristics
/// shift the base weights. For example, a tiny planetary nebula needs
/// more stability than a huge galaxy.
///
/// Receives:
/// - [base] — the starting weight profile (from TargetType)
/// - [objectProps] — physical properties of the target (nullable fields)
///
/// Returns: a new [WeightProfile] with adjusted weights.
WeightProfile adjustForObject(
	WeightProfile base, {
	ObjectProperties? objectProps,
}) {
	if (objectProps == null) return base;

	var stability = base.stability;
	var darkness = base.darkness;
	var moonW = base.moon;

	// Angular size adjustment: small objects push stability UP, large push DOWN.
	// The shift is proportional to log-distance from a "neutral" size of ~5 arcmin.
	if (objectProps.angularSizeArcmin != null) {
		final size = objectProps.angularSizeArcmin!;
		if (size < 1.0) {
			// Tiny object (planetary nebula, tight galaxy): stability very important.
			// Push up to 1.0 proportionally.
			stability = min(1.0, stability + (1.0 - size) * 0.4);
		} else if (size > 30.0) {
			// Large object (M31, LMC): stability less critical.
			// Push down, but not below 0.1.
			stability = max(0.1, stability - min(0.3, (size - 30) * 0.002));
		}
	}

	// Surface brightness adjustment: faint objects need darker skies.
	// SB values: lower = brighter (like magnitudes). Typical range 12–26.
	// "Neutral" SB ~20 mag/arcmin². Objects fainter than 20 push darkness UP.
	if (objectProps.surfaceBrightness != null) {
		final sb = objectProps.surfaceBrightness!;
		if (sb > 22.0) {
			// Very faint — push darkness and moon weights toward 1.0.
			final push = min(0.2, (sb - 22.0) * 0.05);
			darkness = min(1.0, darkness + push);
			moonW = min(1.0, moonW + push);
		} else if (sb < 16.0) {
			// Very bright — can tolerate moonlight better.
			final pull = min(0.3, (16.0 - sb) * 0.05);
			darkness = max(0.0, darkness - pull);
		}
	}

	return base.copyWith(
		stability: stability,
		darkness: darkness,
		moon: moonW,
	);
}

/// Adjusts a weight profile based on rig-specific properties.
///
/// Compares the rig's capabilities to the target and atmospheric conditions
/// to determine which factors the rig is sensitive to.
///
/// Receives:
/// - [base] — current weight profile (possibly already adjusted for object)
/// - [rigProps] — rig specifications (nullable fields)
/// - [targetAngularSizeArcmin] — target's angular size for Dawes limit check
///
/// Returns: a new [WeightProfile] with adjusted weights.
WeightProfile adjustForRig(
	WeightProfile base, {
	RigProperties? rigProps,
	double? targetAngularSizeArcmin,
}) {
	if (rigProps == null) return base;

	var rigW = base.rig;
	var stability = base.stability;

	// Dawes limit vs target resolution.
	// If the rig can't resolve the target, rig suitability weight drops.
	if (rigProps.apertureMm != null && targetAngularSizeArcmin != null) {
		// Dawes limit in arcseconds; target size in arcseconds.
		final dawes = 116.0 / rigProps.apertureMm!;
		final targetArcsec = targetAngularSizeArcmin! * 60.0;
		if (dawes > targetArcsec) {
			// Rig can't resolve this target — heavily penalize rig suitability.
			rigW = max(0.0, rigW - 0.5);
		}
	}

	// Pixel scale vs stability: if pixels are much coarser than the
	// atmosphere, stability matters less (the rig can't see the difference).
	if (rigProps.pixelScaleArcsec != null) {
		final ps = rigProps.pixelScaleArcsec!;
		if (ps > 6.0) {
			// Very coarse pixels — stability is irrelevant.
			stability = max(0.1, stability - 0.3);
		} else if (ps < 1.0) {
			// Very fine pixels — atmosphere is the bottleneck.
			stability = min(1.0, stability + 0.2);
		}
	}

	return base.copyWith(rig: rigW, stability: stability);
}
