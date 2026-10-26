# CWeb-KeepAliveAdmin.ps1 -- keep-alive controls on the status page and the request queue for agents.
# Dot-sourced by CWeb-Server.ps1 (PowerShell 7).
#
# - Per-site on/off: a site profile (<data folder>\keepalive\<id>.js) runs on every matching tab unless the user turned it off for
#   this instance. Kept in the instance's data folder (keepalive-sites.json).
# - Requests: "Keep alive" on a tab whose site has no profile files a request (keepalive-requests.json in the
#   instance's data folder): the site's address only (scheme and host), never the full page URL.
# - Drafts: an agent works a request and submits a profile with the API (keepalive op=draft). It's saved to
#   <data folder>\keepalive\drafts\<id>.js, which the keep-alive never reads. It runs only after the user clicks Enable on the
#   status page, which moves it to <data folder>\keepalive\<id>.js (a profile it replaces is kept in keepalive\replaced\).
#   CWeb ships with no profiles: each machine builds its own this way.

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
    return @{ success = $true; request = $r.id; site = $origin; message = 'Requested. Ask an agent to work the CWeb keep-alive requests.' }
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

function Add-KeepAliveDraft {
    # From an agent: keepalive op=draft {name, source, request?}.
    param([string]$Name, [string]$Source, [string]$RequestId, [string]$Client)
    if ($Name -notmatch $script:KaIdPattern) { return @{ success = $false; error = "Draft name '$Name': 1-40 lowercase letters, digits, hyphens (the vendor, e.g. 'example-portal')." } }
    $bad = Test-KeepAliveSource $Source
    if ($bad) { return @{ success = $false; error = $bad } }
    New-Item -ItemType Directory -Path $script:KaAdmin.DraftDir -Force | Out-Null
    $path = Join-Path $script:KaAdmin.DraftDir "$Name.js"
    Set-Content -LiteralPath $path -Value $Source -Encoding utf8 -NoNewline
    if ($RequestId) {
        $r = $script:KaAdmin.Requests | Where-Object id -eq $RequestId | Select-Object -First 1
        if ($r) { $r.state = 'drafted'; $r.draft = $Name; $r.by = $Client; $r.note = $null; Save-KeepAliveRequests }
    }
    Write-KeepAliveLog "draft '$Name' submitted by $Client$(if ($RequestId) { " for request $RequestId" }) -- waiting for review on the status page" Yellow
    return @{ success = $true; draft = $Name; message = 'Saved as a draft. It runs only after the user enables it on the status page.' }
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
