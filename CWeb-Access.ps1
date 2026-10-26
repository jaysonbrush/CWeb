# CWeb-Access.ps1 -- who may use this instance's API. Dot-sourced by CWeb-Server.ps1 (PowerShell 7).
#
# A client (an agent session, a script) asks to attach with POST /attach {client}. The request waits on the status
# page until the user clicks Approve or Deny. On Approve the server makes a random key for that client, hands it over
# once (GET /attach/<ticket>), and keeps only its SHA-256 fingerprint in approvals.json, so the approval survives
# restarts and lasts until revoked. Every /api request must carry an approved key in X-API-Key.
#
# Two ids per pending request: the ticket is private (only the waiting client has it; it collects the key), the ref
# is public (shown on the keyless status page, used by Approve/Deny). Never put a ticket or a key in status data.

$script:AccessPendingMinutes = 60   # a request (or an approved key nobody collected) is dropped after this
$script:AccessMaxPending     = 20
$script:AccessMaxKeys        = 10   # keys per client (one per machine view or session that asked); oldest dropped
$script:AccessSaveMinutes    = 5    # how often a changed last-used time is written to disk

function New-CWebSecret {
    param([int]$Bytes = 32)
    $b = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes($Bytes)
    return [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-CWebFingerprint {
    param([string]$Key)
    $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Key))
    return [Convert]::ToHexString($hash).ToLowerInvariant()
}

function Test-CWebClientName {
    param([string]$Name)
    return $Name -cmatch '^[a-z0-9][a-z0-9-]{0,39}$'
}

function Initialize-CWebAccess {
    param([string]$DataDir)
    $script:Access = @{
        Path     = Join-Path $DataDir 'approvals.json'
        Clients  = @{}            # name -> @{ fingerprints (newest last); approved; lastUsed }
        ByPrint  = @{}            # fingerprint -> name
        Pending  = [System.Collections.Generic.List[object]]::new()
        Dirty    = $false
        LastSave = Get-Date
    }
    if (-not (Test-Path $script:Access.Path)) { return }
    try {
        $saved = Get-Content $script:Access.Path -Raw | ConvertFrom-Json -AsHashtable
        foreach ($name in @($saved.clients.Keys)) {
            $c = $saved.clients[$name]
            # "fingerprints" (a list); files from before 2026.10.26.018 have one "fingerprint".
            $prints = @(@($c.fingerprints) + @($c.fingerprint) | Where-Object { $_ -match '^[0-9a-f]{64}$' } | Select-Object -Unique)
            if (-not (Test-CWebClientName $name) -or -not $prints.Count) { continue }
            $script:Access.Clients[$name] = @{ fingerprints = [System.Collections.Generic.List[string]]::new([string[]]$prints); approved = [string]$c.approved; lastUsed = [string]$c.lastUsed }
            foreach ($fp in $prints) { $script:Access.ByPrint[$fp] = $name }
        }
        Write-Host "  Access: $($script:Access.Clients.Count) approved client(s)"
    } catch {
        # Unreadable file: set it aside and start with no approvals (clients ask again), rather than not starting.
        $bad = "$($script:Access.Path).bad-$(Get-Date -Format yyyyMMdd-HHmmss)"
        Move-Item -LiteralPath $script:Access.Path -Destination $bad -Force
        Write-Host "  Access: approvals.json was unreadable ($($_.Exception.Message)); set aside as $bad. Clients must be approved again." -ForegroundColor Yellow
    }
}

function Save-CWebAccess {
    # Write to a temp file, then swap it in, so a crash mid-write can't leave a half-written file.
    $clients = [ordered]@{}
    foreach ($name in ($script:Access.Clients.Keys | Sort-Object)) {
        $c = $script:Access.Clients[$name]
        $clients[$name] = [ordered]@{ fingerprints = @($c.fingerprints); approved = $c.approved; lastUsed = $c.lastUsed }
    }
    $tmp = "$($script:Access.Path).tmp"
    [ordered]@{ note = 'CWeb approved clients. Fingerprints (SHA-256) of their keys only, never the keys.'; clients = $clients } |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tmp -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $script:Access.Path -Force
    $script:Access.Dirty = $false
    $script:Access.LastSave = Get-Date
}

