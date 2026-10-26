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
$blocked = @(Get-ChildItem $PSScriptRoot -Recurse -File -Include *.ps1, *.dll, *.exe -ErrorAction SilentlyContinue | Where-Object {
    try { [bool](Get-Item -LiteralPath $_.FullName -Stream Zone.Identifier -ErrorAction Stop) } catch { $false }
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
. (Join-Path $PSScriptRoot 'CWeb-Profiles.ps1')   # leftover profiles

# Settings come from the instance (instances.json, config.json). The server only ever listens on this machine.
# $script:Port is final once the listener opens (Open-CWebListener): it may move off a port another program holds.
$script:Port = $script:Inst.ConfiguredPort
$script:ListenAddress = '127.0.0.1'
$script:ProfileDir = $script:Inst.ProfileDir

# Who may use the API: clients approved on the status page, each with its own key (see CWeb-Access.ps1).
. (Join-Path $PSScriptRoot 'CWeb-Access.ps1')
Initialize-CWebAccess -DataDir $script:Inst.DataDir
$script:Caller = $null   # the approved client making the current /api request

# Browser state
$script:Browser = $null
$script:BrowserStartError = $null   # why the automatic start at launch failed, for the status page
$script:StopRequested = $false   # set by the status page's Stop server button

# Session keep-alive (profiles in <data folder>\keepalive\; see claude.md). Runs between API requests, so it never
# interleaves with a caller's commands. Per-tab state is keyed by window handle.
$script:KeepAlive = @{
    Enabled         = $script:Inst.KeepAliveEnabled
    TickSeconds     = $script:Inst.KeepAliveTick
    MaxCheckSeconds = $script:Inst.KeepAliveMax
    SiteDir         = Join-Path $script:Inst.DataRoot 'keepalive'   # this machine's site profiles (none ship with CWeb)
    Tabs            = @{}
    LastTick        = [datetime]::MinValue
    Events          = [System.Collections.Generic.List[object]]::new()   # recent renewals/warnings, for /status
}
# Per-site on/off, keep-alive requests and agent drafts (see CWeb-KeepAliveAdmin.ps1).
. (Join-Path $PSScriptRoot 'CWeb-KeepAliveAdmin.ps1')
Initialize-KeepAliveAdmin -DataDir $script:Inst.DataDir

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
    $where = if ($Persist) { $script:ProfileDir } else { 'throwaway profile' }
    Write-Host "  Browser started ($where)"
    return @{ success = $true; message = "Browser started"; profile = $where }
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
                # Name any tab the user opened since the last check, so it's in the list now.
                try { Invoke-KeepAliveTick } catch { }
                $tabs = Chrome-ListTabs -Browser $script:Browser
                return @{ success = $true; tabs = @($tabs) }
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
                    "on"     { $script:KeepAlive.Enabled = $true }
                    "off"    { $script:KeepAlive.Enabled = $false }
                    "check"  {
                        # Check every tab now, regardless of schedule.
                        foreach ($t in $script:KeepAlive.Tabs.Values) { $t.NextCheck = [datetime]::MinValue }
                        Invoke-KeepAliveTick -Force
                    }
                    "status" { }
                    # The request queue (see CWeb-KeepAliveAdmin.ps1 and KEEPALIVE.md).
                    "requests" {
                        return @{ success = $true; requests = @($script:KaAdmin.Requests | Where-Object state -eq 'open'); all = @($script:KaAdmin.Requests); howTo = 'KEEPALIVE.md' }
                    }
                    "drafts" {
                        return @{ success = $true; drafts = @(Get-KeepAliveDrafts | ForEach-Object { $_.Remove('source'); $_ }) }
                    }
                    "draft" {
                        return Add-KeepAliveDraft -Name ([string]$Body.name) -Source ([string]$Body.source) -RequestId ([string]$Body.request) -Client $script:Caller
                    }
                    "decline" {
                        return Set-KeepAliveRequestDeclined -RequestId ([string]$Body.request) -Note ([string]$Body.note) -Client $script:Caller
                    }
                    default  { return @{ success = $false; error = "Unknown keepalive op '$op' (status|on|off|check|requests|drafts|draft|decline)" } }
                }
                return @{ success = $true; enabled = $script:KeepAlive.Enabled; sites = @(Get-KeepAliveSites | ForEach-Object { $_.Name }); tabs = @(Get-KeepAliveStatus) }
            }

            default {
                return @{ success = $false; error = "Unknown action: $action" }
            }
        }
    } catch {
        return @{ success = $false; error = $_.Exception.Message }
    }
}

# ---- Clients sharing one browser ----
# WebDriver has one "current tab" for everyone, so each client's own position is kept here and restored before each of
# its commands: its tab (the one it named with `tab`, else the one it used last) and the iframe it was in on that tab.
# A tab opened with `newtab` is owned by the client that opened it: others may read it, not change it.
$script:ClientCtx = @{}      # client -> @{ Handle = <window handle>; Frames = @{ <handle> = [list of frame specs] } }
$script:TabOwners = @{}      # window handle -> owning client
$script:DriverCtx = @{ Handle = $null; Client = $null; Stamp = -1 }   # where the driver was last put for a client
$script:SwitchStamp = 0      # bumped by anything else that moves the driver (keep-alive, status page), forcing a re-switch

