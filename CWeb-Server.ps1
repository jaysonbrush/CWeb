#Requires -Version 7.0
<#
.SYNOPSIS
    CWeb server: a REST API that drives one Chrome window, shared by Claude agent sessions.

.DESCRIPTION
    One server per instance (instances.json). Each instance has its own port, Chrome profile, logs and
    state in %USERPROFILE%\CWebData\<instance>\, and only one server per instance can run.
    The server opens Chrome itself on start. Uses the core browser module (.\browser\Browser-Functions.ps1).

.EXAMPLE
    pwsh -File .\CWeb-Server.ps1 -Instance work
    Normally started by Start-CWeb.cmd, not by hand.
#>

param(
    [string]$Instance = 'work'
)

$ErrorActionPreference = "Stop"
$script:CWebRoot = $PSScriptRoot
$script:ChromeModulePath = Join-Path $PSScriptRoot "browser"
# Module version (YYYY.MM.DD.NNN) lives only in .\VERSION.
$script:ModuleVersion = try { (Get-Content (Join-Path $PSScriptRoot "VERSION") -Raw).Trim() } catch { "unknown" }

. (Join-Path $PSScriptRoot 'CWeb-Common.ps1')
try { $script:Inst = Get-CWebInstance -Name $Instance -Root $PSScriptRoot }
catch { Write-Error "CWeb: $($_.Exception.Message)"; exit 1 }
$script:InstanceName = $script:Inst.Name
New-Item -ItemType Directory -Path $script:Inst.DataDir -Force | Out-Null

# ---- One server per instance: a named lock held for the life of this process ----
$script:Lock = [System.Threading.Mutex]::new($false, $script:Inst.LockName)
try { $script:HaveLock = $script:Lock.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $script:HaveLock = $true }   # last server crashed; the lock is ours now
if (-not $script:HaveLock) {
    Write-Host "CWeb instance '$($script:InstanceName)' is already running (port $($script:Inst.Port)). Not starting a second server."
    exit 2
}

# ---- Logging: %USERPROFILE%\CWebData\<instance>\logs\server-<date>.log (whole console) + chromedriver-<date>.log ----
# Logs older than 7 days are deleted on each launch.
$script:LogDir = $script:Inst.LogDir
New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
Get-ChildItem $script:LogDir -File -Filter *.log -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | Remove-Item -Force -ErrorAction SilentlyContinue
$env:CWEB_LOGDIR = $script:LogDir   # Chrome-Start writes the chromedriver log here
try { Start-Transcript -Path (Join-Path $script:LogDir "server-$(Get-Date -Format yyyy-MM-dd).log") -Append | Out-Null } catch { }

# Startup diagnostics -- what usually breaks on a new machine.
Write-Host "==== CWeb server $($script:ModuleVersion) instance '$($script:InstanceName)' starting $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===="
Write-Host "  Machine: $env:COMPUTERNAME  User: $env:USERNAME  PowerShell: $($PSVersionTable.PSVersion)  OS: $([Environment]::OSVersion.VersionString)  64-bit: $([Environment]::Is64BitProcess)"
Write-Host "  Folder:  $PSScriptRoot"
Write-Host "  Data:    $($script:Inst.DataDir)"
foreach ($req in @('browser\Browser-Functions.ps1', 'browser\Selenium\Selenium.WebDriver.dll|browser\Selenium\WebDriver.dll', 'browser\chrome-win64\chrome.exe', 'browser\chromedriver-win64\chromedriver.exe', 'instances.json')) {
    # "a|b" = either file will do (Selenium renamed its DLL in 4.4x)
    $found = $req -split '\|' | Where-Object { Test-Path (Join-Path $PSScriptRoot $_) } | Select-Object -First 1
    Write-Host ("  {0,-45} {1}" -f $(if ($found) { $found } else { $req }), $(if ($found) { 'OK' } else { 'MISSING' }))
}
# Per-file try/catch: some drives (network shares) throw on alternate-stream reads even with SilentlyContinue --
# a file we can't check is simply skipped, never fatal.
# File.Exists on "<file>:Zone.Identifier" answers without throwing, so nothing lands in the server log for clean files.
$blocked = @(Get-ChildItem $PSScriptRoot -Recurse -File -Include *.ps1, *.dll, *.exe -ErrorAction SilentlyContinue | Where-Object {
    try { [System.IO.File]::Exists("$($_.FullName):Zone.Identifier") } catch { $false }
})
if ($blocked.Count) { Write-Host "  WARNING: $($blocked.Count) file(s) are marked as downloaded/blocked by Windows -- run: Get-ChildItem '$PSScriptRoot' -Recurse | Unblock-File" -ForegroundColor Yellow }

# Validate chrome module exists
$chromeFunctionsPath = Join-Path $script:ChromeModulePath "Browser-Functions.ps1"
if (-not (Test-Path $chromeFunctionsPath)) {
    Write-Error "Chrome module not found at: $script:ChromeModulePath"
    Write-Error "Expected Browser-Functions.ps1 at: $chromeFunctionsPath"
    Write-Error "Please ensure the 'browser' folder is in the CWeb folder"
    exit 1
}

# Load Chrome functions from the core module
. $chromeFunctionsPath

# Settings come from the instance (instances.json, config.json). The server only ever listens on this machine.
# $script:Port is final once the listener opens (Open-CWebListener): it may move off a port another program holds.
$script:Port = $script:Inst.ConfiguredPort
$script:ListenAddress = '127.0.0.1'
$script:ProfileDir = $script:Inst.ProfileDir

# Who may use the API: programs of this Windows user. They send the key from <data folder>\cweb.key, a file only this
# user can read (cweb.sh and CWeb-Client.ps1 do it for them). Web pages can't send it: a custom header needs a CORS
# preflight, which this server never approves.
$script:ApiKey = Initialize-CWebKey

# Browser state
$script:Browser = $null
$script:BrowserStartError = $null   # why the automatic start at launch failed, for the status page
$script:BrowserClosed = $null       # when Chrome was last found closed or not answering (it's reopened at once), for the status page
$script:LastStartAttempt = [datetime]::MinValue
$script:StopRequested = $false   # set by the status page's Stop server button

# Keep-alive (CWeb-KeepAlive.ps1): each flagged site in its own background tab, checked between API requests.
$script:KeepAlive = @{
    Enabled         = $script:Inst.KeepAliveEnabled
    TickSeconds     = $script:Inst.KeepAliveTick
    MaxCheckSeconds = $script:Inst.KeepAliveMax
    SiteDir         = Join-Path $script:Inst.DataRoot 'keepalive'   # this machine's site profiles (never in git)
    Sites           = @{}   # site id -> its tab and last check
    LastTick        = [datetime]::MinValue
    Events          = [System.Collections.Generic.List[object]]::new()   # recent renewals/warnings, for /status
}
. (Join-Path $PSScriptRoot 'CWeb-DevTools.ps1')   # reads and runs scripts in tabs without switching to them
. (Join-Path $PSScriptRoot 'CWeb-KeepAlive.ps1')

