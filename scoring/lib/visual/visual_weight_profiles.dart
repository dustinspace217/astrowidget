// lib/visual/visual_weight_profiles.dart
//
// Per-target-type weight profiles for the VISUAL intent (spec §9.3).
// Imaging intent continues to use the legacy 7-factor profiles from
// lib/scoring/weight_profile.dart — this file is visual-only.
//
// ─────────────────────────────────────────────────────────────────
// Plan coordination with 5.5
// ─────────────────────────────────────────────────────────────────
// The Phase F plan doc cited 9 DSO sub-types (doubleStar, openCluster,
// globularCluster, brightNebula, faintNebula, galaxy, …). Those
// variants don't exist in the current [TargetType] enum yet — they're
// a Plan 5.5 §4.6 refinement that splits the current `dso` variant
// into 6 specialized entries. This file ships the base 6-row table
// against the actual enum, with galaxy-ish defaults for the umbrella
// `dso` row (galaxies are the canonical "dark, faint, transparency-
// sensitive" DSO case — the most common misc-DSO). When Plan 5.5
// expands the enum, the constant here gets expanded too; the API
// stays the same and no downstream code has to move.
//
// ─────────────────────────────────────────────────────────────────
// Weight rationale (visual vs imaging intent)
// ─────────────────────────────────────────────────────────────────
// Visual observation cares about:
//   * transparency (cirrus destroys faint detail through an eyepiece
//     even when a camera can still pull it out of noise)
//   * seeing (for high-magnification lunar/planetary/double-star work)
//   * Bortle / airmass (affects eye-adapted limiting magnitude)
//   * wind (moves the scope; matters more at high power)
// It cares less about moonlight on bright targets (you can see the
// Moon WHILE observing it) and less about subtle sky glow for
// naturally bright targets (planets, lunar features).
//
// Values in the literal below are reasoned estimates anchored in:
//   * Bortle scale publications (Sky & Telescope 2001 feature + follow-
//     on community discussion)
//   * Limiting-magnitude formula: lim ≈ 2 + 5·log₁₀(aperture_mm) −
//     0.3·(Bortle − 1), which tells us how Bortle dominates for faint
//     diffuse objects
//   * Cloudy Nights / stargazers-lounge visual-observing threads
//     documenting eyepiece-based observing preferences

import '../scoring/target_type.dart';

/// Six-column per-target-type weights for the visual intent. Plan 5.5
/// §4.6 adds four equipment-aware columns (magnification, trueFov,
/// exitPupil, dawesLimit) — they land as additional fields on this
/// same class, not a new type. Kept immutable (`const`) so the whole
/// table can be const-constructed and ship as compiled-in data.
class VisualWeights {
	/// How much lunar illumination hurts observability. Bright targets
	/// (planets, Moon itself) → ~0.2 (mostly unaffected). Faint diffuse
	/// DSOs → ~0.95 (full moon ruins them).
	final double moon;

	/// Transparency weight — how much cirrus / high cloud penalizes
	/// the target. Tight double stars tolerate haze (~0.3); faint
	/// nebulae don't (~0.95).
	final double transparency;

	/// Seeing weight — matters most for high-magnification lunar,
	/// planetary, and double-star work; low for extended-object DSOs
	/// where turbulence is averaged away by the eye's integration.
	final double seeing;

	/// Bortle (sky-glow) weight. Planetary / lunar barely care (~0.3);
	/// faint diffuse targets are dominated by it (~0.95).
	final double bortle;

	/// Airmass (altitude-driven extinction). All visible targets care,
	/// but faint-DSO hunters care more because extinction eats into
	/// an already-thin signal.
	final double airmass;

	/// Wind weight. Drives scope-wobble severity; matters more at
	/// high magnification where the wobble amplitude is amplified.
	final double wind;

	const VisualWeights({
		required this.moon,
		required this.transparency,
		required this.seeing,
		required this.bortle,
		required this.airmass,
		required this.wind,
	});
}

/// Visual weights keyed by [TargetType]. Every variant of the current
/// enum has an explicit row — adding a new variant without updating
/// this map will make [visualWeightsFor] return the conservative
/// fallback, but the addition should still land here for parity with
/// imaging weights.
const visualWeightsByTargetType = <TargetType, VisualWeights>{
	// DSO — umbrella entry for any deep-sky target until Plan 5.5
	// splits into galaxy/nebula/cluster sub-variants. Weighted like
	// galaxies (the most demanding DSO sub-type) so the umbrella
	// defaults errs toward "penalize when conditions degrade."
	TargetType.dso: VisualWeights(
		moon: 0.95,
		transparency: 0.9,
		seeing: 0.4,
		bortle: 0.95,
		airmass: 0.8,
		wind: 0.4,
	),
	// Planetary — bright, small, high-magnification. Seeing dominates.
	TargetType.planetary: VisualWeights(
		moon: 0.2,
		transparency: 0.4,
		seeing: 0.95,
		bortle: 0.3,
		airmass: 0.5,
		wind: 0.7,
	),
	// Lunar — moon weight is N/A (target IS the Moon). Seeing matters
	// heavily for terminator / crater rim detail; other factors mild.
	TargetType.lunar: VisualWeights(
		moon: 0.0,
		transparency: 0.4,
		seeing: 0.9,
		bortle: 0.2,
		airmass: 0.5,
		wind: 0.6,
	),
	// Solar — shipped here as a conservative stub. Full solar scoring
	// (H-alpha / white-light discrimination, limb seeing, etc.) lands
	// in Plan 6 when the solar imaging mode arrives. The table needs
	// a row so map lookups always hit; weights approximate "daytime
	// bright-target" observing.
	TargetType.solar: VisualWeights(
		moon: 0.0,
		transparency: 0.5,
		seeing: 0.95,
		bortle: 0.0,
		airmass: 0.6,
		wind: 0.7,
	),
	// Comet — diffuse and often faint. Transparency and Bortle matter;
	// moonlight is punishing when the coma is low-contrast.
	TargetType.comet: VisualWeights(
		moon: 0.8,
		transparency: 0.85,
		seeing: 0.4,
		bortle: 0.85,
		airmass: 0.7,
		wind: 0.4,
	),
	// Aurora — naked-eye / wide-field observation. Transparency and
	// Bortle dominate (dark skies show fainter structure); seeing is
	// irrelevant (aurora has no fine detail at eyepiece scales).
	TargetType.aurora: VisualWeights(
		moon: 0.6,
		transparency: 0.9,
		seeing: 0.0,
		bortle: 0.95,
		airmass: 0.6,
		wind: 0.2,
	),
};

/// Returns the [VisualWeights] for a given [TargetType], falling back
/// to a neutral 0.5-across-the-board profile if the type isn't in the
/// table. The fallback exists so a future enum addition doesn't crash
/// scoring — it produces a "mediocre everything matters" profile until
/// the weights are explicitly tuned. Emit at debug-time, not runtime,
/// if you're changing [TargetType] and forgetting to add a row here.
VisualWeights visualWeightsFor(TargetType type) {
	return visualWeightsByTargetType[type] ??
		const VisualWeights(
			moon: 0.5,
			transparency: 0.5,
			seeing: 0.5,
			bortle: 0.5,
			airmass: 0.5,
			wind: 0.5,
		);
}
