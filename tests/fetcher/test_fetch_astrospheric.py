"""
Tests for fetch_astrospheric — the part that handles API retry, response
shape validation, and API key scrubbing in error paths.
"""

from unittest.mock import MagicMock, patch

import pytest
import requests

import astrowidget_fetch as fx


def _good_response() -> dict:
	"""
	Mocked Astrospheric V2 response that passes shape validation. Shape verified
	against the LIVE v2 API on 2026-08-04 (probe: scratchpad/probe_v2_shape.py):
	variables are nested per-row under HourlyForecast — NOT top-level as the
	official docs' example shows. Each row carries {ValueColor, ActualValue}
	per requested variable.
	"""
	return {
		"TimeZone": "America/Los_Angeles",
		"UTCMinuteOffset": -480,
		"ModelTime": "2026080412",
		"HourForecastTime": "2026080415",
		"Latitude": 47.6,
		"Longitude": -122.5,
		"IsNBMAvailable": True,
		"APICreditCostOfCall": 65,
		"APICreditsRemaining": 29790,
		"HourlyForecast": [
			{
				"UTCForecastHour": "2026-08-04T15:00:00Z",
				"HourOffset": 0,
				"Cloud": {"ValueColor": "#003E7E", "ActualValue": 12.0},
				"Transparency": {"ValueColor": "#95D4D4", "ActualValue": 17.0},
				"Seeing": {"ValueColor": "#003E7E", "ActualValue": 5.0},
			},
			{
				"UTCForecastHour": "2026-08-04T16:00:00Z",
				"HourOffset": 1,
				"Cloud": {"ValueColor": "#003E7E", "ActualValue": 34.0},
				"Transparency": {"ValueColor": "#95D4D4", "ActualValue": 14.0},
				"Seeing": {"ValueColor": "#003E7E", "ActualValue": 4.0},
			},
		],
	}


def _mock_response(status: int, body: dict | None = None) -> MagicMock:
	"""Builds a MagicMock that quacks like a requests.Response."""
	resp = MagicMock()
	resp.status_code = status
	resp.json.return_value = body if body is not None else {}
	def raise_for_status():
		if status >= 400:
			raise requests.HTTPError(f"{status} Error")
	resp.raise_for_status.side_effect = raise_for_status
	return resp


def test_fetch_astrospheric_happy_path():
	"""200 + well-shaped V2 body → returns dict ADAPTED to the legacy column
	shape every downstream consumer (ensemble_cloud_by_hour, merge_hourly)
	still expects."""
	with patch.object(fx.requests, "post", return_value=_mock_response(200, _good_response())):
		result = fx.fetch_astrospheric("test-key", 47.0, -122.0)
	assert "Astrospheric_Seeing" in result


def test_fetch_astrospheric_requests_only_needed_variables():
	"""The V2 request body must carry the Variables subset — omitting it bills
	the FULL variable set (~130 credits/site instead of 65), which would blow
	the 29,900 monthly cap at our 4×/day × 3-site cadence."""
	mock = MagicMock(return_value=_mock_response(200, _good_response()))
	with patch.object(fx.requests, "post", mock):
		fx.fetch_astrospheric("test-key", 47.0, -122.0)
	sent = mock.call_args.kwargs["json"]
	assert sent["Variables"] == list(fx.ASTROSPHERIC_V2_VARIABLES)
	assert sent["APIKey"] == "test-key"


def test_fetch_astrospheric_adapts_v2_rows_to_legacy_columns():
	"""Row-oriented V2 HourlyForecast → legacy column arrays, preserving
	HourOffset alignment and ActualValue. A transposition bug here would
	silently shift every seeing/transparency/cloud hour."""
	with patch.object(fx.requests, "post", return_value=_mock_response(200, _good_response())):
		result = fx.fetch_astrospheric("test-key", 47.0, -122.0)
	# UTCStartTime is synthesized from the HourOffset-0 row so the existing
	# UTCStartTime+HourOffset alignment logic keeps working unchanged.
	assert result["UTCStartTime"] == "2026-08-04T15:00:00Z"
	seeing = result["Astrospheric_Seeing"]
	transp = result["Astrospheric_Transparency"]
	cloud = result["RDPS_CloudCover"]
	assert [e["HourOffset"] for e in seeing] == [0, 1]
	assert [e["Value"]["ActualValue"] for e in seeing] == [5.0, 4.0]
	assert [e["Value"]["ActualValue"] for e in transp] == [17.0, 14.0]
	assert [e["Value"]["ActualValue"] for e in cloud] == [12.0, 34.0]
	# Credits-remaining passes through for the budget warning.
	assert result["APICreditsRemaining"] == 29790


