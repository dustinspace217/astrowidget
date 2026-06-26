"""Tests for enrich_night_smoke — the per-night `smoke` block (smoke feature)."""
import astrowidget_fetch as fx


def test_enrich_night_smoke_window_mean_and_peak():
	"""AOD mean + peak over the dark window; AQI/PM2.5 window means; fires attached.
	Rows outside the window are excluded."""
	night = {"dark_window": {"start": "2026-06-26T05:00:00Z",
							 "end": "2026-06-26T08:00:00Z"}}
	aq_rows = [
		{"time": "2026-06-26T05:00", "aerosol_optical_depth": 0.08,
		 "us_aqi": 52, "pm2_5": 7.6},
		{"time": "2026-06-26T06:00", "aerosol_optical_depth": 0.16,
		 "us_aqi": 50, "pm2_5": 6.0},
		{"time": "2026-06-26T12:00", "aerosol_optical_depth": 0.99,
		 "us_aqi": 99, "pm2_5": 99},   # outside the window — excluded
	]
	fires = {"count": 3, "nearestKm": 58.4, "maxFrp": 120.5,
			 "radiusKm": 150, "source": "VIIRS_NOAA20_NRT", "asOf": "2026-06-25"}
	fx.enrich_night_smoke(night, aq_rows, fires)
	s = night["smoke"]
	assert s["aodPeak"] == 0.16
	assert abs(s["aodMean"] - 0.12) < 0.001
	assert s["usAqi"] == 51         # mean(52, 50)
	assert s["pm25"] == 6.8         # mean(7.6, 6.0)
	assert s["firesNearby"]["nearestKm"] == 58.4


def test_enrich_night_smoke_handles_no_data():
	"""No air-quality + no fires → every field null (null ≠ 0)."""
	night = {"dark_window": {"start": "2026-06-26T05:00:00Z",
							 "end": "2026-06-26T08:00:00Z"}}
	fx.enrich_night_smoke(night, [], None)
	assert night["smoke"] == {
		"aodMean": None, "aodPeak": None, "usAqi": None,
		"pm25": None, "firesNearby": None,
	}


def test_enrich_night_smoke_no_window_keeps_fires():
	"""A degenerate night (no dark_window) yields null AOD/AQI but still attaches the
	site-level fire snapshot — fires aren't window-scoped."""
	night = {"dark_window": None}
	fires = {"count": 1, "nearestKm": 10.0, "maxFrp": 50.0,
			 "radiusKm": 150, "source": "x", "asOf": "2026-06-25"}
	fx.enrich_night_smoke(
		night,
		[{"time": "2026-06-26T05:00", "aerosol_optical_depth": 0.1,
		  "us_aqi": 40, "pm2_5": 5}],
		fires,
	)
	assert night["smoke"]["aodMean"] is None
	assert night["smoke"]["firesNearby"]["count"] == 1
