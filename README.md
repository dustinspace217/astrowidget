# astrowidget

A Widget for astrophotographers. At-a-glance go/no-go conditions
for up to three imaging sites tonight (and the next two nights), with verdicts
for broadband and narrowband imaging modes.

Data combines [Astrospheric](https://www.astrospheric.com/) (atmospheric
transparency and seeing — Pro subscription, **optional**, North America only),
[Open-Meteo](https://open-meteo.com/) (multi-model cloud cover, precipitation
probability, wind gusts — free, no key), and [7Timer!](https://www.7timer.info/)
(free seeing/transparency for sites Astrospheric doesn't cover). Astrospheric is
used automatically where it's available and a key is supplied; everywhere else the
widget runs entirely on the free sources — see
[Data sources & graceful fallback](#data-sources--graceful-fallback).

## Status

Pre-release. Built for personal use. The widget runs end-to-end on Fedora 43
KDE Plasma 6 and may work on other Plasma 6 distributions without modification.

## Features

- **Per-site verdict at a glance** — three colored dots in your Plasma panel,
  one click for full forecast.
- **Broadband / Narrowband / Neither** recommendation per site, per night.
  Same scoring engine the
  [astroplan](https://github.com/dustinspace217/astroplan) mobile app uses.
- **Astro-specific factors** — transparency, seeing, astronomical dark window,
  moon geometry, dew spread — alongside standard weather variables.
- **Multi-model cloud cover** — Open-Meteo lets us pull cloud forecasts from
  GFS, ECMWF, and ICON simultaneously and show model convergence.
- **Astro-dark notification** — fires when astro dark begins at a site with a
  GO verdict. Serves as the imaging-start reminder; you can disable in config.
- **Three nights ahead** — tonight + next two via tabs in the popup. Useful for
  scheduling decisions at remote sites.
- **Night-vision mode** — red-only palette preserves dark adaptation when the
  widget is open near a scope.
- **No background process** — fetcher runs 4×/day on a systemd timer and exits.
  Plasmoid is in `plasmashell` with zero network code.

## Requirements

- KDE Plasma 6 (Wayland or X11) for Linux widget, Ubersicht for Mac,
  Rainmeter for Windows.  There is also a platform-agnostic standalone
  app.
- Python 3.12 or later
- Dart SDK 3.11 or later (for building the scoring binary)
- *(Optional)* An [Astrospheric Pro](https://www.astrospheric.com/account) account
  and API key — adds a North-America-only transparency/seeing feed. Without it, the
  widget uses the free 7Timer + Open-Meteo sources automatically.
- `requests` (`pip install requests`)
- `notify-send` (provided by libnotify on most distributions)

## Installation

```bash
# Build the Dart scoring binary from the self-contained scoring/ package.
# (dart build cli, NOT dart compile exe — geoengine ships native-asset build hooks.)
cd scoring && dart pub get && dart build cli -t bin/score_location.dart -o build
cp build/bundle/bin/score_location ../bin/astrowidget-score && cd ..

# Install the plasmoid package.
cd ~/Claude/astrowidget
kpackagetool6 --type Plasma/Applet --install plasmoid/space.dustin.astrowidget

# Install systemd units.
cp systemd/astrowidget-fetch.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now astrowidget-fetch.timer

# Create your config from the template.
mkdir -p ~/.config/astrowidget
cp config.example.toml ~/.config/astrowidget/config.toml
chmod 600 ~/.config/astrowidget/config.toml
# Edit the file — add your sites (and, optionally, an Astrospheric Pro key).

# Run the fetcher once to populate state.json.
~/Claude/astrowidget/fetcher/astrowidget_fetch.py

# Add the plasmoid to your panel: right-click panel → "Add or Manage Widgets" → search "astrowidget".
```

A combined `install.sh` runs all of the above.

## Desktop widgets per platform

The fetcher and the scoring engine are cross-platform; what differs per OS is the
*widget* that paints `state.json` on your desktop. They all read the **same**
`state.json` the fetcher writes to your OS cache directory, so setup is always:
**(1)** get the fetcher producing `state.json` on a schedule, then **(2)** install
the widget for your platform.

| Platform | Widget | Tech | Folder | `state.json` location |
|----------|--------|------|--------|-----------------------|
| Linux / KDE | Plasma plasmoid | QML | `plasmoid/` | `~/.cache/astrowidget/` |
| Any | Standalone window | Qt 6 / PySide6 | `desktop/` | (same as the OS) |
| Windows | Rainmeter skin | Rainmeter + Lua | `rainmeter/` | `%LOCALAPPDATA%\cache\astrowidget\` |
| macOS | Übersicht widget | HTML/CSS/JS | `ubersicht/` | `~/Library/Caches/astrowidget/` |

The Linux plasmoid is covered under [Installation](#installation); the Qt 6 window
is in `desktop/README.md`. The two desktop-overlay widgets:

### Windows — Rainmeter skin

**Dependencies**
- **Rainmeter** ≥ 4.5 — `winget install -e --id Rainmeter.Rainmeter` (or
  [rainmeter.net](https://www.rainmeter.net)). The skin uses Rainmeter's built-in
  Lua to parse the JSON — **no plugins to install**.
- **Python 3.12+** + the `astrowidget-score.exe` scoring binary, to run the
  fetcher. See **[WINDOWS.md](WINDOWS.md)** to set those up.
- The fetcher must run on a schedule (Task Scheduler) so `state.json` stays fresh.

**Install**
1. Copy the `rainmeter\AstroWidget\` folder into `Documents\Rainmeter\Skins\`.
2. Schedule the fetcher — run it once manually first so `state.json` exists, then
   (every 6 hours; `pythonw.exe` avoids a console flash):
   ```
   schtasks /Create /TN "astrowidget" /TR "\"C:\Path\to\pythonw.exe\" \"C:\Path\to\astrowidget\fetcher\astrowidget_fetch.py\"" /SC HOURLY /MO 6 /F
   ```
3. Right-click the Rainmeter tray icon → **Manage** → select
   `AstroWidget\AstroWidget.ini` → **Load**. Drag to position; lock via the skin's
   right-click menu.

The skin auto-reads `%LOCALAPPDATA%\cache\astrowidget\state.json` (where the
fetcher writes). If you relocated the cache, set `STATEFILE` to an absolute path in
the skin's `[Variables]`. The Lua parser has an offline test:
`cd rainmeter\AstroWidget\@Resources\Scripts && lua test_state.lua`.

### macOS — Übersicht widget

**Dependencies**
- **Übersicht** — `brew install --cask ubersicht` (or
  [tracesof.net/uebersicht](https://tracesof.net/uebersicht/)). macOS 12+. The
  widget is plain JS/CSS — Übersicht bundles its own renderer, so **no Node/npm
  and no build step**.
- **Python 3.12+** + the `astrowidget-score` scoring binary, to run the fetcher.
- The fetcher must run on a schedule (launchd) so `state.json` stays fresh.

**Install**
1. Copy `ubersicht/astrowidget.widget/` into
   `~/Library/Application Support/Übersicht/widgets/`. It appears on the desktop
   immediately (use the menu-bar icon → **Refresh All Widgets** if not).
2. Schedule the fetcher with a LaunchAgent. Create
   `~/Library/LaunchAgents/space.dustin.astrowidget.plist` (use **absolute** paths
   — launchd does not load your shell profile or a venv's `python3`):
   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0"><dict>
     <key>Label</key><string>space.dustin.astrowidget</string>
     <key>ProgramArguments</key>
     <array>
       <string>/usr/bin/python3</string>
       <string>/Users/USERNAME/path/to/astrowidget/fetcher/astrowidget_fetch.py</string>
     </array>
     <key>StartInterval</key><integer>21600</integer>  <!-- every 6h -->
     <key>RunAtLoad</key><true/>
   </dict></plist>
   ```
   Load it: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/space.dustin.astrowidget.plist`

The widget reads `~/Library/Caches/astrowidget/state.json` (where the fetcher
writes). Both widgets degrade gracefully if the file is missing or mid-write — they
show a "waiting" placeholder and self-heal on the next refresh.

## Configuration

See `config.example.toml` for the full template. Minimum to get running:

1. Add one or more `[[sites]]` blocks with real lat/lon and a timezone.
2. *(Optional)* Set `astrospheric_key` to your Pro API key — adds the
   North-America transparency/seeing feed. Blank = run entirely on free sources.
3. (Optional) Tune per-site thresholds in `[thresholds.<site_id>]` blocks.
4. (Optional) Adjust `[notifications]` to your taste.

The config file must be `chmod 600`; the fetcher refuses to read world-readable
configs to prevent accidental key disclosure.

## Data sources & graceful fallback

The widget pulls from up to three forecast sources and degrades gracefully when
any is unavailable:

| Source | Cost | Coverage | Provides |
|---|---|---|---|
| **Open-Meteo** | Free | Global | Multi-model cloud, precip, wind/gusts, visibility, temp/dewpoint |
| **7Timer!** | Free | Global | Seeing & transparency (NCEP GFS-derived) |
| **Astrospheric** | Pro key | North America | Higher-quality transparency, seeing, RDPS cloud |

**Astrospheric eligibility is automatic, derived from each site's lat/lon** — there
is no per-site flag. A site inside Astrospheric's North-America coverage uses it
*if you've supplied a key*; every other site (and every site, if you supply no key)
runs on the free 7Timer + Open-Meteo path. The widget never hard-fails for want of
a key.

When an in-coverage site's Astrospheric fetch fails — no key, a rejected key, or an
outage — the site **transparently falls back to the free sources** and shows a
small, dismissable red notice under its astro-dark line, e.g. *"Astrospheric data
failed (HTTP 403) — using Open-Meteo data."*, with a **"Don't show this again"**
button that suppresses that specific site + failure reason (a *different* failure
at the same site will still surface). Sites outside coverage fall back silently —
there was never anything to warn about.

## Notification rules

| Trigger | Default |
|---|---|
| Tonight's verdict improves (Neither → NB, NB → BB+NB) | ON |
| Tonight's verdict degrades, day-of | ON |
| Astro dark begins at a site with a GO verdict | ON |
| Suppress all notifications during astro dark | OFF |

The astro-dark-begins notification is the imaging-start reminder. It is not
suppressed during dark hours by default — that's the point of it.

## Project structure

```
astrowidget/
├── fetcher/                              # Python fetcher (Astrospheric + Open-Meteo)
├── scoring/                              # Vendored, self-contained Dart scoring engine
├── bin/                                  # Compiled Dart scoring binary (gitignored)
├── plasmoid/space.dustin.astrowidget/    # QML plasmoid package (Linux / Plasma)
├── desktop/                              # Cross-platform Qt 6 desktop app (Win/macOS/Linux)
├── rainmeter/AstroWidget/                # Rainmeter skin + Lua JSON parser (Windows)
├── ubersicht/astrowidget.widget/         # Übersicht widget (macOS desktop overlay)
├── forms/                                # Nightly decision form (calibration capture)
├── grader/                               # FITS auto-grader (calibration ground truth)
├── systemd/                              # User-level systemd unit files (Linux)
├── windows/                              # Windows installer + Task Scheduler script
├── tests/                                # pytest suite
├── docs/design/                          # Public design documentation
├── config.example.toml                   # Configuration template
├── install.sh                            # Linux all-in-one installer
├── WINDOWS.md                            # Windows / macOS setup guide
├── LICENSE                               # GPL-3.0-or-later
└── README.md
```

## How it works

```
systemd timer (4×/day)
    │
    ▼
Python fetcher
    │  POST to Astrospheric (5 credits/call)  ──► transparency, seeing
    │  GET from Open-Meteo (free)             ──► precip, cloud layers, gusts
    │
    ▼
Dart scoring binary (subprocess)
    │  scoreLocation(site, hourly, mode=broadband)
    │  scoreLocation(site, hourly, mode=narrowband)
    │  Computes moon geometry + astro dark window locally
    │
    ▼
state.json (atomic write)
    │
    ▼
QML plasmoid reads state.json (no network, no secrets)
```

## Calibration & auto-grading (Phase 3, in progress)

The scoring weights are physics-derived defaults. To re-tune them against real
outcomes over time, astrowidget builds a labeled dataset in a local SQLite DB
(`~/.local/share/astrowidget/astrowidget.db`):

- **Forecast log** — the fetcher appends every run's verdict + factor scores
  (`forecasts` table). Automatic.
- **Nightly decision form** (`forms/nightly_decision.py`) — a small tkinter form
  fired ~11 PM (`systemd/astrowidget-decision.{service,timer}`) that asks whether
  you imaged your HOME site tonight and, if not, why. This captures the nights you
  *skipped* — the survivorship-bias half the FITS can't show. Persistent: it
  surfaces any night you haven't answered yet.
- **FITS auto-grader** (`grader/`) — grades a session's subs by a star-count proxy
  (transparency ground truth, normalized within target + filter) and classifies the
  trend per the rule *gradual decline = cloud/dawn (dawn excluded by twilight),
  sudden cliff = mechanical artifact (flagged, not fed to weather calibration)*.
  - **Automatic (daily sweep):** a `systemd` timer
    (`systemd/astrowidget-grade.{service,timer}`, ~9 AM local) runs
    `grade.py --scan <Raws-root> --site Bainbridge --write`, which walks the
    `Raws/<Target>/<Rig>/<date>/` tree and grades every complete, not-yet-graded
    night. It **polls** rather than watching the folder: the raws live on a network
    (CIFS) share written by the capture PC, and `inotify` does not fire for remote
    writes — so a watcher would never trigger. Idempotent (already-graded nights are
    skipped), bounded to the last 30 days by default (`--since-days 0` to backfill).
  - **Manual (one session):**
    `python grader/grade.py <session-folder> --site Bainbridge --write`.

The three join on observing-night date + site. Re-tuning the weights from the
accumulated data is a later step (it needs weeks of paired records first).

## License

`astrowidget` is released under the **GNU General Public License v3.0 or later**.
See `LICENSE` for the full text.

The Dart scoring engine under `scoring/` is **vendored** (a frozen copy) from
the author's separate `astroplan` project — astrowidget reuses its ideas and
methods but is a fully independent application with no build- or run-time
dependency on astroplan. See `scoring/VENDORED.md`.

## Acknowledgments

- Forecast data from [Astrospheric](https://www.astrospheric.com/) (Pro
  subscription) and [Open-Meteo](https://open-meteo.com/) (data under
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)).
- Scoring engine vendored from the author's
  [astroplan](https://github.com/dustinspace217/astroplan) project (same author,
  GPL-compatible).
- KDE Plasma 6, Rainmeter, and Übersicht — the desktop-widget hosts.
- The Rainmeter skin bundles [`rxi/json.lua`](https://github.com/rxi/json.lua)
  (MIT) to parse `state.json`, since Rainmeter's Lua has no JSON library.

## Contributing

Currently a personal project. If you find a bug or want to suggest a feature,
open an issue.

## Privacy

This widget does not send your data anywhere. The fetcher talks only to
Astrospheric (with your key) and Open-Meteo (anonymous). All state is local
under `~/.cache/astrowidget/`. No telemetry, no analytics, no third-party
trackers.