$script:NoTabActions = @('start', 'stop', 'listtabs', 'keepalive', 'newtab', 'releasetab', 'switchtab')
# Actions that change a page or a tab. On a tab owned by another client they're refused.
$script:WriteActions = @('navigate', 'back', 'forward', 'refresh', 'click', 'sendkeys', 'selectoption', 'hover', 'scroll',
    'executescript', 'acceptalert', 'dismissalert', 'setcookie', 'deletecookie', 'closetab')
# Actions after which the page is new, so every client's iframe position on that tab is gone.
$script:NewPageActions = @('navigate', 'back', 'forward', 'refresh')

function Get-TabName {
    # The tab's name (what switchtab and `tab` take), or $null if it has none yet.
    param([string]$Handle)
    return ($script:Browser.Tabs.GetEnumerator() | Where-Object { $_.Value -eq $Handle } | Select-Object -First 1).Name
}

function Reset-ClientState {
    # The browser started or stopped: every handle is gone.
    $script:ClientCtx = @{}; $script:TabOwners = @{}
    $script:DriverCtx = @{ Handle = $null; Client = $null; Stamp = -1 }
}

function Get-DefaultTab {
    # A client's first tab when it hasn't picked one: the tab in front unless another client owns it,
    # else the first shared tab, else the tab in front.
    param([string]$Client)
    $d = $script:Browser.Driver
    $front = $d.CurrentWindowHandle
    $o = $script:TabOwners[$front]
    if (-not $o -or $o -eq $Client) { return $front }
    $shared = @($d.WindowHandles) | Where-Object { -not $script:TabOwners[$_] } | Select-Object -First 1
    if ($shared) { return $shared } else { return $front }
}

function Get-ClientCtx {
    param([string]$Client)
    if (-not $script:ClientCtx.ContainsKey($Client)) { $script:ClientCtx[$Client] = @{ Handle = $null; Frames = @{} } }
    return $script:ClientCtx[$Client]
}

function Get-TabHandleByName {
    param([string]$Name)
    if (-not $script:Browser.Tabs.ContainsKey($Name)) { return $null }
    $h = $script:Browser.Tabs[$Name]
    if ($h -notin @($script:Browser.Driver.WindowHandles)) { $script:Browser.Tabs.Remove($Name); return $null }
    return $h
}

function Remove-TabState {
    # Forget owners and frame positions for a tab that's gone. A client whose tab it was keeps pointing at it, so its
    # next command is told "your tab was closed" instead of quietly running somewhere else.
    param([string]$Handle)
    $script:TabOwners.Remove($Handle)
    foreach ($c in $script:ClientCtx.Values) { $c.Frames.Remove($Handle) }
}

function Enter-ClientTab {
    # Puts the driver on the client's tab and back into its iframe, unless it's already there for this client.
    param([string]$Client, [string]$Handle)
    $d = $script:Browser.Driver
    $ctx = Get-ClientCtx $Client
    $dc = $script:DriverCtx
    if ($dc.Handle -eq $Handle -and $dc.Client -eq $Client -and $dc.Stamp -eq $script:SwitchStamp) { return }
    $d.SwitchTo().Window($Handle) | Out-Null   # also leaves any iframe: top-level document of that tab
    foreach ($f in @($ctx.Frames[$Handle])) {
        if (-not $f) { continue }
        try {
            if ($f.ContainsKey('frameId')) { Chrome-SwitchToFrame -Browser $script:Browser -FrameId $f.frameId }
            elseif ($f.ContainsKey('frameName')) { Chrome-SwitchToFrame -Browser $script:Browser -FrameName $f.frameName }
            else { Chrome-SwitchToFrame -Browser $script:Browser -FrameIndex $f.frameIndex }
        } catch {
            # The frame isn't there any more (the page changed): stay on the top-level page.
            $ctx.Frames.Remove($Handle); $d.SwitchTo().Window($Handle) | Out-Null; break
        }
    }
    $script:DriverCtx = @{ Handle = $Handle; Client = $Client; Stamp = $script:SwitchStamp }
}