# Request stats for the /status page. Recent commands record the action and its target only,
# never typed text, scripts or cookie values.
$script:Stats = @{
    Started  = Get-Date
    Requests = 0
    Errors   = 0
    ByAction = @{}
    ByClient = @{}
    Recent   = [System.Collections.Generic.List[object]]::new()
}

function Send-Response {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [hashtable]$Data,
        [int]$StatusCode = 200
    )
    # Never throws: if the response was already (partly) sent or the client went away, log it and move on.
    # (A second Send-Response on the same request used to throw and take the whole server down.)
    try {
        $json = $Data | ConvertTo-Json -Depth 10 -Compress
        $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
        $Response.StatusCode = $StatusCode
        $Response.ContentType = "application/json"
        $Response.ContentLength64 = $buffer.Length
        $Response.OutputStream.Write($buffer, 0, $buffer.Length)
    } catch {
        Write-Host "  (response not sent: $($_.Exception.Message))" -ForegroundColor DarkYellow
    } finally {
        try { $Response.OutputStream.Close() } catch { }
    }
}

function Start-InstanceBrowser {
    # Opens Chrome on this instance's profile (or a throwaway one with -Persist $false, kept in the instance folder).
    param([bool]$Hidden = $false, [bool]$Persist = $true, [bool]$Stealth = $true)
    # Temp and throwaway folders a previous run couldn't delete (Chrome still held a file at shutdown). Only one
    # server per instance runs, so none of them is in use now.
    Get-ChildItem $script:Inst.DataDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(temp|throwaway)-\d+$' } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    $script:ChromeStartError = $null
    $script:Browser = Chrome-Start -Hidden $Hidden -Persist $Persist -UserDataPath $script:ProfileDir -WorkRoot $script:Inst.DataDir -WindowName "CWeb $($script:Inst.Label)" -Stealth $Stealth -ErrorAction SilentlyContinue
    if (-not $script:Browser) {
        # Chrome-Start returns $null on failure -- report it instead of claiming success.
        $why = if ($script:ChromeStartError) { $script:ChromeStartError } else { 'Chrome-Start returned nothing (no error captured).' }
        Write-Host "  START FAILED: $why" -ForegroundColor Red
        $script:BrowserStartError = $why
        return @{ success = $false; error = "Chrome did not start: $why" }
    }
    $script:BrowserStartError = $null
    $script:BrowserClosed = $null
    $where = if ($Persist) { $script:ProfileDir } else { 'throwaway profile' }
    Write-Host "  Browser started ($where)"
    return @{ success = $true; message = "Browser started"; profile = $where }
}

function Test-InstanceBrowser {
    # True if Chrome is open and ChromeDriver answers. Chrome can close under the server (its window closed, a crash),
    # and ChromeDriver can lose it; the driver then reports no tabs (WindowHandles is null) or a dead session. Any other
    # error (an alert is open, say) still counts as alive. One driver call.
    if (-not $script:Browser) { return $false }
    try { return [bool]@(@($script:Browser.Driver.WindowHandles) | Where-Object { $_ }).Count }
    catch { return $_.Exception.Message -notmatch 'invalid session|not reachable|disconnected|refused|session deleted|No connection could be made|timed out' }
}

function Confirm-InstanceBrowser {
    # Makes sure Chrome is open and answering before it's used: if it was closed, crashed or lost its ChromeDriver, the
    # leftovers are closed cleanly and Chrome opens again with its tabs and sign-ins. True when Chrome is ready.
    if (Test-InstanceBrowser) { return $true }
    if ($script:Browser) {
        Write-Host "[$(Get-Date -Format HH:mm:ss)] Chrome was closed or stopped answering; opening it again." -ForegroundColor Yellow
        $script:BrowserClosed = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        try { $script:Browser.Driver.Quit() } catch { }
        try { $script:Browser.Service.Dispose() } catch { }
        $script:Browser = $null
    }
    if (@(Get-ChromeProfileProcess -UserDataPath $script:ProfileDir).Count) {
        # A Chrome still open on the profile without a driver: close it the way its own Exit does, so nothing is lost.
        if (-not (Close-ChromeProfile -UserDataPath $script:ProfileDir -TimeoutSeconds 20)) { Close-ChromeProfile -UserDataPath $script:ProfileDir -TimeoutSeconds 1 -Force | Out-Null }
    }
    Reset-TabState
    # A start that just failed isn't retried for a minute (each try can take minutes).
    if ($script:BrowserStartError -and ((Get-Date) - $script:LastStartAttempt).TotalSeconds -lt 60) { return $false }
    $script:LastStartAttempt = Get-Date
    $r = Start-InstanceBrowser -Hidden $script:Inst.Hidden -Persist $true
    return [bool]$r.success
}