def test_fetch_astrospheric_rejects_rows_missing_a_variable():
	"""200 whose rows lack a requested variable (e.g. the API silently stops
	serving Transparency) → no_data, never a partial dataset scored as clear."""
	body = _good_response()
	for row in body["HourlyForecast"]:
		del row["Transparency"]
	with patch.object(fx.requests, "post", return_value=_mock_response(200, body)):
		with pytest.raises(fx.AstrosphericFetchError, match="missing"):
			fx.fetch_astrospheric("test-key", 47.0, -122.0)


def test_fetch_astrospheric_rejects_empty_hourly_forecast():
	"""200 with an empty HourlyForecast list ('No Data' shape) → no_data."""
	body = _good_response()
	body["HourlyForecast"] = []
	with patch.object(fx.requests, "post", return_value=_mock_response(200, body)):
		with pytest.raises(fx.AstrosphericFetchError):
			fx.fetch_astrospheric("test-key", 47.0, -122.0)


def test_fetch_astrospheric_rejects_non_dict_rows():
	"""QA CR-1 regression: non-dict rows must raise AstrosphericFetchError, not
	escape as AttributeError — main() catches only AstrosphericFetchError /
	RequestException per site, so an escape aborts the ENTIRE run. Both escape
	variants confirmed empirically pre-fix: a string first row whose text
	happens to contain the variable names (slipping the substring accident of
	`v not in rows[0]`), and a corrupt LATER row after a valid row 0."""
	sneaky = {"HourlyForecast": ["Cloud Transparency Seeing unavailable"]}
	with patch.object(fx.requests, "post", return_value=_mock_response(200, sneaky)):
		with pytest.raises(fx.AstrosphericFetchError) as ei:
			fx.fetch_astrospheric("test-key", 47.0, -122.0)
	assert ei.value.code == "no_data"

	later = _good_response()
	later["HourlyForecast"].append("corrupt")
	with patch.object(fx.requests, "post", return_value=_mock_response(200, later)):
		with pytest.raises(fx.AstrosphericFetchError) as ei:
			fx.fetch_astrospheric("test-key", 47.0, -122.0)
	assert ei.value.code == "no_data"


def test_fetch_astrospheric_rewinds_utcstarttime_to_offset_zero():
	"""QA TA-1: a forecast whose rows START at HourOffset 2 must synthesize the
	OFFSET-ZERO epoch (row time minus its offset), because downstream computes
	hour = UTCStartTime + HourOffset. Rows arrive REVERSED to also pin the
	min()-anchor selection. Pre-fix revert-that-passes: returning the first
	row's own timestamp shifted every hour by 2 with all other tests green."""
	body = _good_response()
	body["HourlyForecast"] = [
		{
			"UTCForecastHour": "2026-08-04T18:00:00Z", "HourOffset": 3,
			"Cloud": {"ActualValue": 5.0}, "Transparency": {"ActualValue": 8.0},
			"Seeing": {"ActualValue": 3.0},
		},
		{
			"UTCForecastHour": "2026-08-04T17:00:00Z", "HourOffset": 2,
			"Cloud": {"ActualValue": 4.0}, "Transparency": {"ActualValue": 9.0},
			"Seeing": {"ActualValue": 4.0},
		},
	]
	with patch.object(fx.requests, "post", return_value=_mock_response(200, body)):
		result = fx.fetch_astrospheric("test-key", 47.0, -122.0)
	# Anchor = the offset-2 row at 17:00Z → offset-zero epoch is 15:00Z.
	assert result["UTCStartTime"] == "2026-08-04T15:00:00Z"


