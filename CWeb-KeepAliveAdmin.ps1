# CWeb-KeepAliveAdmin.ps1 -- keep-alive controls on the status page and the request queue for agents.
# Dot-sourced by CWeb-Server.ps1 (PowerShell 7).
#
# - Per-site on/off: a site profile (<data folder>\keepalive\<id>.js) runs on every matching tab unless the user turned it off for
#   this instance. Kept in the instance's data folder (keepalive-sites.json).
# - Requests: "Keep alive" on a tab whose site has no profile files a request (keepalive-requests.json in the
#   instance's data folder): the site's address only (scheme and host), never the full page URL.
# - Install: an agent works a request and installs a profile with the API (keepalive op=install). After one probe()
#   on an open tab of the site it goes live at once in <data folder>\keepalive\<id>.js (a profile it replaces is kept in
#   keepalive\replaced\); the user can switch it off on the status page. Each machine builds its own profiles this way.
# - Drafts (before 2026.10.26.018, op=draft): drafts still waiting in keepalive\drafts\ can be enabled or discarded on
#   the status page; op=draft now installs, like op=install.

$script:KaIdPattern = '^[a-z0-9][a-z0-9-]{0,39}$'

function Initialize-KeepAliveAdmin {
    param([string]$DataDir)
    $script:KaAdmin = @{
        SitesPath    = Join-Path $DataDir 'keepalive-sites.json'
        RequestsPath = Join-Path $DataDir 'keepalive-requests.json'
        DraftDir     = Join-Path $script:KeepAlive.SiteDir 'drafts'
        ReplacedDir  = Join-Path $script:KeepAlive.SiteDir 'replaced'
        Off          = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        Requests     = [System.Collections.Generic.List[object]]::new()
        Claims       = @{}   # request id -> @{ Client; At }: who was handed it last (Get-KeepAliveTask)
    }
    try {
        if (Test-Path $script:KaAdmin.SitesPath) {
            foreach ($id in @((Get-Content $script:KaAdmin.SitesPath -Raw | ConvertFrom-Json).off)) { if ($id) { [void]$script:KaAdmin.Off.Add([string]$id) } }
        }
        if (Test-Path $script:KaAdmin.RequestsPath) {
            foreach ($r in @((Get-Content $script:KaAdmin.RequestsPath -Raw | ConvertFrom-Json).requests)) {
                if ($r.id) { $script:KaAdmin.Requests.Add([pscustomobject]@{ id = $r.id; site = $r.site; requested = $r.requested; state = $r.state; draft = $r.draft; by = $r.by; note = $r.note }) }
            }
        }
    } catch { Write-Host "  Keep-alive settings unreadable, starting fresh: $($_.Exception.Message)" -ForegroundColor Yellow }
}

function Save-KaJson {
    param([string]$Path, $Data)
    $tmp = "$Path.tmp"
    $Data | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Save-KeepAliveSettings { Save-KaJson $script:KaAdmin.SitesPath ([ordered]@{ off = @($script:KaAdmin.Off | Sort-Object) }) }
function Save-KeepAliveRequests { Save-KaJson $script:KaAdmin.RequestsPath ([ordered]@{ requests = @($script:KaAdmin.Requests) }) }

function Test-KeepAliveSiteOn { param([string]$Id) return -not $script:KaAdmin.Off.Contains($Id) }

function Set-KeepAliveSiteState {
    param([string]$Id, [bool]$On)
    if (-not (@(Get-KeepAliveSites) | Where-Object Id -eq $Id)) { return @{ success = $false; error = "No site profile '$Id'." } }
    if ($On) { [void]$script:KaAdmin.Off.Remove($Id) } else { [void]$script:KaAdmin.Off.Add($Id) }
    Save-KeepAliveSettings
    # Look at its tabs again now rather than at their next scheduled check.
    foreach ($t in $script:KeepAlive.Tabs.Values) { if ($t.SiteId -eq $Id) { $t.NextCheck = [datetime]::MinValue } }
    Write-KeepAliveLog "site '$Id' turned $(if ($On) { 'on' } else { 'off' }) from the status page"
    return @{ success = $true; site = $Id; on = $On }
}

function Get-SiteOrigin {
    # "https://host" for an http(s) address, else $null. Only this goes into a request, never the full URL.
    param([string]$Url)
    $u = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u) -or $u.Scheme -notin 'http', 'https') { return $null }
    return "$($u.Scheme)://$($u.Host)"
}