function Invoke-BrowserAction {
    param([hashtable]$Body)

    $action = $Body.action
    if (-not $action) {
        return @{ success = $false; error = "Missing 'action' parameter" }
    }

    try {
        switch ($action.ToLower()) {
            "start" {
                if ($script:Browser) {
                    return @{ success = $false; error = "Browser already running. Use 'stop' first." }
                }
                # Always this instance's profile; callers can't choose another one.
                $hidden = if ($Body.ContainsKey('hidden')) { [bool]$Body.hidden } else { $script:Inst.Hidden }
                $persist = -not ($Body.ContainsKey('persist') -and $Body.persist -eq $false)   # default on: the saved profile
                $stealth = -not ($Body.ContainsKey('stealth') -and $Body.stealth -eq $false)   # default on
                $r = Start-InstanceBrowser -Hidden $hidden -Persist $persist -Stealth $stealth
                if (-not $r.success) { $r.logs = $script:LogDir }
                return $r
            }

            "stop" {
                if (-not $script:Browser) {
                    return @{ success = $false; error = "No browser running" }
                }
                Chrome-Stop -Browser $script:Browser
                $script:Browser = $null
                return @{ success = $true; message = "Browser stopped" }
            }

            "navigate" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                if (-not $Body.url) { return @{ success = $false; error = "Missing 'url' parameter" } }
                Chrome-Navigate -Browser $script:Browser -Url $Body.url
                return @{ success = $true; url = $Body.url }
            }

            "gettitle" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                $title = Chrome-GetTitle -Browser $script:Browser
                return @{ success = $true; title = $title }
            }

            "geturl" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                $url = Chrome-GetCurrentUrl -Browser $script:Browser
                return @{ success = $true; url = $url }
            }

            "getpagesource" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                $source = Chrome-GetPageSource -Browser $script:Browser
                return @{ success = $true; source = $source }
            }

            "screenshot" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                if (-not $Body.filePath) { return @{ success = $false; error = "Missing 'filePath' parameter" } }
                $path = Chrome-Screenshot -Browser $script:Browser -FilePath $Body.filePath
                return @{ success = $true; filePath = $path }
            }

            "back" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                Chrome-Back -Browser $script:Browser
                return @{ success = $true }
            }

            "forward" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                Chrome-Forward -Browser $script:Browser
                return @{ success = $true }
            }

            "refresh" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                Chrome-Refresh -Browser $script:Browser
                return @{ success = $true }
            }

            "newtab" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                $url = if ($Body.url) { $Body.url } else { "about:blank" }
                $name = $Body.name
                if ($name) {
                    Chrome-NewTab -Browser $script:Browser -Url $url -Name $name
                } else {
                    Chrome-NewTab -Browser $script:Browser -Url $url
                }
                return @{ success = $true; url = $url; name = $name }
            }

            "switchtab" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                if (-not $Body.name) { return @{ success = $false; error = "Missing 'name' parameter" } }
                Chrome-SwitchTab -Browser $script:Browser -Name $Body.name
                return @{ success = $true; tab = $Body.name }
            }

            "closetab" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                Chrome-CloseTab -Browser $script:Browser
                return @{ success = $true }
            }

            "listtabs" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                # Every tab, by name (tabs opened by hand are named after their site), without switching to any.
                $pages = Update-TabNames
                $details = @($script:Browser.Tabs.GetEnumerator() | Where-Object { $pages.ContainsKey($_.Value) } | Sort-Object Name | ForEach-Object {
                    [ordered]@{ name = $_.Name; title = [string]$pages[$_.Value].title; url = [string]$pages[$_.Value].url; keepAlive = $_.Name.StartsWith('keepalive-') }
                })
                return @{ success = $true; tabs = @($details | ForEach-Object { $_.name }); details = $details }
            }

            "findelement" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                if (-not $Body.by -or -not $Body.value) { return @{ success = $false; error = "Missing 'by' or 'value' parameter" } }
                $element = Chrome-FindElement -Browser $script:Browser -By $Body.by -Value $Body.value
                return @{ success = $true; found = $true; tagName = $element.TagName; text = $element.Text }
            }

            "findelements" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                if (-not $Body.by -or -not $Body.value) { return @{ success = $false; error = "Missing 'by' or 'value' parameter" } }
                $elements = Chrome-FindElements -Browser $script:Browser -By $Body.by -Value $Body.value
                $results = @()
                foreach ($el in $elements) {
                    $results += @{ tagName = $el.TagName; text = $el.Text }
                }
                return @{ success = $true; count = $results.Count; elements = $results }
            }

            "click" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                if (-not $Body.by -or -not $Body.value) { return @{ success = $false; error = "Missing 'by' or 'value' parameter" } }
                $timeout = if ($Body.timeout) { [int]$Body.timeout } else { 5 }
                Chrome-Click -Browser $script:Browser -By $Body.by -Value $Body.value -TimeoutInSeconds $timeout
                return @{ success = $true }
            }

            "sendkeys" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                if (-not $Body.by -or -not $Body.value -or -not $Body.text) {
                    return @{ success = $false; error = "Missing 'by', 'value', or 'text' parameter" }
                }
                $clear = if ($Body.clear) { $Body.clear } else { $false }
                if ($clear) {
                    Chrome-SendKeys -Browser $script:Browser -By $Body.by -Value $Body.value -Text $Body.text -Clear
                } else {
                    Chrome-SendKeys -Browser $script:Browser -By $Body.by -Value $Body.value -Text $Body.text
                }
                return @{ success = $true }
            }

            "gettext" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                if (-not $Body.by -or -not $Body.value) { return @{ success = $false; error = "Missing 'by' or 'value' parameter" } }
                $text = Chrome-GetText -Browser $script:Browser -By $Body.by -Value $Body.value
                return @{ success = $true; text = $text }
            }

            "getattribute" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                if (-not $Body.by -or -not $Body.value -or -not $Body.attribute) {
                    return @{ success = $false; error = "Missing 'by', 'value', or 'attribute' parameter" }
                }
                $attr = Chrome-GetAttribute -Browser $script:Browser -By $Body.by -Value $Body.value -Attribute $Body.attribute
                return @{ success = $true; attribute = $Body.attribute; value = $attr }
            }

            "selectoption" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                if (-not $Body.by -or -not $Body.value -or -not $Body.selectBy -or -not $Body.option) {
                    return @{ success = $false; error = "Missing 'by', 'value', 'selectBy', or 'option' parameter" }
                }
                Chrome-SelectOption -Browser $script:Browser -By $Body.by -Value $Body.value -SelectBy $Body.selectBy -Option $Body.option
                return @{ success = $true }
            }

            "switchtoframe" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                if ($Body.default) {
                    Chrome-SwitchToFrame -Browser $script:Browser -Default
                } elseif ($Body.frameId) {
                    Chrome-SwitchToFrame -Browser $script:Browser -FrameId $Body.frameId
                } elseif ($Body.frameName) {
                    Chrome-SwitchToFrame -Browser $script:Browser -FrameName $Body.frameName
                } elseif ($null -ne $Body.frameIndex) {
                    Chrome-SwitchToFrame -Browser $script:Browser -FrameIndex $Body.frameIndex
                } else {
                    return @{ success = $false; error = "Missing frame identifier (frameId, frameName, frameIndex, or default)" }
                }
                return @{ success = $true }
            }

            "hover" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                if (-not $Body.by -or -not $Body.value) { return @{ success = $false; error = "Missing 'by' or 'value' parameter" } }
                Chrome-Hover -Browser $script:Browser -By $Body.by -Value $Body.value
                return @{ success = $true }
            }

            "wait" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                $timeout = if ($Body.timeout) { $Body.timeout } else { 30 }
                Chrome-Wait -Browser $script:Browser -TimeoutInSeconds $timeout
                return @{ success = $true }
            }

            "waitforelement" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                if (-not $Body.by -or -not $Body.value) { return @{ success = $false; error = "Missing 'by' or 'value' parameter" } }
                $timeout = if ($Body.timeout) { $Body.timeout } else { 30 }
                $element = Chrome-WaitForElement -Browser $script:Browser -By $Body.by -Value $Body.value -TimeoutInSeconds $timeout -Visible ([bool]$Body.visible)
                return @{ success = $true; found = $true; tagName = $element.TagName }
            }

            "executescript" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                if (-not $Body.script) { return @{ success = $false; error = "Missing 'script' parameter" } }
                $args = if ($Body.arguments) { $Body.arguments } else { @() }
                $result = Chrome-ExecuteScript -Browser $script:Browser -Script $Body.script -Arguments $args
                return @{ success = $true; result = $result }
            }

            "status" {
                return @{
                    success = $true
                    version = $script:ModuleVersion
                    browserRunning = ($null -ne $script:Browser)
                    url = if ($script:Browser) { Chrome-GetCurrentUrl -Browser $script:Browser } else { $null }
                    title = if ($script:Browser) { Chrome-GetTitle -Browser $script:Browser } else { $null }
                }
            }

            # ===== NEW ACTIONS =====

            "getpagetext" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                if ($Body.by -and $Body.value) {
                    $text = Chrome-GetPageText -Browser $script:Browser -By $Body.by -Value $Body.value
                } else {
                    $text = Chrome-GetPageText -Browser $script:Browser
                }
                return @{ success = $true; text = $text }
            }

            "scroll" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                $direction = if ($Body.direction) { $Body.direction } else { "Down" }
                $pixels = if ($Body.pixels) { $Body.pixels } else { 500 }
                if ($direction -eq "ToElement") {
                    if (-not $Body.by -or -not $Body.value) {
                        return @{ success = $false; error = "Missing 'by' or 'value' for ToElement scroll" }
                    }
                    Chrome-Scroll -Browser $script:Browser -Direction $direction -By $Body.by -Value $Body.value
                } else {
                    Chrome-Scroll -Browser $script:Browser -Direction $direction -Pixels $pixels
                }
                return @{ success = $true }
            }

            "getelementhtml" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                if (-not $Body.by -or -not $Body.value) { return @{ success = $false; error = "Missing 'by' or 'value' parameter" } }
                $html = Chrome-GetElementHtml -Browser $script:Browser -By $Body.by -Value $Body.value
                return @{ success = $true; html = $html }
            }

            "getalllinks" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                $links = Chrome-GetAllLinks -Browser $script:Browser
                return @{ success = $true; count = $links.Count; links = $links }
            }

            "getallforms" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                $forms = Chrome-GetAllForms -Browser $script:Browser
                return @{ success = $true; count = $forms.Count; forms = $forms }
            }

            "acceptalert" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                if ($Body.promptText) {
                    Chrome-AcceptAlert -Browser $script:Browser -PromptText $Body.promptText
                } else {
                    Chrome-AcceptAlert -Browser $script:Browser
                }
                return @{ success = $true }
            }

            "dismissalert" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                Chrome-DismissAlert -Browser $script:Browser
                return @{ success = $true }
            }

            "getalerttext" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                $text = Chrome-GetAlertText -Browser $script:Browser
                return @{ success = $true; text = $text }
            }

            "getcookies" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                if ($Body.name) {
                    $cookie = Chrome-GetCookies -Browser $script:Browser -Name $Body.name
                    return @{ success = $true; cookie = $cookie }
                } else {
                    $cookies = Chrome-GetCookies -Browser $script:Browser
                    return @{ success = $true; count = $cookies.Count; cookies = $cookies }
                }
            }

            "setcookie" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                if (-not $Body.name -or -not $Body.value) { return @{ success = $false; error = "Missing 'name' or 'value' parameter" } }
                $params = @{ Browser = $script:Browser; Name = $Body.name; Value = $Body.value }
                if ($Body.domain) { $params.Domain = $Body.domain }
                if ($Body.path) { $params.Path = $Body.path }
                Chrome-SetCookie @params
                return @{ success = $true }
            }

            "deletecookie" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                if ($Body.name) {
                    Chrome-DeleteCookie -Browser $script:Browser -Name $Body.name
                } else {
                    Chrome-DeleteCookie -Browser $script:Browser
                }
                return @{ success = $true }
            }

            "waitforurl" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                $timeout = if ($Body.timeout) { $Body.timeout } else { 30 }
                $params = @{ Browser = $script:Browser; TimeoutInSeconds = $timeout }
                if ($Body.contains) { $params.Contains = $Body.contains }
                if ($Body.matches) { $params.Matches = $Body.matches }
                if ($Body.changed) { $params.Changed = $true }
                $url = Chrome-WaitForUrl @params
                return @{ success = $true; url = $url }
            }

            "getwindowsize" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                $size = Chrome-GetWindowSize -Browser $script:Browser
                return @{ success = $true; width = $size.width; height = $size.height }
            }

            "setwindowsize" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                if (-not $Body.width -or -not $Body.height) { return @{ success = $false; error = "Missing 'width' or 'height' parameter" } }
                Chrome-SetWindowSize -Browser $script:Browser -Width $Body.width -Height $Body.height
                return @{ success = $true }
            }

            "maximize" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                Chrome-Maximize -Browser $script:Browser
                return @{ success = $true }
            }

            "getelementinfo" {
                if (-not $script:Browser) { return @{ success = $false; error = "No browser running" } }
                if (-not $Body.by -or -not $Body.value) { return @{ success = $false; error = "Missing 'by' or 'value' parameter" } }
                $info = Chrome-GetElementInfo -Browser $script:Browser -By $Body.by -Value $Body.value
                return @{ success = $true; element = $info }
            }

            "keepalive" {
                $op = if ($Body.op) { $Body.op.ToLower() } else { "status" }
                switch ($op) {
                    { $_ -in 'add', 'install' } { return Add-KeepAliveSite -Source ([string]$Body.source) }   # install: the old name
                    "remove" { return Remove-KeepAliveSite -Id ([string]$Body.site) }
                    "check"  { Invoke-KeepAliveTick -Force }
                    "status" { }
                    default  { return @{ success = $false; error = "Unknown keepalive op '$op' (status|add|remove|check)" } }
                }
                return @{ success = $true; sites = @(Get-KeepAliveStatus | ForEach-Object { $_.Remove('source'); $_ }) }
            }

            default {
                return @{ success = $false; error = "Unknown action: $action" }
            }
        }
    } catch {
        return @{ success = $false; error = $_.Exception.Message }
    }
}

