// scoring/bin/narrowband.dart
// astrowidget's OWN narrowband sky-brightness model (NOT vendored — lives in bin/).
//
// WHY this exists: a narrowband filter (Dustin's Antlia 3nm) passes ~1-3 nm around an
// emission line and rejects ~99% of the broadband CONTINUUM that moonlight, light
// pollution, and twilight contribute. So the sky background a narrowband sub actually
// sees is far darker than the broadband sky — which is why Ha works under a gibbous moon
// from a suburban yard. This computes a real NB-effective sky score from that physics,
// replacing the old "down-weight the broadband sky factor" heuristic.
//
// HOW: take the broadband sky-brightening above a pristine sky (moon + light-pollution +
// snow), convert it to an excess-FLUX ratio (magnitudes are logarithmic, so rejection
// must happen in flux space), keep only `leakage` of that flux, convert back to
// magnitudes, and score with the SAME 0-100 curve the broadband model uses. Reuses the
// exported vendored functions so it stays consistent and never forks the physics.
//
// BACK-PORT: this is a pure function over the same inputs/constants as the vendored
// locationSkyBrightnessScore — it lifts into astroplan's lib/scoring/sky_brightness.dart
// as a sibling when the refined models flow back (astrowidget → astroplan, one-way).
import 'dart:math' as math;
import 'package:astrowidget_scoring/scoring/sky_brightness.dart';

/// Continuum-flux fraction a narrowband filter transmits ≈ Δλ_filter / Δλ_continuum ×
/// imperfection. Antlia 3nm: (3/~100) × ~1.7 ≈ 0.05. The one knob; tunable per filter set
/// via the stdin `nb_leakage` override, calibratable later from the auto-grader.
const double nbLeakageDefault = 0.05;

// Physics constants re-stated from the vendored sky_brightness.dart (private there). Keep
// in sync with that file — they define the same magnitude scale the broadband model uses.
const double _pristineSb = 21.85; // Bortle-1 zenith (darkest), mag/arcsec²
const double _defaultZenithSb = 20.5; // fallback when Bortle unknown
const double _moonMaxDeltaMag = 3.0; // worst-case moon brightening (full, zenith)
const double _snowGain = 0.3; // fresh-snow albedo amplification

/// Narrowband sky-brightness sub-score (0-100, higher = darker = better).
///
/// Receives: [bortle] 1-9 or null; [moonIlluminationPercent] 0-100;
///   [moonAltitudeDeg] degrees above horizon; [snowDepthM] ground snow (metres);
///   [leakage] continuum-flux fraction transmitted (0-1).
/// Returns: 0-100. leakage→0 ⇒ 100 (perfect rejection); leakage=1 ⇒ the broadband sky
///   score (no rejection); monotonically decreasing in leakage.
int narrowbandSkyScore({
	int? bortle,
	required double moonIlluminationPercent,
	required double moonAltitudeDeg,
	double snowDepthM = 0.0,
	double leakage = nbLeakageDefault,
}) {
	// Guard the one external knob. A negative leakage (a plausible config typo — it's a
	// user-facing 0-1 fraction) makes nbFluxRatio ≤ 0 → log(NaN) → skyBrightnessScore's
	// .round() throws a Dart Error that aborts the WHOLE run, not a per-site error. >1 is
	// unphysical (>100% continuum transmission). Clamp to [0, 1].
	final l = leakage.clamp(0.0, 1.0);
	final baseSb = zenithSkyBrightness(bortle) ?? _defaultZenithSb;
	final burden = moonBurden(
		illuminationPercent: moonIlluminationPercent,
		moonAltitudeDeg: moonAltitudeDeg,
	);
	final moonDelta = burden * _moonMaxDeltaMag;
	final lpExcess = (_pristineSb - baseSb).clamp(0.0, 5.0);
	final snowExtra =
		(snowDepthM > 0.01 ? _snowGain : 0.0) * (moonDelta + lpExcess);
	// Broadband sky-brightening above pristine, in magnitudes.
	final bbBrightening = moonDelta + lpExcess + snowExtra;

	// Reject the continuum in FLUX space: the filter sees only `leakage` of the excess.
	final bbExcessFlux = math.pow(10, bbBrightening / 2.5).toDouble() - 1.0;
	final nbFluxRatio = 1.0 + l * bbExcessFlux;
	final nbBrightening = 2.5 * (math.log(nbFluxRatio) / math.ln10); // back to mag
	final nbEffectiveSb = _pristineSb - nbBrightening;
	return skyBrightnessScore(nbEffectiveSb);
}
