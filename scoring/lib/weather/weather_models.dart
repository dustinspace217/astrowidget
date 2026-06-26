// lib/weather/weather_models.dart
// Data models for weather forecast and air quality data from Open-Meteo.
//
// These are plain Dart classes with no framework dependencies — usable by
// the HTTP client, cache, scoring engine, or tests without importing
// Flutter, Riverpod, or Drift.
//
// Phase E Task 6: [WeatherForecast] gained a [derivedSeeing] field — a
// nullable [SeeingResult] computed once per (location, fetch) cycle.
// Plan 5 §10.2 mandates this caching shape: one derived-seeing HTTP call
// per weather refresh, never per-target. Scoring reads forecast.derivedSeeing
// instead of invoking DerivedSeeingService itself. Null means "cache predates
// Phase E" or "SeeingResult serialized with an unknown discriminator";
// both are treated as "no seeing available" by consumers.
import '../seeing/seeing_result.dart';

/// One hour of weather data from the Open-Meteo forecast API.
///
/// Fields map directly to Open-Meteo's hourly response parameters.
/// JSON keys use Open-Meteo's snake_case naming (e.g., 'cloud_cover').
class HourlyWeather {
	/// UTC timestamp for this hour's data point.
	final DateTime time;

	/// Total cloud cover as a percentage (0–100).
	final double cloudCover;

	/// Low-altitude cloud cover (0–3 km) as a percentage.
	/// Low clouds are binary blockers and most reliably forecast.
	final double cloudCoverLow;

	/// Mid-altitude cloud cover (3–8 km) as a percentage.
	/// Usually thick enough to block all astronomical observation.
	final double cloudCoverMid;

	/// High-altitude cloud cover (8+ km, cirrus) as a percentage.
	/// Worst for DSOs — destroys transparency while looking "clear."
	final double cloudCoverHigh;

	/// Relative humidity at 2m above ground (0–100%).
	final double humidity;

	/// Air temperature at 2m in degrees Celsius.
	final double temperature;

	/// Dewpoint temperature at 2m in degrees Celsius.
	/// Temp − dewpoint spread indicates dew risk on optics.
	final double dewpoint;

	/// Wind speed at 10m in km/h.
	final double windSpeed;

	/// Wind gust speed at 10m in km/h.
	final double windGusts;

	/// Probability of precipitation (0–100%).
	final double precipitationProbability;

	/// Precipitation amount in millimetres.
	final double precipitation;

	/// Atmospheric visibility in metres.
	final double visibility;

	/// 250 hPa (jet-stream level) wind speed in km/h — the forecastable driver of
	/// astronomical seeing (Phase 1, spec §5/§2a). NULLABLE on purpose: null means
	/// "no jet data" so the seeing blend SKIPS it, distinct from 0.0 which would be
	/// a dead-calm jet = falsely excellent seeing. NEVER default this to 0.0.
	final double? windSpeed250hPa;

	/// Ground snow depth in metres (Phase 1b, spec §5). Snow reflects moonlight +
	/// light pollution back into the sky (albedo ~0.8), a broadband sky-brightness
	/// modifier. Non-nullable with a 0.0 default: 0 = no snow is a real, neutral
	/// value (unlike the jet wind, snow has no null-vs-zero ambiguity).
	final double snowDepth;

	/// Creates an [HourlyWeather] with all fields.
	const HourlyWeather({
		required this.time,
		required this.cloudCover,
		required this.cloudCoverLow,
		required this.cloudCoverMid,
		required this.cloudCoverHigh,
		required this.humidity,
		required this.temperature,
		required this.dewpoint,
		required this.windSpeed,
		required this.windGusts,
		required this.precipitationProbability,
		required this.precipitation,
		required this.visibility,
		this.windSpeed250hPa, // nullable, NOT required — old cache/test JSON omits it
		this.snowDepth = 0.0, // metres of ground snow; 0 = none (Phase 1b)
	});