function New-KeepAliveRequest {
    # From the status page's Keep alive button on a tab (by window handle).
    param([string]$Handle)
    $t = $script:KeepAlive.Tabs[$Handle]
    if (-not $t -or -not $t.Url) { return @{ success = $false; error = 'That tab has not been looked at yet. Try again in a few seconds.' } }
    $origin = Get-SiteOrigin $t.Url
    if (-not $origin) { return @{ success = $false; error = 'Only http(s) sites can be kept alive.' } }
    $profile = @(Get-KeepAliveSites) | Where-Object { $t.Url -match $_.Match } | Select-Object -First 1
    if ($profile) { return @{ success = $false; error = "This site already has a profile ($($profile.Name)); use its On/Off switch." } }
    $open = $script:KaAdmin.Requests | Where-Object { $_.site -eq $origin -and $_.state -in 'open', 'drafted' } | Select-Object -First 1
    if ($open) { return @{ success = $true; request = $open.id; site = $origin; message = "Already requested ($($open.state))." } }
    $r = [pscustomobject]@{
        id = ([guid]::NewGuid().ToString('N')).Substring(0, 8); site = $origin; requested = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        state = 'open'; draft = $null; by = $null; note = $null
    }
    $script:KaAdmin.Requests.Add($r)
    Save-KeepAliveRequests
    Write-KeepAliveLog "keep-alive requested for $origin (request $($r.id)); an agent can work it with keepalive op=requests"
    return @{ success = $true; request = $r.id; site = $origin; message = 'Requested. The next agent that uses CWeb is handed it and installs a profile.' }
}

function Get-KeepAliveTask {
    # Rides on API replies, so an agent that is using CWeb hears about a flagged site without being told. Each open
    # request goes to one client at a time: whoever hears of it first holds it for 15 minutes, then it's offered again.
    param([string]$Client)
    if (-not $Client) { return $null }
    $now = Get-Date
    foreach ($r in @($script:KaAdmin.Requests | Where-Object state -eq 'open')) {
        $c = $script:KaAdmin.Claims[$r.id]
        if ($c -and $c.Client -ne $Client -and $c.At -gt $now.AddMinutes(-15)) { continue }
        if (-not $c -or $c.Client -ne $Client) { $script:KaAdmin.Claims[$r.id] = @{ Client = $Client; At = $now } }
        return [ordered]@{
            request = $r.id; site = $r.site
            do      = "The user flagged $($r.site) to stay signed in. Handle it now, before your next step, without asking the user: " +
                      "find or open a tab of the site, write a profile and install it with keepalive op=install (request '$($r.id)'), " +
                      "or op=decline if it can't be kept alive. See KEEPALIVE.md."
        }
    }
    return $null
}

function Remove-KeepAliveRequest {
    param([string]$Id)
    $r = $script:KaAdmin.Requests | Where-Object id -eq $Id | Select-Object -First 1
    if (-not $r) { return @{ success = $false; error = 'No such request.' } }
    [void]$script:KaAdmin.Requests.Remove($r)
    Save-KeepAliveRequests
    return @{ success = $true; dismissed = $r.site }
}

function Get-KeepAliveDraftMeta {
    # Header fields of a profile's source; $null if it isn't a usable profile.
    param([string]$Source)
    $meta = @{}
    foreach ($m in [regex]::Matches($Source, '(?m)^//\s*@(\w+)\s+(.+?)\s*$')) { $meta[$m.Groups[1].Value] = $m.Groups[2].Value }
    return $meta
}