function Invoke-ClientAction {
    # Runs one /api command for a client in that client's own tab and frame. See the comment above $script:ClientCtx.
    param([hashtable]$Body, [string]$Client)
    $action = ([string]$Body.action).ToLower()
    if ($action -in 'start', 'stop') {
        $r = Invoke-BrowserAction -Body $Body
        if ($r.success) { Reset-ClientState }
        return $r
    }
    if (-not $script:Browser -or -not $action) { return Invoke-BrowserAction -Body $Body }
    $ctx = Get-ClientCtx $Client
    $d = $script:Browser.Driver

    try {
        switch ($action) {
            'switchtab' {
                if (-not $Body.name) { return @{ success = $false; error = "Missing 'name' parameter" } }
                $h = Get-TabHandleByName $Body.name
                if (-not $h) { return @{ success = $false; error = "No tab named '$($Body.name)'. Run listtabs." } }
                $ctx.Handle = $h
                Enter-ClientTab -Client $Client -Handle $h
                return @{ success = $true; tab = $Body.name; owner = $script:TabOwners[$h] }
            }
            'newtab' {
                $r = Invoke-BrowserAction -Body $Body
                if ($r.success) {
                    $h = $d.CurrentWindowHandle
                    if (-not $Body.name) { Register-UnnamedTab -Handle $h -Url $d.Url }   # unnamed: named after its site
                    $script:TabOwners[$h] = $Client
                    $ctx.Handle = $h
                    $script:DriverCtx = @{ Handle = $h; Client = $Client; Stamp = $script:SwitchStamp }
                    $r.tab = Get-TabName $h; $r.owner = $Client
                }
                return $r
            }
            'releasetab' {
                $h = if ($Body.tab) { Get-TabHandleByName $Body.tab } else { $ctx.Handle }
                if (-not $h) { return @{ success = $false; error = "No such tab. Pass 'tab' or switchtab first." } }
                if ($script:TabOwners[$h] -ne $Client) { return @{ success = $false; error = "Tab '$(Get-TabName $h)' isn't yours to release." } }
                $script:TabOwners.Remove($h)
                return @{ success = $true; tab = (Get-TabName $h); owner = $null }
            }
            'listtabs' {
                $r = Invoke-BrowserAction -Body $Body
                if ($r.success) {
                    $r.details = @($script:Browser.Tabs.GetEnumerator() | Sort-Object Name | ForEach-Object {
                        $ka = $script:KeepAlive.Tabs[$_.Value]
                        [ordered]@{ name = $_.Name; owner = $script:TabOwners[$_.Value]; mine = ($_.Value -eq $ctx.Handle); url = $(if ($ka) { $ka.Url }) }
                    })
                }
                return $r
            }
        }
        if ($action -in $script:NoTabActions) { return Invoke-BrowserAction -Body $Body }

        # Which tab: the one named in the request (for this request only; switchtab changes the client's own tab),
        # else the client's own, else (its first request) a default that it then keeps.
        $handles = @($d.WindowHandles)
        if ($Body.tab) {
            $h = Get-TabHandleByName $Body.tab
            if (-not $h) { return @{ success = $false; error = "No tab named '$($Body.tab)'. Run listtabs." } }
        } elseif ($ctx.Handle) {
            $h = $ctx.Handle
            if ($h -notin $handles) {
                Remove-TabState $h
                return @{ success = $false; error = 'Your tab was closed. Run listtabs, then switchtab, or pass tab.' }
            }
        } else {
            $h = Get-DefaultTab -Client $Client
            $ctx.Handle = $h
        }

        $owner = $script:TabOwners[$h]
        if ($owner -and $owner -ne $Client -and $action -in $script:WriteActions) {
            return @{ success = $false; error = "Tab '$(Get-TabName $h)' belongs to $owner, so you can read it but not $action in it. Open your own with newtab." }
        }

        Enter-ClientTab -Client $Client -Handle $h
        $r = Invoke-BrowserAction -Body $Body

        # Keep the client's position up to date.
        if ($r.success) {
            if ($action -eq 'switchtoframe') {
                if ($Body.default) { $ctx.Frames.Remove($h) }
                else {
                    $spec = if ($Body.frameId) { @{ frameId = $Body.frameId } } elseif ($Body.frameName) { @{ frameName = $Body.frameName } } else { @{ frameIndex = [int]$Body.frameIndex } }
                    if (-not $ctx.Frames.ContainsKey($h)) { $ctx.Frames[$h] = [System.Collections.Generic.List[object]]::new() }
                    $ctx.Frames[$h].Add($spec)
                }
            } elseif ($action -in $script:NewPageActions) {
                foreach ($c in $script:ClientCtx.Values) { $c.Frames.Remove($h) }
            } elseif ($action -eq 'closetab') {
                Remove-TabState $h
                $script:SwitchStamp++
            }
        }
        if ($r -is [hashtable] -and $action -ne 'closetab') { $r.tab = Get-TabName $h }
        return $r
    } catch {
        return @{ success = $false; error = $_.Exception.Message }
    }
}

# ---- Session keep-alive ----
# Each <data folder>\keepalive\<site>.js defines `var site = { probe: fn, renew: fn }` with header lines
# "// @name", "// @match <url regex>" and "// @renewBelow <seconds>". probe() returns
# { loggedOut, remaining } read from the site without changing anything; renew() extends the
# session without reloading. Files are re-read on each check, so a new site needs no restart.
function Write-KeepAliveLog {
    param([string]$Message, [string]$Color = 'Cyan')
    Write-Host "[$(Get-Date -Format HH:mm:ss)] [keepalive] $Message" -ForegroundColor $Color
    $script:KeepAlive.Events.Insert(0, [ordered]@{ time = (Get-Date -Format 'HH:mm:ss'); warn = ($Color -ne 'Cyan'); message = $Message })
    if ($script:KeepAlive.Events.Count -gt 100) { $script:KeepAlive.Events.RemoveAt(100) }
}

