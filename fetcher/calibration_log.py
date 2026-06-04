"""
calibration_log.py — the astrowidget calibration database (Phase 3).

A local SQLite database that accumulates, GOING FORWARD, the labeled dataset for
re-tuning the scoring weights against real outcomes:

  - `forecasts`   — the forecast + score, logged on every fetch (this module).
  - `decisions`   — the user's nightly answer: imaged or not, and why (the
                    persistent ~11 PM form, built next; this is the survivorship-
                    bias-correcting half the FITS alone can't give — it records the
                    nights you SKIPPED and the reason).
  - `fits_grades` — per imaged night, the FITS auto-grader's metrics (built later).

The three join on (night_date, site_id). This module OWNS the schema + the DB path
so the fetcher, the decision form, and the grader all share one source of truth.
stdlib `sqlite3` — no new dependency.

Why a DB (not the earlier JSONL idea or a spreadsheet): one queryable store all
three writers share, with the join built in, and durable across the weeks of
accumulation the re-tune needs.

NOTE on scope (2026-06-03, per Dustin): decisions + FITS grading focus on the
HOME site (Bainbridge — the one he can directly verify). The forecast log records
ALL configured sites, because it's free (the scores are already computed) and a
complete record is more useful later; the join simply only has decision/grade rows
for the sites we actually label.
"""

import os
import sqlite3
import sys
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any


def _data_dir() -> Path:
	"""Persistent per-user DATA directory (NOT cache — this is user-owned
	calibration data we never want auto-purged). Mirrors Qt's AppDataLocation per
	OS so a future GUI form + the grader resolve the same DB:
	    Windows -> %LOCALAPPDATA%\\astrowidget
	    macOS   -> ~/Library/Application Support/astrowidget
	    Linux   -> $XDG_DATA_HOME/astrowidget, else ~/.local/share/astrowidget
	Deliberately a SIBLING of the cache dir (which uses a \\cache subfolder /
	~/Library/Caches), so calibration data and disposable cache never collide."""
	if sys.platform == "win32":
		local = os.environ.get("LOCALAPPDATA")
		base = Path(local) if local else Path.home() / "AppData" / "Local"
		return base / "astrowidget"
	if sys.platform == "darwin":
		return Path.home() / "Library" / "Application Support" / "astrowidget"
	xdg = os.environ.get("XDG_DATA_HOME")
	base = Path(xdg) if xdg and os.path.isabs(xdg) else Path.home() / ".local" / "share"
	return base / "astrowidget"


DB_PATH = _data_dir() / "astrowidget.db"


# One statement per object; executed with executescript on connect (all IF NOT
# EXISTS, so connecting is idempotent and also migrates an older DB forward).
_SCHEMA = """
CREATE TABLE IF NOT EXISTS forecasts (
    id              INTEGER PRIMARY KEY,
    fetched_at      TEXT NOT NULL,   -- ISO-UTC of the fetch run
    night_date      TEXT NOT NULL,   -- observing-night date (local, noon-to-noon), the join key
    night_label     TEXT,            -- 'Tonight' / '+1 night' / '+2 nights'
    site_id         TEXT NOT NULL,
    recommendation  TEXT,            -- 'BB+NB' / 'NB only' / 'Neither'
    bb_score        INTEGER,
    bb_verdict      TEXT,
    nb_score        INTEGER,
    nb_verdict      TEXT,
    cloud           INTEGER,         -- factor sub-scores (any may be NULL/absent)
    stability       INTEGER,
    sky_brightness  INTEGER,
    transparency    INTEGER,
    moon_illum      REAL,
    moon_alt        REAL,
    precip_peak_pct INTEGER,
    best_window_start TEXT,          -- NULL when no clear window
    best_window_end   TEXT,
    managed         INTEGER,         -- 0/1
    dark_start      TEXT,
    dark_end        TEXT
);
CREATE INDEX IF NOT EXISTS ix_forecasts_night ON forecasts(night_date, site_id);

CREATE TABLE IF NOT EXISTS decisions (
    id          INTEGER PRIMARY KEY,
    recorded_at TEXT NOT NULL,
    night_date  TEXT NOT NULL,
    site_id     TEXT NOT NULL,
    imaged      INTEGER,             -- 1 yes / 0 no / NULL = asked, not yet answered
    reason      TEXT,                -- why not (or a free note when imaged)
    notes       TEXT,
    UNIQUE(night_date, site_id)      -- one decision per night+site (the form upserts)
);

CREATE TABLE IF NOT EXISTS fits_grades (
    id                INTEGER PRIMARY KEY,
    graded_at         TEXT NOT NULL,
    night_date        TEXT NOT NULL,
    site_id           TEXT NOT NULL,
    target            TEXT,
    filter            TEXT,
    n_subs            INTEGER,
    star_count_median REAL,
    star_count_trend  REAL,          -- slope over the session (normalized within target+filter)
    bg_median         REAL,
    transition_class  TEXT,          -- 'stable' / 'gradual-cloud' / 'sudden-artifact' / 'dawn'
    notes             TEXT
);
CREATE INDEX IF NOT EXISTS ix_grades_night ON fits_grades(night_date, site_id);
"""


