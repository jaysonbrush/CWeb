# CWeb-Client.ps1 -- how agents and scripts connect to a CWeb instance (PowerShell 7).
#
#   . <CWeb folder>\CWeb-Client.ps1
#   $c = Connect-CWeb -Client support-ticket-triage                # once per session; safe to repeat
#   Invoke-CWeb -Instance $c.instance -Client support-ticket-triage @{ action = 'navigate'; url = 'https://example.org' }
#
# Connect-CWeb attaches to the instance the user is working in: the running one (or, if several run, the one this
# client already has a key for; otherwise it lists them so the agent can ask). With -Instance it attaches to that one,
# if it's running. It never starts or creates an instance: that's the user's call. It reuses the client's saved key if
# it still works, and otherwise asks for access and waits for the user to approve it on the status page. The key is
# saved in <data folder>\<instance>\clients\<client>.key, so later sessions with the same client name connect with no
# click. Keys are never printed.
#
# Run as a script (used by cweb.sh), it prints JSON and exits 0 connected, 3 still waiting, 4 denied, 6 several
# instances running (pick one), 1 error (e.g. none running):
#   pwsh -NoProfile -File CWeb-Client.ps1 -Connect -Client support-ticket-triage [-Instance work]

param(
    [switch]$Connect,
    [string]$Instance,
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
        [string]$Instance,        # omit: the running instance
        [Parameter(Mandatory)] [string]$Client,
        [int]$WaitSeconds = 90,   # how long this call waits for approval; run it again to keep waiting
        [switch]$NoStart          # no effect (kept for old scripts): connect never starts an instance
    )
    $null = Get-CWebClientFiles -Inst ([pscustomobject]@{ ClientsDir = '.' }) -Client $Client   # checks the name
    $ask = 'Ask the user to start the instance they work in (Start-CWeb.cmd, or Start on its status page). Agents never start or create instances.'

    # 1. The instance: the one the user has running. Never start one.
    if (-not $Instance) {
        $running = @(Get-CWebInstanceList -Root $script:CWebClientRoot | Where-Object running)
        if ($running.Count -gt 1) {
            # Several: the one this client already has a key for, if that's just one.
            $mine = @($running | Where-Object { Test-Path (Get-CWebClientFiles -Inst (Get-CWebInstance -Name $_.name -Root $script:CWebClientRoot) -Client $Client).Key })
            if ($mine.Count -eq 1) { $running = $mine }
        }
        if ($running.Count -eq 0) {
            return [pscustomobject]@{ status = 'error'; instance = $null; client = $Client; message = "No CWeb instance is running. $ask" }
        }
        if ($running.Count -gt 1) {
            $names = ($running | ForEach-Object { "$($_.name) ($($_.label))" }) -join ', '
            return [pscustomobject]@{ status = 'choose'; instance = $null; client = $Client; instances = @($running | ForEach-Object { [ordered]@{ name = $_.name; label = $_.label } })
                message = "Several CWeb instances are running: $names. Ask the user which one they work in, then connect to it by name." }
        }
        $Instance = $running[0].name
    }
    $inst = Get-CWebInstance -Name $Instance -Root $script:CWebClientRoot
    $files = Get-CWebClientFiles -Inst $inst -Client $Client
    $base = "http://127.0.0.1:$($inst.Port)"
    $statusUrl = "$base/status#access"
    function Result($status, $message) {
        [pscustomobject]@{ status = $status; instance = $inst.Name; client = $Client; port = $inst.Port; statusUrl = $statusUrl; message = $message }
    }
    function Connected($message) {
        # Connected, plus the sites the user flagged to keep alive: how an agent hears about them.
        $res = Result 'connected' $message
        try {
            $st = Invoke-RestMethod "$base/status.json" -TimeoutSec 5
            $open = @($st.keepAlive.requests | Where-Object state -eq 'open' | ForEach-Object { [ordered]@{ id = $_.id; site = $_.site } })
            if ($open.Count) {
                $res | Add-Member -NotePropertyName keepAliveRequests -NotePropertyValue $open
                $res.message += " The user flagged $($open.Count) site(s) to keep alive ($(($open | ForEach-Object { $_.site }) -join ', ')): build and install a profile for each (KEEPALIVE.md), unless you're busy with something the user asked for first."
            }
        } catch { }
        $res
    }
    if (-not (Get-CWebRunningServer -Instance $inst)) {
        return Result 'error' "CWeb '$($inst.Name)' isn't running. $ask"
    }

    # Several sessions of one client share its key file, so another session may write a key at any moment: read it
    # fresh each time, and never delete a key other than the one just found not to work.
    function Read-Key { if (Test-Path $files.Key) { $k = (Get-Content -LiteralPath $files.Key -Raw -ErrorAction SilentlyContinue); if ($k) { $k.Trim() } } }
    function Test-Key($k) { (Invoke-CWebHttp POST "$base/api" @{ action = 'status' } @{ 'X-API-Key' = $k }).code }

    # 2. A saved key that still works: done.
    $key = Read-Key
    if ($key) {
        $code = Test-Key $key
        if ($code -eq 200) { return Connected "Connected to CWeb '$($inst.Name)' as $Client." }
        if ($code -ne 401) { return Result 'error' "CWeb '$($inst.Name)' didn't answer the key check (HTTP $code)." }
        Start-Sleep -Seconds 2   # another session may be saving a new key right now
        $now = Read-Key
        if ($now -and $now -ne $key -and (Test-Key $now) -eq 200) { return Connected "Connected to CWeb '$($inst.Name)' as $Client." }
        Write-Host "The saved key for $Client no longer works (revoked); asking for access again."
        if ((Read-Key) -eq $key) { Remove-Item -LiteralPath $files.Key -Force -ErrorAction SilentlyContinue }
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
            $tmp = "$($files.Key).$PID.tmp"
            Set-Content -LiteralPath $tmp -Value $s.json.key -NoNewline
            Move-Item -LiteralPath $tmp -Destination $files.Key -Force   # whole file at once: other sessions read it
            Remove-Item -LiteralPath $files.Ticket -Force -ErrorAction SilentlyContinue
            return Connected "Approved. Connected to CWeb '$($inst.Name)' as $Client."
        }
        if ($state -eq 'denied') {
            Remove-Item -LiteralPath $files.Ticket -Force -ErrorAction SilentlyContinue
            return Result 'denied' "Access for '$Client' was denied on the status page."
        }
        # Another session of this client may have collected the key for the same request: use it, don't ask again.
        $k = Read-Key
        if ($k -and (Test-Key $k) -eq 200) {
            Remove-Item -LiteralPath $files.Ticket -Force -ErrorAction SilentlyContinue
            return Connected "Approved. Connected to CWeb '$($inst.Name)' as $Client."
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
        [Parameter(Mandatory)] [string]$Instance,   # the one Connect-CWeb returned
        [Parameter(Mandatory)] [string]$Client,
        [Parameter(Mandatory, Position = 0)] [hashtable]$Body,
        [int]$TimeoutSec = 300
    )
    $inst = Get-CWebInstance -Name $Instance -Root $script:CWebClientRoot
    $files = Get-CWebClientFiles -Inst $inst -Client $Client
    if (-not (Test-Path $files.Key)) { throw "Not connected as '$Client' to CWeb '$($inst.Name)'. Run Connect-CWeb -Instance $($inst.Name) -Client $Client." }
    $key = (Get-Content -LiteralPath $files.Key -Raw).Trim()
    $r = Invoke-CWebHttp POST "http://127.0.0.1:$($inst.Port)/api" $Body @{ 'X-API-Key' = $key } $TimeoutSec
    if ($r.code -eq 0) { throw "CWeb '$($inst.Name)' isn't answering (stopped?). Ask the user to start it; agents never start instances." }
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
    exit $(switch ($res.status) { 'connected' { 0 } 'waiting' { 3 } 'denied' { 4 } 'choose' { 6 } default { 1 } })
}
