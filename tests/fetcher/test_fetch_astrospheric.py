"""
Tests for fetch_astrospheric — the part that handles API retry, response
shape validation, and API key scrubbing in error paths.
"""

from unittest.mock import MagicMock, patch

import pytest
import requests

import astrowidget_fetch as fx


def _good_response() -> dict:
	"""Mocked Astrospheric response that passes shape validation."""
	return {
		"TimeZone": "America/Los_Angeles",
		"UTCMinuteOffset": -480,
		"ModelTime": "2026052812",
		"Latitude": 47.6,
		"Longitude": -122.5,
		"APICreditUsedToday": 5,
		"Astrospheric_Seeing": [{"Value": 4, "ColorIndex": 1}],
		"Astrospheric_Transparency": [{"Value": 3, "ColorIndex": 1}],
		"RDPS_CloudCover": [{"Value": 12, "ColorIndex": 1}],
		"RDPS_DewPoint": [{"Value": 281.5, "ColorIndex": 1}],
		"RDPS_Temperature": [{"Value": 284.0, "ColorIndex": 1}],
		"RDPS_WindVelocity": [{"Value": 2.5, "ColorIndex": 1}],
		"RDPS_WindDirection": [{"Value": 220, "ColorIndex": 1}],
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
	"""200 + well-shaped body → returns parsed dict."""
	with patch.object(fx.requests, "post", return_value=_mock_response(200, _good_response())):
		result = fx.fetch_astrospheric("test-key", 47.0, -122.0)
	assert "Astrospheric_Seeing" in result


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
	"""200 with missing required keys → AstrosphericFetchError (no silent fail)."""
	bad = {"error": "API down for maintenance"}
	with patch.object(fx.requests, "post", return_value=_mock_response(200, bad)):
		with pytest.raises(fx.AstrosphericFetchError, match="missing required keys"):
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