# ---- Tabs ----
# Every command runs in one tab: the one named by `tab` (navigate or newtab with a new name opens it), else the current
# tab (the one switchtab chose, or the last one used). The iframe a command switched into is remembered per tab and
# restored the next time that tab is used. Tabs CWeb opens for keep-alive (keepalive-<site>) run in the background.
$script:Frames = @{}         # window handle -> [list of frame specs]
$script:DriverAt = @{ Handle = $null; Stamp = -1 }   # where the driver was last put
$script:SwitchStamp = 0      # bumped by anything else that moves the driver (status page), forcing a re-switch

$script:NoTabActions = @('start', 'stop', 'listtabs', 'keepalive', 'newtab', 'switchtab', 'status')
# Actions after which the page is new, so the iframe position on that tab is gone.
$script:NewPageActions = @('navigate', 'back', 'forward', 'refresh')

function Get-TabName {
    # The tab's name (what switchtab and `tab` take), or $null if it has none yet.
    param([string]$Handle)
    return ($script:Browser.Tabs.GetEnumerator() | Where-Object { $_.Value -eq $Handle } | Select-Object -First 1).Name
}

function Get-TabLabel {
    param([string]$Handle)
    $name = Get-TabName $Handle
    if ($name) { "tab '$name'" } else { "tab $($Handle.Substring(0, [math]::Min(8, $Handle.Length)))" }
}

function Reset-TabState {
    # Chrome started or stopped: every handle is gone.
    $script:Frames = @{}
    $script:DriverAt = @{ Handle = $null; Stamp = -1 }
    foreach ($s in $script:KeepAlive.Sites.Values) { $s.Tab = $null; $s.NextCheck = [datetime]::MinValue }
}

function Get-TabHandleByName {
    param([string]$Name)
    if (-not $script:Browser.Tabs.ContainsKey($Name)) { return $null }
    $h = $script:Browser.Tabs[$Name]
    if ($h -notin @($script:Browser.Driver.WindowHandles)) { $script:Browser.Tabs.Remove($Name); return $null }
    return $h
}