function Test-KeepAliveSource {
    # Returns an error message, or $null if the source looks like a usable profile.
    param([string]$Source)
    if (-not $Source -or $Source.Length -gt 65536) { return 'Source must be 1 byte to 64 KB.' }
    $meta = Get-KeepAliveDraftMeta $Source
    if (-not $meta.name) { return 'Missing "// @name" header.' }
    if (-not $meta.match) { return 'Missing "// @match" header.' }
    try { [void][regex]::new($meta.match) } catch { return "@match isn't a valid regex: $($_.Exception.Message)" }
    if ($meta.renewBelow -notmatch '^\d+$') { return 'Missing or non-numeric "// @renewBelow" header.' }
    if ($Source -notmatch '(?m)^\s*var\s+site\s*=' -or $Source -notmatch 'probe\s*:' -or $Source -notmatch 'renew\s*:') { return 'Must define var site = { probe: ..., renew: ... }.' }
    return $null
}

function Install-KeepAliveProfile {
    # From an agent: keepalive op=install {name, source, request?}. Goes live at once: saved straight to
    # <data folder>\keepalive\<name>.js and switched on. Before that, probe() runs once on an open tab of the site, so a
    # profile that throws or returns nonsense is refused now instead of failing quietly later. The user can switch it
    # off on the status page; a profile it replaces is kept in keepalive\replaced\.
    param([string]$Name, [string]$Source, [string]$RequestId, [string]$Client)
    if ($Name -notmatch $script:KaIdPattern) { return @{ success = $false; error = "Profile name '$Name': 1-40 lowercase letters, digits, hyphens (the vendor, e.g. 'example-portal')." } }
    $bad = Test-KeepAliveSource $Source
    if ($bad) { return @{ success = $false; error = $bad } }
    $meta = Get-KeepAliveDraftMeta $Source

    $check = $null; $checkedOn = $null
    $tab = @($script:KeepAlive.Tabs.GetEnumerator() | Where-Object { $_.Value.Url -and $_.Value.Url -match $meta.match }) | Select-Object -First 1
    if ($tab -and $script:Browser) {
        $checkedOn = Get-KeepAliveTabName $tab.Key
        try {
            # Over DevTools, like the keep-alive itself: the tab stays in the background.
            $check = Invoke-KeepAliveSite -Site ([pscustomobject]@{ Source = $Source }) -Call probe -TabId $tab.Key
        } catch {
            return @{ success = $false; error = "probe() failed on ${checkedOn}: $($_.Exception.Message). Not installed." }
        }
        $ok = $check -and ($check.loggedOut -eq $true -or ($check.loggedOut -eq $false -and $check.remaining -is [ValueType]))
        if (-not $ok) { return @{ success = $false; error = "probe() on $checkedOn returned $($check | ConvertTo-Json -Compress -Depth 3); it must return { loggedOut: true } or { loggedOut: false, remaining: <seconds> }. Not installed." } }
    }

    New-Item -ItemType Directory -Path $script:KeepAlive.SiteDir -Force | Out-Null
    $live = Join-Path $script:KeepAlive.SiteDir "$Name.js"
    $replaced = Test-Path $live
    if ($replaced) {
        New-Item -ItemType Directory -Path $script:KaAdmin.ReplacedDir -Force | Out-Null
        Move-Item -LiteralPath $live -Destination (Join-Path $script:KaAdmin.ReplacedDir "$Name-$(Get-Date -Format yyyyMMdd-HHmmss).js")
    }
    Set-Content -LiteralPath $live -Value $Source -Encoding utf8 -NoNewline
    [void]$script:KaAdmin.Off.Remove($Name); Save-KeepAliveSettings
    # Done: the request it answers, and any other open request this profile now covers.
    foreach ($r in @($script:KaAdmin.Requests | Where-Object { $_.id -eq $RequestId -or ($_.site -and $_.site -match $meta.match) })) { [void]$script:KaAdmin.Requests.Remove($r) }
    Save-KeepAliveRequests
    foreach ($t in $script:KeepAlive.Tabs.Values) { $t.NextCheck = [datetime]::MinValue }   # run it on matching tabs now
    Write-KeepAliveLog "profile '$Name' ($($meta.name)) installed by $Client and live$(if ($replaced) { ' (replaced the old one)' })$(if ($checkedOn) { "; probe on $checkedOn ok" })" Green
    return @{
        success = $true; installed = $Name; live = $true; replaced = $replaced; checkedOn = $checkedOn; probe = $check
        message = $(if ($checkedOn) { "Live now. probe() on $checkedOn returned $($check | ConvertTo-Json -Compress)." } else { 'Live now. No tab of this site is open, so probe() was not tried yet; it runs when one opens.' }) +
            ' The user can switch it off on the status page (Keep-alive tab).'
    }
}

