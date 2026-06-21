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
			// The real-model proof: NB rejects the moonlight that craters BB.
			final nb = narrowbandSkyScore(
				bortle: 5, moonIlluminationPercent: 100, moonAltitudeDeg: 80);
			final bb = locationSkyBrightnessScore(
				bortle: 5, moonIlluminationPercent: 100, moonAltitudeDeg: 80);
			expect(nb, greaterThan(60)); // ~67 at leakage 0.05
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

		test('bound: leakage = 1 → equals the broadband sky score (no rejection)', () {
			final nb = narrowbandSkyScore(
				bortle: 5,
				moonIlluminationPercent: 100,
				moonAltitudeDeg: 80,
				leakage: 1.0);
			final bb = locationSkyBrightnessScore(
				bortle: 5, moonIlluminationPercent: 100, moonAltitudeDeg: 80);
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
	});
}
