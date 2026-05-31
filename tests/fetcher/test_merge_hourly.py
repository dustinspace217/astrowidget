"""
Tests for merge_hourly — the per-hour forecast merger.

Open-Meteo is the base weather source for every site. On top of it, the merger
takes an optional ensemble cloud override (which replaces Open-Meteo's
cloud_cover for scoring) and seeing/transparency from one of two sources:
Astrospheric (North-America sites) or a pre-built 7Timer lookup (international).
Output is the canonical hourly array the Dart scoring binary expects.
"""

import astrowidget_fetch as fx


# ─────────────────────────────────────────────────────────────────────────────
# Fixtures
# ─────────────────────────────────────────────────────────────────────────────


def _open_meteo_response(hours: int = 3) -> dict:
	"""Builds a minimal but well-formed Open-Meteo /forecast response."""
	times = [f"2026-05-29T0{i}:00:00" for i in range(hours)]
	def fill(default):
		return [default] * hours
	return {
		"hourly": {
			"time": times,
			"cloud_cover": fill(15.0),
			"cloud_cover_low": fill(0.0),
			"cloud_cover_mid": fill(5.0),
			"cloud_cover_high": fill(10.0),
			"relative_humidity_2m": fill(65.0),
			"temperature_2m": fill(11.0),
			"dewpoint_2m": fill(8.0),
			"wind_speed_10m": fill(8.0),
			"wind_gusts_10m": fill(13.0),
			"precipitation_probability": fill(5.0),
			"precipitation": fill(0.0),
			"visibility": fill(24000.0),
		},
	}


def _astrospheric_response(
	hours: int = 3,
	start: str = "2026-05-29T00:00:00Z",
	seeing_series: list | None = None,
) -> dict:
	"""Builds a minimal but well-formed Astrospheric /GetForecastData_V1 response.

	`start` is UTCStartTime — the hour the Astrospheric forecast begins. The
	merge aligns to Open-Meteo by this timestamp, NOT by raw index.
	`seeing_series`, when provided, lets a test set distinct per-hour seeing
	values so timestamp alignment can be verified positionally.
	"""
	# REAL Astrospheric hourly shape (verified against live API 2026-05-28):
	# each entry is {"Value": {"ActualValue": <num>, "ValueColor": "#hex"},
	# "HourOffset": <int>}. The value is nested under Value.ActualValue and the
	# hour index is HourOffset — NOT a flat {"Value": <num>}.
	def fill(value):
		return [
			{"Value": {"ActualValue": float(value), "ValueColor": "#000000"}, "HourOffset": i}
			for i in range(hours)
		]
	seeing = (
		[
			{"Value": {"ActualValue": float(v), "ValueColor": "#000000"}, "HourOffset": i}
			for i, v in enumerate(seeing_series)
		]
		if seeing_series is not None else fill(4)
	)
	return {
		"TimeZone": "America/Los_Angeles",
		"UTCMinuteOffset": -480,
		"ModelTime": "2026052812",
		"UTCStartTime": start,
		"Latitude": 45.0,
		"Longitude": -120.0,
		"APICreditUsedToday": 5,
		"Astrospheric_Seeing": seeing,
		"Astrospheric_Transparency": fill(3),
		"RDPS_CloudCover": fill(12),
		"RDPS_DewPoint": fill(281.5),
		"RDPS_Temperature": fill(284.0),
		"RDPS_WindVelocity": fill(2.5),
		"RDPS_WindDirection": fill(220),
	}


# ─────────────────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────────────────


def test_merge_produces_one_row_per_hour():
	"""For 3 hours of input, output has 3 rows."""
	merged = fx.merge_hourly(_astrospheric_response(3), _open_meteo_response(3))
	assert len(merged) == 3
	assert all("time" in row for row in merged)


def test_merge_preserves_open_meteo_field_names():
	"""Open-Meteo's snake_case keys must roundtrip unchanged into Dart."""
	merged = fx.merge_hourly(_astrospheric_response(2), _open_meteo_response(2))
	row = merged[0]
	# These are the exact keys astroplan's HourlyWeather.fromJson() reads.
	for key in (
		"cloud_cover", "cloud_cover_low", "cloud_cover_mid", "cloud_cover_high",
		"relative_humidity_2m", "temperature_2m", "dewpoint_2m",
		"wind_speed_10m", "wind_gusts_10m",
		"precipitation_probability", "precipitation", "visibility",
	):
		assert key in row, f"missing key {key}"


