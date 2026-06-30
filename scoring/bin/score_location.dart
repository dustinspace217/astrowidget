// bin/score_location.dart
//
// CLI wrapper around astroplan's scoreLocation() and VetoEvaluator, intended
// to be compiled to a standalone native binary via `dart compile exe` and
// invoked as a subprocess by external tools (currently: the `astrowidget`
// KDE plasmoid fetcher at ~/Claude/astrowidget).
//
// Protocol: read one JSON object from stdin, write one JSON object to stdout,
// exit 0 on success.  All errors are logged to stderr and exit codes are
// non-zero (1 = parse / contract failure, 2 = scoring engine threw).
//
// Why this exists:
// astroplan's scoring engine is pure-Dart and the obvious thing to reuse
// when building any other astrophotography forecast tool.  Rather than
// porting ~2000 lines of scoring logic into Python (which would inevitably
// drift), the consumer compiles this entry-point to a native binary and
// pipes JSON through it.  Calibration improvements in scoring_engine.dart
// automatically reach any downstream consumer after a rebuild.
//
// Why the BB/NB recommendation logic lives here, not in scoring_engine.dart:
// scoreLocation() doesn't currently accept an ImagingMode parameter (that
// exists only on scoreTarget()).  Rather than modify the public surface of
// scoreLocation() — which would be a breaking change for astroplan — this
// wrapper computes the broadband score from the engine's defaults, then
// rebuilds a narrowband score by re-weighting the engine-returned factor
// scores with a much-reduced sky-brightness weight (narrowband rejects
// moonlight + light pollution).  This is a site-level BB/NB approximation,
// not the per-target distinction scoreTarget() makes.
// See ~/Claude/astrowidget/docs/superpowers/specs/2026-05-28-astrowidget-design.md
// §6.2 for the spec and §8 for the recommendation algorithm.

import 'dart:convert';
import 'dart:io';
import 'package:astrowidget_scoring/astro/moon_geometry.dart';
import 'package:astrowidget_scoring/astro/visibility.dart';
import 'package:astrowidget_scoring/scoring/scoring_engine.dart';
import 'package:astrowidget_scoring/scoring/sky_brightness.dart'; // locationSkyBrightnessScore (NB moon dock baseline)
import 'package:astrowidget_scoring/scoring/veto_evaluator.dart';
import 'package:astrowidget_scoring/weather/weather_models.dart';
import 'narrowband.dart'; // astrowidget's own NB sky model (DEF-V2-03)
import 'moon_window.dart'; // averaged burden + moon-free window + NB moon dock (2026-06-29)

// ─────────────────────────────────────────────────────────────────────────────
// Narrowband composite
// ─────────────────────────────────────────────────────────────────────────────

// Narrowband is now a REAL forward model (nb-model-v1, spec 2026-06-20), not the old
// heuristic re-weight. Only SKY BRIGHTNESS is filter-dependent — a narrowband filter
// rejects ~99% of the moon/LP/twilight continuum, so its sky background is far darker
// than broadband (this is why Ha works under a gibbous moon). Cloud, stability, and
// transparency block emission lines just like broadband, so those sub-scores carry over
// unchanged. So the NB verdict is: swap the engine's broadband skyBrightness sub-score
// for narrowbandSkyScore() (narrowband.dart), then re-composite with the SAME location
// weights the engine uses. Because narrowbandSkyScore ≥ the broadband sky score for every
// input, NB ≥ BB falls out of the model — no artificial floor.
//
// These mirror scoreLocation's location weights (scoring_engine.dart) — keep in sync.
// When this refinement back-ports to astroplan they become the engine's NB-mode weights.
const Map<String, double> _nbCompositeWeights = <String, double>{
	'cloud': 1.0,
	'stability': 0.6,
	'skyBrightness': 0.8,
	'transparency': 0.9,
};
const String _nbMethod = 'nb-model-v1';

