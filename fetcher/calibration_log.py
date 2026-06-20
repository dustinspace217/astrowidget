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
from datetime import datetime, timedelta, timezone
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
    dark_end        TEXT,
    -- Raw forecast READINGS (what Astrospheric / Open-Meteo actually reported),
    -- averaged over the dark window — the enrich_night_factors() displayFactors the
    -- QML shows. Stored next to the SCORES above so calibration can correlate the
    -- actual reads against the lived outcome (FITS grade + decision), not just the
    -- engine's own scores. Forward-only: rows logged before this addition are NULL here.
    seeing_raw         REAL,
    seeing_label       TEXT,
    transparency_raw   REAL,
    transparency_label TEXT,
    st_source          TEXT,         -- 'astrospheric' / '7timer' (OPPOSITE raw scales)
    cloud_pct          INTEGER,
    cloud_low          INTEGER,
    cloud_mid          INTEGER,
    cloud_high         INTEGER,
    wind_kmh           INTEGER,
    gusts_kmh          INTEGER,
    dew_spread_c       REAL,
    precip_pct         INTEGER,
    visibility_km      REAL,
    cloud_spread       INTEGER       -- model cloud-cover disagreement (max - min %)
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
    notes             TEXT,
    dir_date          TEXT,           -- the session FOLDER's date name; the skip pre-filter
                                      -- keys on it (a remote site's folder date differs from
                                      -- the Pacific-computed night_date) — DEF-3b-02.
    source_file_count INTEGER,        -- total FITS files in the folder when graded; the sweep
                                      -- re-grades a night whose folder has GROWN past it, so a
                                      -- partial grade (robocopy still flushing) self-heals — DEF-3b-01.
    -- One grade per night+site+target+filter, so re-grading a night (the daily
    -- sweep, or a manual re-run) REPLACES rather than duplicates.
    UNIQUE(night_date, site_id, target, filter)
);
CREATE INDEX IF NOT EXISTS ix_grades_night ON fits_grades(night_date, site_id);
"""


# Columns ADD-ed to an existing `forecasts` table (CREATE TABLE IF NOT EXISTS cannot
# add columns to a table that already exists). _migrate is PRAGMA-guarded so it's a
# no-op once present. Keep in sync with the raw-reading columns in _SCHEMA above.
_FORECAST_RAW_COLUMNS = [
	("seeing_raw", "REAL"), ("seeing_label", "TEXT"),
	("transparency_raw", "REAL"), ("transparency_label", "TEXT"),
	("st_source", "TEXT"),
	("cloud_pct", "INTEGER"), ("cloud_low", "INTEGER"),
	("cloud_mid", "INTEGER"), ("cloud_high", "INTEGER"),
	("wind_kmh", "INTEGER"), ("gusts_kmh", "INTEGER"),
	("dew_spread_c", "REAL"), ("precip_pct", "INTEGER"),
	("visibility_km", "REAL"), ("cloud_spread", "INTEGER"),
]

# The displayFactors keys log_run reads — an UNWRITTEN contract with the fetcher's
# enrich_night_factors (a separate file). If a producer-side rename drifts from these,
# every .get() in log_run silently yields NULL and the row still "succeeds", quietly
# dropping real readings for weeks. This set lets log_run WARN on drift instead. Keep
# in sync with enrich_night_factors' displayFactors dict.
_EXPECTED_DF_KEYS = frozenset({
	"seeing", "transparency", "source", "cloudPct", "cloudLow", "cloudMid",
	"cloudHigh", "windKmh", "gustsKmh", "dewSpreadC", "precipPct",
	"visibilityKm", "cloudConvergence",
})


# Columns ADD-ed to an existing `fits_grades` table (same reasoning as the forecast
# columns above). dir_date + source_file_count back DEF-3b-02 + DEF-3b-01; both are
# NULL on rows graded before the columns existed, which the grader treats as "unknown"
# (skip the growth check, fall back to night_date for the skip key).
_GRADES_ADDED_COLUMNS = [
	("dir_date", "TEXT"),
	("source_file_count", "INTEGER"),
]


def _migrate(conn: sqlite3.Connection) -> None:
	"""Add any missing columns to a pre-existing DB. A fresh DB already has them from
	_SCHEMA; this catches a DB created before they were added. PRAGMA table_info lists
	the current columns, so ALTER runs only for the missing ones — idempotent, and it
	never touches existing rows (they stay NULL there)."""
	for table, cols in (("forecasts", _FORECAST_RAW_COLUMNS),
						("fits_grades", _GRADES_ADDED_COLUMNS)):
		existing = {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}
		for name, col_type in cols:
			if name not in existing:
				try:
					conn.execute(f"ALTER TABLE {table} ADD COLUMN {name} {col_type}")
				except sqlite3.OperationalError as e:
					# Name the migration + the offending column, so a caller's log doesn't
					# show an opaque "DB open failed" that has to be reverse-engineered.
					raise sqlite3.OperationalError(
						f"calibration migration failed adding {table}.{name}: {e}") from e
	conn.commit()


def connect() -> sqlite3.Connection:
	"""Open (creating the dir + tables if needed) and return a connection. Callers
	close it. Idempotent: re-running the schema is safe and forward-migrates."""
	DB_PATH.parent.mkdir(parents=True, exist_ok=True)
	conn = sqlite3.connect(str(DB_PATH))
	conn.executescript(_SCHEMA)
	_migrate(conn)
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
		dt = dt.replace(tzinfo=timezone.utc)
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
				# Raw readings the QML shows (enrich_night_factors' displayFactors). None
				# when no hourly slice was available — each .get() then yields None → NULL.
				df = night.get("displayFactors") or {}
				# A PRESENT displayFactors that's missing expected keys = producer/consumer
				# key drift (a fetcher-side rename). WARN loudly — otherwise the .get()s
				# below silently NULL real readings for weeks. Fires zero times for the
				# legitimate no-slice case (df is {}, so the `df and` short-circuits).
				if df and not _EXPECTED_DF_KEYS <= df.keys():
					sys.stderr.write(
						"astrowidget: calibration log: displayFactors missing "
						f"{sorted(_EXPECTED_DF_KEYS - df.keys())} — fetcher key drift? "
						"storing NULL for those readings.\n")
				see = df.get("seeing") or {}
				tra = df.get("transparency") or {}
				conv = df.get("cloudConvergence") or {}
				conn.execute(
					"""INSERT INTO forecasts (
						fetched_at, night_date, night_label, site_id, recommendation,
						bb_score, bb_verdict, nb_score, nb_verdict,
						cloud, stability, sky_brightness, transparency,
						moon_illum, moon_alt, precip_peak_pct,
						best_window_start, best_window_end, managed, dark_start, dark_end,
						seeing_raw, seeing_label, transparency_raw, transparency_label,
						st_source, cloud_pct, cloud_low, cloud_mid, cloud_high,
						wind_kmh, gusts_kmh, dew_spread_c, precip_pct, visibility_km,
						cloud_spread
					) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,
							  ?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
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
						see.get("raw"), see.get("label"),
						tra.get("raw"), tra.get("label"),
						df.get("source"), df.get("cloudPct"), df.get("cloudLow"),
						df.get("cloudMid"), df.get("cloudHigh"),
						df.get("windKmh"), df.get("gustsKmh"), df.get("dewSpreadC"),
						df.get("precipPct"), df.get("visibilityKm"),
						conv.get("spread"),
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


