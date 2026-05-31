# astrowidget — Project Context for Claude

## What This Is
A KDE Plasma 6 plasmoid that shows astrophotography-specific weather forecasts
for 1–3 configured imaging sites at a glance. Sourced from Astrospheric (Pro
API, transparency + seeing) and Open-Meteo (free, multi-model cloud + precip +
gusts). Verdicts per site: Broadband viable / Narrowband only / Neither.
Notification on transitions including during astro dark (alert is the
imaging-start reminder).

## Tech Stack
- **Fetcher:** Python 3.12+ (Fedora 43 stock), single external dep: `requests`.
- **Scoring:** Dart native binary compiled from astroplan's pure-Dart
  `scoring_engine.dart` via `dart compile exe`. Invoked as a subprocess by the
  Python fetcher.
- **Plasmoid:** QML, Plasma 6 APIs. Compact representation (panel) + full
  representation (popup).
- **Scheduling:** systemd user timer, 4×/day aligned to Astrospheric refresh.

## Key Files
- `docs/superpowers/specs/2026-05-28-astrowidget-design.md` — authoritative
  design spec. Read this before making architectural changes.
- `notes/local-context.md` — Dustin's site-specific data (gitignored).
- `fetcher/astrowidget-fetch.py` — fetcher entry point.
- `plasmoid/space.dustin.astrowidget/` — QML plasmoid package.
- `bin/astrowidget-score` — compiled Dart scoring binary (gitignored;
  built from astroplan).

## Key Commands
- `python3 fetcher/astrowidget-fetch.py` — run fetcher once
- `pytest tests/` — run test suite
- `cd ~/Claude/astroplan && dart compile exe bin/score_location.dart -o ~/Claude/astrowidget/bin/astrowidget-score` — build scoring binary
- `kpackagetool6 --type Plasma/Applet --upgrade plasmoid/space.dustin.astrowidget` — install/upgrade plasmoid
- `systemctl --user enable --now astrowidget-fetch.timer` — enable scheduled fetches

## Conventions
- Python: 4-space indent, comprehensive docstrings, type hints.
- QML: 4-space indent (QML's convention), comments explain non-obvious bindings.
- Comment thoroughly per workspace-level rules — every function explains what,
  why, where data comes from. New language features get inline teaching comments.
- All code must pass `pre-commit` checks before commit (TBD: ruff for Python,
  high-entropy / lat-lon guard).

## Privacy
- The repo is intended for eventual public sharing; nothing personal ships.
- `config.toml`, `state.json`, `notes/`, and `docs/superpowers/` are all
  gitignored. The shipped artifact is `config.example.toml`, code, README,
  LICENSE.
- Pre-commit hook (TBD) refuses commits containing API keys or lat/lon-shaped
  float pairs in non-template files.

## Upstream Coupling
The Dart scoring engine lives in `~/Claude/astroplan`. Changes to its public
surface are breaking changes for astrowidget. See the design spec §16 for the
exact list of load-bearing astroplan files.
