# CWeb-Client.ps1 -- how agents and scripts connect to a CWeb instance (PowerShell 7).
#
#   . <CWeb folder>\CWeb-Client.ps1
#   Connect-CWeb -Instance work -Client support-ticket-triage      # once per session; safe to repeat
#   Invoke-CWeb  -Instance work -Client support-ticket-triage @{ action = 'navigate'; url = 'https://example.org' }
#
# Connect-CWeb finds the instance's server (starting it if it's down), reuses the client's saved key if it still
# works, and otherwise asks for access and waits for the user to approve it on the status page. The key is saved in
# %USERPROFILE%\CWebData\<instance>\clients\<client>.key, so later sessions with the same client name connect with no
# click. Keys are never printed.
#
# Run as a script (used by cweb.sh), it prints JSON and exits 0 connected, 3 still waiting, 4 denied, 1 error:
#   pwsh -NoProfile -File CWeb-Client.ps1 -Connect -Instance work -Client support-ticket-triage

param(
    [switch]$Connect,
    [string]$Instance = 'work',
    [string]$Client,
    [int]$WaitSeconds = 90
)

. (Join-Path $PSScriptRoot 'CWeb-Common.ps1')
$script:CWebClientRoot = $PSScriptRoot

function Get-CWebClientFiles {
    param($Inst, [string]$Client)
    if ($Client -cnotmatch '^[a-z0-9][a-z0-9-]{0,39}$') {
        throw "Client name '$Client': use 1-40 lowercase letters, digits and hyphens, e.g. support-ticket-triage."
    }
    [pscustomobject]@{
        Key    = Join-Path $Inst.ClientsDir "$Client.key"
        Ticket = Join-Path $Inst.ClientsDir "$Client.ticket"   # a request still waiting for approval
    }
}

function Invoke-CWebHttp {
    # One HTTP call that never throws on HTTP errors. Returns { code; json }. code 0 = no answer.
    param([string]$Method, [string]$Url, $Body, [hashtable]$Headers = @{}, [int]$TimeoutSec = 30)
    try {
        $req = @{ Uri = $Url; Method = $Method; Headers = $Headers; SkipHttpErrorCheck = $true; TimeoutSec = $TimeoutSec }
        if ($null -ne $Body) { $req.Body = ($Body | ConvertTo-Json -Depth 10 -Compress); $req.ContentType = 'application/json' }
        $r = Invoke-WebRequest @req
        [pscustomobject]@{ code = [int]$r.StatusCode; json = $(try { $r.Content | ConvertFrom-Json } catch { $null }) }
    } catch { [pscustomobject]@{ code = 0; json = $null } }
}