# ─────────────────────────────────────────────────────────────────────────────
# Decision-form support (Phase 3 Part 2). These take an open connection (the form
# opens one for its lifetime) and are unit-tested separately from the GUI, which is
# a thin PySide6 shell over them.
# ─────────────────────────────────────────────────────────────────────────────

# Column order returned by latest_forecast(), so callers can read by name.
_FORECAST_KEYS = (
	"recommendation", "bb_score", "nb_score", "cloud", "transparency",
	"moon_illum", "best_window_start", "best_window_end",
)


def latest_forecast(conn: sqlite3.Connection, night_date: str, site_id: str,
					night_label: str = "Tonight") -> dict[str, Any] | None:
	"""The most-recently-fetched forecast row for (night_date, site, label), so the
	form can show tonight's verdict as context. Returns a dict keyed by
	_FORECAST_KEYS, or None if nothing's been logged for that night yet."""
	row = conn.execute(
		"""SELECT recommendation, bb_score, nb_score, cloud, transparency,
				  moon_illum, best_window_start, best_window_end
		   FROM forecasts
		   WHERE night_date = ? AND site_id = ? COLLATE NOCASE AND night_label = ?
		   ORDER BY fetched_at DESC LIMIT 1""",
		(night_date, site_id, night_label),
	).fetchone()
	return dict(zip(_FORECAST_KEYS, row)) if row else None


