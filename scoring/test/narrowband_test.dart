import 'package:test/test.dart';
import 'package:astrowidget_scoring/scoring/sky_brightness.dart';
import '../bin/narrowband.dart';

void main() {
	group('narrowbandSkyScore', () {
		test('dark + moonless → ~100 (pristine)', () {
			final s = narrowbandSkyScore(
				bortle: 2, moonIlluminationPercent: 0, moonAltitudeDeg: 0);
			expect(s, greaterThanOrEqualTo(95));
		});

		test('full moon high → still high AND strictly above broadband', () {
			// The real-model proof: NB rejects the moonlight that craters BB. The spec
			// anchors this at ~67 (Bortle 5, full moon, leakage 0.05); pin it as a regression.
			final nb = narrowbandSkyScore(
				bortle: 5, moonIlluminationPercent: 100, moonAltitudeDeg: 80);
			final bb = locationSkyBrightnessScore(
				bortle: 5, moonIlluminationPercent: 100, moonAltitudeDeg: 80);
			expect(nb, greaterThanOrEqualTo(64)); // spec anchor ~67
			expect(nb, lessThanOrEqualTo(70));
			expect(nb, greaterThan(bb)); // BB ≈ 0 at this input
		});

		test('bright Bortle no moon → still good AND strictly above broadband', () {
			final nb = narrowbandSkyScore(
				bortle: 8, moonIlluminationPercent: 0, moonAltitudeDeg: 0);
			final bb = locationSkyBrightnessScore(
				bortle: 8, moonIlluminationPercent: 0, moonAltitudeDeg: 0);
			expect(nb, greaterThan(70)); // ~83 — narrowband from a city
			expect(nb, greaterThan(bb)); // BB ≈ 21
		});

		test('bound: leakage = 1 → reconstructs the broadband sky score (non-degenerate)',
			() {
			// MILD moon at a moderate site → BB sky is mid-range (NOT cratered to 0), so the
			// flux round-trip identity is meaningfully exercised, not a vacuous 0 == 0.
			final nb = narrowbandSkyScore(
				bortle: 4,
				moonIlluminationPercent: 50,
				moonAltitudeDeg: 30,
				leakage: 1.0);
			final bb = locationSkyBrightnessScore(
				bortle: 4, moonIlluminationPercent: 50, moonAltitudeDeg: 30);
			expect(bb, greaterThan(20)); // guard: the input is non-degenerate
			expect(nb, equals(bb));
		});

		test('bound: leakage = 0 → pristine 100 (perfect rejection)', () {
			final s = narrowbandSkyScore(
				bortle: 8,
				moonIlluminationPercent: 100,
				moonAltitudeDeg: 80,
				leakage: 0.0);
			expect(s, equals(100));
		});

		test('monotonically decreasing in leakage', () {
			int at(double l) => narrowbandSkyScore(
				bortle: 5,
				moonIlluminationPercent: 100,
				moonAltitudeDeg: 80,
				leakage: l);
			expect(at(0.03), greaterThan(at(0.05)));
			expect(at(0.05), greaterThan(at(0.10)));
		});

		test('out-of-range leakage is clamped, never NaN-crashes', () {
			// A negative config typo would make nbFluxRatio ≤ 0 → log(NaN) → round() throws,
			// aborting the whole run. Clamp to 0 → pristine; >1 clamps to 1 → the BB score.
			expect(
				narrowbandSkyScore(
					bortle: 5,
					moonIlluminationPercent: 100,
					moonAltitudeDeg: 80,
					leakage: -0.5),
				equals(100));
			final overOne = narrowbandSkyScore(
				bortle: 5, moonIlluminationPercent: 100, moonAltitudeDeg: 80, leakage: 5.0);
			final atOne = narrowbandSkyScore(
				bortle: 5, moonIlluminationPercent: 100, moonAltitudeDeg: 80, leakage: 1.0);
			expect(overOne, equals(atOne));
		});

		test('snow lowers the NB sky score (continuum NB also rejects — mirrors BB)', () {
			final dry = narrowbandSkyScore(
				bortle: 7, moonIlluminationPercent: 100, moonAltitudeDeg: 80, snowDepthM: 0.0);
			final snowy = narrowbandSkyScore(
				bortle: 7, moonIlluminationPercent: 100, moonAltitudeDeg: 80, snowDepthM: 0.05);
			expect(snowy, lessThan(dry)); // snow amplifies the brightening NB rejects only partly
		});

		test('null Bortle uses the default baseline (no crash, sensible score)', () {
			final s = narrowbandSkyScore(
				bortle: null, moonIlluminationPercent: 50, moonAltitudeDeg: 30);
			expect(s, greaterThanOrEqualTo(0));
			expect(s, lessThanOrEqualTo(100));
		});
	});
}
