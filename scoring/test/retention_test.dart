import 'package:test/test.dart';
import '../bin/retention.dart';

// Convenience: composite a band score from raw inputs with sensible defaults.
// Mirrors how the wrapper will call the core (see score_location.dart wiring).
int _score({
	required String band, // 'BB' | 'NB'
	int cloudFactor = 98,
	double avgBurden = 0.0,
	int? bortle = 2,
	double snowDepthM = 0.0,
	double? aodMean,
	int firePenalty = 0,
	int stabilityFactor = 75,
	double? leakage,
}) {
	final r = compositeRetentions(
		cloudFactor: cloudFactor,
		avgBurden: avgBurden,
		bortle: bortle,
		snowDepthM: snowDepthM,
		aodMean: aodMean,
		firePenalty: firePenalty,
		stabilityFactor: stabilityFactor,
		nbLeakage: leakage ?? nbEffectiveLeakage,
	);
	return band == 'BB' ? r.broadband.score : r.narrowband.score;
}

void main() {
	group('four-corner acceptance (Dustin 2026-07-01)', () {
		test('moonless-cloudless best > single-problem nights > fullmoon-cloudy worst',
			() {
			final best = _score(band: 'BB', cloudFactor: 95, avgBurden: 0.0);
			final cloudy = _score(band: 'BB', cloudFactor: 45, avgBurden: 0.0);
			final moony = _score(band: 'BB', cloudFactor: 95, avgBurden: 0.45);
			final worst = _score(band: 'BB', cloudFactor: 45, avgBurden: 0.45);
			expect(best, greaterThan(cloudy));
			expect(best, greaterThan(moony));
			expect(cloudy, greaterThan(worst));
			expect(moony, greaterThan(worst));
		});
	});

	group('anchors + floors', () {
		test('dark-site clear moonless night scores ≥92 (typical-good ≈ 1.0)', () {
			// B2 with 2% cloud lands ~94: 0.98 time × ~0.96 sky (B2 honestly gives up
			// ~4% depth vs pristine B1 — 0.17 mag × S). The anchor is "near-100 minus
			// honest small costs", NOT a padded 100 — grade inflation is the old model.
			expect(_score(band: 'BB', cloudFactor: 98, bortle: 2), greaterThanOrEqualTo(92));
			// And a literally-perfect night at a pristine B1 site touches ~98+.
			expect(_score(band: 'BB', cloudFactor: 100, bortle: 1), greaterThanOrEqualTo(98));
		});
		test('overcast night craters regardless of everything else being perfect', () {
			expect(_score(band: 'BB', cloudFactor: 3, bortle: 1, stabilityFactor: 100),
				lessThanOrEqualTo(5));
		});
		test('retention floors hold at absurd inputs (no negative/NaN)', () {
			final s = _score(band: 'BB', cloudFactor: 0, avgBurden: 1.0, bortle: 9,
				aodMean: 3.0, firePenalty: 25, stabilityFactor: 0);
			expect(s, greaterThanOrEqualTo(0));
		});
	});

	group('NB ≥ BB (structural, L < 1)', () {
		test('holds across the input grid', () {
			for (var burden = 0.0; burden <= 1.0; burden += 0.25) {
				for (final bortle in [1, 3, 5, 7, 9]) {
					final bb = _score(band: 'BB', avgBurden: burden, bortle: bortle);
					final nb = _score(band: 'NB', avgBurden: burden, bortle: bortle);
					expect(nb, greaterThanOrEqualTo(bb),
						reason: 'burden=$burden bortle=$bortle');
				}
			}
		});
		test('leakage override 1.0 ⇒ NB == BB (parity guard)', () {
			final bb = _score(band: 'BB', avgBurden: 0.4, bortle: 4, leakage: 1.0);
			final nb = _score(band: 'NB', avgBurden: 0.4, bortle: 4, leakage: 1.0);
			expect(nb, equals(bb));
		});
	});

	group('monotonicity (each effect only ever lowers the score)', () {
		test('rising moon burden lowers BB', () {
			expect(_score(band: 'BB', avgBurden: 0.2),
				greaterThan(_score(band: 'BB', avgBurden: 0.6)));
		});
		test('rising AOD lowers the score, never raises it', () {
			expect(_score(band: 'BB', aodMean: 0.05),
				greaterThanOrEqualTo(_score(band: 'BB', aodMean: 0.30)));
			expect(_score(band: 'BB', aodMean: 0.30),
				greaterThan(_score(band: 'BB', aodMean: 0.60)));
		});
		test('fire penalty lowers the score (never raises — anti-inversion)', () {
			expect(_score(band: 'BB', aodMean: 0.1, firePenalty: 0),
				greaterThan(_score(band: 'BB', aodMean: 0.1, firePenalty: 20)));
		});
		test('snow lowers both bands under moon+LP', () {
			expect(_score(band: 'BB', avgBurden: 0.4, bortle: 5, snowDepthM: 0.0),
				greaterThan(_score(band: 'BB', avgBurden: 0.4, bortle: 5, snowDepthM: 0.05)));
			expect(_score(band: 'NB', avgBurden: 0.4, bortle: 5, snowDepthM: 0.0),
				greaterThan(_score(band: 'NB', avgBurden: 0.4, bortle: 5, snowDepthM: 0.05)));
		});
		test('worse stability lowers the score gently', () {
			final good = _score(band: 'BB', stabilityFactor: 80);
			final bad = _score(band: 'BB', stabilityFactor: 0);
			expect(good, greaterThan(bad));
			expect(good - bad, lessThanOrEqualTo(20)); // gentle, not dominating
		});
	});

	group('transparency retention (measured AOD curve, calibrate_aod.py 2026-07-01)', () {
		test('curve points', () {
			expect(transparencyRetention(0.03, 0), closeTo(1.00, 0.001));
			expect(transparencyRetention(0.10, 0), closeTo(0.99, 0.001));
			expect(transparencyRetention(0.20, 0), closeTo(0.96, 0.001));
			expect(transparencyRetention(0.40, 0), closeTo(0.78, 0.001));
			expect(transparencyRetention(0.60, 0), closeTo(0.65, 0.001));
		});
		test('interpolates between points', () {
			final mid = transparencyRetention(0.30, 0);
			expect(mid, lessThan(0.96));
			expect(mid, greaterThan(0.78));
		});
		test('no AOD data → identity (omit-not-zero, multiplicative form)', () {
			expect(transparencyRetention(null, 0), equals(1.0));
		});
		test('fire dock multiplies; advisory-only when no AOD is unaffected here', () {
			expect(transparencyRetention(0.10, 20), closeTo(0.99 * 0.80, 0.001));
		});
		test('floor at 0.50 for extreme smoke', () {
			expect(transparencyRetention(2.0, 0), greaterThanOrEqualTo(0.50));
		});
	});

	group('product identity (auditability — the score IS the product)', () {
		test('score == round(100 × Π retentions), both bands', () {
			final r = compositeRetentions(cloudFactor: 62, avgBurden: 0.26, bortle: 5,
				snowDepthM: 0.0, aodMean: 0.12, firePenalty: 0, stabilityFactor: 54,
				nbLeakage: nbEffectiveLeakage);
			for (final band in [r.broadband, r.narrowband]) {
				final p = band.timeCloud * band.sky * band.transparency * band.seeing;
				expect(band.score, equals((100 * p).round().clamp(0, 100)));
			}
		});
	});

	group('calibration regression (the incident night)', () {
		test('UDRO-like: clear B2, full moon at 27° avg-low → BB crunched, NB holds', () {
			// The reported incident: BB read 85 under a 98% moon. v2 must crunch it.
			final bb = _score(band: 'BB', cloudFactor: 99, avgBurden: 0.35,
				bortle: 2, aodMean: 0.08, stabilityFactor: 75);
			final nb = _score(band: 'NB', cloudFactor: 99, avgBurden: 0.35,
				bortle: 2, aodMean: 0.08, stabilityFactor: 75);
			expect(bb, inInclusiveRange(55, 75)); // ~30% depth loss visible in the SCORE
			expect(nb, inInclusiveRange(78, 95)); // NB mildly dented
			expect(nb - bb, greaterThanOrEqualTo(12)); // the gap emerges
		});
	});
}
