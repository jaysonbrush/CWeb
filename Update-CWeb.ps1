#Requires -Version 7.0
<#
.SYNOPSIS
    Updates CWeb on this machine: stops the running instances (after asking), pulls the new version, runs setup, and
    starts again the instances that were running.

.DESCRIPTION
    1. Checks for a new version (git fetch). Already up to date: stops nothing and exits.
    2. Lists the running instances and the agents working in them, and asks before stopping them (-Yes: doesn't ask).
    3. Stops each one the way the status page's Stop server does (Chrome closes cleanly, sign-ins are kept). Only if
       that fails does it ask to force-stop the server.
    4. git pull --ff-only (never merges or overwrites local changes).
    5. Setup-CWeb.ps1 from the new version: the pinned Chrome, data folder moves, the self-check.
    6. Starts the instances that were running before and prints their status pages.

.EXAMPLE
    pwsh -File .\Update-CWeb.ps1          # asks before stopping anything
    pwsh -File .\Update-CWeb.ps1 -Yes     # for scripts: stops, updates and restarts without asking
#>
param(
    [switch]$Yes   # don't ask before stopping instances (or before force-stopping one that won't stop)
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path $root 'CWeb-Common.ps1')

function Say($msg, $color = 'Gray') { Write-Host $msg -ForegroundColor $color }
function Step($msg) { Write-Host ''; Write-Host "== $msg" -ForegroundColor Cyan }
function Confirm-CWeb($question) {
    if ($Yes) { return $true }
    try { $a = Read-Host "$question [y/N]" } catch { return $false }   # no console to ask on: treat as no
    return $a -match '^(y|yes)$'
}
function Invoke-Git { & git.exe -C $root @args 2>&1; if ($LASTEXITCODE) { throw "git $($args -join ' ') failed (exit $LASTEXITCODE)." } }

function Get-RunningInstances {
    # Instances of this machine whose server runs, with what the user should know before they're stopped. One that runs
    # but doesn't answer is listed too (NotAnswering): it has to be stopped before the update all the same.
    foreach ($name in @((Get-CWebInstanceTable -Root $root).Keys)) {
        $i = Get-CWebInstance -Name $name -Root $root
        $st = Get-CWebRunningServer -Instance $i
        if (-not $st) {
            $info = Get-CWebServerInfo -ServerFile $i.ServerFile
            if ($info) { [pscustomobject]@{ Instance = $i; Port = [int]$info.port; Tabs = '?'; Agents = @(); NotAnswering = $true } }
            continue
        }
        $agents = @($st.tabUse.PSObject.Properties | ForEach-Object { $_.Value.owner; $_.Value.users } | Where-Object { $_ } | Sort-Object -Unique)
        [pscustomobject]@{ Instance = $i; Port = [int]$st.server.port; Tabs = [int]$st.browser.tabCount; Agents = $agents; NotAnswering = $false }
    }
}

function Stop-Instance($r) {
    # The status page's Stop server: closes Chrome cleanly (sign-ins kept), then the server exits.
    $p = $r.Port
    if (-not $r.NotAnswering) {
        try {
            Invoke-RestMethod "http://127.0.0.1:$p/status/stopserver" -Method POST -ContentType 'application/json' -Body '{}' `
                -Headers @{ 'X-Status-Request' = '1'; 'Origin' = "http://127.0.0.1:$p" } -TimeoutSec 30 | Out-Null
        } catch { }
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $deadline) {
            if (-not (Test-CWebServerProcess -Instance $r.Instance)) { Say "  Stopped $($r.Instance.Name)."; return $true }
            Start-Sleep -Seconds 1
        }
    }
    $info = Get-CWebServerInfo -ServerFile $r.Instance.ServerFile
    if (-not $info) { Say "  Stopped $($r.Instance.Name)."; return $true }
    Say "  $($r.Instance.Name) $(if ($r.NotAnswering) { "isn't answering" } else { "didn't stop within 30 seconds" })." Yellow
    if (-not (Confirm-CWeb "  Force-stop the $($r.Instance.Name) server (process $($info.pid))? Its Chrome window is closed first, cleanly.")) { return $false }
    # Chrome first, the way its own Exit does (session saved, no "didn't shut down correctly" on the next start).
    Stop-CWebServerProcess -Instance $r.Instance -Root $root | Out-Null
    Say "  Force-stopped $($r.Instance.Name)."
    return $true
}

function Start-Instances($list) {
    # Starts the instances that were running, with the CWeb code now on disk (re-read: the pull may have changed it).
    if (-not $list) { return }
    . (Join-Path $root 'CWeb-Common.ps1')
    Step 'Starting the instances that were running'
    foreach ($r in $list) {
        try {
            $i = Get-CWebInstance -Name $r.Instance.Name -Root $root
            $st = Start-CWebServer -Instance $i -Root $root
            Say "  $($i.Name): http://127.0.0.1:$($st.server.port)/status$(if (-not $st.browser.running) { "  (Chrome didn't start: $($st.browser.startError))" })" $(if ($st.browser.running) { 'Green' } else { 'Yellow' })
        } catch { Say "  $($r.Instance.Name) didn't start: $($_.Exception.Message)" Red }
    }
}

Say "CWeb update -- $(try { (Get-Content (Join-Path $root 'VERSION') -Raw).Trim() } catch { '?' }) -- $env:COMPUTERNAME" White
Say "  Folder: $root"

# ================================ Is there a new version? ================================
Step 'Checking for a new version'
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git is not installed. Install it (winget install --id Git.Git), or download the new CWeb and run Setup-CWeb.cmd.' }
& git.exe -C $root rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE) { throw "$root isn't a git clone, so it can't update itself. Download the new CWeb into this folder and run Setup-CWeb.cmd." }
$changed = @(Invoke-Git status --porcelain --untracked-files=no)
if ($changed.Count) {
    throw "CWeb files in $root were changed here, so pulling could overwrite them:`n  $($changed -join "`n  ")`nKeep or undo those changes (git stash / git checkout), then run this again. Nothing was stopped."
}
Invoke-Git fetch --quiet | Out-Null
$branch = (Invoke-Git rev-parse --abbrev-ref HEAD | Select-Object -First 1)
$upstream = & git.exe -C $root rev-parse --abbrev-ref '@{u}' 2>$null
if ($LASTEXITCODE -or -not $upstream) { throw "Branch '$branch' doesn't track a remote branch, so there's nothing to pull from." }
$behind = [int](Invoke-Git rev-list --count "HEAD..@{u}" | Select-Object -First 1)
if ($behind -eq 0) { Say '  Already up to date. Nothing was stopped.' Green; exit 0 }
$remoteVersion = try { (Invoke-Git show "@{u}:VERSION" | Select-Object -First 1).Trim() } catch { '?' }
Say "  New version $remoteVersion on $upstream ($behind commit(s))."

# ================================ Stop the running instances ================================
Step 'Running instances'
$running = @(Get-RunningInstances)
if ($running.Count) {
    foreach ($r in $running) {
        $who = if ($r.NotAnswering) { 'not answering' } elseif ($r.Agents.Count) { "agents in tabs: $($r.Agents -join ', ')" } else { 'no agent in a tab' }
        Say ("  {0,-10} port {1}  {2} tab(s), {3}" -f $r.Instance.Name, $r.Port, $r.Tabs, $who)
    }
    Say '  Stopping closes their Chrome windows: agents working in them are interrupted, and anything typed into an'
    Say '  unsent form is lost. Sign-ins are kept. They start again after the update.'
    if (-not (Confirm-CWeb "Stop $($running.Count) instance(s) and update?")) { Say 'Nothing was stopped or updated.' Yellow; exit 1 }
    $stopped = @()
    foreach ($r in $running) {
        if (Stop-Instance $r) { $stopped += $r; continue }
        Say "  $($r.Instance.Name) is still running, so CWeb can't be updated now. Starting the others again." Red
        Start-Instances $stopped
        exit 1
    }
} else {
    Say '  None.'
}

# ================================ Pull ================================
Step "Pulling $remoteVersion"
try {
    Invoke-Git pull --ff-only --quiet | ForEach-Object { "  $_" }
} catch {
    Say "  $($_.Exception.Message) CWeb is unchanged." Red
    Start-Instances $running
    exit 1
}
Say "  Now at $((Get-Content (Join-Path $root 'VERSION') -Raw).Trim())." Green

# ================================ Setup (from the new version) ================================
Step 'Setup'
& pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Setup-CWeb.ps1')
$setupFailed = [bool]$LASTEXITCODE
if ($setupFailed) { Say "  Setup reported a problem (exit $LASTEXITCODE; see above)." Red }

Start-Instances $running
Say ''
if ($setupFailed) { Say 'Updated, but setup reported a problem (above).' Yellow; exit 1 }
Say "CWeb is updated." Green
