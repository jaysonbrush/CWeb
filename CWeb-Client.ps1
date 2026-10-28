# CWeb-Client.ps1 -- how scripts use CWeb from PowerShell 7 (agents in Bash use cweb.sh, which calls this to start it).
#
#   . <CWeb folder>\CWeb-Client.ps1
#   Invoke-CWeb @{ action = 'navigate'; tab = 'tickets'; url = 'https://example.org' }     # the work instance
#   Invoke-CWeb -Instance personal @{ action = 'getpagetext'; tab = 'mail' }              # another one, only when told
#
# Invoke-CWeb starts the instance if it isn't running (its Chrome opens with its tabs and sign-ins) and sends the key from
# <data folder>\cweb.key, which only this Windows user can read. Nothing to approve, nothing to connect first.
#
# Run as a script (used by cweb.sh), it makes sure the instance runs and prints JSON: exit 0 running, 3 still starting
# (run it again), 1 error.
#   pwsh -NoProfile -File CWeb-Client.ps1 -Ensure [-Instance work]

param(
    [switch]$Ensure,
    [switch]$Connect,          # old name for -Ensure
    [string]$Instance = 'work',
    [string]$Client,           # no effect (kept for old scripts)
    [int]$WaitSeconds = 90
)

. (Join-Path $PSScriptRoot 'CWeb-Common.ps1')
$script:CWebClientRoot = $PSScriptRoot

function Start-CWebIfNeeded {
    # Makes sure the instance's server runs and answers. Starts it if it isn't running (one caller at a time; the others
    # wait for that one). Returns { status = running | starting | error; instance; port; statusUrl; message }.
    param([string]$Instance = 'work', [int]$WaitSeconds = 90)
    try { $inst = Get-CWebInstance -Name $Instance -Root $script:CWebClientRoot }
    catch { return [pscustomobject]@{ status = 'error'; instance = $Instance; message = $_.Exception.Message } }
    function Result($status, $message) {
        $i = Get-CWebInstance -Name $inst.Name -Root $script:CWebClientRoot   # the port it really took
        [pscustomobject]@{ status = $status; instance = $i.Name; port = $i.Port; statusUrl = "http://127.0.0.1:$($i.Port)/status"; message = $message }
    }
    if (Get-CWebRunningServer -Instance $inst) { return Result 'running' "CWeb '$($inst.Name)' is running." }

    $proc = $null
    $gate = [System.Threading.Mutex]::new($false, 'Local\CWeb-client-start')
    try { $null = $gate.WaitOne(30000) } catch [System.Threading.AbandonedMutexException] { }
    try {
        if (-not (Test-CWebServerProcess -Instance $inst)) {
            Write-Host "CWeb '$($inst.Name)' isn't running; starting it."
            $proc = Start-CWebServerProcess -Instance $inst -Root $script:CWebClientRoot
            $deadline = (Get-Date).AddSeconds(30)   # its server.json appears before Chrome opens
            while (-not (Test-CWebServerProcess -Instance $inst) -and -not $proc.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
        }
    } finally { try { $gate.ReleaseMutex() } catch { }; $gate.Dispose() }

    if (Wait-CWebServer -Instance $inst -Seconds $WaitSeconds -Process $proc) { return Result 'running' "CWeb '$($inst.Name)' is running." }
    if (Test-CWebServerProcess -Instance $inst) {
        return Result 'starting' "CWeb '$($inst.Name)' is starting (Chrome is opening its tabs). Run the command again in a moment."
    }
    $why = if ($proc -and $proc.HasExited) { " (exit $($proc.ExitCode))" } else { '' }
    return Result 'error' "CWeb '$($inst.Name)' didn't start$why. Logs: $($inst.LogDir)"
}

function Invoke-CWeb {
    # Sends one command and returns the server's reply. Starts the instance first if it isn't running.
    param(
        [Parameter(Mandatory, Position = 0)] [hashtable]$Body,
        [string]$Instance = 'work',
        [string]$Client,          # shown on the status page's command list (optional)
        [int]$TimeoutSec = 300
    )
    $key = Initialize-CWebKey
    for ($try = 0; $try -lt 2; $try++) {
        $inst = Get-CWebInstance -Name $Instance -Root $script:CWebClientRoot
        $headers = @{ 'X-CWeb-Key' = $key }
        if ($Client) { $headers['X-CWeb-Client'] = $Client }
        try {
            $r = Invoke-WebRequest "http://127.0.0.1:$($inst.Port)/api" -Method POST -Body ($Body | ConvertTo-Json -Depth 10 -Compress) `
                -ContentType 'application/json' -Headers $headers -TimeoutSec $TimeoutSec -SkipHttpErrorCheck
            return ($r.Content | ConvertFrom-Json)
        } catch {
            if ($try) { throw }
            $s = Start-CWebIfNeeded -Instance $Instance
            if ($s.status -ne 'running') { throw $s.message }
        }
    }
}

function Connect-CWeb {
    # Old scripts: nothing to connect any more. Makes sure the instance runs and reports it the old way.
    param([string]$Instance = 'work', [string]$Client, [int]$WaitSeconds = 90, [switch]$NoStart)
    $s = Start-CWebIfNeeded -Instance $Instance -WaitSeconds $WaitSeconds
    $status = switch ($s.status) { 'running' { 'connected' } 'starting' { 'waiting' } default { 'error' } }
    [pscustomobject]@{ status = $status; instance = $s.instance; client = $Client; port = $s.port; statusUrl = $s.statusUrl; message = $s.message }
}

# Run as a script: make sure the instance runs and print the result as JSON.
if ($Ensure -or $Connect) {
    try { $res = Start-CWebIfNeeded -Instance $Instance -WaitSeconds $WaitSeconds }
    catch { $res = [pscustomobject]@{ status = 'error'; instance = $Instance; message = $_.Exception.Message } }
    if ($Connect) { $res | Add-Member -NotePropertyName client -NotePropertyValue $Client; if ($res.status -eq 'running') { $res.status = 'connected' } }
    $res | ConvertTo-Json -Compress
    exit $(switch ($res.status) { { $_ -in 'running', 'connected' } { 0 } 'starting' { 3 } default { 1 } })
}