/// Equipment-protection precipitation veto: fires when the PEAK (maximum)
/// precipitation probability across the exposure (sunset→sunrise) window
/// exceeds [threshold].
///
/// Deliberately different from VetoEvaluator.checkPrecipitation, which AVERAGES
/// over the window. For protecting an uncovered scope the user wants "basically
/// any real chance of rain" to trigger, so a single high-probability hour
/// vetoes the night even when the window average is low. Returns null (no veto)
/// for an empty window. (astrowidget requirement 2026-05-28.)
/// Peak (maximum) precipitation probability across [hours]; 0.0 for an empty
/// window. This single value feeds BOTH the equipment-protection veto and the
/// widget's per-night precip display, so the two always agree on "the overnight
/// rain risk" — fixing the earlier mismatch where the veto used the peak but the
/// display showed a dark-window average. (astrowidget 2026-05-30.)
double _peakPrecipPct(List<HourlyWeather> hours) {
	double peak = 0.0;
	for (final h in hours) {
		// NaN = "no data for this hour" (the fetcher stopped fabricating 50%
		// for absent hours, QA 2026-06-09). Skip it — a missing reading must
		// not raise the peak; NaN comparisons are false anyway, but be explicit.
		if (h.precipitationProbability.isNaN) continue;
		if (h.precipitationProbability > peak) {
			peak = h.precipitationProbability;
		}
	}
	return peak;
}

VetoResult? _peakPrecipVeto(List<HourlyWeather> hours, double threshold) {
	if (hours.isEmpty) return null;
	final peak = _peakPrecipPct(hours);
	if (peak > threshold) {
		return VetoResult(
			vetoName: 'precipitation',
			reason: 'Overnight rain chance peaks at ${peak.toStringAsFixed(0)}% '
				'(exceeds your ${threshold.toStringAsFixed(0)}% limit) — keep the '
				'scope covered.',
		);
	}
	return null;
}

/// Peak-wind veto over the imaging window — deliberately NOT the engine's
/// VetoEvaluator.checkWind, which AVERAGES wind across the window. Averaging
/// is the exact structural flaw the 2026-06-03 cloud-gate incident exposed
/// (a veto-class factor hiding inside a mean): a 2–3 h 60 km/h blow in an
/// 8 h window averages under a 48 km/h dome-close threshold and reads green,
/// while the iTelescope dome physically shuts mid-night (auto-close ~that
/// speed) and a home scope shakes regardless of how calm the rest of the
/// window was. Same pattern as _peakPrecipVeto above. (QA 2026-06-09.)
///
/// Missing hours carry windSpeed 0.0 (the neutral default) and simply cannot
/// raise the peak. Gusts (windGusts) are fetched but deliberately NOT vetoed
/// yet — sustained speed is the dome-close criterion; a separate gust
/// threshold is a future, separately-configured refinement.
VetoResult? _peakWindVeto(List<HourlyWeather> hours, double threshold) {
	if (hours.isEmpty) return null;
	var peak = 0.0;
	for (final h in hours) {
		if (h.windSpeed > peak) peak = h.windSpeed;
	}
	if (peak > threshold) {
		return VetoResult(
			vetoName: 'wind',
			reason: 'Wind peaks at ${peak.toStringAsFixed(0)} km/h during the '
				'window (exceeds your ${threshold.toStringAsFixed(0)} km/h limit) '
				'— tracking and equipment safety at risk.',
		);
	}
	return null;
}

/// Rebuilds the engine's reason list with the "Best window" shown in this
/// machine's LOCAL time zone instead of the engine's UTC placeholder. The widget
/// shows times on the user's own clock (the dedicated dark-window line does too);
/// only this one engine reason was still UTC. We localize it HERE, in the
/// astrowidget wrapper, deliberately NOT touching the shared scoring engine — the
/// Flutter app keeps its own formatting. loc.bestWindow gives the structured
/// window, so we drop the engine's UTC sentence and re-add a local one (kept
/// last, where the engine placed it).
List<String> _localizeReasons(LocationScore loc) {
	final out = <String>[];
	for (final r in loc.reasons) {
		if (r.startsWith('Best window:')) continue; // drop the UTC-formatted one
		out.add(r);
	}
	final bw = loc.bestWindow;
	if (bw != null) {
		out.add('Best window: ${_formatLocalTime(bw.start)} to '
			'${_formatLocalTime(bw.end)}.');
	}
	return out;
}

