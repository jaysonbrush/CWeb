# CWeb-KeepAlive.ps1 -- keeps flagged sites signed in. Dot-sourced by CWeb-Server.ps1.
#
# One file per site in <data folder>\keepalive\<id>.js, shared by every instance on this machine (never in git):
#   // @name        Example
#   // @url         https://app.example.com/            the page CWeb keeps open for it, in its own background tab
#   // @match       ^https://([^/]+\.)?example\.com/    the site's pages (a regex)
#   // @renewBelow  300                                 renew when fewer seconds than this are left
#   var site = { probe: function () { return { loggedOut: false, remaining: 1234 }; }, renew: function () { ... } };
# probe() only reads (signed out? seconds left?); renew() extends the session without reloading. Either may return a
# promise. Each site gets its own tab, named keepalive-<id>, opened in the background; everything runs over DevTools,
# so no tab is switched to and no agent is involved. Adding a site (keepalive op add, or Add on the status page) tests
# it on the live site first and saves it only if probe() works.

function Write-KeepAliveLog {
    param([string]$Message, [string]$Color = 'Cyan')
    Write-Host "[$(Get-Date -Format HH:mm:ss)] [keepalive] $Message" -ForegroundColor $Color
    $script:KeepAlive.Events.Insert(0, [ordered]@{ time = (Get-Date -Format 'HH:mm:ss'); warn = ($Color -ne 'Cyan'); message = $Message })
    if ($script:KeepAlive.Events.Count -gt 100) { $script:KeepAlive.Events.RemoveAt(100) }
}

