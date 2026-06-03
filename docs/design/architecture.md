# astrowidget — Architecture Overview (public)

This document is a high-level architectural summary intended for public
consumption. For the full design spec (including risk analysis, decision
rationale, and component interfaces), see the internal spec under
`docs/superpowers/` (gitignored).

## Three-tier split

```
┌─────────────────────────────────────────────────────────────────┐
│  systemd user timer (4×/day, UTC-aligned to API refresh)        │
│                                ▼                                │
│  Python fetcher (no persistent process):                        │
│    ┌─── Astrospheric Pro API ──── transparency, seeing,         │
│    │    (POST, 5 credits/call)    RDPS cloud cover              │
│    └─── Open-Meteo API ─────────── cloud cover (multi-model),   │
│         (GET, free, no key)       precip prob, gusts,           │
│                                    visibility, temp, dewpoint   │
│                                ▼                                │
│  Dart scoring binary (subprocess, from vendored scoring/):      │
│    - scoreLocation() × 2 per site (broadband, narrowband)       │
│    - Moon geometry + astro dark window computed locally         │
│                                ▼                                │
│  ~/.cache/astrowidget/state.json (atomic write)                 │
│  notify-send on verdict transitions                             │
└─────────────────────────────────────────────────────────────────┘
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│  KDE Plasmoid (QML):                                            │
│    - compact: per-site colored dots in panel                    │
│    - full: popup with per-site columns, meteogram, factor detail│
│  Reads state.json via QFileSystemWatcher; no network code.      │
└─────────────────────────────────────────────────────────────────┘
```

## Why this split

- **Decoupling.** A flaky API never freezes your Plasma panel; a QML reload
  never burns API credits; the fetcher exits between runs and consumes zero
  steady-state resources.
- **Secret isolation.** The Astrospheric key lives in `~/.config/astrowidget/`
  (perms 0600), readable only by the Python fetcher. The Dart binary and QML
  package never see it.
- **Scoring reuse.** The Dart binary is built from the vendored `scoring/`
  package — a frozen, self-contained copy of the `scoreLocation()` engine the
  `astroplan` app also uses (see `scoring/VENDORED.md`). astrowidget has no
  build- or run-time dependency on astroplan; the binary is invoked as a
  subprocess, and the fetcher is otherwise scoring-agnostic.

## Data sources & graceful fallback

The fetcher draws on up to three forecast sources (the diagram above simplifies
this to two). **Astrospheric is optional**; the free sources cover every site:

| Source | Cost | Coverage | Provides |
|---|---|---|---|
| **Open-Meteo** | Free | Global | Multi-model cloud, precip, wind/gusts, visibility, temp/dewpoint |
| **7Timer!** | Free | Global | Seeing & transparency (NCEP GFS-derived) |
| **Astrospheric** | Pro key | North America | Higher-quality transparency, seeing, RDPS cloud |

Astrospheric eligibility is **derived automatically from each site's lat/lon** —
there is no per-site flag. In-coverage sites use it when a key is present;
everything else (and everything, if no key is set) runs on 7Timer + Open-Meteo.
When an in-coverage site's Astrospheric call fails (no key / rejected key /
outage), it falls back to the free sources and surfaces a small dismissable notice
in the UI; out-of-coverage sites fall back silently. The widget never hard-fails
for want of a key.

## Recommendation algorithm

For each site, for each of the next three nights:

1. Run `scoreLocation()` with `ImagingMode.broadband`.
2. Run `scoreLocation()` with `ImagingMode.narrowband`.
3. Each call returns a verdict (Excellent / Good / Marginal / Poor / Don't Bother)
   and any safety vetoes that fired (cloud >95%, precip, wind, dew).
4. If both pass (verdict ≥ Marginal, no vetoes) → **BB+NB**.
5. Else if only narrowband passes → **NB only**.
6. Else → **Neither**.

The scoring engine handles the broadband/narrowband distinction internally:
its moon and darkness weights drop to near zero under narrowband, reflecting
that narrowband filters reject ~99% of moonlight.

> **Being redesigned (2026).** The algorithm above is the *current* behavior; a
> redesign is in progress (see the next section).

## Planned: scoring redesign & per-site modes

A scoring redesign is underway (2026), driven by validating the engine against
real captured-frame outcomes rather than theory. Highlights, for anyone building
on this:

- **Two per-site scoring modes, set by a `managed` config flag:**
  - `managed = false` (default — a **home / backyard** site): the imager gambles on
    partly-cloudy nights for clear gaps, so the score reports the **chance of a
    usable clear window** instead of a hard cloud gate, and makes **precipitation a
    hard veto**. Partial cloud degrades the score but never forces "Neither".
  - `managed = true` (a **remote / hosted** site whose dome opens only when clear):
    a clean **go / no-go** verdict.
- **Honest broadband/narrowband:** green means *genuinely good*; "NB only" when the
  moon or light pollution compromises broadband but the sky is otherwise usable.
- **Factor changes:** the always-100 astronomical-darkness factor is removed from
  the weighted score (it carried no per-night information and inverted BB vs NB); a
  geometry-aware moon model (illumination × altitude, ~zero when the moon is below
  the horizon) feeds a sky-brightness factor alongside **per-site Bortle**;
  transparency, jet-stream seeing, aerosol/smoke, and snow-albedo are added.
- **Bortle** is auto-derived from the site's lat/lon (light-pollution lookup), with
  an optional per-site `bortle` config override.
- **FITS auto-grader:** an offline tool grades each captured session's frames
  (star-count / background, normalized within target + filter) against that night's
  forecast, accumulating a labeled calibration dataset over time — the ground truth
  where forecasts miss thin/uniform cloud. Gradual star-count decline reads as
  cloud or dawn; a sudden cliff reads as a mechanical/obstruction artifact.
- **Future:** a local API endpoint to feed a live Sky Quality Meter reading
  directly into the sky-brightness score.

The full design spec lives in the gitignored internal `docs/superpowers/` tree.

## Notification model

The fetcher diffs the new `state.json` against the previous run's. It fires
`notify-send` when:

- Tonight's verdict transitions upward (improvement)
- Tonight's verdict degrades day-of (you're about to image, conditions tanked)
- Astronomical dark begins at a site with a GO verdict (imaging-start reminder)

All three are user-configurable.

## Update cadence

Astrospheric refreshes its forecast every 6 hours, so the fetcher runs four
times per day at 00:10 / 06:10 / 12:10 / 18:10 UTC. Each run costs 5 Astrospheric
credits per site (60 credits/day for 3 sites, under the 100/day Pro budget) and
~3 Open-Meteo calls per site (24 calls/day, far under the 10,000/day free limit).

## Storage

- `~/.config/astrowidget/config.toml` — user configuration (0600 perms,
  never committed, contains the API key and per-site coordinates).
- `~/.cache/astrowidget/state.json` — current forecast state, atomically
  rewritten by every fetcher run.
- `~/.cache/astrowidget/state.prev.json` — prior state, for diff-based
  notifications.
- `~/Claude/astrowidget/bin/astrowidget-score` — compiled Dart binary
  (gitignored; built from the astroplan source).

No telemetry, no analytics, no remote logging.