# Tabs the user opens by hand (or Chrome restores) have no name, so switchtab can't reach them.
# The server names them after their site: the label before the top-level domain ("example" for
# portal.example.org), with -2, -3... for repeats. A name is kept once given, even if the tab navigates.
# Tabs on chrome:// or about: pages wait until they load a website.
function Register-UnnamedTab {
    param([string]$Handle, [string]$Url)
    if ($script:Browser.Tabs.Values -contains $Handle) { return }
    $u = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u) -or $u.Scheme -notin @('http', 'https')) { return }
    $labels = $u.Host -split '\.'
    $base = if ($u.HostNameType -ne 'Dns') { 'ip' } elseif ($labels.Count -ge 2) { $labels[-2] } else { $labels[0] }
    $base = ($base -replace '[^a-zA-Z0-9-]', '').ToLower()
    if (-not $base) { $base = 'tab' }
    $name = $base; $i = 2
    while ($script:Browser.Tabs.ContainsKey($name)) { $name = "$base-$i"; $i++ }
    $script:Browser.Tabs[$name] = $Handle
    Write-Host ("[{0}] {1,-14} {2} {3}" -f (Get-Date -Format HH:mm:ss), 'named tab', $name, $Url) -ForegroundColor DarkCyan
}

function Update-TabNames {
    # Names unnamed tabs and forgets closed ones. Returns the open tabs (DevTools: id = handle, url, title).
    $pages = Get-DevToolsTabs
    foreach ($n in @($script:Browser.Tabs.Keys)) { if (-not $pages.ContainsKey($script:Browser.Tabs[$n])) { $script:Browser.Tabs.Remove($n) } }
    foreach ($p in $pages.Values) { Register-UnnamedTab -Handle ([string]$p.id) -Url ([string]$p.url) }
    return $pages
}

function Enter-Tab {
    # Puts the driver on the tab and back into the iframe it was in there, unless it's already there.
    param([string]$Handle)
    $d = $script:Browser.Driver
    if ($script:DriverAt.Handle -eq $Handle -and $script:DriverAt.Stamp -eq $script:SwitchStamp) { return }
    $d.SwitchTo().Window($Handle) | Out-Null   # also leaves any iframe: top-level document of that tab
    foreach ($f in @($script:Frames[$Handle])) {
        if (-not $f) { continue }
        try {
            if ($f.ContainsKey('frameId')) { Chrome-SwitchToFrame -Browser $script:Browser -FrameId $f.frameId }
            elseif ($f.ContainsKey('frameName')) { Chrome-SwitchToFrame -Browser $script:Browser -FrameName $f.frameName }
            else { Chrome-SwitchToFrame -Browser $script:Browser -FrameIndex $f.frameIndex }
        } catch {
            # The frame isn't there any more (the page changed): stay on the top-level page.
            $script:Frames.Remove($Handle); $d.SwitchTo().Window($Handle) | Out-Null; break
        }
    }
    $script:DriverAt = @{ Handle = $Handle; Stamp = $script:SwitchStamp }
}

function Get-WorkTab {
    # The tab a command without `tab` runs in: the current one, unless it's gone or a keep-alive tab.
    $d = $script:Browser.Driver
    $handles = @($d.WindowHandles)
    $ka = @($script:Browser.Tabs.GetEnumerator() | Where-Object { $_.Name.StartsWith('keepalive-') } | ForEach-Object { $_.Value })
    $h = $script:DriverAt.Handle
    if (-not $h -or $h -notin $handles) { try { $h = $d.CurrentWindowHandle } catch { $h = $null } }
    if (-not $h -or $h -notin $handles -or $h -in $ka) { $h = $handles | Where-Object { $_ -notin $ka } | Select-Object -Last 1 }
    if (-not $h) { $h = $handles | Select-Object -Last 1 }
    return $h
}

function Invoke-TabAction {
    # Runs one /api command in its tab (see the comment above $script:Frames).
    param([hashtable]$Body)
    $action = ([string]$Body.action).ToLower()
    if ($action -in 'start', 'stop') {
        $r = Invoke-BrowserAction -Body $Body
        if ($r.success) { Reset-TabState }
        return $r
    }
    if (-not $action -or $action -in 'status', 'keepalive') { return Invoke-BrowserAction -Body $Body }
    if (-not (Confirm-InstanceBrowser)) {
        return @{ success = $false; error = "Chrome didn't start: $script:BrowserStartError Logs: $($script:LogDir)" }
    }
    $d = $script:Browser.Driver

    try {
        $name = if ($action -in 'newtab', 'switchtab') { [string]$Body.name } else { [string]$Body.tab }
        if ($action -eq 'newtab' -and -not $name) { $name = [string]$Body.tab }
        $h = if ($name) { Get-TabHandleByName $name } else { $null }

        switch ($action) {
            'switchtab' {
                if (-not $name) { return @{ success = $false; error = "Missing 'name' parameter" } }
                if (-not $h) { return @{ success = $false; error = "No tab named '$name'. Run listtabs." } }
                Enter-Tab $h
                return @{ success = $true; tab = $name }
            }
            'newtab' {
                if ($h) {
                    # Already open: use it (and load the address, if one was given).
                    Enter-Tab $h
                    if ($Body.url) { Chrome-Navigate -Browser $script:Browser -Url $Body.url | Out-Null; $script:Frames.Remove($h) }
                    return @{ success = $true; tab = $name; url = $Body.url; existing = $true }
                }
                $r = Invoke-BrowserAction -Body @{ action = 'newtab'; url = $Body.url; name = $name }
                if ($r.success) {
                    $h = $d.CurrentWindowHandle
                    if (-not $name) { Register-UnnamedTab -Handle $h -Url $d.Url }   # unnamed: named after its site
                    $script:DriverAt = @{ Handle = $h; Stamp = $script:SwitchStamp }
                    $r.tab = Get-TabName $h
                }
                return $r
            }
        }
        if ($action -in $script:NoTabActions) { return Invoke-BrowserAction -Body $Body }

        # This server answers one request at a time, so loading its own page from a command would wait on itself.
        if ($action -eq 'navigate' -and [string]$Body.url -match "^https?://(127\.0\.0\.1|localhost):$($script:Port)(/|$)") {
            return @{ success = $false; error = "That's this CWeb's own status page: read http://127.0.0.1:$($script:Port)/status.json with curl instead." }
        }

        if ($name -and -not $h) {
            # A new tab name: navigate opens it; anything else needs it open first.
            if ($action -ne 'navigate') { return @{ success = $false; error = "No tab named '$name'. Open it with navigate (tab + url), or run listtabs." } }
            return Invoke-TabAction -Body @{ action = 'newtab'; name = $name; url = $Body.url }
        }
        if (-not $h) { $h = Get-WorkTab }

        Enter-Tab $h
        $r = Invoke-BrowserAction -Body $Body

        # Keep the tab's iframe position up to date.
        if ($r.success) {
            if ($action -eq 'switchtoframe') {
                if ($Body.default) { $script:Frames.Remove($h) }
                else {
                    $spec = if ($Body.frameId) { @{ frameId = $Body.frameId } } elseif ($Body.frameName) { @{ frameName = $Body.frameName } } else { @{ frameIndex = [int]$Body.frameIndex } }
                    if (-not $script:Frames.ContainsKey($h)) { $script:Frames[$h] = [System.Collections.Generic.List[object]]::new() }
                    $script:Frames[$h].Add($spec)
                }
            } elseif ($action -in $script:NewPageActions) {
                $script:Frames.Remove($h)
            } elseif ($action -eq 'closetab') {
                $script:Frames.Remove($h)
                foreach ($n in @($script:Browser.Tabs.Keys | Where-Object { $script:Browser.Tabs[$_] -eq $h })) { $script:Browser.Tabs.Remove($n) }
                $script:DriverAt = @{ Handle = $null; Stamp = -1 }
                $next = Get-WorkTab
                if ($next) { Enter-Tab $next }
                return $r
            }
        }
        if ($r -is [hashtable]) { $r.tab = Get-TabName $h }
        return $r
    } catch {
        return @{ success = $false; error = $_.Exception.Message }
    }
}

