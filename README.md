# astrowidget

A KDE Plasma 6 widget for astrophotographers. At-a-glance go/no-go conditions
for up to three imaging sites tonight (and the next two nights), with verdicts
for broadband and narrowband imaging modes.

Data combines [Astrospheric](https://www.astrospheric.com/) (atmospheric
transparency and seeing — Pro subscription required) with
[Open-Meteo](https://open-meteo.com/) (multi-model cloud cover, precipitation
probability, wind gusts — free, no key).

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

- KDE Plasma 6 (Wayland or X11)
- Python 3.12 or later
- Dart SDK 3.11 or later (for building the scoring binary)
- An [Astrospheric Pro](https://www.astrospheric.com/account) account and API key
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
# Edit the file — add your Astrospheric API key and your sites.

# Run the fetcher once to populate state.json.
~/Claude/astrowidget/fetcher/astrowidget_fetch.py

# Add the plasmoid to your panel: right-click panel → "Add or Manage Widgets" → search "astrowidget".
```

A combined `install.sh` runs all of the above.

## Windows & macOS

The KDE plasmoid is Linux-only, but the fetcher, the scoring engine, and a
cross-platform **Qt 6 desktop window** run on Windows and macOS too. See
**[WINDOWS.md](WINDOWS.md)** for the Windows setup (Task Scheduler scheduling,
toast notifications, and the desktop app), and `desktop/README.md` for the
window itself.

## Configuration

See `config.example.toml` for the full template. Minimum to get running:

1. Set `astrospheric_key` to your Pro API key.
2. Add one or more `[[sites]]` blocks with real lat/lon and a timezone.
3. (Optional) Tune per-site thresholds in `[thresholds.<site_id>]` blocks.
4. (Optional) Adjust `[notifications]` to your taste.

The config file must be `chmod 600`; the fetcher refuses to read world-readable
configs to prevent accidental key disclosure.

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
- KDE Plasma 6 — the platform this widget targets.

## Contributing

Currently a personal project. If you find a bug or want to suggest a feature,
open an issue.

## Privacy

This widget does not send your data anywhere. The fetcher talks only to
Astrospheric (with your key) and Open-Meteo (anonymous). All state is local
under `~/.cache/astrowidget/`. No telemetry, no analytics, no third-party
trackers.
