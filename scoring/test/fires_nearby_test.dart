// Tests for the FiresNearby model (smoke feature, 2026-06-25).
import 'package:test/test.dart';
import 'package:astrowidget_scoring/weather/weather_models.dart';

void main() {
	test('FiresNearby.fromJson parses all fields', () {
		final f = FiresNearby.fromJson({
			'count': 3,
			'nearestKm': 58.4,
			'maxFrp': 120.5,
			'radiusKm': 150,
			'source': 'VIIRS_NOAA20_NRT',
			'asOf': '2026-06-25',
		});
		expect(f.count, 3);
		expect(f.nearestKm, 58.4);
		expect(f.maxFrp, 120.5);
		expect(f.radiusKm, 150);
		expect(f.source, 'VIIRS_NOAA20_NRT');
	});

	test('FiresNearby.fromJson tolerates missing optionals', () {
		final f = FiresNearby.fromJson({'count': 1, 'radiusKm': 150});
		expect(f.count, 1);
		expect(f.nearestKm, isNull);
		expect(f.maxFrp, isNull);
		expect(f.source, isNull);
	});

	test('FiresNearby round-trips through toJson', () {
		final f = FiresNearby.fromJson({
			'count': 2, 'nearestKm': 30.0, 'maxFrp': 90.0, 'radiusKm': 150,
		});
		final j = f.toJson();
		expect(j['count'], 2);
		expect(j['nearestKm'], 30.0);
		expect(j['radiusKm'], 150);
	});
}