# ---- Status page: GET /status (page) and /status.json (data) ----
# No API key (a browser can't send the header), so it answers only requests addressed to this
# machine's loopback name and sends no CORS header, so other websites can't read it.
function Test-LocalStatusRequest {
    param([System.Net.HttpListenerRequest]$Request)
    $hostName = ($Request.Headers['Host'] -split ':')[0]
    return $Request.IsLocal -and $hostName -in @('127.0.0.1', 'localhost')
}

function Add-RequestStat {
    param([hashtable]$Body, $Result, [double]$Ms, [string]$Target, [string]$Client)
    $s = $script:Stats
    $action = if ($Body.action) { [string]$Body.action } else { '?' }
    $ok = -not ($Result -is [hashtable] -and $Result.ContainsKey('success') -and -not $Result.success)
    $s.Requests++
    if (-not $ok) { $s.Errors++ }
    $s.ByAction[$action] = 1 + [int]$s.ByAction[$action]
    $who = if ($Client) { $Client } else { '?' }
    $s.ByClient[$who] = 1 + [int]$s.ByClient[$who]
    $tab = if ($Result -is [hashtable] -and $Result.tab) { [string]$Result.tab } elseif ($Body.tab) { [string]$Body.tab } else { $null }
    # Target only -- never text, script, arguments, promptText or cookie values.
    $target = if ($Target) { $Target } else { switch ($action.ToLower()) {
        { $_ -in 'navigate', 'newtab' } { (@($Body.name, $Body.url) | Where-Object { $_ }) -join ' ' }
        'switchtab' { $Body.name }
        'keepalive' { $Body.op }
        { $_ -in 'setcookie', 'getcookies', 'deletecookie' } { $Body.name }
        default { if ($Body.by) { "$($Body.by)=$($Body.value)" } }
    } }
    if ($target -and $target.Length -gt 90) { $target = $target.Substring(0, 87) + '...' }
    $s.Recent.Insert(0, [ordered]@{
        time   = Get-Date -Format 'HH:mm:ss'
        client = $who
        action = $action
        tab    = $tab
        target = $target
        ms     = [int]$Ms
        ok     = $ok
        error  = if ($ok) { $null } else { [string]$Result.error }
    })
    if ($s.Recent.Count -gt 200) { $s.Recent.RemoveAt(200) }

    # Console line, e.g. "[10:41:02] support-triage   navigate       [example] https://portal.example.org/   1204 ms"
    $r = $s.Recent[0]
    $line = "[{0}] {1,-24} {2,-14} {3}{4}" -f $r.time, $r.client, $r.action, $(if ($r.tab) { "[$($r.tab)] " }), $r.target
    if ($ok) { Write-Host ("{0}  {1} ms" -f $line, $r.ms) }
    else { Write-Host ("{0}  {1} ms  FAILED: {2}" -f $line, $r.ms, $r.error) -ForegroundColor Red }
}

function Get-StatusData {
    $browser = [ordered]@{ running = [bool]$script:Browser; startError = $script:BrowserStartError; closed = $script:BrowserClosed; tabCount = 0 }
    $tabs = @()
    if ($script:Browser) {
        # Read over DevTools: no tab is switched to. Empty if Chrome has just closed; the next command reopens it.
        try {
            $pages = Update-TabNames
            $browser.tabCount = $pages.Count
            $tabs = @($pages.Values | ForEach-Object {
                $n = Get-TabName ([string]$_.id)
                [ordered]@{ id = [string]$_.id; name = $n; title = [string]$_.title; url = [string]$_.url; keepAlive = [bool]($n -and $n.StartsWith('keepalive-')) }
            } | Sort-Object { $_.keepAlive }, { $_.name })
        } catch { $browser.running = $false }
    }
    [ordered]@{
        now       = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
        server    = [ordered]@{
            version  = $script:ModuleVersion
            instance = $script:InstanceName
            label    = $script:Inst.Label
            port     = $script:Port
            configuredPort = $script:Inst.ConfiguredPort
            profile  = $script:ProfileDir
            started  = $script:Stats.Started.ToString('yyyy-MM-dd HH:mm:ss')
            uptimeSeconds = [int]((Get-Date) - $script:Stats.Started).TotalSeconds
            dataRoot = $script:Inst.DataRoot
        }
        # All instances, for the status page's switcher. instances.json may be mid-edit; then show only this one.
        instances = @(try { Get-CWebInstanceList -Root $script:CWebRoot } catch {
            [pscustomobject]@{ name = $script:InstanceName; label = $script:Inst.Label; port = $script:Port; running = $true }
        })
        browser   = $browser
        tabs      = $tabs
        keepAlive = [ordered]@{
            enabled = $script:KeepAlive.Enabled
            folder  = $script:KeepAlive.SiteDir
            sites   = @(Get-KeepAliveStatus)
            events  = @($script:KeepAlive.Events)
        }
        requests  = [ordered]@{ total = $script:Stats.Requests; errors = $script:Stats.Errors; byAction = $script:Stats.ByAction; byClient = $script:Stats.ByClient }
        recent    = @($script:Stats.Recent)
    }
}

# The page's actions (POST /status/<action>). A write must be safe from other websites making the browser send it, so it
# needs the X-Status-Request header: a foreign site can't add it without a CORS preflight, which this server never approves.
function Test-StatusActionRequest {
    param([System.Net.HttpListenerRequest]$Request)
    return (Test-LocalStatusRequest -Request $Request) -and $Request.Headers['X-Status-Request'] -eq '1'
}

function Close-TabByHandle {
    param([string]$Handle)
    if (-not $script:Browser) { return @{ success = $false; error = 'No browser running' } }
    $d = $script:Browser.Driver
    $handles = @($d.WindowHandles)
    if ($Handle -notin $handles) { return @{ success = $false; error = 'That tab is already closed.' } }
    if ($handles.Count -le 1) { return @{ success = $false; error = "Can't close the last tab; that would end the browser." } }
    $label = Get-TabLabel $Handle
    Close-DevToolsTab -TabId $Handle   # no switching: the tab agents are on stays where it is
    foreach ($name in @($script:Browser.Tabs.Keys | Where-Object { $script:Browser.Tabs[$_] -eq $Handle })) { $script:Browser.Tabs.Remove($name) }
    $script:Frames.Remove($Handle)
    if ($script:DriverAt.Handle -eq $Handle) { $script:DriverAt = @{ Handle = $null; Stamp = -1 } }
    return @{ success = $true; closed = $label }
}