function Read-KeepAliveSource {
    # The site described by one profile's text, or throws why it can't be used.
    param([string]$Source, [string]$Id)
    $meta = @{}
    foreach ($m in [regex]::Matches($Source, '(?m)^//\s*@(\w+)\s+(.+?)\s*$')) { $meta[$m.Groups[1].Value] = $m.Groups[2].Value }
    if (-not $meta.match) { throw 'It needs a "// @match <regex>" line.' }
    try { $null = [regex]::new($meta.match) } catch { throw "@match isn't a valid regex: $($_.Exception.Message)" }
    if ($meta.url) {
        $u = $null
        if (-not [Uri]::TryCreate($meta.url, [UriKind]::Absolute, [ref]$u) -or $u.Scheme -notin 'http', 'https') { throw '@url must be a full http(s) address.' }
        if ($meta.url -notmatch $meta.match) { throw "@url ($($meta.url)) doesn't match @match ($($meta.match))." }
    }
    if ($Source -notmatch '\bvar\s+site\s*=' -or $Source -notmatch '\bprobe\b' -or $Source -notmatch '\brenew\b') { throw 'It must define var site = { probe: ..., renew: ... }.' }
    $name = if ($meta.name) { $meta.name } else { $Id }
    if (-not $Id) { $Id = ($name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-') }
    if ($Id -notmatch '^[a-z0-9][a-z0-9-]{0,39}$') { throw "Site id '$Id': use letters, digits and hyphens (from @name)." }
    [pscustomobject]@{
        Id         = $Id
        Name       = $name
        Url        = $meta.url
        Match      = $meta.match
        RenewBelow = if ($meta.renewBelow) { [int]$meta.renewBelow } else { 300 }
        Source     = $Source
    }
}

function Get-KeepAliveSites {
    if (-not (Test-Path $script:KeepAlive.SiteDir)) { return }
    foreach ($f in Get-ChildItem $script:KeepAlive.SiteDir -Filter *.js -File) {
        try { Read-KeepAliveSource -Source (Get-Content -LiteralPath $f.FullName -Raw) -Id $f.BaseName }
        catch { Write-Host "  (keep-alive $($f.Name) skipped: $($_.Exception.Message))" -ForegroundColor DarkYellow }
    }
}

function Get-KeepAliveState {
    param([string]$Id)
    if (-not $script:KeepAlive.Sites.ContainsKey($Id)) {
        $script:KeepAlive.Sites[$Id] = @{ Tab = $null; NextCheck = [datetime]::MinValue; LoggedOut = $false; Remaining = $null; CheckedAt = $null; LastRenew = $null; Last = 'not checked yet' }
    }
    return $script:KeepAlive.Sites[$Id]
}

function Invoke-KeepAliveSite {
    # Runs the profile's probe() or renew() in its tab over DevTools.
    param($Site, [ValidateSet('probe', 'renew')][string]$Call, [string]$TabId)
    # Marks the tab as the site's (sessionStorage survives Chrome restoring the tab), so a restart finds it again.
    $mark = "try { sessionStorage.setItem('cweb-keepalive', $(ConvertTo-Json $Site.Id)); } catch (e) {}"
    $js = "(function () {`n$mark`n" + $Site.Source + "`n;return Promise.resolve(site.$Call()).then(function (r) { return JSON.stringify(r === undefined ? null : r); });`n})()"
    $raw = Invoke-DevToolsScript -TabId $TabId -Expression $js
    return $raw | ConvertFrom-Json
}

function Get-KeepAliveTab {
    # The site's own tab: the one CWeb opened for it, else (no @url) any open tab on the site. Opens it if needed;
    # returns $null when it was only just opened (still loading).
    param($Site, $State, [hashtable]$Pages)
    if ($State.Tab -and $Pages.ContainsKey($State.Tab)) { return $State.Tab }
    $State.Tab = $null
    $onSite = @($Pages.Values | Where-Object { [string]$_.url -match $Site.Match })
    if (-not $Site.Url) { return ($onSite | Select-Object -First 1).id }
    $name = "keepalive-$($Site.Id)"
    # Its tab from before a restart (Chrome restored it): marked in sessionStorage by an earlier check.
    foreach ($p in $onSite) {
        try { $mine = (Invoke-DevToolsScript -TabId ([string]$p.id) -Expression "sessionStorage.getItem('cweb-keepalive')" -TimeoutSeconds 5) -eq $Site.Id } catch { $mine = $false }
        if (-not $mine) { continue }
        foreach ($n in @($script:Browser.Tabs.Keys | Where-Object { $script:Browser.Tabs[$_] -eq [string]$p.id })) { $script:Browser.Tabs.Remove($n) }
        $State.Tab = [string]$p.id
        $script:Browser.Tabs[$name] = $State.Tab
        return $State.Tab
    }
    $id = New-DevToolsTab -Url $Site.Url
    $State.Tab = $id
    $script:Browser.Tabs[$name] = $id
    Write-KeepAliveLog "$($Site.Name): opened its tab ($name, $($Site.Url))"
    return $null
}

function Wait-KeepAliveTab {
    # Waits (up to 30 s) for a tab's page to finish loading.
    param([string]$TabId)
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        try { if ((Invoke-DevToolsScript -TabId $TabId -Expression 'document.readyState' -TimeoutSeconds 5) -eq 'complete') { return } } catch { }
        Start-Sleep -Milliseconds 500
    }
}

function Test-KeepAliveSite {
    # One check of a site in its tab: probe, and renew if it's running low. Updates its state; returns the probe.
    param($Site, $State, [string]$TabId, [switch]$AlwaysRenew)
    $ka = $script:KeepAlive
    $now = Get-Date
    $page = (Get-DevToolsTabs)[$TabId]
    if ($Site.Url -and [string]$page.url -notmatch $Site.Match) {
        # Left the site (a sign-in page elsewhere, or someone navigated it): that's signed out; send it back.
        if (-not $State.LoggedOut) { Write-KeepAliveLog "$($Site.Name) is signed out (its tab is on $($page.url)). Sign in again in the CWeb window." Yellow }
        $State.LoggedOut = $true; $State.Remaining = $null; $State.Last = "signed out (tab on $($page.url))"
        $State.NextCheck = $now.AddSeconds(300)
        try { $null = Invoke-DevToolsScript -TabId $TabId -Expression "location.href = $(ConvertTo-Json $Site.Url)" } catch { }
        return $null
    }
    $p = Invoke-KeepAliveSite -Site $Site -Call probe -TabId $TabId
    if ($null -eq $p -or $null -eq $p.loggedOut) { throw 'probe() must return { loggedOut, remaining }.' }
    $State.CheckedAt = Get-Date
    if ($p.loggedOut) {
        if (-not $State.LoggedOut) { Write-KeepAliveLog "$($Site.Name) is signed out. Sign in again in the CWeb window (tab keepalive-$($Site.Id))." Yellow }
        $State.LoggedOut = $true; $State.Remaining = $null; $State.Last = 'signed out'
        $State.NextCheck = $now.AddSeconds(120)
        return $p
    }
    if ($null -eq ($p.remaining -as [double])) { throw 'probe() returned no number in remaining.' }
    if ($State.LoggedOut) { Write-KeepAliveLog "$($Site.Name) is signed in again." }
    $State.LoggedOut = $false
    $left = [int]$p.remaining
    $State.Last = "ok, ${left}s left"
    if ($left -le $Site.RenewBelow -or $AlwaysRenew) {
        $how = Invoke-KeepAliveSite -Site $Site -Call renew -TabId $TabId
        Start-Sleep -Seconds 2   # some sites renew asynchronously
        $p2 = Invoke-KeepAliveSite -Site $Site -Call probe -TabId $TabId
        $after = if ($p2.loggedOut) { 0 } else { [int]$p2.remaining }
        $State.LastRenew = Get-Date
        $State.Last = "renewed ${left}s -> ${after}s ($how)"
        if ($after -le $left -and -not $AlwaysRenew) {
            Write-KeepAliveLog "$($Site.Name): renew did not extend the session: $($State.Last)" Yellow
            $State.Remaining = $after; $State.NextCheck = $now.AddSeconds(60)
            return $p2
        }
        Write-KeepAliveLog "$($Site.Name): $($State.Last)"
        $left = $after
    }
    $State.Remaining = $left
    $State.NextCheck = $now.AddSeconds([math]::Max(30, [math]::Min($ka.MaxCheckSeconds, $left - $Site.RenewBelow - 15)))
    return $p
}

function Invoke-KeepAliveTick {
    # Runs between requests. Checks each site when it's due; opens Chrome again if it was closed and sites need it.
    param([switch]$Force)
    $ka = $script:KeepAlive
    $ka.LastTick = Get-Date
    $sites = @(Get-KeepAliveSites)
    if (-not $ka.Enabled -or -not $sites.Count) { return }
    if (-not (Confirm-InstanceBrowser)) { return }
    $pages = Get-DevToolsTabs
    foreach ($id in @($ka.Sites.Keys)) { if ($id -notin $sites.Id) { $ka.Sites.Remove($id) } }
    $now = Get-Date
    foreach ($site in $sites) {
        $st = Get-KeepAliveState $site.Id
        if (-not $Force -and $st.NextCheck -gt $now) { continue }
        try {
            $tab = Get-KeepAliveTab -Site $site -State $st -Pages $pages
            if (-not $tab) {
                $st.Last = if ($site.Url) { 'tab opening' } else { 'no tab open on the site (add a // @url line)' }
                $st.NextCheck = $now.AddSeconds($(if ($site.Url) { 15 } else { 120 }))
                continue
            }
            Test-KeepAliveSite -Site $site -State $st -TabId $tab | Out-Null
        } catch {
            $st.Last = "error: $($_.Exception.Message)"
            $st.NextCheck = $now.AddSeconds(120)
            Write-KeepAliveLog "$($site.Name): $($st.Last)" Yellow
        }
    }
}

function Add-KeepAliveSite {
    # Tests a profile on the live site (opens its tab, probe(), and renew() if signed in) and saves it if probe works.
    # The same id again replaces that site's profile.
    param([string]$Source)
    try { $site = Read-KeepAliveSource -Source $Source } catch { return @{ success = $false; error = "Not added: $($_.Exception.Message)" } }
    if (-not $site.Url) { return @{ success = $false; error = 'Not added: it needs a "// @url <address>" line (the page CWeb keeps open for it).' } }
    if (-not (Confirm-InstanceBrowser)) { return @{ success = $false; error = "Not added: Chrome isn't running ($script:BrowserStartError)." } }
    $st = Get-KeepAliveState $site.Id
    $pages = Get-DevToolsTabs
    $tab = Get-KeepAliveTab -Site $site -State $st -Pages $pages
    if (-not $tab) { $tab = $st.Tab }
    Wait-KeepAliveTab -TabId $tab
    try { $p = Test-KeepAliveSite -Site $site -State $st -TabId $tab -AlwaysRenew }
    catch { return @{ success = $false; error = "Not added: it failed on the live site: $($_.Exception.Message)"; tab = "keepalive-$($site.Id)" } }
    New-Item -ItemType Directory -Path $script:KeepAlive.SiteDir -Force | Out-Null
    $path = Join-Path $script:KeepAlive.SiteDir "$($site.Id).js"
    $existed = Test-Path $path
    Set-Content -LiteralPath "$path.tmp" -Value $Source -NoNewline -Encoding utf8
    Move-Item -LiteralPath "$path.tmp" -Destination $path -Force
    Write-KeepAliveLog "$($site.Name): $(if ($existed) { 'profile replaced' } else { 'added' }) ($($st.Last))"
    $msg = if ($st.LoggedOut) { "Saved. $($site.Name) is signed out in CWeb: sign in on tab keepalive-$($site.Id), and it's kept signed in from then on." }
           else { "Saved and running: $($site.Name) $($st.Last)." }
    return @{ success = $true; site = $site.Id; name = $site.Name; signedIn = -not $st.LoggedOut; result = $st.Last; message = $msg }
}

function Remove-KeepAliveSite {
    param([string]$Id)
    $path = Join-Path $script:KeepAlive.SiteDir "$Id.js"
    if ($Id -notmatch '^[a-z0-9][a-z0-9-]{0,39}$' -or -not (Test-Path $path)) { return @{ success = $false; error = "No keep-alive site '$Id'." } }
    Remove-Item -LiteralPath $path -Force
    $st = $script:KeepAlive.Sites[$Id]
    if ($st -and $st.Tab -and $script:Browser) {
        Close-DevToolsTab -TabId $st.Tab
        $script:Browser.Tabs.Remove("keepalive-$Id")
    }
    $script:KeepAlive.Sites.Remove($Id)
    Write-KeepAliveLog "$Id removed"
    return @{ success = $true; removed = $Id }
}

function Get-KeepAliveStatus {
    # One row per site, for /status.json and the keepalive action.
    foreach ($site in @(Get-KeepAliveSites)) {
        $st = Get-KeepAliveState $site.Id
        [ordered]@{
            id                 = $site.Id
            name               = $site.Name
            url                = $site.Url
            match              = $site.Match
            state              = if ($st.Last -like 'error*') { 'error' } elseif ($st.LoggedOut) { 'signed out' } elseif ($null -ne $st.Remaining) { 'signed in' } else { 'waiting' }
            secondsLeftAtCheck = $st.Remaining
            checkedAt          = if ($st.CheckedAt) { [DateTimeOffset]::new($st.CheckedAt).ToUnixTimeMilliseconds() } else { $null }
            last               = $st.Last
            lastRenew          = if ($st.LastRenew) { $st.LastRenew.ToString('HH:mm:ss') } else { $null }
            tab                = "keepalive-$($site.Id)"
            source             = $site.Source
        }
    }
}