	/// Deserializes from a JSON map (one hour's worth of data).
	///
	/// Missing numeric fields default to 0.0 so downstream scoring
	/// can proceed without null checks on every field.
	/// The 'time' key is the ISO 8601 string from the API's time array.
	/// Open-Meteo timestamps omit the 'Z' suffix but are always UTC —
	/// we append it before parsing so Dart treats the result as UTC.
	factory HourlyWeather.fromJson(Map<String, dynamic> json) {
		final rawTime = json['time'] as String;
		// Ensure the string is treated as UTC: append 'Z' if no timezone info present.
		final timeStr = rawTime.endsWith('Z') ? rawTime : '${rawTime}Z';
		// Default values philosophy: use PESSIMISTIC defaults for fields where
		// 0.0 has a specific meaning that could mislead scoring. Fields where
		// 0.0 is neutral (wind, precipitation) keep 0.0.
		//
		// cloudCover: 50% (unknown ≠ clear)
		// humidity: 50% (unknown ≠ "perfectly dry" — was 0.0, which gave
		//   falsely excellent humidity scores. Bug fix: GitHub #32)
		// precipitationProbability: NaN sentinel when absent (was 50% — that
		//   pessimistic default predates the PEAK precip veto: under window
		//   AVERAGING a 50 was a mild penalty, but under peak semantics one
		//   missing hour exceeded a 10% home threshold and hard-vetoed a dry
		//   night. NaN propagates the same skip-don't-fabricate convention as
		//   temperature/dewpoint; _peakPrecipPct skips NaN hours. QA 2026-06-09)
		// visibility: 10000m (reasonable median)
		// temperature/dewpoint: both use NaN sentinel when absent, because
		//   0.0/0.0 creates dew spread = 0 which triggers the condensation
		//   veto on completely absent data. NaN propagates through arithmetic
		//   but the scoring engine already guards NaN. Bug fix: GitHub #32.
		return HourlyWeather(
			time: DateTime.parse(timeStr),
			cloudCover: (json['cloud_cover'] as num?)?.toDouble() ?? 50.0,
			cloudCoverLow: (json['cloud_cover_low'] as num?)?.toDouble() ?? 0.0,
			cloudCoverMid: (json['cloud_cover_mid'] as num?)?.toDouble() ?? 0.0,
			cloudCoverHigh: (json['cloud_cover_high'] as num?)?.toDouble() ?? 0.0,
			humidity: (json['relative_humidity_2m'] as num?)?.toDouble() ?? 50.0,
			temperature: (json['temperature_2m'] as num?)?.toDouble() ?? double.nan,
			dewpoint: (json['dewpoint_2m'] as num?)?.toDouble() ?? double.nan,
			windSpeed: (json['wind_speed_10m'] as num?)?.toDouble() ?? 0.0,
			windGusts: (json['wind_gusts_10m'] as num?)?.toDouble() ?? 0.0,
			precipitationProbability:
				(json['precipitation_probability'] as num?)?.toDouble() ?? double.nan,
			precipitation: (json['precipitation'] as num?)?.toDouble() ?? 0.0,
			visibility: (json['visibility'] as num?)?.toDouble() ?? 10000.0,
			// NO `?? 0.0`: null = "no jet data" (the seeing blend skips it); 0.0
			// would read as a dead-calm jet = falsely excellent seeing. (Phase 1.)
			windSpeed250hPa: (json['wind_speed_250hPa'] as num?)?.toDouble(),
			// `?? 0.0` is correct here (unlike the jet wind): absent snow = no snow.
			snowDepth: (json['snow_depth'] as num?)?.toDouble() ?? 0.0,
		);
	}

	/// Serializes to a JSON-compatible map.
	///
	/// Uses the same snake_case keys as the API so fromJson/toJson roundtrip
	/// through the weather cache without key translation.
	Map<String, dynamic> toJson() => {
		'time': time.toIso8601String(),
		'cloud_cover': cloudCover,
		'cloud_cover_low': cloudCoverLow,
		'cloud_cover_mid': cloudCoverMid,
		'cloud_cover_high': cloudCoverHigh,
		'relative_humidity_2m': humidity,
		'temperature_2m': temperature,
		'dewpoint_2m': dewpoint,
		'wind_speed_10m': windSpeed,
		'wind_gusts_10m': windGusts,
		'precipitation_probability': precipitationProbability,
		'precipitation': precipitation,
		'visibility': visibility,
		'wind_speed_250hPa': windSpeed250hPa,
		'snow_depth': snowDepth,
	};
}