def connect() -> sqlite3.Connection:
	"""Open (creating the dir + tables if needed) and return a connection. Callers
	close it. Idempotent: re-running the schema is safe and forward-migrates."""
	DB_PATH.parent.mkdir(parents=True, exist_ok=True)
	conn = sqlite3.connect(str(DB_PATH))
	conn.executescript(_SCHEMA)
	return conn


def observing_date(dt_local: datetime) -> str:
	"""The observing-night date (YYYY-MM-DD) for a LOCAL datetime, using the
	standard noon-to-noon convention: a night is labeled by the EVENING it began,
	so we subtract 12 hours before taking the date. This makes a dark window that
	starts after local midnight (e.g. Bainbridge near the solstice, ~12:30 AM)
	still file under the prior evening's date — and makes an 11 PM answer and a
	2 AM answer about the same night resolve to the same key.

	Receives: dt_local — a timezone-AWARE or naive LOCAL datetime.
	Returns: 'YYYY-MM-DD'.
	"""
	return (dt_local - timedelta(hours=12)).date().isoformat()


def _iso_to_local(iso: str | None) -> datetime | None:
	"""Parse the fetcher's UTC ISO string (naive = no offset, or 'Z'/offset) and
	convert to the machine's LOCAL time. None on bad/missing input. The form and
	the grader run on the same machine, so 'local' is consistent across writers."""
	if not isinstance(iso, str) or not iso:
		return None
	s = iso.replace("Z", "+00:00")
	try:
		dt = datetime.fromisoformat(s)
	except ValueError:
		return None
	if dt.tzinfo is None:
		from datetime import timezone as _tz
		dt = dt.replace(tzinfo=_tz.utc)
	return dt.astimezone()  # machine local


def log_run(scoring_output: dict[str, Any], fetched_at: datetime) -> int:
	"""Append one `forecasts` row per (site, night) from a scoring-binary output.

	Best-effort: this is a calibration side-effect and must NEVER break a fetch, so
	any error is swallowed (and reported to stderr). Logging EVERY fetch (4x/day) is
	intentional — it captures how the forecast for a given night evolves through the
	day; a later query picks the last fetch before dark as the 'final' forecast.

	Receives:
	  scoring_output — the parsed JSON from the scoring binary: {sites: [{id, status,
	    nights: [{label, recommendation, broadband:{score,verdict,factors:{...}},
	    narrowband:{score,verdict}, moon:{illumination_pct,max_alt_during_dark},
	    best_window, managed, precip_peak_pct, dark_window:{start,end}}]}]}.
	  fetched_at — the fetch's UTC datetime.
	Returns: number of rows written (0 on any failure).
	"""
	try:
		conn = connect()
	except sqlite3.Error as e:
		sys.stderr.write(f"astrowidget: calibration DB open failed (non-fatal): {e}\n")
		return 0
	rows = 0
	try:
		fetched_iso = fetched_at.isoformat()
		sites = scoring_output.get("sites")
		if not isinstance(sites, list):
			return 0
		for site in sites:
			if not isinstance(site, dict):
				continue
			sid = site.get("id")
			if not sid or site.get("status") != "ok":
				continue
			for night in site.get("nights", []):
				bb = night.get("broadband") or {}
				nb = night.get("narrowband") or {}
				factors = bb.get("factors") or {}
				moon = night.get("moon") or {}
				bw = night.get("best_window") or {}
				dw = night.get("dark_window") or {}
				dark_start = dw.get("start")
				# Join key: observing-night date from the dark-window start (local).
				# Fall back to the fetch instant if there's no dark window.
				ref_local = _iso_to_local(dark_start) or fetched_at.astimezone()
				night_date = observing_date(ref_local)
				conn.execute(
					"""INSERT INTO forecasts (
						fetched_at, night_date, night_label, site_id, recommendation,
						bb_score, bb_verdict, nb_score, nb_verdict,
						cloud, stability, sky_brightness, transparency,
						moon_illum, moon_alt, precip_peak_pct,
						best_window_start, best_window_end, managed, dark_start, dark_end
					) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
					(
						fetched_iso, night_date, night.get("label"), sid,
						night.get("recommendation"),
						bb.get("score"), bb.get("verdict"),
						nb.get("score"), nb.get("verdict"),
						factors.get("cloud"), factors.get("stability"),
						factors.get("skyBrightness"), factors.get("transparency"),
						moon.get("illumination_pct"), moon.get("max_alt_during_dark"),
						night.get("precip_peak_pct"),
						bw.get("start"), bw.get("end"),
						1 if night.get("managed") else 0,
						dark_start, dw.get("end"),
					),
				)
				rows += 1
		conn.commit()
	except Exception as e:  # noqa: BLE001 — best-effort side-effect; see below.
		# Deliberately broad: calibration logging is a non-critical side-effect that
		# must NEVER break a fetch (the user's verdict matters; the log doesn't). It
		# is NOT silent — every failure is reported to stderr / the journal — so this
		# satisfies the "no silent failures" rule while guaranteeing the fetch
		# survives any malformed scoring output or DB hiccup.
		sys.stderr.write(f"astrowidget: calibration log failed (non-fatal): {e}\n")
		return 0
	finally:
		conn.close()
	return rows
