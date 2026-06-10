// test/dark_window_regression_test.dart
//
// Regression tests for the dark-window solver's degenerate-end bug
// (found 2026-06-09, fixed in visibility.dart's _sunCrossingWindow).
//
// The morning (ascending) -18° search used to be seeded at the exact instant
// of the evening (descending) crossing. geoengine refines crossings to a
// 0.1 s tolerance, so the seed could land a hair past the true root, where
// the altitude function is zero-within-noise — and the ascending root-finder
// "converged" immediately, returning end ≈ start + 1 ms. Sporadic (depends on
// which side of the root the refinement lands) and seasonal (the shallow
// near-solstice crossing widens the noise band). Bainbridge (47.62°N) hit it
// on the 2026-06-10/11 and 2026-06-14/15 nights: 0-minute windows between
// healthy ~120/~110-minute neighbours, which blanked the widget's stats.
//
// These tests pin the two observed failure nights, the smoothness of the
// whole solstice trough, and the documented small-window semantics.
import 'package:test/test.dart';

import 'package:astrowidget_scoring/astro/visibility.dart';

void main() {
	group('astronomicalDarkWindow — degenerate-end regression (Bainbridge 47.62N)', () {
		const lat = 47.62;
		const lon = -122.5;

		test('2026-06-10/11 night (the night that collapsed to 0 min) is ~120 min', () {
			final w = astronomicalDarkWindow(DateTime.utc(2026, 6, 10),
				latitude: lat, longitude: lon);
			expect(w.isAvailable, isTrue,
				reason: 'this night has real astro dark; the bug zeroed it');
			expect(w.durationHours! * 60, inInclusiveRange(110, 130));
		});

		test('2026-06-14/15 night (the second collapsed night) is ~109 min', () {
			final w = astronomicalDarkWindow(DateTime.utc(2026, 6, 14),
				latitude: lat, longitude: lon);
			expect(w.isAvailable, isTrue);
			expect(w.durationHours! * 60, inInclusiveRange(100, 120));
		});

		test('solstice trough June 8 - July 2 is smooth: every night 60-200 min, '
			'and adjacent nights differ by <= 6 min (no collapses, no spikes)', () {
			double? prev;
			for (var day = DateTime.utc(2026, 6, 8);
					day.isBefore(DateTime.utc(2026, 7, 2));
					day = day.add(const Duration(days: 1))) {
				final w = astronomicalDarkWindow(day, latitude: lat, longitude: lon);
				expect(w.isAvailable, isTrue, reason: 'no dark window on $day');
				final mins = w.durationHours! * 60;
				expect(mins, inInclusiveRange(60, 200), reason: 'absurd window on $day');
				if (prev != null) {
					expect((mins - prev).abs(), lessThanOrEqualTo(6),
						reason: 'discontinuity at $day: $prev -> $mins min');
				}
				prev = mins;
			}
		});

		test('graze latitude (48.55N, solstice) still finds its genuinely tiny '
			'window — and never fabricates a wraparound ~24 h one', () {
			final w = astronomicalDarkWindow(DateTime.utc(2026, 6, 20),
				latitude: 48.55, longitude: lon);
			if (w.isAvailable) {
				// Real windows here are ~10-20 min; the pre-fix wraparound artifact
				// would have been >20 h. Anything under an hour is sane.
				expect(w.durationHours! * 60, lessThan(60));
			}
			// A null window is also acceptable (the <5-min seed-offset trade-off,
			// documented in _sunCrossingWindow) — only a fabricated long window fails.
		});
	});

	group('horizonWindow — shares the fixed helper (0° target)', () {
		test('Bainbridge winter night (2026-12-21) is a sane ~15-16 h sunset→sunrise', () {
			final w = horizonWindow(DateTime.utc(2026, 12, 21),
				latitude: 47.62, longitude: -122.5);
			expect(w.isAvailable, isTrue);
			expect(w.durationHours, inInclusiveRange(14.0, 17.0));
		});

		test('Bainbridge summer night (2026-06-20) is a sane ~8 h sunset→sunrise', () {
			final w = horizonWindow(DateTime.utc(2026, 6, 20),
				latitude: 47.62, longitude: -122.5);
			expect(w.isAvailable, isTrue);
			expect(w.durationHours, inInclusiveRange(7.0, 9.5));
		});

		test('64N winter night (Fairbanks band, 2026-12-21) keeps its GENUINE '
			'>20 h night — a duration-threshold guard would wrongly null it', () {
			// Day length at 64N winter solstice is ~3.6 h, so the real night is
			// ~20.4 h. This is why the wraparound guard tests the Sun's altitude
			// at the window midpoint instead of cutting on duration (review
			// finding, 2026-06-09): genuine high-latitude nights and the ~23.9 h
			// artifact overlap in duration, but only the artifact contains noon.
			final w = horizonWindow(DateTime.utc(2026, 12, 21),
				latitude: 64.0, longitude: -147.7);
			expect(w.isAvailable, isTrue,
				reason: 'genuine 64N winter night must not be guard-nulled');
			expect(w.durationHours, inInclusiveRange(19.5, 21.5));
		});
	});
}
