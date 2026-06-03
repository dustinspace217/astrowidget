// test/scoring_engine_redesign_test.dart
//
// Unit tests for the Phase-1 scoreLocation changes that the binary-level Python
// tests cannot reach deterministically:
//   - correction 3: when the window is too short for a real stability assessment
//     (the degenerate 50 sentinel), the 250 hPa jet is used ALONE, not blended
//     50/50 with the meaningless sentinel;
//   - the 250 hPa null fallback (absent jet -> surface proxy, never a calm-jet 100);
//   - fix 2: an absent factor is OMITTED from factorScores, never written as 0.
//
// These need a single-hour (or AOD-free) window, which the compiled binary — which
// always receives a full multi-hour forecast — can't easily produce.

import 'package:test/test.dart';
import 'package:astrowidget_scoring/scoring/scoring_engine.dart';
import 'package:astrowidget_scoring/weather/weather_models.dart';
import 'package:astrowidget_scoring/astro/visibility.dart';

// One HourlyWeather via fromJson (the same shape the fetcher emits). jet250 is
// included only when given, so a null-jet hour can be built.
HourlyWeather _hour(String time, {required double cloud, double? jet250}) {
  final m = <String, dynamic>{
    'time': time, 'cloud_cover': cloud, 'cloud_cover_low': 0.0,
    'cloud_cover_mid': 0.0, 'cloud_cover_high': 0.0,
    'relative_humidity_2m': 50.0, 'temperature_2m': 10.0, 'dewpoint_2m': 2.0,
    'wind_speed_10m': 5.0, 'wind_gusts_10m': 10.0,
    'precipitation_probability': 0.0, 'precipitation': 0.0, 'visibility': 30000.0,
  };
  if (jet250 != null) m['wind_speed_250hPa'] = jet250;
  return HourlyWeather.fromJson(m);
}

void main() {
  group('scoreLocation seeing blend (correction 3 — degenerate stability)', () {
    test('a single-hour window with a 250 hPa jet uses the jet ALONE, '
        'not blended with the 50 sentinel', () {
      // A 30-minute dark window catches only the 06:00 hour -> windowHrs.length==1
      // -> surfaceStability is the degenerate 50 sentinel. With a jet present the
      // seeing factor must be the jet score alone: jet=30 -> _linearScore(30, 15,
      // 100) = 82, NOT the (82+50)/2 = 66 blend.
      final start = DateTime.utc(2026, 1, 15, 6, 0);
      final end = DateTime.utc(2026, 1, 15, 6, 30);
      final loc = scoreLocation(
        forecast: WeatherForecast(
          locationId: 0, fetchedAt: start,
          hours: [_hour('2026-01-15T06:00', cloud: 10.0, jet250: 30.0)],
        ),
        darkWindow: DarkWindow(start: start, end: end),
        moonIlluminationPercent: 0, moonAltitude: -90,
      );
      expect(loc.factorScores['stability'], 82,
          reason: 'jet-alone (82), not the 66 blend with the 50 sentinel');
    });

    test('a multi-hour window blends the jet with the real surface stability', () {
      final start = DateTime.utc(2026, 1, 15, 6, 0);
      final end = DateTime.utc(2026, 1, 15, 9, 0);
      final loc = scoreLocation(
        forecast: WeatherForecast(
          locationId: 0, fetchedAt: start,
          hours: [
            _hour('2026-01-15T06:00', cloud: 10.0, jet250: 30.0),
            _hour('2026-01-15T07:00', cloud: 10.0, jet250: 30.0),
            _hour('2026-01-15T08:00', cloud: 10.0, jet250: 30.0),
          ],
        ),
        darkWindow: DarkWindow(start: start, end: end),
        moonIlluminationPercent: 0, moonAltitude: -90,
      );
      // >= 2 hours -> surfaceStability is real, so the seeing factor is the blend
      // of jet (82) and surface — strictly NOT the bare jet score.
      final stability = loc.factorScores['stability']!;
      expect(stability, isNot(82), reason: 'should be a blend, not jet-alone');
      expect(stability, inInclusiveRange(50, 100));
    });

    test('a null 250 hPa jet falls back to the surface proxy, '
        'never scored as an ideal calm jet', () {
      final start = DateTime.utc(2026, 1, 15, 6, 0);
      final end = DateTime.utc(2026, 1, 15, 9, 0);
      final loc = scoreLocation(
        forecast: WeatherForecast(
          locationId: 0, fetchedAt: start,
          hours: [
            _hour('2026-01-15T06:00', cloud: 10.0),
            _hour('2026-01-15T07:00', cloud: 10.0),
            _hour('2026-01-15T08:00', cloud: 10.0),
          ],
        ),
        darkWindow: DarkWindow(start: start, end: end),
        moonIlluminationPercent: 0, moonAltitude: -90,
      );
      expect(loc.factorScores['stability'], isNot(100),
          reason: 'absent jet must not read as an ideal calm jet');
    });
  });

  group('scoreLocation factor presence (fix 2 — omit absent, never zero)', () {
    DarkWindow dw() =>
        DarkWindow(start: DateTime.utc(2026, 1, 15, 6), end: DateTime.utc(2026, 1, 15, 9));
    List<HourlyWeather> hrs() => [
          _hour('2026-01-15T06:00', cloud: 10.0, jet250: 30.0),
          _hour('2026-01-15T07:00', cloud: 10.0, jet250: 30.0),
        ];

    test('no AOD -> factorScores OMITS transparency (and the removed darkness key)',
        () {
      final loc = scoreLocation(
        forecast: WeatherForecast(locationId: 0, fetchedAt: dw().start!, hours: hrs()),
        darkWindow: dw(), moonIlluminationPercent: 0, moonAltitude: -90,
      );
      expect(loc.factorScores.containsKey('transparency'), isFalse);
      expect(loc.factorScores.containsKey('darkness'), isFalse);
      expect(loc.factorScores.containsKey('moon'), isFalse);
      expect(loc.factorScores.containsKey('skyBrightness'), isTrue); // always present
    });

    test('with AOD -> transparency IS present', () {
      final aq = [
        AirQuality.fromJson({'time': '2026-01-15T06:00', 'aerosol_optical_depth': 0.05}),
        AirQuality.fromJson({'time': '2026-01-15T07:00', 'aerosol_optical_depth': 0.05}),
      ];
      final loc = scoreLocation(
        forecast: WeatherForecast(
            locationId: 0, fetchedAt: dw().start!, hours: hrs(), airQuality: aq),
        darkWindow: dw(), moonIlluminationPercent: 0, moonAltitude: -90,
      );
      expect(loc.factorScores.containsKey('transparency'), isTrue);
    });
  });
}
