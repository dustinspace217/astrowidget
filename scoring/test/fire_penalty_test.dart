// test/fire_penalty_test.dart
//
// Tests for the FIRMS fire-proximity transparency penalty in scoreLocation
// (smoke feature, 2026-06-25). A nearby active fire docks the transparency
// factor (and, via the wrapper, narrowband) and adds a ⚠ advisory reason.
import 'package:test/test.dart';
import 'package:astrowidget_scoring/scoring/scoring_engine.dart';
import 'package:astrowidget_scoring/weather/weather_models.dart';
import 'package:astrowidget_scoring/astro/visibility.dart';

HourlyWeather _hour(String time) => HourlyWeather.fromJson(<String, dynamic>{
	'time': time, 'cloud_cover': 5.0, 'cloud_cover_low': 0.0,
	'cloud_cover_mid': 0.0, 'cloud_cover_high': 0.0,
	'relative_humidity_2m': 50.0, 'temperature_2m': 10.0, 'dewpoint_2m': 2.0,
	'wind_speed_10m': 5.0, 'wind_gusts_10m': 10.0,
	'precipitation_probability': 0.0, 'precipitation': 0.0, 'visibility': 30000.0,
	'wind_speed_250hPa': 20.0,
});

final _start = DateTime.utc(2026, 1, 15, 6, 0);
final _end = DateTime.utc(2026, 1, 15, 9, 0);

List<HourlyWeather> _hrs() => [
	_hour('2026-01-15T06:00'), _hour('2026-01-15T07:00'), _hour('2026-01-15T08:00'),
];

// Clear AOD (0.05) → transparency ~100 before any fire penalty.
List<AirQuality> _clearAq() => [
	AirQuality.fromJson({'time': '2026-01-15T06:00', 'aerosol_optical_depth': 0.05}),
	AirQuality.fromJson({'time': '2026-01-15T07:00', 'aerosol_optical_depth': 0.05}),
	AirQuality.fromJson({'time': '2026-01-15T08:00', 'aerosol_optical_depth': 0.05}),
];

LocationScore _score({FiresNearby? fires, List<AirQuality>? aq}) => scoreLocation(
	forecast: WeatherForecast(
		locationId: 0, fetchedAt: _start, hours: _hrs(), airQuality: aq),
	darkWindow: DarkWindow(start: _start, end: _end),
	moonIlluminationPercent: 0, moonAltitude: -90,
	firesNearby: fires,
);

void main() {
	test('no fires → transparency unchanged (~100)', () {
		final loc = _score(aq: _clearAq(), fires: null);
		expect(loc.factorScores['transparency'], greaterThanOrEqualTo(95));
	});

	test('close intense fire docks transparency and adds advisory', () {
		// proximity = 1 - 15/150 = 0.9; intensity = clamp(200/100,.3,1) = 1 →
		// penalty ≈ 22-23; clear AOD 100 → ~77-78.
		final fires = FiresNearby.fromJson(
			{'count': 3, 'nearestKm': 15.0, 'maxFrp': 200.0, 'radiusKm': 150});
		final loc = _score(aq: _clearAq(), fires: fires);
		expect(loc.factorScores['transparency'], lessThan(80));
		expect(loc.reasons.any((r) => r.contains('active fire')), isTrue);
	});

	test('penalty is capped — a fire alone never zeroes transparency', () {
		final fires = FiresNearby.fromJson(
			{'count': 50, 'nearestKm': 0.5, 'maxFrp': 9999.0, 'radiusKm': 150});
		final loc = _score(aq: _clearAq(), fires: fires);
		// clear AOD 100, max penalty 25 → ~75; never below ~70.
		expect(loc.factorScores['transparency'], greaterThanOrEqualTo(70));
	});

	test('fire seeds a transparency factor even with no AOD data', () {
		final fires = FiresNearby.fromJson(
			{'count': 2, 'nearestKm': 30.0, 'maxFrp': 150.0, 'radiusKm': 150});
		final loc = _score(aq: null, fires: fires);
		expect(loc.factorScores.containsKey('transparency'), isTrue);
		expect(loc.factorScores['transparency'], lessThan(100));
	});

	test('distant small fire docks little', () {
		final fires = FiresNearby.fromJson(
			{'count': 1, 'nearestKm': 140.0, 'maxFrp': 20.0, 'radiusKm': 150});
		final loc = _score(aq: _clearAq(), fires: fires);
		expect(loc.factorScores['transparency'], greaterThanOrEqualTo(98));
	});
}
