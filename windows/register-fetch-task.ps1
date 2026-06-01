#Requires -Version 5.1
<#
.SYNOPSIS
	Registers (or updates) the astrowidget fetch scheduled task on Windows — the
	Task Scheduler equivalent of the Linux systemd user timer + service.

.DESCRIPTION
	Creates a per-user task "astrowidget-fetch" that runs the Python fetcher 4x
	per day. Re-running overwrites the existing task (idempotent), the same way
	`systemctl --user enable` is on Linux.

	TWO things here are load-bearing and were chosen deliberately:

	1. LogonType = Interactive ("run only when user is logged on"). The fetcher
	   emits WinRT toast notifications; a toast is only DISPLAYED when the task
	   runs inside the logged-in user's interactive session. A task set to "run
	   whether logged on or not" executes in Session 0, where the toast is
	   created but never shown (Session 0 isolation). Interactive also means no
	   stored password is needed — it uses the user's existing session token.

	2. pythonw.exe (windowless) is preferred over python.exe so the 4x/day run
	   doesn't flash a console window. The fetcher guards against pythonw's
	   None stdout/stderr; its important errors still surface as toasts and as
	   stale data in the widget. To see detailed output, run the fetcher
	   manually: `python <repo>\fetcher\astrowidget_fetch.py`.

	Unlike the Linux timer (UTC-aligned to Astrospheric's 6-hourly refresh), the
	triggers here are four FIXED LOCAL times (00:10, 06:10, 12:10, 18:10). The
	forecast still updates 4x/day; depending on your timezone it may read a model
	run a couple hours old, which is negligible for a multi-night forecast — and
	it avoids fragile UTC/DST DateTime math in PowerShell.

.PARAMETER FetcherPath
	Path to astrowidget_fetch.py. Defaults to ..\fetcher\ relative to this script.

.PARAMETER PythonExe
	Python executable to run the fetcher. Defaults to auto-detect (pythonw.exe,
	then python.exe) on PATH.

.PARAMETER TaskName
	Scheduled task name. Defaults to "astrowidget-fetch".

.EXAMPLE
	powershell -ExecutionPolicy Bypass -File .\windows\register-fetch-task.ps1
#>
param(
	[string]$FetcherPath = (Join-Path $PSScriptRoot '..\fetcher\astrowidget_fetch.py'),
	[string]$PythonExe = '',
	[string]$TaskName = 'astrowidget-fetch'
)

# Fail fast: any cmdlet error aborts the script rather than half-registering.
$ErrorActionPreference = 'Stop'

# Validate BEFORE resolving: with $ErrorActionPreference='Stop', Resolve-Path on
# a missing path throws its own generic terminating error first, which would
# make the friendly message below unreachable. So check existence, then resolve
# to an absolute path (the fetcher resolves bin/ and config paths from __file__,
# so the task needs no working directory set — only an absolute path here).
if (-not (Test-Path -LiteralPath $FetcherPath)) {
	throw "astrowidget: fetcher not found at $FetcherPath"
}
$FetcherPath = (Resolve-Path -LiteralPath $FetcherPath).Path

# Pick the Python to run the task with. Prefer pythonw.exe (no console window);
# fall back to python.exe. Get-Command returns the absolute path Task Scheduler
# needs (its environment may not resolve a bare 'python' the same way a shell
# does).
if (-not $PythonExe) {
	$cmd = Get-Command pythonw.exe -ErrorAction SilentlyContinue
	if (-not $cmd) { $cmd = Get-Command python.exe -ErrorAction SilentlyContinue }
	if (-not $cmd) {
		throw "astrowidget: neither pythonw.exe nor python.exe found on PATH. Install Python 3.11+ from python.org with 'Add python.exe to PATH'."
	}
	$PythonExe = $cmd.Source
}

# ── Action: run the fetcher. The path is quoted in case it contains spaces. ──
$action = New-ScheduledTaskAction -Execute $PythonExe -Argument ('"{0}"' -f $FetcherPath)

# ── Triggers: four daily local-time fires ~6h apart. [datetime]::Today is local
#    midnight; AddHours/AddMinutes set the time of day, which -Daily then uses. ──
$triggers = @(0, 6, 12, 18 | ForEach-Object {
	New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.AddHours($_).AddMinutes(10))
})

# ── Principal: run as the current user, in their interactive session (so toasts
#    show), with least privilege (no admin needed for the fetch). ──
$userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited

# ── Settings: laptop-friendly (run on battery, don't stop on battery), run a
#    missed fire ASAP (StartWhenAvailable ≈ systemd Persistent=true), and cap a
#    hung fetch at 5 minutes. ──
$settings = New-ScheduledTaskSettingsSet `
	-AllowStartIfOnBatteries `
	-DontStopIfGoingOnBatteries `
	-StartWhenAvailable `
	-ExecutionTimeLimit (New-TimeSpan -Minutes 5)

# ── Register (overwrite if it already exists). -Force makes this idempotent. ──
Register-ScheduledTask `
	-TaskName $TaskName `
	-Action $action `
	-Trigger $triggers `
	-Principal $principal `
	-Settings $settings `
	-Force | Out-Null

Write-Host "astrowidget: scheduled task '$TaskName' registered."
Write-Host "  Runs:    $PythonExe `"$FetcherPath`""
Write-Host "  As:      $userId (interactive — toasts will display)"
Write-Host "  When:    daily at 00:10, 06:10, 12:10, 18:10 (local time)"
Write-Host ""
Write-Host "  Test now:   Start-ScheduledTask -TaskName $TaskName"
Write-Host "  Inspect:    Get-ScheduledTaskInfo -TaskName $TaskName"
Write-Host "  Remove:     Unregister-ScheduledTask -TaskName $TaskName -Confirm:`$false"