def test_fetch_astrospheric_tolerates_null_values_in_later_rows(capsys):
	"""QA TA-2: a null variable in a LATER row (per-hour gap) must not fail the
	fetch — it becomes a {"Value": None} entry the downstream offset maps skip.
	Only whole-column nullness is a loud event (see the all-null test below)."""
	body = _good_response()
	body["HourlyForecast"][1]["Seeing"] = None
	with patch.object(fx.requests, "post", return_value=_mock_response(200, body)):
		result = fx.fetch_astrospheric("test-key", 47.0, -122.0)
	assert result["Astrospheric_Seeing"][1]["Value"] is None
	# Hour 0 still carries its numeric value → no all-null warning either.
	assert "no usable Seeing" not in capsys.readouterr().err


def test_fetch_astrospheric_warns_on_all_null_column(capsys):
	"""QA CR-2: a column that is present but ENTIRELY null degrades downstream
	to '—'/free-source silently by design — so the fetch must say so on stderr
	(the run-level signal an admin sees), while still succeeding for the other
	variables."""
	body = _good_response()
	for row in body["HourlyForecast"]:
		row["Seeing"] = None
	with patch.object(fx.requests, "post", return_value=_mock_response(200, body)):
		result = fx.fetch_astrospheric("test-key", 47.0, -122.0)
	assert "no usable Seeing" in capsys.readouterr().err
	# The fetch itself still succeeds with the other columns intact.
	assert result["RDPS_CloudCover"][0]["Value"]["ActualValue"] == 12.0


def test_fetch_astrospheric_falls_back_on_non_numeric_offsets():
	"""QA TA-4: rows whose HourOffset is missing or a string must not crash the
	adapter. UTCStartTime falls back to the first row's own timestamp, and the
	column entries keep their raw HourOffset for astro_by_offset's positional
	fallback."""
	body = _good_response()
	body["HourlyForecast"][0]["HourOffset"] = None
	body["HourlyForecast"][1]["HourOffset"] = "3"
	with patch.object(fx.requests, "post", return_value=_mock_response(200, body)):
		result = fx.fetch_astrospheric("test-key", 47.0, -122.0)
	assert result["UTCStartTime"] == "2026-08-04T15:00:00Z"
	assert [e["HourOffset"] for e in result["Astrospheric_Seeing"]] == [None, "3"]


def test_fetch_astrospheric_posts_to_v2_endpoint():
	"""QA TA-5: pin the URL itself. Without this, reverting the endpoint
	constant to the retired V1 host passes the whole suite. The literal
	fragment guards the constant; the constant equality guards the call."""
	mock = MagicMock(return_value=_mock_response(200, _good_response()))
	with patch.object(fx.requests, "post", mock):
		fx.fetch_astrospheric("test-key", 47.0, -122.0)
	url = mock.call_args.args[0]
	assert url == fx.ASTROSPHERIC_FORECAST_URL
	assert "v2-api-public.astrospheric.com" in url


def test_fetch_astrospheric_retries_on_5xx_then_succeeds():
	"""500 on first attempt, 200 on second → caller sees success, no exception."""
	calls = [_mock_response(500), _mock_response(200, _good_response())]
	with patch.object(fx.requests, "post", side_effect=calls):
		result = fx.fetch_astrospheric("test-key", 47.0, -122.0)
	assert "Astrospheric_Seeing" in result


def test_fetch_astrospheric_raises_after_two_5xx_failures():
	"""500 on both attempts → AstrosphericFetchError."""
	with patch.object(fx.requests, "post", return_value=_mock_response(500)):
		with pytest.raises(fx.AstrosphericFetchError):
			fx.fetch_astrospheric("test-key", 47.0, -122.0)