function Open-TabFromStatus {
    param([string]$Url, [string]$Name)
    if (-not (Confirm-InstanceBrowser)) { return @{ success = $false; error = "Chrome didn't start: $script:BrowserStartError" } }
    $u = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u) -or $u.Scheme -notin @('http', 'https')) {
        return @{ success = $false; error = 'Enter a full http:// or https:// address.' }
    }
    if ($Name) {
        if ($Name -notmatch '^[A-Za-z0-9_-]{1,40}$') { return @{ success = $false; error = 'Name: letters, numbers, - and _ only.' } }
        if ($script:Browser.Tabs.ContainsKey($Name)) { return @{ success = $false; error = "A tab named '$Name' already exists." } }
    }
    $id = New-DevToolsTab -Url $u.AbsoluteUri
    if ($Name) { $script:Browser.Tabs[$Name] = $id } else { Register-UnnamedTab -Handle $id -Url $u.AbsoluteUri }
    return @{ success = $true; opened = (Get-TabLabel $id) }
}

function Invoke-StatusAction {
    param([System.Net.HttpListenerRequest]$Request, [System.Net.HttpListenerResponse]$Response)
    if (-not (Test-StatusActionRequest -Request $Request)) {
        Send-Response -Response $Response -Data @{ success = $false; error = 'Forbidden' } -StatusCode 403
        return
    }
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $reader = New-Object System.IO.StreamReader($Request.InputStream)
        $body = $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable
        $reader.Close()
    } catch { $body = @{} }
    if (-not $body) { $body = @{} }
    $action = ($Request.Url.AbsolutePath -split '/')[-1]
    $target = ''
    try {
        switch ($action) {
            'closetab'      { $result = Close-TabByHandle -Handle ([string]$body.id); $target = [string]$result.closed }
            'newtab'        { $result = Open-TabFromStatus -Url ([string]$body.url) -Name ([string]$body.name); $target = "$($result.opened) $($body.url)" }
            'stopserver'    {
                # Answer first; the main loop then exits and its cleanup closes Chrome and the listener.
                $script:StopRequested = $true
                $result = @{ success = $true; message = 'Stopping: closing Chrome, then the server.' }
            }
            'startbrowser'  { $result = if (Confirm-InstanceBrowser) { @{ success = $true; message = 'Chrome is open.' } } else { @{ success = $false; error = "Chrome didn't start: $script:BrowserStartError" } } }
            'startinstance' {
                # Launch another instance's server without waiting for it; the switcher shows it once it's up.
                $other = Get-CWebInstance -Name ([string]$body.name) -Root $script:CWebRoot
                if ($other.Name -eq $script:InstanceName -or (Test-CWebServerProcess -Instance $other)) { $result = @{ success = $true; message = 'Already running.' } }
                else { Start-CWebServerProcess -Instance $other -Root $script:CWebRoot | Out-Null; $result = @{ success = $true; message = "Starting $($other.Label)." } }
                $target = $other.Name
            }
            'kaadd'         { $result = Add-KeepAliveSite -Source ([string]$body.source); $target = [string]$result.site }
            'karemove'      { $result = Remove-KeepAliveSite -Id ([string]$body.site); $target = [string]$body.site }
            'kacheck'       { Invoke-KeepAliveTick -Force; $result = @{ success = $true } }
            default         { $result = @{ success = $false; error = "Unknown action '$action'." } }
        }
    } catch {
        $result = @{ success = $false; error = $_.Exception.Message }
    }
    Send-Response -Response $Response -Data $result
    try { Add-RequestStat -Body @{ action = $action } -Result $result -Ms $timer.Elapsed.TotalMilliseconds -Target $target.Trim() -Client 'status page' } catch { }
}

function Send-StatusPage {
    param([System.Net.HttpListenerRequest]$Request, [System.Net.HttpListenerResponse]$Response)
    try {
        if (-not (Test-LocalStatusRequest -Request $Request)) {
            $Response.StatusCode = 403; $Response.Close(); return
        }
        if ($Request.Url.AbsolutePath -eq '/status.json') {
            $type = 'application/json'
            $text = Get-StatusData | ConvertTo-Json -Depth 8 -Compress
        } else {
            $type = 'text/html; charset=utf-8'
            $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'status.html') -Raw
        }
        $buffer = [System.Text.Encoding]::UTF8.GetBytes($text)
        $Response.StatusCode = 200
        $Response.ContentType = $type
        $Response.Headers.Add('Cache-Control', 'no-store')
        $Response.ContentLength64 = $buffer.Length
        $Response.OutputStream.Write($buffer, 0, $buffer.Length)
    } catch {
        $at = $_.InvocationInfo
        Write-Host "  (status page not sent: $($_.Exception.Message)$(if ($at.ScriptName) { " at $(Split-Path $at.ScriptName -Leaf):$($at.ScriptLineNumber)" }))" -ForegroundColor DarkYellow
    } finally {
        try { $Response.OutputStream.Close() } catch { }
    }
}

