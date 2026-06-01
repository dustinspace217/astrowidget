# astrowidget — desktop app (cross-platform)

A standalone **Qt 6** window showing the astrowidget forecast on **Windows,
macOS, and Linux** — the same per-site columns, secondary chips, meteograms, and
night-vision mode as the KDE Plasma plasmoid, without needing KDE/Plasma.

It reads the same `state.json` the Python fetcher writes, so the fetcher (and the
Dart scoring binary) must be set up and scheduled first — see the top-level
README. The desktop app is **display only**; it never makes network calls.

## Run it

**Linux** — uses the system Qt 6 `qml` runtime:

```bash
./run.sh
# needs qt6-qtdeclarative (Fedora: sudo dnf install qt6-qtdeclarative)
```

**Windows / macOS / Linux** — via PySide6, which bundles its own Qt 6 (no
separate Qt install):

```bash
pip install PySide6
python3 run.py        # on Windows:  python run.py
```

Both launchers load the identical QML under `qml/`.

## What it shows

- One full column per **primary** site: verdict pill, astro-dark window in your
  local time zone, seeing / transparency / cloud / moon / wind / dew / precip /
  visibility, the broadband + narrowband scores, multi-model cloud convergence,
  vetoes, reasons, and an hourly cloud meteogram.
- **Secondary** sites as collapsed chips along the bottom — click one to expand
  its full column beside the primaries.
- A **Night vision** button (red-on-near-black palette) to preserve dark
  adaptation near a scope.
- Polls `state.json` every 30 seconds; shows a stale indicator after 8 hours.

## Where it reads `state.json`

`<cache>/astrowidget/state.json`, where `<cache>` is Qt's generic cache location
(`~/.cache` on Linux, `%LOCALAPPDATA%` on Windows). **The fetcher must write to
the same place** — on Linux it already does; the Windows fetcher setup aligns the
two.

## Windows scheduling + notifications

The Python fetcher is cross-platform, but the Linux setup uses a systemd timer +
`notify-send`. On Windows it runs under **Task Scheduler** with WinRT toast
notifications, built and scheduled by `windows\install.ps1`. See
**[WINDOWS.md](../WINDOWS.md)** for the full Windows setup.