def test_merge_attaches_seeing_transparency_fields():
	"""Astro-quality values appear under the source-agnostic _seeing_raw /
	_transparency_raw keys (aligned by the Astrospheric start time)."""
	merged = fx.merge_hourly(_astrospheric_response(1), _open_meteo_response(1))
	row = merged[0]
	assert row["_seeing_raw"] == 4
	assert row["_transparency_raw"] == 3


def test_merge_aligns_astrospheric_by_timestamp_not_index():
	"""
	THE timestamp-alignment fix. Astrospheric starts 6h BEFORE Open-Meteo.
	Open-Meteo hour 0 is 2026-05-29T00:00; Astrospheric starts at
	2026-05-28T18:00, so its index 6 is the 00:00 hour. The merged row for
	OM hour 0 must carry Astrospheric's index-6 seeing value, NOT index 0.
	With raw-index zipping (the old bug) it would wrongly carry index 0.
	"""
	# Distinct per-hour seeing so we can tell which index landed where.
	# 7 hours: indices 0..6, values 10..16. Index 6 (00:00 UTC) = value 16.
	astro = _astrospheric_response(
		hours=7,
		start="2026-05-28T18:00:00Z",
		seeing_series=[10, 11, 12, 13, 14, 15, 16],
	)
	om = _open_meteo_response(3)  # 00:00, 01:00, 02:00 on 2026-05-29
	merged = fx.merge_hourly(astro, om)
	# OM 00:00 -> Astro 18:00+6h=00:00 -> index 6 -> seeing 16.
	assert merged[0]["_seeing_raw"] == 16
	# OM 01:00 -> Astro index 7 -> out of range -> None (not fabricated).
	assert merged[1]["_seeing_raw"] is None


def test_merge_no_start_time_yields_none_seeing():
	"""Missing UTCStartTime → seeing/transparency unavailable (None), NOT an
	index-based guess. The old code index-aligned as a fallback, but that risked
	the exact silent hour-shift the timestamp alignment exists to avoid; with the
	unified source-agnostic lookup we prefer an honest "—" over a possibly-
	misaligned value. (The real Astrospheric API always returns UTCStartTime.)"""
	astro = _astrospheric_response(2, seeing_series=[7, 8])
	del astro["UTCStartTime"]
	merged = fx.merge_hourly(astro, _open_meteo_response(2))
	assert merged[0]["_seeing_raw"] is None
	assert merged[1]["_seeing_raw"] is None


def test_merge_missing_astro_hour_is_none_not_default():
	"""
	When no Astrospheric hour matches an Open-Meteo hour, the field is None
	(honest "no data"), NOT a fabricated good-seeing default. Adversarial
	review flagged that fabricating astro defaults is anti-coverage.
	"""
	# Astrospheric covers only the first hour; OM has 3.
	astro = _astrospheric_response(1, start="2026-05-29T00:00:00Z")
	merged = fx.merge_hourly(astro, _open_meteo_response(3))
	assert merged[0]["_seeing_raw"] == 4   # matched
	assert merged[2]["_seeing_raw"] is None  # no matching astro hour


def test_merge_empty_open_meteo_yields_empty_list():
	"""No timestamps from Open-Meteo means no rows produced."""
	om = {"hourly": {"time": []}}
	merged = fx.merge_hourly(_astrospheric_response(0), om)
	assert merged == []


def test_merge_truncates_when_required_field_missing():
	"""
	Missing entire variable array in Open-Meteo truncates the output to
	prevent fabricated data flowing into scoring. Spec §13 explicit rule.
	"""
	om = _open_meteo_response(2)
	# Strip wind_gusts_10m to simulate API omitting it entirely.
	del om["hourly"]["wind_gusts_10m"]
	merged = fx.merge_hourly(_astrospheric_response(2), om)
	# Truncated to zero complete hours — no fabricated wind values reach scoring.
	assert merged == []


