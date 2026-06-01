# astrowidget on Windows

The KDE Plasma plasmoid is Linux-only, but the rest of astrowidget is
cross-platform. On Windows you get the same forecast through a standalone
**Qt 6 desktop window** instead of a panel widget, with the Python fetcher
running on **Task Scheduler** instead of a systemd timer.

This is the Windows-specific path. For what the app shows and how the scoring
works, see the main [README](README.md). (macOS notes are at the bottom.)

## What's different from the Plasma version

| | Linux / Plasma | Windows |
|---|---|---|
| UI | KDE panel plasmoid | Standalone Qt 6 window (`desktop\run.py`) |
| Scheduler | systemd user timer | Task Scheduler (`astrowidget-fetch`) |
| Notifications | `notify-send` (libnotify) | WinRT toast (built-in PowerShell) |
| Scoring binary | `bin/astrowidget-score` | `bin\astrowidget-score.exe` |
| Cache (`state.json`) | `~/.cache/astrowidget\` | `%LOCALAPPDATA%\cache\astrowidget\` |
| Config | `~/.config/astrowidget\` | `%USERPROFILE%\.config\astrowidget\` |

The fetcher, the scoring engine, and the QML UI are otherwise identical.

## Prerequisites

- **Windows 10 or 11.**
- **Python 3.11+** — from [python.org](https://www.python.org/downloads/), with
  **"Add python.exe to PATH"** ticked during install.
- **Dart SDK 3.11+** — from [dart.dev](https://dart.dev/get-dart) (or Flutter,
  which bundles Dart), on PATH. Needed once, to build the scoring binary.
- **`requests`** — `pip install requests`.
- **PySide6** — `pip install PySide6` (bundles its own Qt 6; this *is* the
  desktop window).
- An **[Astrospheric Pro](https://www.astrospheric.com/account)** API key.

## Quick install

From the repo root, in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\install.ps1
```

`install.ps1` does all of the following:

1. Checks Python 3.11+, Dart, and `requests`.
2. Builds the Dart scoring binary (`dart build cli`) → `bin\astrowidget-score.exe`.
3. Creates `%USERPROFILE%\.config\astrowidget\config.toml` from the template
   (only if it doesn't already exist).
4. Registers the `astrowidget-fetch` scheduled task (4×/day).
5. Runs the fetcher once to populate `state.json`.

Then **edit the config** with your API key and sites:

```powershell
notepad $env:USERPROFILE\.config\astrowidget\config.toml
```

…and **launch the window**:

```powershell
pip install PySide6
python .\desktop\run.py
```

## The scheduled task

`install.ps1` registers a per-user task named **`astrowidget-fetch`** that runs
the fetcher four times a day (local 00:10 / 06:10 / 12:10 / 18:10). Re-running
`windows\register-fetch-task.ps1` re-registers it.

```powershell
Start-ScheduledTask      -TaskName astrowidget-fetch              # run now
Get-ScheduledTaskInfo    -TaskName astrowidget-fetch             # last/next run
Unregister-ScheduledTask -TaskName astrowidget-fetch -Confirm:$false  # remove
```

**Why "run only when user is logged on":** the task uses the *Interactive* logon
type on purpose. Toast notifications only display inside your logged-in session —
a task set to "run whether logged on or not" runs in Session 0, where the toast
is created but never shown. Keep the default.

> Unlike the Linux timer (UTC-aligned to Astrospheric's 6-hourly model refresh),
> the Windows triggers are four fixed *local* times. The forecast still updates
> 4×/day; depending on your timezone it may read a model run a couple hours old,
> which is negligible for a multi-night forecast.

## Notifications

Verdict transitions (and config errors) raise a Windows **toast** via the
built-in WinRT API driven by PowerShell — no extra module to install. If toasts
don't appear:

1. Confirm the task is **"Run only when user is logged on"** (see above).
2. Check **Settings → System → Notifications** is on for "Windows PowerShell"
   (toasts are attributed to PowerShell's built-in app identity).
3. The one detail that couldn't be tested ahead of time is the `-Sta` flag in
   `_notify_windows`; if toasts still don't show, try removing it.

The toast source reads "Windows PowerShell" rather than "astrowidget" — a branded
app identity is future polish; a toast that *reliably appears* was the priority.

## Manual install (without install.ps1)

```powershell
# 1. Build the scoring binary (dart build cli, NOT dart compile exe —
#    geoengine ships native-asset build hooks that dart compile exe can't run).
cd scoring
dart pub get
dart build cli -t bin/score_location.dart -o build
copy build\bundle\bin\score_location.exe ..\bin\astrowidget-score.exe
cd ..

# 2. Create the config, then edit it (add your Astrospheric key + sites).
mkdir $env:USERPROFILE\.config\astrowidget
copy config.example.toml $env:USERPROFILE\.config\astrowidget\config.toml

# 3. Register the scheduled task.
powershell -ExecutionPolicy Bypass -File .\windows\register-fetch-task.ps1

# 4. Run once, then launch the window.
python .\fetcher\astrowidget_fetch.py
pip install PySide6
python .\desktop\run.py
```

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Window says "No data yet" | The fetcher hasn't run, or wrote elsewhere. Run `python .\fetcher\astrowidget_fetch.py` and confirm it writes `%LOCALAPPDATA%\cache\astrowidget\state.json`. |
| Window shows stale data | Trigger a refresh: `Start-ScheduledTask -TaskName astrowidget-fetch`. |
| No toasts | Task must be "run only when user is logged on" — see **Notifications**. |
| "scoring binary not found" | Re-run `install.ps1`, or build it manually (above). The fetcher looks for `bin\astrowidget-score.exe`. |
| A console flashes 4×/day | The task should run `pythonw.exe`; re-run `register-fetch-task.ps1` (it prefers pythonw). |
| "running scripts is disabled" | Use the `-ExecutionPolicy Bypass` flag shown above — it applies to that one run only and doesn't change your machine's policy. |

## macOS

There's no macOS installer, but the pieces work: the desktop window runs the same
way (`pip install PySide6` then `python desktop/run.py`), notifications use
`osascript`, and the fetcher writes to Qt's macOS cache location
(`~/Library/Caches/astrowidget/`). Schedule the fetcher yourself with `cron` or a
`launchd` agent (the systemd timer in `systemd/` is the model for the cadence:
4×/day). Build the scoring binary exactly as on Linux — `bin/astrowidget-score`,
no `.exe`.
