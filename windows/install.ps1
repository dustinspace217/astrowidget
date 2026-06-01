#Requires -Version 5.1
<#
.SYNOPSIS
	astrowidget Windows installer — the install.sh equivalent for Windows.

.DESCRIPTION
	Builds the Dart scoring binary from the in-repo scoring/ package, creates
	config.toml from the template, registers the 4x/day fetch scheduled task, and
	(optionally) runs the fetcher once. Idempotent: safe to re-run after changes;
	it never clobbers an existing config.toml.

	There is NO plasmoid on Windows — the KDE Plasma widget is Linux-only. On
	Windows the forecast is shown by the cross-platform desktop app
	(desktop\run.py via PySide6); see desktop\README.md and WINDOWS.md.

	Run from anywhere (the script resolves repo paths relative to itself):
	  powershell -ExecutionPolicy Bypass -File .\windows\install.ps1

.PARAMETER NoFetch
	Skip the initial fetcher run (e.g. when the config still has placeholders).
#>
param([switch]$NoFetch)

# Fail fast — any error aborts rather than half-installing.
$ErrorActionPreference = 'Stop'

# Resolve repo paths relative to this script (which lives in windows\), so the
# installer works regardless of the current working directory.
$RepoRoot   = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$ScoringDir = Join-Path $RepoRoot 'scoring'
$BinDir     = Join-Path $RepoRoot 'bin'
$Fetcher    = Join-Path $RepoRoot 'fetcher\astrowidget_fetch.py'
$Example    = Join-Path $RepoRoot 'config.example.toml'
# Matches the fetcher's CONFIG_PATH = Path.home()/.config/astrowidget/config.toml.
$ConfigDir  = Join-Path $env:USERPROFILE '.config\astrowidget'
$ConfigPath = Join-Path $ConfigDir 'config.toml'

# ── Sanity checks — fail loudly on missing prerequisites. ────────────────────
function Require-Command($name, $hint) {
	if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
		throw "astrowidget install: missing required command '$name'. $hint"
	}
}
Require-Command python 'Install Python 3.11+ from python.org (tick "Add python.exe to PATH").'
Require-Command dart   'Install the Dart SDK (or Flutter, which bundles Dart) and add it to PATH.'

# Python >= 3.11 — tomllib (used to parse config.toml) is stdlib only from 3.11.
& python -c "import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)"
if ($LASTEXITCODE -ne 0) {
	throw "astrowidget install: Python 3.11+ required (found $(& python --version 2>&1))."
}
# requests is the fetcher's single external dependency.
& python -c "import requests" 2>$null
if ($LASTEXITCODE -ne 0) {
	throw "astrowidget install: Python 'requests' not found. Install with: pip install requests"
}
# The vendored Dart scoring source must be present (the package is self-contained).
if (-not (Test-Path -LiteralPath (Join-Path $ScoringDir 'bin\score_location.dart'))) {
	throw "astrowidget install: vendored scoring engine missing at $ScoringDir."
}

# ── 1. Build the Dart scoring binary from the self-contained scoring/ package. ─
Write-Host '==> Building Dart scoring binary (from vendored scoring/ engine)...'
# LOAD-BEARING: do NOT switch to `dart compile exe`. The scoring package's
# dependency graph (geoengine) contains build hooks, which `dart compile exe`
# does not support ("use 'dart build' instead"). `dart build cli` is correct and
# emits a standalone binary under bundle/bin/. Mirrors install.sh.
$BuildTmp = Join-Path $env:TEMP 'astrowidget-build'
if (Test-Path -LiteralPath $BuildTmp) { Remove-Item -Recurse -Force $BuildTmp }
Push-Location $ScoringDir
try {
	dart pub get
	if ($LASTEXITCODE -ne 0) { throw 'dart pub get failed.' }
	dart build cli -t bin/score_location.dart -o $BuildTmp
	if ($LASTEXITCODE -ne 0) { throw 'dart build cli failed.' }
} finally {
	Pop-Location
}
# The built executable is score_location.exe on Windows; fall back to a no-suffix
# name defensively in case a future Dart changes the bundle layout.
$Built = Join-Path $BuildTmp 'bundle\bin\score_location.exe'
if (-not (Test-Path -LiteralPath $Built)) {
	$Built = Join-Path $BuildTmp 'bundle\bin\score_location'
}
if (-not (Test-Path -LiteralPath $Built)) {
	throw "astrowidget install: build produced no binary under $BuildTmp\bundle\bin."
}
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
# The fetcher looks for astrowidget-score.exe on Windows (it appends .exe).
Copy-Item -LiteralPath $Built -Destination (Join-Path $BinDir 'astrowidget-score.exe') -Force
Write-Host "    OK: $(Join-Path $BinDir 'astrowidget-score.exe')"

# ── 2. Create config.toml from the template if it doesn't already exist. ──────
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
if (-not (Test-Path -LiteralPath $ConfigPath)) {
	Copy-Item -LiteralPath $Example -Destination $ConfigPath
	# No chmod-600 equivalent is needed: the fetcher skips the POSIX permission
	# check on Windows, and files under %USERPROFILE% are user-private by the
	# default NTFS ACL.
	Write-Host "==> Created $ConfigPath"
	Write-Host '    NOTE: edit it and add your Astrospheric API key + sites.'
} else {
	Write-Host "==> Config already exists, leaving alone: $ConfigPath"
}

# ── 3. Register the 4x/day fetch scheduled task (the systemd-timer equivalent). ─
Write-Host '==> Registering scheduled task...'
& (Join-Path $PSScriptRoot 'register-fetch-task.ps1') -FetcherPath $Fetcher

# ── 4. Initial fetcher run (optional). ───────────────────────────────────────
if (-not $NoFetch) {
	Write-Host '==> Running fetcher once to populate state.json...'
	# Console python here (not pythonw) so any config errors are visible. Don't
	# abort the install on failure — the config likely still has placeholder
	# values; the user gets a clear next-step below.
	& python $Fetcher
	if ($LASTEXITCODE -eq 0) {
		Write-Host '    OK: state.json written'
	} else {
		Write-Host '    NOTE: fetcher exited non-zero (config likely still has'
		Write-Host "    placeholders). Edit $ConfigPath and re-run:"
		Write-Host '      Start-ScheduledTask -TaskName astrowidget-fetch'
	}
}

Write-Host ''
Write-Host 'Install complete. Next steps:'
Write-Host "  1. Edit $ConfigPath with your API key and sites."
Write-Host '  2. Launch the desktop app to see the forecast:'
Write-Host '       pip install PySide6'
Write-Host "       python `"$(Join-Path $RepoRoot 'desktop\run.py')`""
Write-Host '  3. Trigger a manual refresh any time:'
Write-Host '       Start-ScheduledTask -TaskName astrowidget-fetch'