function Get-KeepAliveSites {
    if (-not (Test-Path $script:KeepAlive.SiteDir)) { return }
    foreach ($f in Get-ChildItem $script:KeepAlive.SiteDir -Filter *.js -File) {
        $src = Get-Content -LiteralPath $f.FullName -Raw
        $meta = @{}
        foreach ($m in [regex]::Matches($src, '(?m)^//\s*@(\w+)\s+(.+?)\s*$')) { $meta[$m.Groups[1].Value] = $m.Groups[2].Value }
        if (-not $meta.match) { continue }
        [pscustomobject]@{
            Id         = $f.BaseName   # stable key (file name), used by the per-site on/off switch
            Name       = if ($meta.name) { $meta.name } else { $f.BaseName }
            Match      = $meta.match
            RenewBelow = if ($meta.renewBelow) { [int]$meta.renewBelow } else { 300 }
            Source     = $src
        }
    }
}

function Invoke-KeepAliveSite {
    param($Site, [ValidateSet('probe', 'renew')][string]$Call)
    $raw = $script:Browser.Driver.ExecuteScript($Site.Source + "`n;return JSON.stringify(site.$Call());")
    return $raw | ConvertFrom-Json
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

function Get-KeepAliveTabName {
    param([string]$Handle)
    $name = ($script:Browser.Tabs.GetEnumerator() | Where-Object { $_.Value -eq $Handle } | Select-Object -First 1).Name
    if ($name) { "tab '$name'" } else { "tab $($Handle.Substring(0, [math]::Min(8, $Handle.Length)))" }
}

function Get-KeepAliveStatus {
    if (-not $script:Browser) { return }
    foreach ($kv in $script:KeepAlive.Tabs.GetEnumerator()) {
        $t = $kv.Value
        [ordered]@{
            id                 = $kv.Key
            tab                = Get-KeepAliveTabName $kv.Key
            title              = $t.Title
            url                = $t.Url
            site               = $t.Site
            siteId             = $t.SiteId
            origin             = Get-SiteOrigin $t.Url
            secondsLeftAtCheck = $t.Remaining
            checkedAt          = if ($t.CheckedAt) { [DateTimeOffset]::new($t.CheckedAt).ToUnixTimeMilliseconds() } else { $null }
            signedOut          = $t.LoggedOut
            last               = $t.LastResult
            lastRenew          = if ($t.LastRenew) { $t.LastRenew.ToString('HH:mm:ss') } else { $null }
            nextCheck          = $t.NextCheck.ToString('HH:mm:ss')
        }
    }
    # Tabs opened since the last keep-alive pass: listed now (with what's known), checked on the next pass.
    try { $handles = @($script:Browser.Driver.WindowHandles) } catch { return }
    foreach ($h in $handles) {
        if ($script:KeepAlive.Tabs.ContainsKey($h)) { continue }
        [ordered]@{
            id = $h; tab = Get-KeepAliveTabName $h; title = $null; url = $null; site = $null; siteId = $null; origin = $null
            secondsLeftAtCheck = $null; checkedAt = $null; signedOut = $false
            last = 'new, not checked yet'; lastRenew = $null; nextCheck = 'next pass'
        }
    }
}

# Checks only the tabs that are due. A check has to switch to the tab (which brings it to the
# front), so each tab is checked shortly before its session needs renewing, and at least every
# MaxCheckSeconds in case it navigated to another site. Always switches back afterwards.
function Invoke-KeepAliveTick {
    param([switch]$Force)
    $ka = $script:KeepAlive
    $ka.LastTick = Get-Date
    if (-not $script:Browser) { return }
    $renewing = $ka.Enabled -or $Force   # when off, tabs are still looked at (and named), but nothing is renewed
    $driver = $script:Browser.Driver
    try { $handles = @($driver.WindowHandles); $origin = $driver.CurrentWindowHandle } catch { return }   # alert open, browser gone
    foreach ($h in @($ka.Tabs.Keys)) { if ($h -notin $handles) { $ka.Tabs.Remove($h) } }
    $now = Get-Date
    $due = @($handles | Where-Object { -not $ka.Tabs.ContainsKey($_) -or $ka.Tabs[$_].NextCheck -le $now })
    if (-not $due.Count) { return }
    $sites = if ($renewing) { @(Get-KeepAliveSites) } else { @() }
    try {
        foreach ($h in $due) {
            if (-not $ka.Tabs.ContainsKey($h)) {
                $ka.Tabs[$h] = @{ Site = $null; Url = $null; Remaining = $null; LoggedOut = $false; LastRenew = $null; LastResult = 'new'; NextCheck = $now }
            }
            $t = $ka.Tabs[$h]
            try {
                $driver.SwitchTo().Window($h) | Out-Null
                $t.Url = $driver.Url
                $t.Title = $driver.Title
                Register-UnnamedTab -Handle $h -Url $t.Url
                $site = $sites | Where-Object { $t.Url -match $_.Match } | Select-Object -First 1
                $t.Site = if ($site) { $site.Name } else { $null }
                $t.SiteId = if ($site) { $site.Id } else { $null }
                if ($site -and -not (Test-KeepAliveSiteOn $site.Id)) {
                    # Turned off for this instance on the status page: recognised, never probed or renewed.
                    $t.Remaining = $null; $t.LoggedOut = $false; $t.LastResult = 'off for this site'
                    $t.NextCheck = $now.AddSeconds($ka.MaxCheckSeconds)
                    continue
                }
                if (-not $site) {
                    $t.Remaining = $null; $t.LastResult = if ($renewing) { 'no site profile' } else { 'keep-alive off' }
                    # A tab still waiting for a name (blank new-tab page) is looked at again soon.
                    $named = $script:Browser.Tabs.Values -contains $h
                    $t.NextCheck = $now.AddSeconds($(if ($named) { $ka.MaxCheckSeconds } else { 30 }))
                    continue
                }
                $p = Invoke-KeepAliveSite -Site $site -Call probe
                if ($p.loggedOut) {
                    if (-not $t.LoggedOut) { Write-KeepAliveLog "$(Get-KeepAliveTabName $h) ($($site.Name)) is signed out -- log in again" Yellow }
                    $t.LoggedOut = $true; $t.Remaining = $null; $t.LastResult = 'signed out'
                    $t.NextCheck = $now.AddSeconds(120)
                    continue
                }
                $t.LoggedOut = $false
                $left = [int]$p.remaining
                $t.LastResult = "ok, ${left}s left"
                if ($left -le $site.RenewBelow) {
                    $how = Invoke-KeepAliveSite -Site $site -Call renew
                    Start-Sleep -Seconds 2   # some sites renew asynchronously
                    $p2 = Invoke-KeepAliveSite -Site $site -Call probe
                    $after = if ($p2.loggedOut) { 0 } else { [int]$p2.remaining }
                    $t.LastRenew = Get-Date
                    $t.LastResult = "renewed ${left}s -> ${after}s ($how)"
                    if ($after -le $left) {
                        Write-KeepAliveLog "$(Get-KeepAliveTabName $h) ($($site.Name)): renew did not extend the session: $($t.LastResult)" Yellow
                        $t.Remaining = $after; $t.CheckedAt = Get-Date; $t.NextCheck = $now.AddSeconds(60)
                        continue
                    }
                    Write-KeepAliveLog "$(Get-KeepAliveTabName $h) ($($site.Name)): $($t.LastResult)"
                    $left = $after
                }
                $t.Remaining = $left
                $t.CheckedAt = Get-Date
                $t.NextCheck = $now.AddSeconds([math]::Max(30, [math]::Min($ka.MaxCheckSeconds, $left - $site.RenewBelow - 15)))
            } catch {
                $t.LastResult = "error: $($_.Exception.Message)"
                $t.NextCheck = $now.AddSeconds(120)
                Write-KeepAliveLog "$(Get-KeepAliveTabName $h): $($t.LastResult)" Yellow
            }
        }
    } finally {
        try { $driver.SwitchTo().Window($origin) | Out-Null } catch { }
        $script:SwitchStamp++   # the driver left the client's frame; re-enter it before the next command
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
    $browser = [ordered]@{ running = [bool]$script:Browser; startError = $script:BrowserStartError; currentId = $null; currentTab = $null; url = $null; tabCount = 0 }
    if ($script:Browser) {
        try {
            $d = $script:Browser.Driver
            $browser.tabCount = @($d.WindowHandles).Count
            $browser.currentId = $d.CurrentWindowHandle
            $browser.currentTab = Get-KeepAliveTabName $d.CurrentWindowHandle
            $browser.url = $d.Url
        } catch { $browser.url = "(unavailable: $($_.Exception.Message))" }
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
        # Per tab (by window handle): the client that owns it and the clients whose current tab it is.
        tabUse    = $(
            $use = [ordered]@{}
            if ($script:Browser) {
                foreach ($h in @($script:Browser.Driver.WindowHandles)) {
                    $users = @($script:ClientCtx.GetEnumerator() | Where-Object { $_.Value.Handle -eq $h } | ForEach-Object { $_.Key } | Sort-Object)
                    $use[$h] = [ordered]@{ owner = $script:TabOwners[$h]; users = $users }
                }
            }
            $use
        )
        access    = Get-AccessStatus
        keepAlive = [ordered]@{
            enabled = $script:KeepAlive.Enabled
            sites   = @(Get-KeepAliveSites | ForEach-Object { [ordered]@{ id = $_.Id; name = $_.Name; match = $_.Match; on = (Test-KeepAliveSiteOn $_.Id) } })
            requests = @($script:KaAdmin.Requests)
            drafts  = @(Get-KeepAliveDrafts)
            tabs    = @(Get-KeepAliveStatus)
            events  = @($script:KeepAlive.Events)
        }
        requests  = [ordered]@{ total = $script:Stats.Requests; errors = $script:Stats.Errors; byAction = $script:Stats.ByAction; byClient = $script:Stats.ByClient }
        recent    = @($script:Stats.Recent)
    }
}

# The page's actions (POST /status/closetab). Unlike reads, a write must also be safe from other
# websites making the browser send it, so it needs the X-Status-Request header (a foreign site can't
# add it without a CORS preflight, which this server never approves) and our own Origin. The Origin is required, not
# just checked when sent: the page's fetch always sends it, and a script has to add it on purpose, so an agent doesn't
# start, create or delete instances by calling these by accident (any program of the user's can still fake it).
function Test-StatusActionRequest {
    param([System.Net.HttpListenerRequest]$Request)
    if (-not (Test-LocalStatusRequest -Request $Request)) { return $false }
    if ($Request.Headers['X-Status-Request'] -ne '1') { return $false }
    $origin = $Request.Headers['Origin']
    return [bool]$origin -and $origin -in @("http://127.0.0.1:$($script:Port)", "http://localhost:$($script:Port)")
}

function Remove-InstanceFromStatus {
    # Delete on the status page: stops the instance if it's running (its own Stop server: Chrome closes cleanly), then
    # takes it off the list. Its folder stays as a leftover profile. Deleting this instance stops this server last.
    param([string]$Name)
    $other = Get-CWebInstance -Name $Name -Root $script:CWebRoot
    if ($other.AllNames.Count -le 1) { return @{ success = $false; error = "'$Name' is the only instance. Create another one before deleting it." } }
    $here = $other.Name -eq $script:InstanceName
    if (-not $here -and (Test-CWebServerProcess -Instance $other)) {
        $p = $other.Port
        try {
            Invoke-RestMethod "http://127.0.0.1:$p/status/stopserver" -Method POST -ContentType 'application/json' -Body '{}' `
                -Headers @{ 'X-Status-Request' = '1'; 'Origin' = "http://127.0.0.1:$p" } -TimeoutSec 30 | Out-Null
        } catch { }
        $deadline = (Get-Date).AddSeconds(30)
        while ((Test-CWebServerProcess -Instance $other) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
        if (Test-CWebServerProcess -Instance $other) { return @{ success = $false; error = "'$Name' didn't stop within 30 seconds, so it wasn't deleted. Stop it on its own status page, then try again." } }
    }
    Remove-CWebInstance -Name $other.Name -Root $script:CWebRoot
    Write-Host "[$(Get-Date -Format HH:mm:ss)] instance '$($other.Name)' deleted from the status page; its folder is kept as a leftover profile" -ForegroundColor Yellow
    if ($here) { $script:StopRequested = $true }
    return @{ success = $true; deleted = $other.Name; stopping = $here; message = "Deleted '$($other.Name)'. Its profile and sign-ins are kept: Restore it under + New, Leftover profiles." }
}

function Close-TabByHandle {
    param([string]$Handle)
    if (-not $script:Browser) { return @{ success = $false; error = 'No browser running' } }
    $d = $script:Browser.Driver
    $handles = @($d.WindowHandles)
    if ($Handle -notin $handles) { return @{ success = $false; error = 'That tab is already closed.' } }
    if ($handles.Count -le 1) { return @{ success = $false; error = "Can't close the last tab; that would end the browser." } }
    $label = Get-KeepAliveTabName $Handle
    $origin = $d.CurrentWindowHandle
    $d.SwitchTo().Window($Handle) | Out-Null
    $d.Close()
    foreach ($name in @($script:Browser.Tabs.Keys | Where-Object { $script:Browser.Tabs[$_] -eq $Handle })) { $script:Browser.Tabs.Remove($name) }
    $script:KeepAlive.Tabs.Remove($Handle)
    Remove-TabState $Handle   # its owner and anyone's position in it
    $script:SwitchStamp++
    # Back to the tab the API was on; if that's the one closed, the last remaining tab.
    $back = if ($origin -ne $Handle) { $origin } else { @($d.WindowHandles)[-1] }
    $d.SwitchTo().Window($back) | Out-Null
    return @{ success = $true; closed = $label; current = (Get-KeepAliveTabName $back) }
}

function Open-TabFromStatus {
    param([string]$Url, [string]$Name)
    if (-not $script:Browser) { return @{ success = $false; error = 'No browser running' } }
    $u = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u) -or $u.Scheme -notin @('http', 'https')) {
        return @{ success = $false; error = 'Enter a full http:// or https:// address.' }
    }
    if ($Name) {
        if ($Name -notmatch '^[A-Za-z0-9_-]{1,40}$') { return @{ success = $false; error = 'Name: letters, numbers, - and _ only.' } }
        if ($script:Browser.Tabs.ContainsKey($Name)) { return @{ success = $false; error = "A tab named '$Name' already exists." } }
    }
    $d = $script:Browser.Driver
    $origin = $d.CurrentWindowHandle
    try {
        if ($Name) { Chrome-NewTab -Browser $script:Browser -Url $u.AbsoluteUri -Name $Name }
        else { Chrome-NewTab -Browser $script:Browser -Url $u.AbsoluteUri; Register-UnnamedTab -Handle $d.CurrentWindowHandle -Url $d.Url }
        $handle = $d.CurrentWindowHandle
    } finally {
        # Put the API back on the tab it was using; the new tab is the user's to look at.
        try { $d.SwitchTo().Window($origin) | Out-Null } catch { }
        $script:SwitchStamp++
    }
    return @{ success = $true; opened = (Get-KeepAliveTabName $handle) }
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
    $action = ($Request.Url.AbsolutePath -split '/')[-1]   # closetab | newtab | stopserver | approve | deny | revoke | startinstance | newinstance | deleteinstance | ...
    try {
        if ($action -eq 'deleteinstance') {
            $result = Remove-InstanceFromStatus -Name ([string]$body.name)
            $target = [string]$body.name
        } elseif ($action -eq 'deleteprofile') {
            $result = Remove-CWebLeftoverProfile -Name ([string]$body.name) -Root $script:CWebRoot
            $target = [string]$body.name
        } elseif ($action -in 'kasite', 'karequest', 'kadismiss', 'kaenable', 'kadiscard') {
            switch ($action) {
                'kasite'    { $result = Set-KeepAliveSiteState -Id ([string]$body.site) -On ([bool]$body.on); $target = "$($body.site) $(if ($body.on) { 'on' } else { 'off' })" }
                'karequest' { $result = New-KeepAliveRequest -Handle ([string]$body.id); $target = [string]$result.site }
                'kadismiss' { $result = Remove-KeepAliveRequest -Id ([string]$body.request); $target = [string]$result.dismissed }
                'kaenable'  { $result = Enable-KeepAliveDraft -Id ([string]$body.draft); $target = [string]$body.draft }
                'kadiscard' { $result = Remove-KeepAliveDraft -Id ([string]$body.draft); $target = [string]$body.draft }
            }
        } elseif ($action -in 'startinstance', 'newinstance') {
            # Launch another instance's server without waiting for it (this server handles one request at a time);
            # the switcher shows it once it's up.
            if ($action -eq 'newinstance') {
                $other = New-CWebInstance -Name ([string]$body.name) -Label ([string]$body.label) -Root $script:CWebRoot
                Write-Host "[$(Get-Date -Format HH:mm:ss)] new instance '$($other.Name)' ($($other.Label)) on port $($other.Port)" -ForegroundColor Green
            } else {
                $other = Get-CWebInstance -Name ([string]$body.name) -Root $script:CWebRoot
            }
            if ($other.Name -eq $script:InstanceName -or (Test-CWebServerProcess -Instance $other)) {
                $result = @{ success = $true; name = $other.Name; port = $other.Port; message = 'Already running.' }
            } else {
                Start-CWebServerProcess -Instance $other -Root $script:CWebRoot
                $result = @{ success = $true; name = $other.Name; label = $other.Label; port = $other.Port; message = "Starting $($other.Label) on port $($other.Port)." }
            }
            $target = "$($other.Name) port $($other.Port)"
        } elseif ($action -in 'approve', 'deny') {
            $result = Set-AttachDecision -Ref ([string]$body.ref) -Approve ($action -eq 'approve')
            $target = "from status page: $(if ($result.approved) { $result.approved } elseif ($result.denied) { $result.denied })"
        } elseif ($action -eq 'revoke') {
            $result = Revoke-CWebClient -Client ([string]$body.client)
            $target = "from status page: $($body.client)"
        } elseif ($action -eq 'stopserver') {
            # Answer first; the main loop then exits and its cleanup closes Chrome and the listener.
            $script:StopRequested = $true
            $result = @{ success = $true; message = 'Stopping: closing Chrome, then the server.' }
            $target = 'from status page'
        } elseif ($action -eq 'newtab') {
            $result = Open-TabFromStatus -Url ([string]$body.url) -Name ([string]$body.name)
            $target = "from status page: $(if ($result.opened) { $result.opened }) $($body.url)"
        } else {
            $url = if ($script:KeepAlive.Tabs.ContainsKey([string]$body.id)) { $script:KeepAlive.Tabs[[string]$body.id].Url }
            $result = Close-TabByHandle -Handle ([string]$body.id)
            $target = "from status page: $(if ($result.closed) { $result.closed } else { 'tab' }) $url"
        }
    } catch {
        $result = @{ success = $false; error = $_.Exception.Message }
    }
    Send-Response -Response $Response -Data $result
    try { Add-RequestStat -Body @{ action = $action } -Result $result -Ms $timer.Elapsed.TotalMilliseconds -Target ($target -replace '^from status page:\s*', '').Trim() -Client 'status page' } catch { }
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
        } elseif ($Request.Url.AbsolutePath -eq '/status/profiles.json') {
            # For the New instance form, fetched when it opens (folder sizes take a moment, so not in /status.json).
            $type = 'application/json'
            $text = [ordered]@{
                leftovers = @(Get-CWebLeftoverProfiles -Root $script:CWebRoot)
            } | ConvertTo-Json -Depth 5 -Compress
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
        Write-Host "  (status page not sent: $($_.Exception.Message))" -ForegroundColor DarkYellow
    } finally {
        try { $Response.OutputStream.Close() } catch { }
    }
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

    # "Here I am" file for the launcher and Connect-CWeb. No key in it.
    [ordered]@{
        instance = $script:InstanceName
        port     = $script:Port
        pid      = $PID
        version  = $script:ModuleVersion
        started  = $script:Stats.Started.ToString('yyyy-MM-dd HH:mm:ss')
        folder   = $PSScriptRoot
    } | ConvertTo-Json | Set-Content -LiteralPath $script:Inst.ServerFile -Encoding utf8

    # Open Chrome now, so the launcher needs no key. Requests that arrive meanwhile wait in the listener's queue.
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
        Save-CWebAccessIfDue
        try {
        $request = $context.Request
        $response = $context.Response

        # Status page (polled every few seconds, so not logged)
        if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -in @('/', '/status', '/status.json', '/status/profiles.json')) {
            Send-StatusPage -Request $request -Response $response
            continue
        }
        if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -in @('/status/closetab', '/status/newtab', '/status/stopserver', '/status/approve', '/status/deny', '/status/revoke', '/status/startinstance', '/status/newinstance', '/status/kasite', '/status/karequest', '/status/kadismiss', '/status/kaenable', '/status/kadiscard', '/status/deleteprofile', '/status/deleteinstance')) {
            Invoke-StatusAction -Request $request -Response $response
            if ($script:StopRequested) { Write-Host "[$(Get-Date -Format HH:mm:ss)] Stop requested from the status page"; break }
            continue
        }

        # Attach: POST /attach {client} asks for access; GET /attach/<ticket> waits for the decision and collects the key.
        $path = $request.Url.AbsolutePath
        if ($path -eq '/attach' -or $path.StartsWith('/attach/')) {
            if (-not (Test-AttachRequest -Request $request)) {
                Send-Response -Response $response -Data @{ success = $false; error = 'Forbidden: /attach is for local scripts (send X-CWeb-Attach: 1, no Origin).' } -StatusCode 403
            } elseif ($request.HttpMethod -eq 'POST' -and $path -eq '/attach') {
                try {
                    $reader = New-Object System.IO.StreamReader($request.InputStream)
                    $ab = $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable; $reader.Close()
                } catch { $ab = @{} }
                Send-Response -Response $response -Data (New-AttachRequest -Client ([string]$ab.client))
            } elseif ($request.HttpMethod -eq 'GET' -and $path.StartsWith('/attach/')) {
                $r = Get-AttachState -Ticket $path.Substring(8)
                Send-Response -Response $response -Data $r -StatusCode $(if ($r.status -eq 'unknown') { 404 } else { 200 })
            } else {
                Send-Response -Response $response -Data @{ success = $false; error = 'Use POST /attach or GET /attach/<ticket>' } -StatusCode 404
            }
            continue
        }

        # No CORS headers: only local scripts use the API, never web pages. A preflight gets no approval.
        if ($request.HttpMethod -eq "OPTIONS") {
            $response.StatusCode = 204
            $response.Close()
            continue
        }

        # Log request (API calls are logged after they run, as a readable action line)
        if (-not ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -eq "/api")) {
            Write-Host "[$(Get-Date -Format HH:mm:ss)] $($request.HttpMethod) $($request.Url.PathAndQuery)"
        }

        # Check authentication: the key of a client approved on the status page
        $script:Caller = Resolve-CWebClient -Request $request
        if (-not $script:Caller) {
            Send-Response -Response $response -Data @{ success = $false; error = "Unauthorized: no approved key. Attach first (POST /attach), or the key was revoked." } -StatusCode 401
            continue
        }

        # Handle POST /api
        if ($request.HttpMethod -eq "POST" -and $request.Url.AbsolutePath -eq "/api") {
            $reader = New-Object System.IO.StreamReader($request.InputStream)
            $bodyText = $reader.ReadToEnd()
            $reader.Close()

            try {
                $body = $bodyText | ConvertFrom-Json -AsHashtable
                $timer = [System.Diagnostics.Stopwatch]::StartNew()
                $result = Invoke-ClientAction -Body $body -Client $script:Caller
                Send-Response -Response $response -Data $result
                try { Add-RequestStat -Body $body -Result $result -Ms $timer.Elapsed.TotalMilliseconds -Client $script:Caller } catch { }
            } catch {
                Send-Response -Response $response -Data @{ success = $false; error = "Invalid JSON: $($_.Exception.Message)" } -StatusCode 400
            }
        } else {
            Send-Response -Response $response -Data @{ success = $false; error = "Use POST /api" } -StatusCode 404
        }
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
    Save-CWebAccessIfDue -Now   # last-used times not yet written
    # Remove the "here I am" file only if it's ours, then free the instance lock.
    try {
        $sf = $script:Inst.ServerFile
        if ((Test-Path $sf) -and ((Get-Content $sf -Raw | ConvertFrom-Json).pid -eq $PID)) { Remove-Item -LiteralPath $sf -Force }
    } catch { }
    try { $script:Lock.ReleaseMutex(); $script:Lock.Dispose() } catch { }
    Write-Host "Server stopped."
    try { Stop-Transcript | Out-Null } catch { }
}
