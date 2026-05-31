// lib/scoring/intents/visual_factors.dart
//
// Bridges the visual 6-column weight profile to the scoring engine's
// existing 7-column [WeightProfile] shape. The scoring engine was
// built for the imaging intent (Plan 4c scoring v2) — this file lets
// the same engine score visual targets by swapping in a visual-
// weighted profile rather than running a second parallel engine.
//
// Why a mapping layer instead of rewriting the scoring engine:
// Phase F's goal is "minimum visual plumbing" — deliver the
// Map<Intent, TargetScore> API contract that unblocks the dual-score
// UI and intent-aware notifications. A full engine rewrite would
// duplicate the ~1400-line weighted-average + veto + reason-string
// logic, and Plan 5.5 will introduce a 10-column weight shape that
// changes the math again. The mapper gives correct-enough visual
// scoring today and a single source of truth to evolve.
//
// DEF-F-01 (registered in plan5-index.md): intent-invariant subresult
// hoisting refactor — the plan's original Task 5 design had the
// engine compute cloud / darkness / moon severity / altitude /
// stability / smoke / elevation ONCE and then apply intent-specific
// weights, guaranteeing <1.15× dual-intent cost vs single-intent.
// Shipping the wrapper today (2× cost for dual-intent) is within
// the sub-100ms user-visible budget for the tens-of-targets case
// Plan 5 ships; the optimization lands in Plan 5.5 or Plan 6b when
// the 10-column weight shape stabilizes.
//
// Axis correspondence (visual → imaging WeightProfile):
//   visual.transparency  → imaging.cloud    (haze/cirrus degrades both)
//   visual.transparency  → imaging.smoke    (visual has one
//                                             transparency axis; the
//                                             imaging engine splits
//                                             cloud cover from AOD.
//                                             We mirror the same
//                                             value on both so a
//                                             smoky day reduces
//                                             visual score too)
//   visual.seeing        → imaging.stability (turbulence proxy)
//   visual.airmass       → imaging.altitude  (mathematically related:
//                                             airmass ≈ 1/sin(alt))
//   visual.moon          → imaging.moon
//   visual.bortle        → (no direct imaging axis; upstream Bortle
//                          is an input to darkness scoring)
//   visual.wind          → (folded into stability assessment upstream)
//
// Imaging-only axes:
//   imaging.darkness     → retained at the base value for that target
//                          type; visual observing also wants darkness
//                          for low-surface-brightness targets, so
//                          reusing the imaging darkness weight is a
//                          reasonable approximation until Plan 5.5
//                          ships a Bortle-aware axis
//   imaging.rig          → retained at a neutral value (0.5) for
//                          visual intent. Plan 5.5 adds magnification,
//                          true-FOV, exit-pupil, and Dawes columns
//                          that together drive an eyepiece-aware
//                          visual rig factor — for now visual rig
//                          scoring is the same "is this rig suitable"
//                          signal imaging uses, half-weighted so it
//                          doesn't dominate

import '../../visual/visual_weight_profiles.dart';
import '../target_type.dart';
import '../weight_profile.dart';

/// Translates a [VisualWeights] row into the 7-column [WeightProfile]
/// the existing scoring engine expects. Callers pass the returned
/// profile to [scoreTarget] via `weightProfileOverride` so the engine
/// skips its per-target-type lookup.
///
/// We intentionally do NOT run [adjustForObject] or [adjustForRig]
/// on the returned profile — those helpers were tuned for imaging
/// intent (pixel-scale vs atmosphere, Dawes vs target size). Plan 5.5
/// adds visual-specific equivalents.
///
/// [baseDarkness] is pulled from the imaging target-type profile
/// rather than introduced as a new visual axis — the rationale is in
/// this file's top comment.
WeightProfile visualWeightsAsWeightProfile({
	required VisualWeights visualWeights,
	required TargetType targetType,
}) {
	// Reach into the existing imaging base profile for the two axes
	// the visual weights don't cover cleanly (darkness, rig). The
	// result is a profile that tracks the visual axes and inherits
	// the imaging profile's structure for the rest.
	final imagingBase = targetType.baseWeightProfile;
	return WeightProfile(
		cloud: visualWeights.transparency,
		stability: visualWeights.seeing,
		darkness: imagingBase.darkness,
		moon: visualWeights.moon,
		altitude: visualWeights.airmass,
		// Visual rig factor — neutralized at 0.5 until Plan 5.5's
		// eyepiece-aware scoring lands. Zero would disable rig
		// consideration entirely (unrealistic: visual observers care
		// about aperture + focal length too); 1.0 would give rig the
		// same imaging weight (over-weighted without the eyepiece
		// signals the imaging rig-scoring depends on).
		rig: 0.5,
		smoke: visualWeights.transparency,
	);
}

/// Convenience combining [visualWeightsFor] + [visualWeightsAsWeightProfile].
/// Returns a visual [WeightProfile] ready to pass to [scoreTarget].
WeightProfile visualWeightProfileFor(TargetType type) {
	return visualWeightsAsWeightProfile(
		visualWeights: visualWeightsFor(type),
		targetType: type,
	);
}
