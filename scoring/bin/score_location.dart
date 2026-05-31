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
// scores with reduced moon/darkness weights.  This is a site-level BB/NB
// approximation, not the per-target distinction scoreTarget() makes.
// See ~/Claude/astrowidget/docs/superpowers/specs/2026-05-28-astrowidget-design.md
// §6.2 for the spec and §8 for the recommendation algorithm.

import 'dart:convert';
import 'dart:io';
import 'package:astrowidget_scoring/astro/moon_geometry.dart';
import 'package:astrowidget_scoring/astro/solar_system.dart' show BodyPosition;
import 'package:astrowidget_scoring/astro/visibility.dart';
import 'package:astrowidget_scoring/scoring/scoring_engine.dart';
import 'package:astrowidget_scoring/scoring/veto_evaluator.dart';
import 'package:astrowidget_scoring/weather/weather_models.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Narrowband re-weighting constants
// ─────────────────────────────────────────────────────────────────────────────

// Narrowband score — HEURISTIC, NOT a calibrated engine mode.
//
// IMPORTANT HONESTY NOTE (2026-05-28): astroplan's scoreLocation() has NO
// ImagingMode parameter — only scoreTarget() does. There is no calibrated
// narrowband location-scoring path in the engine. So this wrapper computes
// a heuristic NB score by re-weighting the broadband run's already-computed
// factor sub-scores (cloud/stability/darkness/moon) with the constants below.
// This is a reasonable approximation — narrowband filters pass ~1nm around
// emission lines and reject ~99% of moonlight, so darkness/moon should matter
// far less — but the WEIGHTS THEMSELVES ARE UNCALIBRATED first-principles
// estimates, not derived from imaging outcomes like the engine's broadband
// constants are. The output is tagged `method: "heuristic-reweight-v1"` so
// consumers (and the user) know not to over-trust the NB number relative to
// the calibrated broadband score. Calibrating these is tracked as a v2 item.
//
// Mathematically the re-weight is sound (a weighted mean of independent
// 0-100 sub-scores), but it is NOT equivalent to re-running the engine with
// narrowband-aware factor scoring — there is no such path to run.
const double _nbCloudWeight = 1.0;
const double _nbStabilityWeight = 0.65;
const double _nbDarknessWeight = 0.15; // vs 0.8 broadband — moon-glow tolerant
const double _nbMoonWeight = 0.05; // vs 0.6 broadband — near-irrelevant for NB
const String _nbMethod = 'heuristic-reweight-v1';

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
		'schema_version': 1,
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
	final forecast = WeatherForecast(
		locationId: 0, // unused by scoreLocation
		fetchedAt: nowUtc,
		hours: hourlyList,
	);

	// Score the next three nights.  "Tonight" = the next astro dark window
	// after nowUtc.  +1 / +2 are the windows on subsequent dates.
	final nights = <Map<String, dynamic>>[];
	for (int offset = 0; offset < 3; offset++) {
		final referenceDate = nowUtc.add(Duration(days: offset));
		nights.add(_scoreOneNight(
			referenceDate: referenceDate,
			label: ['Tonight', '+1 night', '+2 nights'][offset],
			forecast: forecast,
			lat: lat,
			lon: lon,
			windMaxKmh: windMaxKmh,
			precipMaxPct: precipMaxPct,
			dewSpreadMinC: dewSpreadMinC,
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
/// calls scoreLocation() for the broadband baseline, re-weights for
/// narrowband, evaluates safety vetoes, and emits the BB/NB/Neither
/// recommendation.
Map<String, dynamic> _scoreOneNight({
	required DateTime referenceDate,
	required String label,
	required WeatherForecast forecast,
	required double lat,
	required double lon,
	required double windMaxKmh,
	required double precipMaxPct,
	required double dewSpreadMinC,
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

	// Maximum moon altitude during the dark window — useful for users to
	// see at-a-glance whether the moon is above the horizon during their
	// imaging hours. Sample every 15 minutes from start to end and take
	// the max. 15 min is sub-degree precision (moon moves ~0.5°/2 min).
	double maxMoonAlt = -90.0;
	final stepMs = 15 * 60 * 1000;  // 15 minutes
	for (int t = darkWindow.start!.millisecondsSinceEpoch;
		 t <= darkWindow.end!.millisecondsSinceEpoch;
		 t += stepMs) {
		final sampleTime = DateTime.fromMillisecondsSinceEpoch(t, isUtc: true);
		try {
			final pos = getMoonPosition(
				sampleTime,
				latitude: lat,
				longitude: lon,
			);
			if (pos.altitude > maxMoonAlt) {
				maxMoonAlt = pos.altitude;
			}
		} on Exception {
			// Tolerate geoengine throwing on edge cases (rare). Sample is
			// skipped; max stays at whatever it was.
			continue;
		}
	}

	// Broadband baseline: call astroplan's scoreLocation() with engine defaults.
	final loc = scoreLocation(
		forecast: forecast,
		darkWindow: darkWindow,
		moonIlluminationPercent: moonIllum,
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
	final VetoResult? firedVeto =
		VetoEvaluator.checkCloud(loc.factorScores['cloud'] ?? 0) ??
		_peakPrecipVeto(exposureHours, precipMaxPct) ??
		VetoEvaluator.checkWind(windowHours, windMaxKmh) ??
		VetoEvaluator.checkCondensation(windowHours, dewSpreadMinC);
	final vetoes = firedVeto == null
		? const <Map<String, String>>[]
		: <Map<String, String>>[{'name': firedVeto.vetoName, 'reason': firedVeto.reason}];

	// Narrowband: re-weight the engine-returned factor scores with NB weights.
	final cloudS = loc.factorScores['cloud'] ?? 0;
	final stabilityS = loc.factorScores['stability'] ?? 0;
	final darknessS = loc.factorScores['darkness'] ?? 0;
	final moonS = loc.factorScores['moon'] ?? 0;
	final nbWeightedSum = _nbCloudWeight * cloudS +
		_nbStabilityWeight * stabilityS +
		_nbDarknessWeight * darknessS +
		_nbMoonWeight * moonS;
	final nbTotalW = _nbCloudWeight + _nbStabilityWeight +
		_nbDarknessWeight + _nbMoonWeight;
	final nbScore = (nbWeightedSum / nbTotalW).round().clamp(0, 100);
	final nbVerdict = Verdict.fromScore(nbScore);

	// Compute recommendation per spec §8.
	final bbPass = vetoes.isEmpty &&
		(loc.verdict == Verdict.excellent ||
		 loc.verdict == Verdict.good ||
		 loc.verdict == Verdict.marginal);
	final nbPass = vetoes.isEmpty &&
		(nbVerdict == Verdict.excellent ||
		 nbVerdict == Verdict.good ||
		 nbVerdict == Verdict.marginal);
	final recommendation = bbPass && nbPass
		? 'BB+NB'
		: nbPass
			? 'NB only'
			: 'Neither';

	final durationMinutes = darkWindow.end!.difference(darkWindow.start!).inMinutes;

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
			'method': _nbMethod, // 'heuristic-reweight-v1' — not engine-calibrated
		},
		'recommendation': recommendation,
		'precip_peak_pct': precipPeakPct.round(),
		'reasons': _localizeReasons(loc),
	};
}