function Connect-CWeb {
    param(
        [string]$Instance = 'work',
        [Parameter(Mandatory)] [string]$Client,
        [int]$WaitSeconds = 90,   # how long this call waits for approval; run it again to keep waiting
        [switch]$NoStart          # don't start the server if it's down
    )
    $inst = Get-CWebInstance -Name $Instance -Root $script:CWebClientRoot
    $files = Get-CWebClientFiles -Inst $inst -Client $Client
    $base = "http://127.0.0.1:$($inst.Port)"
    $statusUrl = "$base/status#access"
    function Result($status, $message) {
        [pscustomobject]@{ status = $status; instance = $inst.Name; client = $Client; port = $inst.Port; statusUrl = $statusUrl; message = $message }
    }

    # 1. The server: find it, or start it.
    if (-not (Get-CWebRunningServer -Instance $inst)) {
        if ($NoStart) { return Result 'error' "CWeb '$($inst.Name)' isn't running. Start it with Start-CWeb.cmd $($inst.Name)." }
        Write-Host "CWeb '$($inst.Name)' isn't running; starting it..."
        try { Start-CWebServer -Instance $inst -Root $script:CWebClientRoot | Out-Null } catch { return Result 'error' $_.Exception.Message }
        # Look it up again: the server may have moved off a port another program holds.
        $inst = Get-CWebInstance -Name $Instance -Root $script:CWebClientRoot
        $base = "http://127.0.0.1:$($inst.Port)"
        $statusUrl = "$base/status#access"
    }

    # 2. A saved key that still works: done.
    if (Test-Path $files.Key) {
        $key = (Get-Content -LiteralPath $files.Key -Raw).Trim()
        $r = Invoke-CWebHttp POST "$base/api" @{ action = 'status' } @{ 'X-API-Key' = $key }
        if ($r.code -eq 200) { return Result 'connected' "Connected to CWeb '$($inst.Name)' as $Client." }
        if ($r.code -eq 401) {
            Write-Host "The saved key for $Client no longer works (revoked or replaced); asking for access again."
            Remove-Item -LiteralPath $files.Key -Force
        } else { return Result 'error' "CWeb '$($inst.Name)' didn't answer the key check (HTTP $($r.code))." }
    }

    # 3. Ask for access, or keep waiting on the request already made.
    New-Item -ItemType Directory -Path $inst.ClientsDir -Force | Out-Null
    $hdr = @{ 'X-CWeb-Attach' = '1' }
    $ticket = $null
    if (Test-Path $files.Ticket) { $ticket = (Get-Content -LiteralPath $files.Ticket -Raw).Trim() }
    $asked = $false
    $deadline = (Get-Date).AddSeconds([Math]::Max(0, $WaitSeconds))
    $told = $false
    while ($true) {
        if (-not $ticket) {
            $a = Invoke-CWebHttp POST "$base/attach" @{ client = $Client } $hdr
            if (-not ($a.json -and $a.json.success)) { return Result 'error' $(if ($a.json.error) { $a.json.error } else { "Couldn't ask for access (HTTP $($a.code))." }) }
            $ticket = $a.json.ticket
            Set-Content -LiteralPath $files.Ticket -Value $ticket -NoNewline
            $asked = $true
        }
        if (-not $told) {
            Write-Host "Waiting for approval: ask the user to approve '$Client' at $statusUrl"
            $told = $true
        }
        $s = Invoke-CWebHttp GET "$base/attach/$ticket" $null $hdr
        $state = [string]$s.json.status
        if ($state -eq 'approved') {
            Set-Content -LiteralPath $files.Key -Value $s.json.key -NoNewline
            Remove-Item -LiteralPath $files.Ticket -Force -ErrorAction SilentlyContinue
            return Result 'connected' "Approved. Connected to CWeb '$($inst.Name)' as $Client."
        }
        if ($state -eq 'denied') {
            Remove-Item -LiteralPath $files.Ticket -Force -ErrorAction SilentlyContinue
            return Result 'denied' "Access for '$Client' was denied on the status page."
        }
        if ($state -ne 'pending') {
            # The request is gone (expired, or the server restarted). Ask once more in this call.
            Remove-Item -LiteralPath $files.Ticket -Force -ErrorAction SilentlyContinue
            $ticket = $null
            if ($asked) { return Result 'error' "The access request disappeared (HTTP $($s.code)). Run Connect-CWeb again." }
            continue
        }
        if ((Get-Date) -ge $deadline) {
            return Result 'waiting' "Still waiting for approval. Ask the user to approve '$Client' at $statusUrl, then run Connect-CWeb again (it keeps the same request)."
        }
        Start-Sleep -Seconds 3
    }
}

function Invoke-CWeb {
    # Sends one command to the API with the client's saved key. Returns the server's reply.
    param(
        [string]$Instance = 'work',
        [Parameter(Mandatory)] [string]$Client,
        [Parameter(Mandatory, Position = 0)] [hashtable]$Body,
        [int]$TimeoutSec = 300
    )
    $inst = Get-CWebInstance -Name $Instance -Root $script:CWebClientRoot
    $files = Get-CWebClientFiles -Inst $inst -Client $Client
    if (-not (Test-Path $files.Key)) { throw "Not connected as '$Client' to CWeb '$($inst.Name)'. Run Connect-CWeb -Instance $($inst.Name) -Client $Client." }
    $key = (Get-Content -LiteralPath $files.Key -Raw).Trim()
    $r = Invoke-CWebHttp POST "http://127.0.0.1:$($inst.Port)/api" $Body @{ 'X-API-Key' = $key } $TimeoutSec
    if ($r.code -eq 0) { throw "CWeb '$($inst.Name)' isn't answering. Run Connect-CWeb (it starts the server)." }
    if ($r.code -eq 401) { throw "The key for '$Client' was revoked or replaced. Run Connect-CWeb -Instance $($inst.Name) -Client $Client." }
    return $r.json
}

# Run as a script: connect and print the result as JSON.
if ($Connect) {
    try {
        $res = Connect-CWeb -Instance $Instance -Client $Client -WaitSeconds $WaitSeconds
    } catch {
        $res = [pscustomobject]@{ status = 'error'; instance = $Instance; client = $Client; message = $_.Exception.Message }
    }
    $res | ConvertTo-Json -Compress
    exit $(switch ($res.status) { 'connected' { 0 } 'waiting' { 3 } 'denied' { 4 } default { 1 } })
}
