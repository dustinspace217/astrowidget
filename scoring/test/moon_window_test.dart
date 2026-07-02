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

		test('moon rises mid-window → window is the early below-horizon run (≥1h)', () {
			// 10 samples over 135 min, alt -30→30. First 5 below horizon → a 75-min gap.
			final g = computeMoonGeometry(_ramp(-30, 30, 10), _t(0), _t(135));
			expect(g.freeFraction, greaterThan(0));
			expect(g.freeFraction, lessThan(1));
			expect(g.moonFreeWindow!.start, _t(0));
			expect(g.moonFreeWindow!.end, _t(75)); // first 5 samples below horizon
		});

		test('sub-hour moon-free gap is NOT surfaced (degenerate-window guard)', () {
			// 8 samples; first 2 below horizon → only a 30-min gap (< 60 min minimum).
			final g = computeMoonGeometry(_ramp(-15, 45, 8), _t(0), _t(105));
			expect(g.freeFraction, greaterThan(0)); // true proportion still reported
			expect(g.moonFreeWindow, isNull); // but no usable window surfaced
		});

		test('moon down all night with OFF-GRID darkEnd → freeFraction 1.0, no window', () {
			// QA-2026-06-30 regression (adversarial-tester + code-reviewer): the 15-min grid
			// stops short of darkEnd (dark windows aren't 15-min multiples). Measured to the
			// last sample, a moon-down-all-night run gave freeFraction ≈ 0.96 < 1 and spuriously
			// surfaced a redundant whole-night window. darkEnd is 7 min past the last sample.
			final g = computeMoonGeometry(_ramp(-40, -10, 8), _t(0), _t(112));
			expect(g.freeFraction, 1.0);
			expect(g.moonFreeWindow, isNull);
		});

		test('exactly-60-min gap IS surfaced (gate is ≥60, not >60)', () {
			// samples 0-3 below horizon (t0..t45), sample 4 (t60) above → a 60-min run.
			final g = computeMoonGeometry(_ramp(-25, 25, 8), _t(0), _t(105));
			expect(g.moonFreeWindow, isNotNull);
			expect(g.moonFreeWindow!.end, _t(60));
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

		test('averaged effective altitude is BELOW the peak (the averaging claim)', () {
			// A rising moon: the time-averaged altitude (hence the effective scoring altitude
			// the wrapper feeds the engine) must be below the peak — the whole point of
			// averaging vs the old peak-altitude penalty.
			final g = computeMoonGeometry(_ramp(0, 40, 8), _t(0), _t(105));
			expect(effectiveMoonAltitudeDeg(g.avgSinAlt), lessThan(g.maxAltDeg));
		});
	});

	// The score-space NB moon dock tests were removed 2026-07-01: the dock was superseded
	// by the retention-v2 composite (retention.dart / retention_test.dart), where the NB
	// moon response is the calibrated effective flux leakage in one unified sky model.
}