/// One hour of air quality data from the Open-Meteo air quality API.
///
/// Fetched from a separate endpoint than weather forecasts but aligned
/// by time. The [aerosolOpticalDepth] field is the primary metric for
/// astronomical transparency scoring — it measures total column opacity.
class AirQuality {
	/// UTC timestamp for this hour's data point.
	final DateTime time;

	/// Fine particulate matter in µg/m³.
	final double pm2_5;

	/// Coarse particulate matter in µg/m³.
	final double pm10;

	/// Column-integrated aerosol optical depth (dimensionless).
	/// 0 = perfectly clear atmosphere, > 0.3 = visibly degraded.
	/// Nullable because some stations don't report this metric.
	final double? aerosolOpticalDepth;

	/// US EPA Air Quality Index composite (0–500).
	final int usAqi;

	/// AQI computed from PM2.5 alone.
	final int usAqiPm2_5;

	/// AQI computed from PM10 alone.
	final int usAqiPm10;

	/// Creates an [AirQuality] with all fields.
	const AirQuality({
		required this.time,
		required this.pm2_5,
		required this.pm10,
		this.aerosolOpticalDepth,
		required this.usAqi,
		required this.usAqiPm2_5,
		required this.usAqiPm10,
	});

	/// Deserializes from a JSON map.
	///
	/// PM fields default to 0.0; AQI fields default to 0.
	/// [aerosolOpticalDepth] is nullable — null means the station doesn't
	/// report it, which the scoring engine treats as "no smoke data."
	/// Like HourlyWeather, timestamps from the API lack a 'Z' suffix but
	/// are always UTC — we append it before parsing.
	factory AirQuality.fromJson(Map<String, dynamic> json) {
		final rawTime = json['time'] as String;
		// Ensure the string is treated as UTC: append 'Z' if no timezone info present.
		final timeStr = rawTime.endsWith('Z') ? rawTime : '${rawTime}Z';
		return AirQuality(
			time: DateTime.parse(timeStr),
			pm2_5: (json['pm2_5'] as num?)?.toDouble() ?? 0.0,
			pm10: (json['pm10'] as num?)?.toDouble() ?? 0.0,
			aerosolOpticalDepth:
				(json['aerosol_optical_depth'] as num?)?.toDouble(),
			usAqi: (json['us_aqi'] as num?)?.toInt() ?? 0,
			usAqiPm2_5: (json['us_aqi_pm2_5'] as num?)?.toInt() ?? 0,
			usAqiPm10: (json['us_aqi_pm10'] as num?)?.toInt() ?? 0,
		);
	}

	/// Serializes to a JSON-compatible map.
	Map<String, dynamic> toJson() => {
		'time': time.toIso8601String(),
		'pm2_5': pm2_5,
		'pm10': pm10,
		'aerosol_optical_depth': aerosolOpticalDepth,
		'us_aqi': usAqi,
		'us_aqi_pm2_5': usAqiPm2_5,
		'us_aqi_pm10': usAqiPm10,
	};
}

/// Active-fire proximity summary for a site (NASA FIRMS). A single site-level
/// snapshot (NOT hourly): count of satellite-detected active fires within the
/// configured radius, the nearest one's distance, and the peak fire radiative
/// power. Drives the engine's fire-proximity transparency penalty — it catches
/// near-source wildfire smoke the coarse CAMS aerosol model under-resolves
/// (the 2026-06-25 UDRO miss). A null block means "no fire data" → no penalty;
/// the fetcher already collapses count 0 to a null block.
class FiresNearby {
	/// Active fires detected within [radiusKm] of the site.
	final int count;

	/// Great-circle distance (km) to the nearest detection, or null if count 0.
	final double? nearestKm;

	/// Peak fire radiative power (MW) among detections within radius.
	final double? maxFrp;

