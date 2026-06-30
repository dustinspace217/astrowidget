import 'dart:math' as math;
import 'package:test/test.dart';
import '../bin/moon_window.dart';

// 15-min-spaced UTC samples starting at a fixed instant.
DateTime _t(int min) => DateTime.utc(2026, 1, 1, 22).add(Duration(minutes: min));

// n samples 15 min apart, altitude ramping linearly a0 → a1.
List<MoonSample> _ramp(double a0, double a1, int n) => [
	for (var i = 0; i < n; i++)
		MoonSample(time: _t(i * 15), altitudeDeg: a0 + (a1 - a0) * i / (n - 1)),
];

void main() {
	group('computeMoonGeometry', () {
		test('moon down all night → freeFraction 1, no window (Moon-free BB == BB)', () {
			final g = computeMoonGeometry(_ramp(-40, -10, 8), _t(0), _t(105));
			expect(g.freeFraction, 1.0);
			expect(g.moonFreeWindow, isNull);
			expect(g.avgSinAlt, 0.0); // every sample below the horizon
		});

		test('moon up all night → freeFraction 0, no window', () {
			final g = computeMoonGeometry(_ramp(10, 40, 8), _t(0), _t(105));
			expect(g.freeFraction, 0.0);
			expect(g.moonFreeWindow, isNull);
			expect(g.avgSinAlt, greaterThan(0));
		});

		test('moon rises mid-window → window is the early below-horizon run', () {
			final g = computeMoonGeometry(_ramp(-20, 40, 8), _t(0), _t(105));
			expect(g.freeFraction, greaterThan(0));
			expect(g.freeFraction, lessThan(1));
			expect(g.moonFreeWindow!.start, _t(0));
			expect(g.moonFreeWindow!.end, _t(45)); // first 3 samples are below horizon
		});

		test('maxAltDeg is the peak (still emitted for display)', () {
			final g = computeMoonGeometry(_ramp(-20, 40, 8), _t(0), _t(105));
			expect(g.maxAltDeg, closeTo(40, 0.001));
		});

		test('empty samples → degenerate, no crash', () {
			final g = computeMoonGeometry(const [], _t(0), _t(105));
			expect(g.freeFraction, 0);
			expect(g.moonFreeWindow, isNull);
		});
	});

	group('effectiveMoonAltitudeDeg', () {
		test('inverts sin so moonBurden sees the average', () {
			final altEff = effectiveMoonAltitudeDeg(0.5);
			expect(math.sin(altEff * math.pi / 180), closeTo(0.5, 1e-9));
		});

		test('clamps avgSinAlt to [0,1] (no asin domain error)', () {
			expect(effectiveMoonAltitudeDeg(0.0), 0.0);
			expect(effectiveMoonAltitudeDeg(1.0), closeTo(90, 1e-9));
		});
	});

	group('narrowbandMoonAdjustedSky (score-space 0.25 dock)', () {
		test('reproduces the measured 0.25 NB/BB drop ratio at every site', () {
			// bbSkyNoMoon 100 → bbSkyMoon 20 ⇒ BB drop 80. NB drop must be 0.25×80 = 20.
			final nb = narrowbandMoonAdjustedSky(100, 100, 20);
			expect(nb, 80); // 100 − 0.25×80
			final nbDrop = 100 - nb; // nbSkyNoMoon − result
			final bbDrop = 100 - 20;
			expect(nbDrop / bbDrop, closeTo(0.25, 0.001));
		});

		test('preserves NB ≥ BB (structural invariant)', () {
			// nbSkyNoMoon ≥ bbSkyNoMoon (NB rejects LP/snow); result must stay ≥ bbSkyMoon.
			final nb = narrowbandMoonAdjustedSky(100, 78, 44); // Bortle-4-like
			expect(nb, greaterThanOrEqualTo(44));
			expect(nb, 92); // 100 − 0.25×34 = 91.5 → 92
		});

		test('clamps to [0,100]', () {
			expect(narrowbandMoonAdjustedSky(10, 100, 0), 0); // 10 − 25 → clamp 0
			expect(narrowbandMoonAdjustedSky(100, 100, 100), 100); // no moon drop
		});
	});
}