function Test-ApiKey {
    # The request carries this machine's key (constant-time compare) and doesn't come from a web page.
    param([System.Net.HttpListenerRequest]$Request)
    if (-not $Request.IsLocal -or $Request.Headers['Origin']) { return $false }
    $k = [string]$Request.Headers['X-CWeb-Key']
    if (-not $k) { $k = [string]$Request.Headers['X-API-Key'] }   # clients from before 2026.10.28.025
    if (-not $k) { return $false }
    $a = [Text.Encoding]::UTF8.GetBytes($k)
    if ([System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($a, [Text.Encoding]::UTF8.GetBytes($script:ApiKey))) { return $true }
    # The key file may have been replaced (deleted and made again) since this server started: read it once more.
    $script:ApiKey = Initialize-CWebKey
    return [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($a, [Text.Encoding]::UTF8.GetBytes($script:ApiKey))
}

function Open-CWebListener {
    # Listens on the instance's port. If another program holds it and portFallback is on (config.json), moves on to the
    # next free port that no instance is configured for. Sets $script:Port to the port in use; server.json records it.
    $cfg = Get-CWebConfig
    $reserved = @((Get-CWebInstanceTable -Root $script:CWebRoot).Values | ForEach-Object { [int]$_.port })
    $want = $script:Inst.ConfiguredPort
    $tries = @($want)
    if ($cfg.PortFallback) { $tries += @(($want + 1)..([Math]::Min(65535, $want + 100)) | Where-Object { $_ -notin $reserved }) }
    foreach ($p in $tries) {
        if (-not (Test-CWebPortFree $p)) { continue }
        $l = New-Object System.Net.HttpListener
        $l.Prefixes.Add("http://$($script:ListenAddress):$p/")
        try { $l.Start() } catch [System.Net.HttpListenerException] { $l.Close(); continue }
        $script:Port = $p
        if ($p -ne $want) { Write-Host "  Port $want is in use by another program; listening on $p instead." -ForegroundColor Yellow }
        return $l
    }
    if ($cfg.PortFallback) { throw "Port $want and the 100 after it are all in use. Set another port for '$($script:InstanceName)' in $($cfg.Path)." }
    throw "Port $want is in use by another program. Set another port for '$($script:InstanceName)' in $($cfg.Path), or turn portFallback on there."
}

# Main server loop
$listener = $null
try {
    $listener = Open-CWebListener
    $prefix = "http://$($script:ListenAddress):$($script:Port)/"
    Write-Host "CWeb server started (version $($script:ModuleVersion))"
    Write-Host "  Instance: $($script:InstanceName) ($($script:Inst.Label))"
    Write-Host "  Endpoint: $prefix"
    Write-Host "  Profile:  $($script:ProfileDir)"
    Write-Host "  Chrome Module: $script:ChromeModulePath"
    Write-Host ""
    Write-Host "  Keep-alive: $(if ($script:KeepAlive.Enabled) { 'on' } else { 'off' }) (sites in $($script:KeepAlive.SiteDir))"
    Write-Host "  Status page: http://127.0.0.1:$($script:Port)/status"
    Write-Host ""

    # "Here I am" file for the launcher and clients. No key in it.
    [ordered]@{
        instance = $script:InstanceName
        port     = $script:Port
        pid      = $PID
        version  = $script:ModuleVersion
        started  = $script:Stats.Started.ToString('yyyy-MM-dd HH:mm:ss')
        folder   = $PSScriptRoot
    } | ConvertTo-Json | Set-Content -LiteralPath $script:Inst.ServerFile -Encoding utf8

    # Open Chrome now. Requests that arrive meanwhile wait in the listener's queue.
    $script:LastStartAttempt = Get-Date
    $r = Start-InstanceBrowser -Hidden $script:Inst.Hidden -Persist $true
    if ($r.success -and $script:Inst.StartUrl) {
        try { Chrome-Navigate -Browser $script:Browser -Url $script:Inst.StartUrl | Out-Null }
        catch { Write-Host "  Start page didn't load: $($_.Exception.Message)" -ForegroundColor DarkYellow }
    }
    Write-Host ""

    # Requests are handled one at a time; the keep-alive runs between them, never during one.
    $pending = $listener.GetContextAsync()
    while ($listener.IsListening) {
        if (((Get-Date) - $script:KeepAlive.LastTick).TotalSeconds -ge $script:KeepAlive.TickSeconds) {
            try { Invoke-KeepAliveTick } catch { Write-KeepAliveLog "check failed: $($_.Exception.Message)" Yellow }
        }
        try {
            if (-not $pending.Wait([TimeSpan]::FromSeconds($script:KeepAlive.TickSeconds))) { continue }
            $context = $pending.Result
        } catch { break }   # listener stopped (shutdown)
        $pending = $listener.GetContextAsync()
        try {
        $request = $context.Request
        $response = $context.Response
        $path = $request.Url.AbsolutePath

        # Status page (polled every few seconds, so not logged)
        if ($request.HttpMethod -eq "GET" -and $path -in @('/', '/status', '/status.json')) {
            Send-StatusPage -Request $request -Response $response
            continue
        }
        if ($request.HttpMethod -eq "POST" -and $path.StartsWith('/status/')) {
            Invoke-StatusAction -Request $request -Response $response
            if ($script:StopRequested) { Write-Host "[$(Get-Date -Format HH:mm:ss)] Stop requested from the status page"; break }
            continue
        }

        # Clients from before 2026.10.28.025 ask for access with POST /attach, then collect a key with GET /attach/<ticket>.
        # Nothing is approved any more: they get this machine's key at once. Same rule as the API (the custom header a
        # web page can't send, no Origin), so only local programs get it.
        if ($path -eq '/attach' -or $path.StartsWith('/attach/')) {
            if (-not $request.IsLocal -or $request.Headers['Origin'] -or $request.Headers['X-CWeb-Attach'] -ne '1') {
                Send-Response -Response $response -Data @{ success = $false; error = 'Forbidden' } -StatusCode 403
            } elseif ($request.HttpMethod -eq 'POST') {
                Write-Host "[$(Get-Date -Format HH:mm:ss)] old-style attach from a client of an earlier CWeb: handed this machine's key" -ForegroundColor DarkCyan
                Send-Response -Response $response -Data @{ success = $true; ticket = 'auto'; status = 'pending' }
            } else {
                Send-Response -Response $response -Data @{ success = $true; status = 'approved'; key = $script:ApiKey }
            }
            continue
        }

        # No CORS headers: only local programs use the API, never web pages. A preflight gets no approval.
        if ($request.HttpMethod -eq "OPTIONS") {
            $response.StatusCode = 204
            $response.Close()
            continue
        }

        if (-not ($request.HttpMethod -eq "POST" -and $path -eq "/api")) {
            Send-Response -Response $response -Data @{ success = $false; error = "Use POST /api" } -StatusCode 404
            continue
        }
        if (-not (Test-ApiKey -Request $request)) {
            Write-Host "[$(Get-Date -Format HH:mm:ss)] refused: an /api request without this machine's key$(if ($request.Headers['Origin']) { " (from a web page: $($request.Headers['Origin']))" })" -ForegroundColor DarkYellow
            Send-Response -Response $response -Data @{ success = $false; error = "Unauthorized: send the key from $(Get-CWebKeyFile) (cweb.sh and CWeb-Client.ps1 do)." } -StatusCode 401
            continue
        }
        # Who's asking, for the status page and log only (cweb.sh sends the client name it was given, if any).
        $client = [string]$request.Headers['X-CWeb-Client']
        if ($client -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,39}$') { $client = 'agent' }

        $reader = New-Object System.IO.StreamReader($request.InputStream)
        $bodyText = $reader.ReadToEnd()
        $reader.Close()
        try { $body = $bodyText | ConvertFrom-Json -AsHashtable }
        catch {
            Send-Response -Response $response -Data @{ success = $false; error = "Invalid JSON: $($_.Exception.Message)" } -StatusCode 400
            continue
        }
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-TabAction -Body $body
        Send-Response -Response $response -Data $result
        try { Add-RequestStat -Body $body -Result $result -Ms $timer.Elapsed.TotalMilliseconds -Client $client } catch { }
        } catch {
            Write-Host "  (request failed: $($_.Exception.Message))" -ForegroundColor DarkYellow
        }
    }
} catch {
    Write-Host "CWeb server failed: $($_.Exception.Message)" -ForegroundColor Red   # in the server log
    throw
} finally {
    Write-Host "Shutting down..."
    if ($script:Browser) {
        Write-Host "Closing browser..."
        Chrome-Stop -Browser $script:Browser
    }
    if ($listener) {
        $listener.Stop()
        $listener.Close()
    }
    # Remove the "here I am" file only if it's ours, then free the instance lock.
    try {
        $sf = $script:Inst.ServerFile
        if ((Test-Path $sf) -and ((Get-Content $sf -Raw | ConvertFrom-Json).pid -eq $PID)) { Remove-Item -LiteralPath $sf -Force }
    } catch { }
    try { $script:Lock.ReleaseMutex(); $script:Lock.Dispose() } catch { }
    Write-Host "Server stopped."
    try { Stop-Transcript | Out-Null } catch { }
}