def test_merge_handles_none_values_uses_distinct_sentinel():
	"""Null Open-Meteo entries become the default; non-null real values pass through.
	Uses 73.0 (not the 50.0 default) so the test actually distinguishes
	'fell back to default' from 'kept the original'."""
	om = _open_meteo_response(2)
	om["hourly"]["cloud_cover"] = [None, 73.0]
	merged = fx.merge_hourly(_astrospheric_response(2), om)
	assert merged[0]["cloud_cover"] == 50.0  # default when None
	assert merged[1]["cloud_cover"] == 73.0  # passes through unchanged


def test_merge_truncates_to_open_meteo_length():
	"""When Astrospheric has more hours than Open-Meteo, output matches OM length."""
	merged = fx.merge_hourly(_astrospheric_response(10), _open_meteo_response(3))
	assert len(merged) == 3


# ─────────────────────────────────────────────────────────────────────────────
# Ensemble cloud override + 7Timer (international) path
# ─────────────────────────────────────────────────────────────────────────────


def test_merge_cloud_by_hour_overrides_open_meteo_cloud():
	"""The ensemble consensus REPLACES Open-Meteo's cloud_cover for the hours it
	covers; hours the ensemble missed fall back to Open-Meteo so a partial
	ensemble never blanks the meteogram."""
	om = _open_meteo_response(2)  # cloud_cover = 15.0 each hour
	# Consensus covers only hour 0 (00:00 UTC) with 60%.
	consensus = {fx._parse_utc_hour("2026-05-29T00:00:00"): 60.0}
	merged = fx.merge_hourly(
		_astrospheric_response(2), om, cloud_by_hour=consensus
	)
	assert merged[0]["cloud_cover"] == 60.0   # ensemble override
	assert merged[1]["cloud_cover"] == 15.0   # fell back to Open-Meteo


def test_merge_seventimer_path_no_astrospheric():
	"""International path: astrospheric=None, seeing/transparency come from a
	passed-in 7Timer st_by_hour lookup keyed by UTC hour."""
	om = _open_meteo_response(2)
	st = {
		fx._parse_utc_hour("2026-05-29T00:00:00"): (2, 3),  # (seeing, transparency)
		fx._parse_utc_hour("2026-05-29T01:00:00"): (4, 5),
	}
	merged = fx.merge_hourly(None, om, st_by_hour=st, st_source="7timer")
	assert merged[0]["_seeing_raw"] == 2
	assert merged[0]["_transparency_raw"] == 3
	assert merged[1]["_seeing_raw"] == 4
	# No Astrospheric and no consensus → cloud_cover stays Open-Meteo's.
	assert merged[0]["cloud_cover"] == 15.0


def test_merge_no_source_seeing_is_none():
	"""astrospheric=None and an empty st_by_hour (e.g. a 7Timer fetch that
	failed and returned {}) → seeing/transparency are None, shown as "—"."""
	merged = fx.merge_hourly(None, _open_meteo_response(2), st_by_hour={})
	assert merged[0]["_seeing_raw"] is None
	assert merged[0]["_transparency_raw"] is None


def test_merge_rejects_nonfinite_cloud():
	"""A non-finite Open-Meteo value (inf/NaN) falls back to the default rather
	than poisoning the scoring cloud. The meteogram clamps for display, but the
	scoring path reads cloud_cover raw, so the merge must sanitize it here."""
	om = _open_meteo_response(2)
	om["hourly"]["cloud_cover"] = [float("inf"), 30.0]
	merged = fx.merge_hourly(_astrospheric_response(2), om)
	assert merged[0]["cloud_cover"] == 50.0   # inf → default
	assert merged[1]["cloud_cover"] == 30.0   # finite value passes through


def test_merge_tolerates_present_but_null_astrospheric_arrays():
	"""REGRESSION (2026-05-30): Astrospheric seeing/transparency present-but-null
	(the same shape the live GFS/NAM fields take) must not crash the seeing
	extraction. `.get(key, [])` returns None for a present-but-null key, so the
	extractor must coerce None to an empty list before iterating."""
	astro = _astrospheric_response(2)
	astro["Astrospheric_Seeing"] = None
	astro["Astrospheric_Transparency"] = None
	merged = fx.merge_hourly(astro, _open_meteo_response(2))
	assert merged[0]["_seeing_raw"] is None
	assert merged[0]["_transparency_raw"] is None