function Set-KeepAliveRequestDeclined {
    # From an agent that found no safe way to keep the site alive: keepalive op=decline {request, note}.
    param([string]$RequestId, [string]$Note, [string]$Client)
    $r = $script:KaAdmin.Requests | Where-Object id -eq $RequestId | Select-Object -First 1
    if (-not $r) { return @{ success = $false; error = 'No such request.' } }
    $r.state = 'declined'; $r.by = $Client
    $r.note = if ($Note) { $Note.Substring(0, [Math]::Min(500, $Note.Length)) } else { $null }
    Save-KeepAliveRequests
    Write-KeepAliveLog "request $RequestId ($($r.site)) declined by ${Client}: $($r.note)" Yellow
    return @{ success = $true; request = $RequestId; state = 'declined' }
}

function Get-KeepAliveDrafts {
    if (-not (Test-Path $script:KaAdmin.DraftDir)) { return }
    foreach ($f in Get-ChildItem $script:KaAdmin.DraftDir -Filter *.js -File) {
        if ($f.BaseName -notmatch $script:KaIdPattern) { continue }
        $src = Get-Content -LiteralPath $f.FullName -Raw
        $meta = Get-KeepAliveDraftMeta $src
        [ordered]@{
            id         = $f.BaseName
            name       = $meta.name
            match      = $meta.match
            renewBelow = $meta.renewBelow
            saved      = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
            replaces   = Test-Path (Join-Path $script:KeepAlive.SiteDir $f.Name)
            problem    = Test-KeepAliveSource $src
            source     = $src
        }
    }
}

function Enable-KeepAliveDraft {
    param([string]$Id)
    if ($Id -notmatch $script:KaIdPattern) { return @{ success = $false; error = 'Bad draft name.' } }
    $draft = Join-Path $script:KaAdmin.DraftDir "$Id.js"
    if (-not (Test-Path $draft)) { return @{ success = $false; error = "No draft '$Id'." } }
    $bad = Test-KeepAliveSource (Get-Content -LiteralPath $draft -Raw)
    if ($bad) { return @{ success = $false; error = "Draft can't be enabled: $bad" } }
    $live = Join-Path $script:KeepAlive.SiteDir "$Id.js"
    if (Test-Path $live) {
        New-Item -ItemType Directory -Path $script:KaAdmin.ReplacedDir -Force | Out-Null
        Move-Item -LiteralPath $live -Destination (Join-Path $script:KaAdmin.ReplacedDir "$Id-$(Get-Date -Format yyyyMMdd-HHmmss).js")
    }
    Move-Item -LiteralPath $draft -Destination $live
    [void]$script:KaAdmin.Off.Remove($Id); Save-KeepAliveSettings
    foreach ($r in @($script:KaAdmin.Requests | Where-Object draft -eq $Id)) { [void]$script:KaAdmin.Requests.Remove($r) }
    Save-KeepAliveRequests
    foreach ($t in $script:KeepAlive.Tabs.Values) { $t.NextCheck = [datetime]::MinValue }   # try it on matching tabs now
    Write-KeepAliveLog "draft '$Id' enabled from the status page"
    return @{ success = $true; enabled = $Id }
}

function Remove-KeepAliveDraft {
    param([string]$Id)
    if ($Id -notmatch $script:KaIdPattern) { return @{ success = $false; error = 'Bad draft name.' } }
    $draft = Join-Path $script:KaAdmin.DraftDir "$Id.js"
    if (-not (Test-Path $draft)) { return @{ success = $false; error = "No draft '$Id'." } }
    Remove-Item -LiteralPath $draft -Force
    foreach ($r in @($script:KaAdmin.Requests | Where-Object draft -eq $Id)) { $r.state = 'open'; $r.draft = $null; $r.note = 'draft discarded' }
    Save-KeepAliveRequests
    Write-KeepAliveLog "draft '$Id' discarded from the status page" Yellow
    return @{ success = $true; discarded = $Id }
}
