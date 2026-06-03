// test/sky_brightness_redesign_test.dart
//
// Unit tests for the Phase-1 location sky-brightness physics (spec §5a):
//   - moonBurden — the geometry-aware moon term, gated on altitude.
//   - locationSkyBrightnessScore — Bortle baseline + moon, never null.
//
// These cover the case the binary-level Python tests CANNOT isolate: the moon's
// illumination and its altitude are computed together from a date inside the
// compiled binary, so they can't be varied independently there. Here they can,
// which lets us pin THE headline guarantee of the redesign — a bright moon BELOW
// the horizon is a dark sky — directly.

import 'package:test/test.dart';
import 'package:astrowidget_scoring/scoring/sky_brightness.dart';

void main() {
  group('moonBurden — geometry-aware moon (spec §5a)', () {
    test('a bright moon BELOW the horizon contributes nothing', () {
      // THE core physics fix: a 95%-illuminated moon below the horizon is a dark
      // sky. max(0, sin(alt)) zeroes the burden for any negative altitude.
      expect(moonBurden(illuminationPercent: 95, moonAltitudeDeg: -1), 0.0);
      expect(moonBurden(illuminationPercent: 100, moonAltitudeDeg: -30), 0.0);
    });

    test('a moon exactly on the horizon contributes nothing', () {
      expect(moonBurden(illuminationPercent: 100, moonAltitudeDeg: 0), 0.0);
    });

    test('a full moon at the zenith is the maximal burden ~1.0', () {
      expect(moonBurden(illuminationPercent: 100, moonAltitudeDeg: 90),
          closeTo(1.0, 1e-9));
    });

    test('a half-illuminated moon at 30 deg is ~0.25 (0.5 x sin30)', () {
      expect(moonBurden(illuminationPercent: 50, moonAltitudeDeg: 30),
          closeTo(0.25, 1e-9));
    });

    test('burden scales with illumination at a fixed altitude', () {
      final low = moonBurden(illuminationPercent: 20, moonAltitudeDeg: 45);
      final high = moonBurden(illuminationPercent: 80, moonAltitudeDeg: 45);
      expect(high, greaterThan(low));
    });

    test('burden scales with altitude at a fixed illumination', () {
      final low = moonBurden(illuminationPercent: 100, moonAltitudeDeg: 10);
      final high = moonBurden(illuminationPercent: 100, moonAltitudeDeg: 70);
      expect(high, greaterThan(low));
    });
  });

  group('locationSkyBrightnessScore — Bortle baseline + moon (Phase-1 fix)', () {
    test('never null even with a null Bortle (default baseline keeps the moon live)',
        () {
      final s = locationSkyBrightnessScore(
          bortle: null, moonIlluminationPercent: 100, moonAltitudeDeg: 80);
      expect(s, isA<int>());
      expect(s, inInclusiveRange(0, 100));
    });

    test('a bright moon BELOW the horizon equals the no-moon baseline', () {
      // The headline guarantee, end to end through the scorer: 100%-illuminated
      // but DOWN imposes no penalty — identical to a moonless sky.
      const bortle = 4;
      final moonDownBright = locationSkyBrightnessScore(
          bortle: bortle, moonIlluminationPercent: 100, moonAltitudeDeg: -5);
      final noMoon = locationSkyBrightnessScore(
          bortle: bortle, moonIlluminationPercent: 0, moonAltitudeDeg: 90);
      expect(moonDownBright, noMoon);
    });

    test('a bright HIGH moon scores well below the same moon when down', () {
      const bortle = 4;
      final up = locationSkyBrightnessScore(
          bortle: bortle, moonIlluminationPercent: 100, moonAltitudeDeg: 80);
      final down = locationSkyBrightnessScore(
          bortle: bortle, moonIlluminationPercent: 100, moonAltitudeDeg: -80);
      expect(up, lessThan(down));
    });

    test('monotonic in Bortle: a darker site scores higher (moonless)', () {
      final dark = locationSkyBrightnessScore(
          bortle: 2, moonIlluminationPercent: 0, moonAltitudeDeg: -90);
      final bright = locationSkyBrightnessScore(
          bortle: 8, moonIlluminationPercent: 0, moonAltitudeDeg: -90);
      expect(dark, greaterThan(bright));
    });

    test('the null-Bortle default baseline sits between Bortle 4 and 5 (moonless)',
        () {
      final b4 = locationSkyBrightnessScore(
          bortle: 4, moonIlluminationPercent: 0, moonAltitudeDeg: -90);
      final b5 = locationSkyBrightnessScore(
          bortle: 5, moonIlluminationPercent: 0, moonAltitudeDeg: -90);
      final dflt = locationSkyBrightnessScore(
          bortle: null, moonIlluminationPercent: 0, moonAltitudeDeg: -90);
      // _defaultZenithSb = 20.5 is between Bortle 4 (20.85) and 5 (19.95).
      expect(dflt, lessThanOrEqualTo(b4));
      expect(dflt, greaterThanOrEqualTo(b5));
    });
  });

  group('snow albedo modifier (Phase 1b)', () {
    // Inputs chosen so the effective sky brightness stays ABOVE the 17.0 floor,
    // so the snow penalty is measurable (a full high moon at a bright site already
    // floors the score to 0, leaving no room to show snow's effect).
    test('ground snow darkens the score at a bright, moonlit site (reflects moon + LP)',
        () {
      final noSnow = locationSkyBrightnessScore(
          bortle: 5, moonIlluminationPercent: 70, moonAltitudeDeg: 40, snowDepthM: 0.0);
      final snow = locationSkyBrightnessScore(
          bortle: 5, moonIlluminationPercent: 70, moonAltitudeDeg: 40, snowDepthM: 0.15);
      expect(snow, lessThan(noSnow));
    });

    test('a <1cm dusting does NOT trigger the penalty (needs real ground cover)', () {
      final dusting = locationSkyBrightnessScore(
          bortle: 5, moonIlluminationPercent: 70, moonAltitudeDeg: 40, snowDepthM: 0.005);
      final none = locationSkyBrightnessScore(
          bortle: 5, moonIlluminationPercent: 70, moonAltitudeDeg: 40, snowDepthM: 0.0);
      expect(dusting, none);
    });

    test('snow barely affects a dark, moonless site (nothing to reflect — Bortle-gated)',
        () {
      final noSnow = locationSkyBrightnessScore(
          bortle: 2, moonIlluminationPercent: 0, moonAltitudeDeg: -90, snowDepthM: 0.0);
      final snow = locationSkyBrightnessScore(
          bortle: 2, moonIlluminationPercent: 0, moonAltitudeDeg: -90, snowDepthM: 0.30);
      expect((noSnow - snow).abs(), lessThanOrEqualTo(3)); // negligible
    });

    test('default snowDepthM is 0 (no effect when omitted)', () {
      final omitted = locationSkyBrightnessScore(
          bortle: 5, moonIlluminationPercent: 80, moonAltitudeDeg: 45);
      final explicitZero = locationSkyBrightnessScore(
          bortle: 5, moonIlluminationPercent: 80, moonAltitudeDeg: 45, snowDepthM: 0.0);
      expect(omitted, explicitZero);
    });
  });
}