	/// The search radius (km) the fetcher used — needed to scale the penalty.
	final int radiusKm;

	/// FIRMS feed the detections came from (e.g. VIIRS_NOAA20_NRT).
	final String? source;

	/// UTC date the snapshot was taken (display only).
	final String? asOf;

	const FiresNearby({
		required this.count,
		this.nearestKm,
		this.maxFrp,
		required this.radiusKm,
		this.source,
		this.asOf,
	});

	/// Deserializes from the fetcher's `firesNearby` JSON. Numeric fields use
	/// null-safe casts (a missing count/radius defaults to 0 — a degenerate
	/// no-penalty state — rather than throwing).
	factory FiresNearby.fromJson(Map<String, dynamic> json) => FiresNearby(
		count: (json['count'] as num?)?.toInt() ?? 0,
		nearestKm: (json['nearestKm'] as num?)?.toDouble(),
		maxFrp: (json['maxFrp'] as num?)?.toDouble(),
		radiusKm: (json['radiusKm'] as num?)?.toInt() ?? 0,
		source: json['source'] as String?,
		asOf: json['asOf'] as String?,
	);

	Map<String, dynamic> toJson() => {
		'count': count,
		'nearestKm': nearestKm,
		'maxFrp': maxFrp,
		'radiusKm': radiusKm,
		'source': source,
		'asOf': asOf,
	};
}

/// One location's weather forecast — the top-level container.
///
/// Contains hourly weather data (typically 72 hours / 3 days) and
/// optionally air quality data aligned to the same hours.
class WeatherForecast {
	/// Which saved location this forecast is for.
	final int locationId;

	/// When the API was called (UTC). Used for cache age calculations.
	final DateTime fetchedAt;

	/// Hourly weather data points (typically 72 for a 3-day forecast).
	final List<HourlyWeather> hours;

	/// Hourly air quality data, time-aligned with [hours] by timestamp.
	/// Null if the air quality fetch failed or wasn't requested.
	/// NOTE: Length may differ from [hours] if the two API calls returned
	/// different hour ranges. Consumers MUST match by timestamp, not by
	/// index. The scoring engine filters both lists by time window.
	/// Bug fix: GitHub #48 — previous comment falsely claimed same length.
	final List<AirQuality>? airQuality;

	/// Derived seeing estimate for this fetch, or null if not computed.
	/// §10.2 mandates this be computed once per (location, fetch) — the
	/// scoring engine reads this value rather than invoking
	/// DerivedSeeingService per-target. Null means:
	///   - cache entry predates Phase E (no `derivedSeeing` key in JSON), OR
	///   - a future SeeingResult variant serialized with an unknown
	///     discriminator (see [SeeingResult.fromJson]), OR
	///   - the service was not injected at construction time (tests).
	/// Consumers treat all three cases as "seeing unavailable."
	final SeeingResult? derivedSeeing;

	/// Creates a [WeatherForecast].
	const WeatherForecast({
		required this.locationId,
		required this.fetchedAt,
		required this.hours,
		this.airQuality,
		this.derivedSeeing,
	});

	/// Returns a copy with selected fields replaced. Used by the weather
	/// service to attach a newly-computed [derivedSeeing] to an otherwise
	/// complete forecast without re-building all fields.
	///
	/// Note on derivedSeeing: passing null does NOT clear the existing
	/// value — the `??` fallback preserves it. This matches copyWith
	/// semantics elsewhere in the codebase (a null argument means "not
	/// specified," not "explicitly clear"). If a caller ever needs to
	/// clear it, they should construct a new WeatherForecast directly.
	WeatherForecast copyWith({
		int? locationId,
		DateTime? fetchedAt,
		List<HourlyWeather>? hours,
		List<AirQuality>? airQuality,
		SeeingResult? derivedSeeing,
	}) {
		return WeatherForecast(
			locationId: locationId ?? this.locationId,
			fetchedAt: fetchedAt ?? this.fetchedAt,
			hours: hours ?? this.hours,
			airQuality: airQuality ?? this.airQuality,
			derivedSeeing: derivedSeeing ?? this.derivedSeeing,
		);
	}