def upsert_decision(conn: sqlite3.Connection, night_date: str, site_id: str,
					imaged: bool | None, reason: str = "", notes: str = "") -> None:
	"""Insert or update the user's decision for a night+site (one per night+site via
	the UNIQUE constraint). imaged: True/False, or None = pending (asked, not yet
	answered). Re-saving overwrites — answering a previously-pending night works."""
	imaged_val = None if imaged is None else (1 if imaged else 0)
	conn.execute(
		"""INSERT INTO decisions (recorded_at, night_date, site_id, imaged, reason, notes)
		   VALUES (?,?,?,?,?,?)
		   ON CONFLICT(night_date, site_id) DO UPDATE SET
			 recorded_at = excluded.recorded_at, imaged = excluded.imaged,
			 reason = excluded.reason, notes = excluded.notes""",
		(datetime.now(timezone.utc).isoformat(), night_date, site_id,
		 imaged_val, reason, notes),
	)
	conn.commit()


def get_decision(conn: sqlite3.Connection, night_date: str,
				 site_id: str) -> dict[str, Any] | None:
	"""The recorded decision for a night+site as {imaged (0/1/None), reason, notes},
	or None if no row exists. Lets the form PRE-FILL an existing answer when you reopen
	a night, so re-editing edits it instead of silently overwriting with blank defaults
	(which lost a note once)."""
	row = conn.execute(
		"SELECT imaged, reason, notes FROM decisions WHERE night_date = ? AND site_id = ? COLLATE NOCASE",
		(night_date, site_id),
	).fetchone()
	return None if row is None else {"imaged": row[0], "reason": row[1], "notes": row[2]}


def ensure_pending(conn: sqlite3.Connection, night_date: str, site_id: str) -> None:
	"""Create a PENDING (imaged=NULL) decision row for a night+site if none exists,
	so a form closed without answering still leaves a re-promptable record — the
	'respond later' guarantee. No-op if a row (pending OR answered) already exists."""
	conn.execute(
		"""INSERT OR IGNORE INTO decisions (recorded_at, night_date, site_id, imaged)
		   VALUES (?,?,?,NULL)""",
		(datetime.now(timezone.utc).isoformat(), night_date, site_id),
	)
	conn.commit()


def pending_nights(conn: sqlite3.Connection, site_id: str, limit: int = 14,
				   as_of: str | None = None) -> list[str]:
	"""Observing-night dates for a site that have a forecast logged but no ANSWERED
	decision yet (imaged IS NULL, whether that's a pending row or no row at all) — the
	nights the form should still let the user answer. Newest first, capped at `limit`
	so an away stretch doesn't surface forever.

	Excludes nights AFTER `as_of` (default: today's observing date). A fetch logs the
	UPCOMING night as 'Tonight', so just after midnight a night that hasn't started is
	already in `forecasts`; prompting "did you image <a night not yet begun>?" is wrong,
	so only nights that have actually occurred are surfaced. `as_of` is a param (not a
	hard-coded now()) so the decision helpers stay deterministically testable."""
	as_of = as_of or observing_date(datetime.now().astimezone())
	rows = conn.execute(
		"""SELECT DISTINCT f.night_date
		   FROM forecasts f
		   LEFT JOIN decisions d
			 ON d.night_date = f.night_date AND d.site_id = f.site_id COLLATE NOCASE
		   WHERE f.site_id = ? COLLATE NOCASE AND f.night_label = 'Tonight' AND d.imaged IS NULL
			 AND f.night_date <= ?
		   ORDER BY f.night_date DESC LIMIT ?""",
		(site_id, as_of, limit),
	).fetchall()
	return [r[0] for r in rows]