function Save-CWebAccessIfDue {
    # Called from the main loop: last-used times are saved now and then, not on every request.
    param([switch]$Now)
    if ($script:Access.Dirty -and ($Now -or ((Get-Date) - $script:Access.LastSave).TotalMinutes -ge $script:AccessSaveMinutes)) {
        try { Save-CWebAccess } catch { Write-Host "  Access: couldn't save approvals.json: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
}

function Resolve-CWebClient {
    # The approved client whose key this request carries, or $null.
    param([System.Net.HttpListenerRequest]$Request)
    $key = $Request.Headers['X-API-Key']
    if (-not $key -or $key.Length -gt 200) { return $null }
    $name = $script:Access.ByPrint[(Get-CWebFingerprint $key)]
    if (-not $name) { return $null }
    $script:Access.Clients[$name].lastUsed = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $script:Access.Dirty = $true
    return $name
}

function Remove-ExpiredAttach {
    $cut = (Get-Date).AddMinutes(-$script:AccessPendingMinutes)
    foreach ($p in @($script:Access.Pending | Where-Object { $_.Requested -lt $cut })) {
        if ($p.State -eq 'pending') { Write-Host "[$(Get-Date -Format HH:mm:ss)] access request from '$($p.Client)' expired" }
        [void]$script:Access.Pending.Remove($p)
    }
}

function Test-AttachRequest {
    # /attach is for local scripts, not web pages: this machine only, our own header (a website can't add it
    # without a CORS preflight, which this server never approves), and no Origin (browsers always send one).
    param([System.Net.HttpListenerRequest]$Request)
    return (Test-LocalStatusRequest -Request $Request) -and $Request.Headers['X-CWeb-Attach'] -eq '1' -and -not $Request.Headers['Origin']
}

function New-AttachRequest {
    param([string]$Client)
    Remove-ExpiredAttach
    if (-not (Test-CWebClientName $Client)) {
        return @{ success = $false; error = "Client name '$Client': use 1-40 lowercase letters, digits and hyphens, e.g. support-ticket-triage." }
    }
    if (@($script:Access.Pending | Where-Object State -eq 'pending').Count -ge $script:AccessMaxPending) {
        return @{ success = $false; error = 'Too many requests are waiting for approval. Try again later.' }
    }
    $p = [pscustomobject]@{
        Ticket    = New-CWebSecret 32
        Ref       = (New-CWebSecret 6).ToLowerInvariant() -replace '[^a-z0-9]', 'x'
        Client    = $Client
        Requested = Get-Date
        State     = 'pending'   # pending | approved | denied
        Key       = $null       # set on approve, cleared once collected
        Replaces  = $script:Access.Clients.ContainsKey($Client)
    }
    $script:Access.Pending.Add($p)
    Write-Host "[$(Get-Date -Format HH:mm:ss)] access request from '$Client' -- waiting for approval on the status page" -ForegroundColor Cyan
    return @{
        success   = $true
        status    = 'pending'
        ticket    = $p.Ticket
        statusUrl = "http://127.0.0.1:$($script:Port)/status#access"
        message   = "Waiting for approval on http://127.0.0.1:$($script:Port)/status. Poll GET /attach/<ticket> every few seconds."
    }
}

function Get-AttachState {
    param([string]$Ticket)
    Remove-ExpiredAttach
    $p = $script:Access.Pending | Where-Object { $_.Ticket -ceq $Ticket } | Select-Object -First 1
    if (-not $p) { return @{ success = $false; status = 'unknown'; error = 'No such request (expired after an hour, or already collected). Ask again.' } }
    switch ($p.State) {
        'pending' { return @{ success = $true; status = 'pending' } }
        'denied'  { [void]$script:Access.Pending.Remove($p); return @{ success = $false; status = 'denied'; error = 'Access was denied on the status page.' } }
        'approved' {
            # The key leaves the server once; after this only its fingerprint exists.
            $key = $p.Key; [void]$script:Access.Pending.Remove($p)
            Write-Host "[$(Get-Date -Format HH:mm:ss)] key collected by '$($p.Client)'"
            return @{ success = $true; status = 'approved'; client = $p.Client; key = $key }
        }
    }
}

function Set-AttachDecision {
    # Approve or deny a pending request by its public ref. Called from the status page.
    param([string]$Ref, [bool]$Approve)
    Remove-ExpiredAttach
    $p = $script:Access.Pending | Where-Object { $_.Ref -ceq $Ref -and $_.State -eq 'pending' } | Select-Object -First 1
    if (-not $p) { return @{ success = $false; error = 'That request is no longer waiting (expired or already decided).' } }
    if (-not $Approve) {
        $p.State = 'denied'
        Write-Host "[$(Get-Date -Format HH:mm:ss)] access denied: '$($p.Client)'" -ForegroundColor Yellow
        return @{ success = $true; denied = $p.Client }
    }
    $key = 'cweb_' + (New-CWebSecret 32)
    $fp = Get-CWebFingerprint $key
    # A re-approval adds a key, it doesn't replace one: another session of the same client may still use the old key,
    # and cutting it off made sessions ask (and be approved) again in turns. The oldest go past $AccessMaxKeys.
    $c = $script:Access.Clients[$p.Client]
    $old = [bool]$c
    if (-not $c) { $c = @{ fingerprints = [System.Collections.Generic.List[string]]::new(); approved = ''; lastUsed = '' }; $script:Access.Clients[$p.Client] = $c }
    $c.fingerprints.Add($fp); $c.approved = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    while ($c.fingerprints.Count -gt $script:AccessMaxKeys) { $script:Access.ByPrint.Remove($c.fingerprints[0]); $c.fingerprints.RemoveAt(0) }
    $script:Access.ByPrint[$fp] = $p.Client
    $p.State = 'approved'; $p.Key = $key
    # Every other request from this client that's still waiting is answered with the same key (parallel sessions).
    foreach ($o in @($script:Access.Pending | Where-Object { $_.Client -eq $p.Client -and $_.State -eq 'pending' })) { $o.State = 'approved'; $o.Key = $key }
    Save-CWebAccess
    Write-Host "[$(Get-Date -Format HH:mm:ss)] access approved: '$($p.Client)'$(if ($old) { ' (adds a key; its other keys keep working)' })" -ForegroundColor Green
    return @{ success = $true; approved = $p.Client }
}

function Revoke-CWebClient {
    param([string]$Client)
    $c = $script:Access.Clients[$Client]
    if (-not $c) { return @{ success = $false; error = "'$Client' isn't an approved client." } }
    foreach ($fp in @($c.fingerprints)) { $script:Access.ByPrint.Remove($fp) }   # every key of this client
    $script:Access.Clients.Remove($Client)
    Save-CWebAccess
    Write-Host "[$(Get-Date -Format HH:mm:ss)] access revoked: '$Client'" -ForegroundColor Yellow
    return @{ success = $true; revoked = $Client }
}

function Get-AccessStatus {
    # For /status.json (no key needed, so no tickets and no keys here).
    Remove-ExpiredAttach
    $now = Get-Date
    [ordered]@{
        pending = @($script:Access.Pending | Where-Object State -eq 'pending' | ForEach-Object {
            [ordered]@{
                ref       = $_.Ref
                client    = $_.Client
                requested = $_.Requested.ToString('HH:mm:ss')
                expiresIn = [int]($_.Requested.AddMinutes($script:AccessPendingMinutes) - $now).TotalSeconds
                replaces  = $_.Replaces
            }
        })
        clients = @($script:Access.Clients.Keys | Sort-Object | ForEach-Object {
            $c = $script:Access.Clients[$_]
            [ordered]@{ name = $_; approved = $c.approved; lastUsed = $c.lastUsed }
        })
    }
}