def test_fetch_astrospheric_does_not_retry_on_4xx():
	"""401 (auth) → fail fast, no second attempt."""
	mock = MagicMock(side_effect=[_mock_response(401)])
	with patch.object(fx.requests, "post", mock):
		with pytest.raises(fx.AstrosphericFetchError):
			fx.fetch_astrospheric("test-key", 47.0, -122.0)
	# Only one call should have been made (no retry on 4xx).
	assert mock.call_count == 1


def test_fetch_astrospheric_rejects_200_with_error_body():
	"""200 with an ErrorInfo body and no HourlyForecast → AstrosphericFetchError
	(no silent fail). V2 errors use {"ErrorInfo": ...}; V1 used {"error": ...} —
	either way the tell is the absent forecast payload."""
	bad = {"ErrorInfo": "API down for maintenance"}
	with patch.object(fx.requests, "post", return_value=_mock_response(200, bad)):
		with pytest.raises(fx.AstrosphericFetchError, match="HourlyForecast"):
			fx.fetch_astrospheric("test-key", 47.0, -122.0)


def test_fetch_astrospheric_rejects_non_dict_response():
	"""200 with non-dict body (e.g., string error) → AstrosphericFetchError."""
	resp = _mock_response(200)
	resp.json.return_value = "API down"
	with patch.object(fx.requests, "post", return_value=resp):
		with pytest.raises(fx.AstrosphericFetchError, match="non-dict"):
			fx.fetch_astrospheric("test-key", 47.0, -122.0)


def test_fetch_astrospheric_error_message_excludes_api_key():
	"""
	Crucial: the error string must NOT contain the API key.
	A user pasting the traceback into a forum should not leak credentials.
	"""
	with patch.object(fx.requests, "post", side_effect=requests.ConnectionError("DNS resolution failed")):
		with pytest.raises(fx.AstrosphericFetchError) as ei:
			fx.fetch_astrospheric("secret-key-do-not-leak", 47.0, -122.0)
	msg = str(ei.value)
	assert "secret-key-do-not-leak" not in msg
	# Should at least name the exception type for diagnostics.
	assert "ConnectionError" in msg


def test_fetch_astrospheric_tags_each_failure_with_stable_code():
	"""Every failure mode tags AstrosphericFetchError with its STABLE .code. The
	code is the persisted dismissal key (<site_id>|<code>), so a regression in the
	status→code mapping (a 403 losing its dedicated code, or `// 100` becoming
	`// 10`) would silently break "Don't show this again" — a saved dismissal would
	stop matching, or worse, mask a different error. This is the one place that
	mapping is exercised end to end; the older tests above only assert that it
	raises, not which code it carries."""

	def _code_for(post_mock) -> str:
		with patch.object(fx.requests, "post", post_mock):
			with pytest.raises(fx.AstrosphericFetchError) as ei:
				fx.fetch_astrospheric("test-key", 47.0, -122.0)
		return ei.value.code

	# 403 (key rejected) gets its own code so it can be dismissed specifically.
	assert _code_for(MagicMock(side_effect=[_mock_response(403)])) == "http_403"
	# Any other 4xx buckets to http_4xx.
	assert _code_for(MagicMock(side_effect=[_mock_response(404)])) == "http_4xx"
	# 5xx on both attempts (one retry happens) → http_5xx.
	assert _code_for(MagicMock(return_value=_mock_response(500))) == "http_5xx"
	# Connection error on both attempts → network.
	assert _code_for(MagicMock(side_effect=requests.ConnectionError("DNS"))) == "network"
	# 200 whose body isn't valid JSON → bad_json.
	_bad_json = _mock_response(200)
	_bad_json.json.side_effect = ValueError("not json")
	assert _code_for(MagicMock(return_value=_bad_json)) == "bad_json"
	# 200 with a non-dict body → no_data.
	_non_dict = _mock_response(200)
	_non_dict.json.return_value = "API down"
	assert _code_for(MagicMock(return_value=_non_dict)) == "no_data"
	# 200 with a dict missing the HourlyForecast payload → no_data.
	assert _code_for(MagicMock(return_value=_mock_response(200, {"ErrorInfo": "x"}))) == "no_data"