	/// Deserializes from a JSON map (from cache storage).
	///
	/// [derivedSeeing] is recovered via [SeeingResult.fromJson], which
	/// returns null for unknown discriminators — so old cache entries
	/// and forward-incompatible entries both land on a null field
	/// without crashing.
	factory WeatherForecast.fromJson(Map<String, dynamic> json) {
		final seeingJson = json['derivedSeeing'];
		return WeatherForecast(
			locationId: json['locationId'] as int,
			fetchedAt: DateTime.parse(json['fetchedAt'] as String),
			hours: (json['hours'] as List)
				.map((h) => HourlyWeather.fromJson(h as Map<String, dynamic>))
				.toList(),
			airQuality: json['airQuality'] != null
				? (json['airQuality'] as List)
					.map((a) => AirQuality.fromJson(a as Map<String, dynamic>))
					.toList()
				: null,
			derivedSeeing: seeingJson is Map<String, dynamic>
				? SeeingResult.fromJson(seeingJson)
				: null,
		);
	}

	/// Serializes to a JSON-compatible map (for cache storage).
	Map<String, dynamic> toJson() => {
		'locationId': locationId,
		'fetchedAt': fetchedAt.toIso8601String(),
		'hours': hours.map((h) => h.toJson()).toList(),
		'airQuality': airQuality?.map((a) => a.toJson()).toList(),
		'derivedSeeing': derivedSeeing?.toJson(),
	};
}

/// A time window representing the user's availability for observing.
///
/// Both boundaries are UTC DateTimes. When passed to the scoring engine,
/// the effective scoring window is the intersection of this window and
/// the astronomical dark window (or observable window for the target).
class TimeWindow {
	/// Start of the availability window (UTC).
	final DateTime start;

	/// End of the availability window (UTC).
	final DateTime end;

	/// Creates a [TimeWindow].
	/// Asserts that [end] is not before [start] — catches reversed windows
	/// during development (assertions are stripped in release builds).
	/// Not const because the assertion calls a method on [end].
	// Real guard — asserts are stripped in release builds, and a reversed window
	// produces negative durationHours that corrupt scoring results silently.
	// Bug fix: GitHub #42.
	TimeWindow({required this.start, required this.end}) {
		if (end.isBefore(start)) {
			throw ArgumentError('TimeWindow end ($end) must not be before start ($start)');
		}
	}

	/// Duration of the window in fractional hours.
	double get durationHours =>
		end.difference(start).inSeconds / 3600.0;

	/// Returns true if [time] falls within this window (inclusive boundaries).
	///
	/// Receives: [time] — a UTC DateTime to check.
	/// Returns: true if start <= time <= end.
	bool contains(DateTime time) =>
		!time.isBefore(start) && !time.isAfter(end);
}

/// Categories of errors that can occur when fetching weather data.
///
/// Used by [WeatherError] to let callers handle different failure modes
/// (e.g., retry on timeout, show "no internet" on networkError).
enum WeatherErrorKind {
	/// The HTTP request exceeded the timeout duration.
	timeout,

	/// The server returned a non-200 status code.
	serverError,

	/// The response body couldn't be parsed as valid forecast data.
	parseError,

	/// No network connection available.
	networkError,

	/// Any other failure (e.g., preconditions like "location not found"
	/// that don't fit the other categories). Used by providers that
	/// can fail for non-network, non-parse reasons.
	unknown,
}

/// An error from the weather data fetch process.
///
/// Wraps a [WeatherErrorKind] with an optional human-readable message.
/// The client returns these instead of throwing exceptions, so callers
/// can handle failures gracefully (e.g., show cached data with a warning).
class WeatherError {
	/// What type of error occurred.
	final WeatherErrorKind kind;

	/// Human-readable description of what went wrong.
	final String message;

	/// Creates a [WeatherError].
	/// [message] is optional — omit it for programmatic errors where only the
	/// [kind] matters (e.g., in tests or internal callers). Provide it when
	/// a human-readable description is available (e.g., HTTP status text).
	const WeatherError({required this.kind, this.message = ''});
}
