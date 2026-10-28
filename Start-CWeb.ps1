# Start-CWeb.ps1
# One-click launcher: starts a CWeb instance's server (unless it's already running) and waits until its Chrome
# window is open. The server opens Chrome itself, so the launcher needs no API key: it only reads the status page.
# Used by Start-CWeb.cmd. Logs to %USERPROFILE%\CWebData\<instance>\logs\launcher-<date>.log.
#   .\Start-CWeb.ps1              -> the 'work' instance
#   .\Start-CWeb.ps1 -Instance personal

param([string]$Instance = 'work')

$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
. (Join-Path $dir 'CWeb-Common.ps1')

function Stop-WithError($msg, $logDir) {
    Write-Host ''
    Write-Host $msg -ForegroundColor Red
    if ($logDir) {
        Write-Host "Logs: $logDir" -ForegroundColor Yellow
        Write-Host '  server-<date>.log       -- server console, startup checks, Chrome start errors'
        Write-Host '  chromedriver-<date>.log -- ChromeDriver detail on why Chrome would not launch'
    }
    try { Stop-Transcript | Out-Null } catch { }
    Read-Host 'Press Enter to close'
    exit 1
}

try { $inst = Get-CWebInstance -Name $Instance -Root $dir } catch { Stop-WithError $_.Exception.Message $null }

New-Item -ItemType Directory -Path $inst.LogDir -Force | Out-Null
Get-ChildItem $inst.LogDir -File -Filter *.log -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | Remove-Item -Force -ErrorAction SilentlyContinue
try { Start-Transcript -Path (Join-Path $inst.LogDir "launcher-$(Get-Date -Format yyyy-MM-dd).log") -Append | Out-Null } catch { }

$version = try { (Get-Content (Join-Path $dir 'VERSION') -Raw).Trim() } catch { 'unknown' }
$statusUrl = "http://127.0.0.1:$($inst.Port)/status"
Write-Host "==== Start-CWeb $version -- instance '$($inst.Name)' ($($inst.Label)) port $($inst.Port) -- $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===="

# 1. Server -- start it unless this instance's server is already running.
$st = Get-CWebRunningServer -Instance $inst
$info = if (-not $st) { Get-CWebServerInfo -ServerFile $inst.ServerFile }
if ($info) {
    # Its process runs but doesn't answer: still opening Chrome, or stuck. Starting another server wouldn't help (it
    # finds the instance lock held and exits), so wait a little, then offer to restart it.
    Write-Host "CWeb '$($inst.Name)' is running (process $($info.pid)) but not answering yet. Waiting up to a minute..."
    $st = Wait-CWebServer -Instance $inst -Seconds 60
    if (-not $st -and (Get-CWebServerInfo -ServerFile $inst.ServerFile)) {
        Write-Host "It still isn't answering." -ForegroundColor Yellow
        $a = try { Read-Host 'Restart it? Its Chrome is closed cleanly first, so your tabs and sign-ins come back. [Y/n]' } catch { 'n' }
        if ($a -match '^(n|no)$') { Stop-WithError "Left it running (process $($info.pid))." $inst.LogDir }
        Write-Host 'Stopping it...'
        Stop-CWebServerProcess -Instance $inst -Root $dir | Out-Null
    }
}
$started = $false
if ($st) {
    Write-Host "CWeb '$($inst.Name)' is already running."
} else {
    Write-Host "Starting CWeb '$($inst.Name)' (Chrome restoring many tabs can take a minute or two)..."
    try { $st = Start-CWebServer -Instance $inst -Root $dir } catch { Stop-WithError $_.Exception.Message $inst.LogDir }
    Write-Host 'Server is up.'
    $started = $true
}
# The server may have moved off a port another program holds; its status data has the real one.
if ([int]$st.server.port -ne $inst.ConfiguredPort) {
    Write-Host "Port $($inst.ConfiguredPort) is in use by another program, so CWeb '$($inst.Name)' is on port $($st.server.port)." -ForegroundColor Yellow
    $statusUrl = "http://127.0.0.1:$($st.server.port)/status"
}

# 2. Browser -- the server opened it at start. On a server that was already running, Chrome may have been closed
# since (its window closed, or it exited): ask the server to open it again.
if (-not $st.browser.running -and -not $started) {
    Write-Host "Chrome isn't open$(if ($st.browser.closed) { " (closed at $($st.browser.closed.Substring(11, 5)))" }). Opening it..."
    $port = [int]$st.server.port
    try {
        $r = Invoke-RestMethod "http://127.0.0.1:$port/status/startbrowser" -Method POST -ContentType 'application/json' -Body '{}' `
            -Headers @{ 'X-Status-Request' = '1'; 'Origin' = "http://127.0.0.1:$port" } -TimeoutSec 360
        if (-not $r.success) { Stop-WithError "Chrome did not start: $($r.error)" $inst.LogDir }
        $st = Get-CWebRunningServer -Instance $inst
    } catch { Stop-WithError "Chrome did not start: $($_.Exception.Message)" $inst.LogDir }
}
if ($st.browser.running) {
    Write-Host "Chrome is open ($($st.browser.url))."
} elseif ($st.browser.startError) {
    Stop-WithError "Chrome did not start: $($st.browser.startError)" $inst.LogDir
} else {
    Write-Host "Chrome isn't open. See the status page: $statusUrl" -ForegroundColor Yellow
}

Write-Host "Ready. Log in to sites in the CWeb $($inst.Label) Chrome window." -ForegroundColor Green
Write-Host "Status page: $statusUrl"
if (-not $inst.ShowServerWindow) { Write-Host 'The server runs in the background. Stop it from the status page.' }
Write-Host '(this window closes in a few seconds)'
try { Stop-Transcript | Out-Null } catch { }
Start-Sleep -Seconds 4