/// Formats a UTC DateTime in this machine's local zone with the zone
/// abbreviation, e.g. "11:30pm PDT" / "1am PST". DateTime.timeZoneName resolves
/// the system zone (the fetcher host's), matching the user's "system time"
/// request and the PDT label already on the dark-window line.
String _formatLocalTime(DateTime utc) {
	final local = utc.toLocal();
	final hour = local.hour;
	final minute = local.minute;
	final period = hour >= 12 ? 'pm' : 'am';
	final displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
	final minuteStr = minute == 0 ? '' : ':${minute.toString().padLeft(2, '0')}';
	return '$displayHour$minuteStr$period ${local.timeZoneName}';
}

// Default veto thresholds — overridable per-site via stdin JSON.
const double _defaultWindMaxKmh = 40.0;
const double _defaultPrecipMaxPct = 30.0;
const double _defaultDewSpreadMinC = 1.5;

// ─────────────────────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────────────────────

Future<void> main(List<String> args) async {
	// Read the entire stdin as a single UTF-8 string.  The caller is expected
	// to write one JSON object then close stdin; partial writes block here.
	final raw = await stdin.transform(utf8.decoder).join();
	dynamic input;
	try {
		input = jsonDecode(raw);
	} catch (e) {
		stderr.writeln('score_location: stdin is not valid JSON: $e');
		exit(1);
	}

	if (input is! Map<String, dynamic>) {
		stderr.writeln('score_location: stdin root must be a JSON object');
		exit(1);
	}

	// now_utc is required (not falling back to wall-clock). A missing or
	// unparseable value produces non-reproducible "Tonight" windows and
	// confusing diffs across runs — the fetcher always supplies it.
	final nowRaw = input['now_utc'];
	if (nowRaw is! String) {
		stderr.writeln('score_location: stdin.now_utc must be an ISO-8601 string');
		exit(1);
	}
	final nowUtc = DateTime.tryParse(nowRaw)?.toUtc();
	if (nowUtc == null) {
		stderr.writeln('score_location: stdin.now_utc could not be parsed: $nowRaw');
		exit(1);
	}
	final sitesIn = input['sites'];
	if (sitesIn is! List) {
		stderr.writeln('score_location: stdin.sites must be an array');
		exit(1);
	}

	final results = <Map<String, dynamic>>[];

	for (final siteRaw in sitesIn) {
		try {
			results.add(_scoreOneSite(siteRaw as Map<String, dynamic>, nowUtc));
		} on Error catch (e, st) {
			// Programmer errors (TypeError, RangeError, NoSuchMethodError, etc.)
			// indicate a schema-shape regression or contract bug — they should
			// fail the whole run loudly, not silently mask as a per-site
			// "error" status.  Per-site resilience is for recoverable
			// exceptions, not bugs in the binary.
			stderr.writeln('score_location: programmer error (rethrowing): $e\n$st');
			rethrow;
		} on Exception catch (e, st) {
			// Per-site recoverable exceptions don't abort the run — other
			// sites still get scored.  The plasmoid receives a status:'error'
			// marker for the affected site.
			stderr.writeln('score_location: site failed: $e\n$st');
			results.add({
				'id': (siteRaw is Map ? siteRaw['id'] : null) ?? 'unknown',
				'status': 'error',
				'error': '$e',
			});
		}
	}

	final out = <String, dynamic>{
		// Schema 2 (2026-06-03, Phase-1 scoring redesign): factors map is now
		// {cloud, stability, skyBrightness, transparency?} (darkness/moon removed);
		// each night gains best_window + managed; NB method is nb-model-v1 (DEF-V2-03).
		'schema_version': 2,
		'computed_at': DateTime.now().toUtc().toIso8601String(),
		'sites': results,
	};

	stdout.writeln(jsonEncode(out));
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-site scoring
// ─────────────────────────────────────────────────────────────────────────────

/// Scores one site for the next three nights (Tonight, +1, +2).
///
/// Receives:
/// - [site] — site object from stdin JSON (id, label, lat, lon, hourly[])
/// - [nowUtc] — current UTC instant, used as the reference for "Tonight"
///
/// Returns: a site result object containing per-night verdicts and factors.
Map<String, dynamic> _scoreOneSite(Map<String, dynamic> site, DateTime nowUtc) {
	final id = site['id'] as String;
	final label = site['label'] as String? ?? id;
	final lat = (site['lat'] as num).toDouble();
	final lon = (site['lon'] as num).toDouble();
	// Phase-1 site inputs from the fetcher (spec §4/§5):
	//   bortle  — light-pollution class 1–9, or null → engine default baseline
	//   managed — HOME (false) vs REMOTE/dome (true). A REMOTE dome is weatherproof,
	//             so it skips the precip EQUIPMENT veto (applied in _scoreOneNight).
	final siteBortle = (site['bortle'] as num?)?.toInt();
	// Optional per-site narrowband leakage override (filter-bandwidth tuning); the
	// fetcher passes it from config.toml when set. Absent → the physics default (0.05).
	final nbLeakage = (site['nb_leakage'] as num?)?.toDouble() ?? nbLeakageDefault;
	final managed = site['managed'] as bool? ?? false;

	// Per-site veto thresholds with sensible defaults.
	final thresholds = (site['thresholds'] as Map<String, dynamic>?) ?? const {};
	final windMaxKmh = (thresholds['wind_max_kmh'] as num?)?.toDouble()
		?? _defaultWindMaxKmh;
	final precipMaxPct = (thresholds['precip_max_pct'] as num?)?.toDouble()
		?? _defaultPrecipMaxPct;
	final dewSpreadMinC = (thresholds['dew_spread_min_c'] as num?)?.toDouble()
		?? _defaultDewSpreadMinC;

	// Parse hourly data into the engine's HourlyWeather model.  The JSON
	// keys match Open-Meteo's snake_case shape — HourlyWeather.fromJson()
	// already knows how to parse this.
	final hourlyList = (site['hourly'] as List)
		.map((h) => HourlyWeather.fromJson(h as Map<String, dynamic>))
		.toList();
	// Per-hour AOD list for the transparency factor. Null / empty / absent → a null
	// forecast.airQuality → the engine OMITS transparency entirely (it is never
	// scored as 0 — absence ≠ worst haze; that inversion is the Phase-1 null-
	// polarity rule). AirQuality.fromJson defaults every non-AOD field, so an
	// AOD-only row from the fetcher is a complete, valid AirQuality.
	final aqRaw = site['airQuality'] as List?;
	final airQuality = (aqRaw == null || aqRaw.isEmpty)
		? null
		: aqRaw
			.map((a) => AirQuality.fromJson(a as Map<String, dynamic>))
			.toList();
	// Optional FIRMS active-fire snapshot (astrowidget-specific). Absent / non-map
	// → null → no penalty (the engine treats null as "no fire data").
	final firesRaw = site['firesNearby'];
	if (firesRaw != null && firesRaw is! Map<String, dynamic>) {
		// A present-but-malformed snapshot (array/string/number) silently disabling
		// the fire penalty would hide a fetcher↔scorer contract break, so make it
		// visible on stderr (→ journal) rather than swallowing it.
		stderr.writeln('score_location: firesNearby has unexpected shape '
			'(${firesRaw.runtimeType}); ignoring');
	}
	final firesNearby = firesRaw is Map<String, dynamic>
		? FiresNearby.fromJson(firesRaw)
		: null;
	final forecast = WeatherForecast(
		locationId: 0, // unused by scoreLocation
		fetchedAt: nowUtc,
		hours: hourlyList,
		airQuality: airQuality,
	);

	// Score the next three nights.  "Tonight" = the night whose astro dark
	// window is in progress or next upcoming — NOT the night implied by the
	// UTC calendar date of nowUtc. astronomicalDarkWindow(date) searches from
	// noon UTC on `date`, so anchoring on nowUtc's own UTC date skips the
	// imminent night whenever the fetch lands between local evening and the
	// next UTC noon: at 17:10 PDT the UTC date has already rolled, and
	// "Tonight" silently became TOMORROW (the widget's Tonight tab at 11 PM
	// showed the following night; found 2026-06-10). Eastern-longitude sites
	// had the mirror-image skew. The anchor below starts one day EARLY and
	// advances past nights that are already over, judged by each candidate's
	// own dark-window END against nowUtc — which is longitude-correct because
	// the window itself is.
	var anchor = nowUtc.subtract(const Duration(days: 1));
	// Bounded: at most 2 advances (yesterday → today → tomorrow). A night is
	// "over" when its dark window has ended at/before nowUtc; a night with NO
	// dark window (e.g. high-latitude midsummer) uses the search range's end
	// (noon UTC the next day) as a proxy so the advance never stalls on it.
	for (int i = 0; i < 2; i++) {
		final w = astronomicalDarkWindow(anchor, latitude: lat, longitude: lon);
		final nightOver = w.end != null
			? !w.end!.isAfter(nowUtc)
			: !DateTime.utc(anchor.year, anchor.month, anchor.day, 12)
				.add(const Duration(days: 1)).isAfter(nowUtc);
		if (!nightOver) break;
		anchor = anchor.add(const Duration(days: 1));
	}

	final nights = <Map<String, dynamic>>[];
	for (int offset = 0; offset < 3; offset++) {
		final referenceDate = anchor.add(Duration(days: offset));
		nights.add(_scoreOneNight(
			referenceDate: referenceDate,
			label: ['Tonight', '+1 night', '+2 nights'][offset],
			forecast: forecast,
			lat: lat,
			lon: lon,
			siteBortle: siteBortle,
			nbLeakage: nbLeakage,
			managed: managed,
			windMaxKmh: windMaxKmh,
			precipMaxPct: precipMaxPct,
			dewSpreadMinC: dewSpreadMinC,
			firesNearby: firesNearby,
		));
	}

	return {
		'id': id,
		'label': label,
		'status': 'ok',
		'nights': nights,
	};
}

/// Scores one (site, night) pair: computes dark window, moon geometry,
/// calls scoreLocation() for the broadband baseline, runs the narrowband
/// forward model (nb-model-v1), evaluates safety vetoes, and emits the
/// BB/NB/Neither recommendation.
Map<String, dynamic> _scoreOneNight({
	required DateTime referenceDate,
	required String label,
	required WeatherForecast forecast,
	required double lat,
	required double lon,
	required int? siteBortle,
	required double nbLeakage,
	required bool managed,
	required double windMaxKmh,
	required double precipMaxPct,
	required double dewSpreadMinC,
	required FiresNearby? firesNearby,
}) {
	// Find tonight's astronomical dark window.
	final darkWindow = astronomicalDarkWindow(
		referenceDate,
		latitude: lat,
		longitude: lon,
	);

	// No astronomical darkness tonight — degenerate result, return early.
	if (darkWindow.start == null || darkWindow.end == null) {
		return {
			'label': label,
			'dark_window': null,
			'moon': null,
			'broadband': {'score': 0, 'verdict': 'dontBother', 'vetoes': []},
			'narrowband': {'score': 0, 'verdict': 'dontBother', 'vetoes': []},
			// Keep the schema-2 top-level keys present even in this degenerate path
			// so consumers never hit an undefined best_window/managed.
			'best_window': null,
			'moonFreeBroadband': null,
			'managed': managed,
			'recommendation': 'Neither',
			'reasons': ['No astronomical darkness on this date.'],
		};
	}

	// Moon illumination at dark-window midpoint — single number that
	// represents the moon's interference for the whole night reasonably.
	final midpoint = DateTime.fromMillisecondsSinceEpoch(
		(darkWindow.start!.millisecondsSinceEpoch + darkWindow.end!.millisecondsSinceEpoch) ~/ 2,
		isUtc: true,
	);
	final moonIllum = moonIllumination(midpoint);

	// Sample the moon's altitude every 15 minutes across the dark window (sub-degree
	// precision — the moon moves ~0.5°/2 min). From these samples the geometry helper
	// derives (a) the TIME-AVERAGED burden basis — within a night the sky background tracks
	// the moon's INSTANTANEOUS altitude at r=0.96 (9,931-sub calibration 2026-06-29), so the
	// old PEAK-altitude penalty over-charged every partial-moon night — and (b) the moon-free
	// window (the broadband-usable gap to surface + score).
	final moonSamples = <MoonSample>[];
	final stepMs = 15 * 60 * 1000; // 15 minutes
	for (int t = darkWindow.start!.millisecondsSinceEpoch;
		 t <= darkWindow.end!.millisecondsSinceEpoch;
		 t += stepMs) {
		final sampleTime = DateTime.fromMillisecondsSinceEpoch(t, isUtc: true);
		try {
			final pos = getMoonPosition(sampleTime, latitude: lat, longitude: lon);
			moonSamples.add(MoonSample(time: sampleTime, altitudeDeg: pos.altitude));
		} on Exception {
			// Tolerate geoengine throwing on edge cases (rare); skip the sample.
			continue;
		}
	}
	final moonGeom =
		computeMoonGeometry(moonSamples, darkWindow.start!, darkWindow.end!);
	// The effective altitude whose moonBurden equals the time-AVERAGED burden — passing it
	// to the scorers applies the average with no engine signature change.
	final scoringAltitude = effectiveMoonAltitudeDeg(moonGeom.avgSinAlt);
	final maxMoonAlt = moonGeom.maxAltDeg; // peak, kept for the display field

	// Broadband baseline: call the engine with the site Bortle and the time-AVERAGED moon
	// altitude (scoringAltitude — see above) so the geometry-aware burden reflects when the
	// moon is actually up, not its peak. (managed is NOT passed — the engine scores uniformly;
	// the HOME/REMOTE split is the precip veto policy below.)
	final loc = scoreLocation(
		forecast: forecast,
		darkWindow: darkWindow,
		moonIlluminationPercent: moonIllum,
		siteBortle: siteBortle,
		moonAltitude: scoringAltitude,
		firesNearby: firesNearby,
	);

	// Imaging-window hours (astronomical dark): used for the cloud / wind /
	// condensation vetoes, which are about imaging conditions + tracking.
	final windowHours = forecast.hours.where((h) =>
		!h.time.isBefore(darkWindow.start!) && !h.time.isAfter(darkWindow.end!),
	).toList();

	// Equipment-EXPOSURE window (sunset→sunrise): the scope is physically
	// uncovered for the whole night, not just the astro-dark core. The
	// precipitation veto uses this wider window so a chance of overnight rain
	// during twilight (scope already uncovered) still triggers protection.
	// Daytime rain — when the scope is covered — is correctly ignored because
	// those hours fall outside [sunset, sunrise]. (User requirement
	// 2026-05-28: max equipment protection.)
	final exposure = horizonWindow(referenceDate, latitude: lat, longitude: lon);
	final exposureHours = (exposure.start != null && exposure.end != null)
		? forecast.hours.where((h) =>
			!h.time.isBefore(exposure.start!) && !h.time.isAfter(exposure.end!),
		).toList()
		: windowHours; // fallback to imaging window if no sunset/sunrise found

	// Peak overnight rain chance over the exposure window — the SAME number the
	// precip veto tests, surfaced so the widget display matches the veto (PEAK,
	// not the dark-window average the display previously computed).
	final precipPeakPct = _peakPrecipPct(exposureHours);

	// Build the veto list. We deliberately do NOT call VetoEvaluator.evaluateAll
	// because its precipitation check averages over the window — we want a
	// PEAK check over the exposure window instead ("basically any real chance
	// of rain → cover up"). Cloud/wind/condensation keep the shared engine
	// checks over the imaging window. Priority order (cloud → precip → wind →
	// condensation) matches evaluateAll.
	//
	// Mode-aware (spec §4): cloud (true overcast), wind (scope shake / dome auto-
	// close) and condensation (dew on optics) fire in BOTH modes. The PRECIP veto
	// is EQUIPMENT protection for an UNCOVERED scope, so it fires in HOME mode only
	// — a REMOTE dome is weatherproof and self-closes, so precip there is not an
	// equipment threat (and a rainy night is already overcast → the cloud veto
	// covers viability). This is the concrete HOME/REMOTE behavioural split.
	// Wind uses a PEAK check (_peakWindVeto) rather than the engine's average,
	// for the same reason precip does — see the veto's doc comment.
	final VetoResult? firedVeto =
		VetoEvaluator.checkCloud(loc.factorScores['cloud'] ?? 0) ??
		(managed ? null : _peakPrecipVeto(exposureHours, precipMaxPct)) ??
		_peakWindVeto(windowHours, windMaxKmh) ??
		VetoEvaluator.checkCondensation(windowHours, dewSpreadMinC);
	final vetoes = firedVeto == null
		? const <Map<String, String>>[]
		: <Map<String, String>>[{'name': firedVeto.vetoName, 'reason': firedVeto.reason}];

	// Narrowband — real forward model (nb-model-v1, spec 2026-06-20). Swap the engine's
	// broadband skyBrightness sub-score for an NB-correct one (narrowbandSkyScore — the
	// filter rejects ~all of the moon/LP continuum), then composite with the SAME location
	// weights the engine uses. Present-factors-only: an absent transparency (no AOD) is
	// skipped, never read as 0 — a 0 would resurrect the BB>NB inversion the Phase-1
	// redesign fixed. Because narrowbandSkyScore ≥ the broadband sky score for every input,
	// NB ≥ BB falls out (no artificial floor needed).
	// Mirror the BB sky model's snow input exactly (scoring_engine.dart): the window-mean
	// ground-snow depth. Snow reflects moon+LP upward — continuum the NB filter also
	// rejects — so the NB sky must apply the SAME brightening to stay consistent with BB
	// (and preserve the leakage=1 ≡ BB identity). Omitting it silently overscored snowy
	// nights (QA workflow 2026-06-20).
	final meanSnowDepth = windowHours.isEmpty
		? 0.0
		: windowHours.map((h) => h.snowDepth).reduce((a, b) => a + b) /
			windowHours.length;
	// NB sky via the SCORE-SPACE moon dock (calibration 2026-06-29, 9,931 subs): narrowband
	// loses 0.25× of broadband's moon hit. Get the LP/snow-only NB baseline (moon OFF) and
	// the BB sky with vs without the (averaged) moon, then dock the moon in score space — a
	// magnitude coupling is eaten by the score curve's 21.5-mag clamp (see moon_window.dart).
	final nbSkyNoMoon = narrowbandSkyScore(
		bortle: siteBortle,
		moonIlluminationPercent: 0, // moon OFF → LP/snow continuum only
		moonAltitudeDeg: -90,
		snowDepthM: meanSnowDepth,
		leakage: nbLeakage,
	);
	final bbSkyNoMoon = locationSkyBrightnessScore(
		bortle: siteBortle,
		moonIlluminationPercent: 0,
		moonAltitudeDeg: -90,
		snowDepthM: meanSnowDepth,
	);
	// BB sky WITH the averaged moon (the engine just computed it). Fallback to the no-moon
	// value on the overcast early-return path, where the engine omits skyBrightness.
	final bbSkyMoon = loc.factorScores['skyBrightness'] ?? bbSkyNoMoon;
	final nbSky = narrowbandMoonAdjustedSky(nbSkyNoMoon, bbSkyNoMoon, bbSkyMoon);
	final nbScores = <String, int>{
		'cloud': loc.factorScores['cloud'] ?? 0,
		'stability': loc.factorScores['stability'] ?? 0,
		'skyBrightness': nbSky,
	};
	if (loc.factorScores.containsKey('transparency')) {
		nbScores['transparency'] = loc.factorScores['transparency']!;
	}
	var nbWeightedSum = 0.0;
	var nbTotalW = 0.0;
	nbScores.forEach((key, score) {
		final w = _nbCompositeWeights[key]!;
		nbWeightedSum += w * score;
		nbTotalW += w;
	});
	final nbRaw = (nbWeightedSum / nbTotalW).round().clamp(0, 100);
	// Cloud gate: opaque cloud blocks emission lines too, so narrowband can't beat the
	// cloud sub-score either (the same cap the engine applies to broadband).
	final cloudFactor = loc.factorScores['cloud'] ?? 0;
	final nbScore = nbRaw < cloudFactor ? nbRaw : cloudFactor;
	final nbVerdict = Verdict.fromScore(nbScore);

	// Compute recommendation per spec §8.
	// Green = genuinely GOOD (spec §5b): require ≥ good. A marginal (40–59) night is
	// NOT a green pass. The old code accepted marginal — which, together with the
	// removed always-100 darkness factor inflating the composite, is how an overcast
	// or moonlit night used to read green. Dropping marginal is half the incident fix
	// (removing the darkness inflation is the other half).
	final bbPass = vetoes.isEmpty &&
		(loc.verdict == Verdict.excellent || loc.verdict == Verdict.good);
	final nbPass = vetoes.isEmpty &&
		(nbVerdict == Verdict.excellent || nbVerdict == Verdict.good);
	// NB is physically never WORSE than BB, and nb-model-v1 makes that STRUCTURAL: the
	// NB composite swaps in an NB-correct sky sub-score (≥ the broadband one) under the
	// same weights + cloud gate, so nbScore ≥ bbScore for every input. So bbPass ⇒ nbPass
	// already — the `bbPass ? BB+NB` clause is exact, not a floor patching imperfect
	// scoring (the old v2 re-weight could score NB a few points below BB; this replaces it).
	final recommendation = bbPass
		? 'BB+NB'
		: nbPass
			? 'NB only'
			: 'Neither';

	final durationMinutes = darkWindow.end!.difference(darkWindow.start!).inMinutes;

	// Moon-free BB (calibration 2026-06-29): the broadband score achievable in the moon-free
	// gap — a SECOND engine pass over that sub-window (userWindow slices cloud/seeing/
	// transparency to it), moon DOWN (altitude -90 → zero burden). computeMoonGeometry returns
	// the window ONLY for a genuine partial gap (0 < freeFraction < 1), so this is null on
	// no-moon and moon-up-all-night nights (display hides it then — see the spec regime table).
	final moonFreeWindow = moonGeom.moonFreeWindow;
	Map<String, dynamic>? moonFreeBroadband;
	if (moonFreeWindow != null) {
		final mf = scoreLocation(
			forecast: forecast,
			darkWindow: darkWindow,
			moonIlluminationPercent: moonIllum,
			userWindow: moonFreeWindow,
			siteBortle: siteBortle,
			moonAltitude: -90.0, // moon below horizon → zero burden over the gap
			firesNearby: firesNearby,
		);
		moonFreeBroadband = {
			'score': mf.score,
			'verdict': mf.verdict.name,
			'window': {
				'start': moonFreeWindow.start.toIso8601String(),
				'end': moonFreeWindow.end.toIso8601String(),
			},
		};
	}

	return {
		'label': label,
		'dark_window': {
			'start': darkWindow.start!.toIso8601String(),
			'end': darkWindow.end!.toIso8601String(),
			'duration_minutes': durationMinutes,
		},
		'moon': {
			'illumination_pct': moonIllum,
			'max_alt_during_dark': maxMoonAlt,
			'freeFraction': moonGeom.freeFraction,
			'freeWindow': moonFreeWindow == null
				? null
				: {
					'start': moonFreeWindow.start.toIso8601String(),
					'end': moonFreeWindow.end.toIso8601String(),
				},
		},
		'broadband': {
			'score': loc.score,
			'verdict': loc.verdict.name,
			'vetoes': vetoes,
			'factors': loc.factorScores,
		},
		'narrowband': {
			'score': nbScore,
			'verdict': nbVerdict.name,
			'vetoes': vetoes, // same hard-stop vetoes apply
			'method': _nbMethod, // 'nb-model-v1' — real forward model, first-principles-uncalibrated
		},
		// The broadband score you could get by shooting LRGB in the moon-free gap (null on
		// no-moon / moon-up-all-night). Display-only; does NOT drive the headline pill (which
		// uses the averaged-moon broadband score above).
		'moonFreeBroadband': moonFreeBroadband,
		// Best clear-sky window within the dark window (≤30% cloud), or null if
		// none. The structured form of the localized "Best window" reason — the
		// HOME-mode gambling aid (where the gaps are). UTC ISO-8601; UI localizes.
		'best_window': loc.bestWindow == null
			? null
			: {
				'start': loc.bestWindow!.start.toIso8601String(),
				'end': loc.bestWindow!.end.toIso8601String(),
			},
		// HOME (false) vs REMOTE (true): lets the UI frame the verdict ("dome site")
		// and records which veto policy was applied this run (precip veto skipped
		// when true).
		'managed': managed,
		'recommendation': recommendation,
		'precip_peak_pct': precipPeakPct.round(),
		'reasons': _localizeReasons(loc),
	};
}
