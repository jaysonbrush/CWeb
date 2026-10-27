# Determine script root for relative paths (works when dot-sourced or run directly)
$script:ChromeScriptRoot = $PSScriptRoot
if (-not $script:ChromeScriptRoot) {
    $script:ChromeScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Backup-ChromeProfile {
    # Sets a saved profile aside (renamed to <profile>.bak-<reason>-<timestamp>) so Chrome starts with a fresh one.
    # Never deletes the current profile; backups older than 30 days are removed.
    param([string]$Path, [string]$Reason)
    if (-not (Test-Path $Path)) { return }
    $parent = Split-Path $Path -Parent; $leaf = Split-Path $Path -Leaf
    Get-ChildItem $parent -Directory -Filter "$leaf.bak-*" -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $dest = Join-Path $parent ("$leaf.bak-$Reason-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Rename-Item -LiteralPath $Path -NewName (Split-Path $dest -Leaf) -ErrorAction Stop
    Write-Host "  Profile set aside: $dest" -ForegroundColor Yellow
    return $dest
}

function Get-ChromeProfileProcess {
    # Chrome processes started with exactly this --user-data-dir. An exact match, not a substring, so
    # ...\CWeb\test\profile never matches ...\CWeb\test\profile-old or another tool's profile.
    param([string]$UserDataPath)
    $p = [regex]::Escape($UserDataPath.TrimEnd('\'))
    $rx = "--user-data-dir=(`"$p\\?`"|$p\\?(\s|$))"
    Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match $rx }
}

function Close-ChromeProfile {
    # Closes the Chrome running on this profile the way its own menu's Exit does: Browser.close over the DevTools port
    # Chrome wrote to <profile>\DevToolsActivePort. Chrome saves the session and records a clean exit, so the next
    # start doesn't say "Chrome didn't shut down correctly". Needs no ChromeDriver (works when the driver hangs or its
    # server is gone). Waits for every process on the profile to end; -Force kills what is left after the wait (an
    # unclean exit, so only as a last resort). Returns $true when no Chrome is left on the profile.
    param([string]$UserDataPath, [int]$TimeoutSeconds = 20, [switch]$Force)
    if (-not $UserDataPath -or -not @(Get-ChromeProfileProcess -UserDataPath $UserDataPath).Count) { return $true }
    $portFile = Join-Path $UserDataPath 'DevToolsActivePort'
    try {
        $port, $path = @(Get-Content -LiteralPath $portFile -ErrorAction Stop)[0, 1]
        $ws = [System.Net.WebSockets.ClientWebSocket]::new()
        $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(5))
        try {
            [void]$ws.ConnectAsync([Uri]"ws://127.0.0.1:$($port.Trim())$($path.Trim())", $cts.Token).GetAwaiter().GetResult()
            $msg = [Text.Encoding]::UTF8.GetBytes('{"id":1,"method":"Browser.close"}')
            [void]$ws.SendAsync([ArraySegment[byte]]::new($msg), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult()
        } finally { $ws.Dispose(); $cts.Dispose() }
    } catch {
        Write-Host "  Couldn't ask Chrome to close ($($_.Exception.Message))." -ForegroundColor DarkYellow
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (-not @(Get-ChromeProfileProcess -UserDataPath $UserDataPath).Count) { return $true }
        Start-Sleep -Milliseconds 500
    }
    if (-not $Force) { return $false }
    $left = @(Get-ChromeProfileProcess -UserDataPath $UserDataPath)
    Write-Host "  Chrome didn't close within ${TimeoutSeconds}s; ending $($left.Count) process(es) (Chrome will offer to restore the tabs)." -ForegroundColor Yellow
    $left | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    return -not @(Get-ChromeProfileProcess -UserDataPath $UserDataPath).Count
}

function Get-ChromeWorkRoot {
    # Where Chrome-Start keeps profiles and temp folders: the caller's folder (CWeb passes its instance folder),
    # else <CWeb data folder>\scripts for standalone scripts. 
    param([string]$WorkRoot)
    if (-not $WorkRoot) {
        # CWeb's data folder (same rule as Get-CWebDataRoot in CWeb-Common.ps1), then \scripts.
        $root = [Environment]::GetEnvironmentVariable('CWEB_DATA', 'User')
        if (-not $root) { $root = $env:CWEB_DATA }
        if (-not $root) {
            $root = Join-Path $env:USERPROFILE 'CWebData'
            $legacy = Join-Path $env:LOCALAPPDATA 'CWeb'   # before CWeb 2026.10.26.015
            if (-not (Test-Path $root) -and (Test-Path $legacy)) { $root = $legacy }
        }
        $WorkRoot = Join-Path $root.TrimEnd('\') 'scripts'
    }
    New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
    return $WorkRoot
}

function Repair-ChromeProfile {
    # Pre-launch checks for a saved (persistent) profile:
    #  1. End leftover automation Chrome still holding THIS profile (a new Chrome would hand off to it and exit,
    #     which ChromeDriver reports as "crashed"). Only processes using this exact --user-data-dir are touched.
    #  2. A profile written by a NEWER Chrome than the bundled one can't be opened (Chrome crashes on start) --
    #     set it aside and start fresh.
    param([string]$UserDataPath, [string]$ChromePath)
    $leftover = @(Get-ChromeProfileProcess -UserDataPath $UserDataPath)
    if ($leftover.Count) {
        Write-Host "  Closing $($leftover.Count) leftover Chrome process(es) still using $UserDataPath" -ForegroundColor Yellow
        Close-ChromeProfile -UserDataPath $UserDataPath -Force | Out-Null
    }
    $lv = Join-Path $UserDataPath 'Last Version'
    if (-not (Test-Path $lv)) { return }
    try {
        $profVer = [version]((Get-Content $lv -Raw).Trim())
        $binVer  = [version]((Get-Item $ChromePath).VersionInfo.ProductVersion)
    } catch { return }
    if ($profVer -gt $binVer) {
        Write-Host "  Saved profile was made by Chrome $profVer, newer than the bundled Chrome $binVer -- it can't be opened." -ForegroundColor Yellow
        Backup-ChromeProfile -Path $UserDataPath -Reason "chrome$profVer" | Out-Null
    }
}

function Chrome-Start {
    [CmdletBinding()]
    param (
        [bool]$Hidden = $False,
        [bool]$Persist = $False,
        [string]$ProfileName = "profile",   # saved profile folder name under WorkRoot (used when UserDataPath isn't given)
        [string]$UserDataPath,              # full path of the saved profile (CWeb passes the instance's profile)
        [string]$WorkRoot,                  # folder for profiles and temp files (default <CWeb data folder>\scripts)
        [string]$WindowName,                # shown in front of the page title in the window's title bar and taskbar (e.g. "CWeb Work")
        [bool]$IsRetry = $False,
        [bool]$Stealth = $True
    )
    $originalTemp = $env:TEMP
    $originalTmp = $env:TMP
    try {
        $WorkRoot = Get-ChromeWorkRoot -WorkRoot $WorkRoot
        $tempPath = Join-Path $WorkRoot "temp-$(Get-Random)"
        New-Item -ItemType Directory -Path $tempPath -Force | Out-Null
        $env:TEMP = $tempPath
        $env:TMP = $tempPath

        # Load required DLLs - paths relative to script location
        # Selenium 4.4x+ names it Selenium.WebDriver.dll; older releases WebDriver.dll. The updater keeps only one.
        $seleniumDllPath = Join-Path $script:ChromeScriptRoot "Selenium\Selenium.WebDriver.dll"
        if (-not (Test-Path $seleniumDllPath)) { $seleniumDllPath = Join-Path $script:ChromeScriptRoot "Selenium\WebDriver.dll" }
        # Newtonsoft.Json: Selenium 4.x no longer needs it (it uses System.Text.Json), and the updater doesn't download
        # it. Loaded only if an older install left it there.
        $jsonDllPath = Join-Path $script:ChromeScriptRoot "Selenium\Newtonsoft.Json.dll"

        # Validate DLL files exist before loading
        if (-not (Test-Path $seleniumDllPath)) {
            throw "Selenium WebDriver DLL not found at: $seleniumDllPath (run CWeb's Setup-CWeb.cmd)"
        }

        # Load DLLs with proper error handling
        try {
            Add-Type -Path $seleniumDllPath
        } catch [System.Reflection.ReflectionTypeLoadException] {
            # DLL already loaded - this is expected on subsequent calls
        }
        if (Test-Path $jsonDllPath) { try {
            Add-Type -Path $jsonDllPath
        } catch [System.Reflection.ReflectionTypeLoadException] {
            # DLL already loaded - this is expected on subsequent calls
        } }

        $chromeOptions = New-Object OpenQA.Selenium.Chrome.ChromeOptions
        $chromePath = Join-Path $script:ChromeScriptRoot "chrome-win64\chrome.exe"
        $chromeOptions.BinaryLocation = $chromePath
        # Use persistent profile if requested, otherwise random profile
        if ($Persist) {
            $userDataPath = if ($UserDataPath) { $UserDataPath } else { Join-Path $WorkRoot $ProfileName }
            Repair-ChromeProfile -UserDataPath $userDataPath -ChromePath $chromePath
        } else {
            $userDataPath = Join-Path $WorkRoot "throwaway-$(Get-Random)"
        }
        $chromeOptions.AddArgument("--user-data-dir=$userDataPath")
        # Persistent profile: reopen like "continue where you left off", so session cookies (site logins that
        # aren't "remember me") survive a restart too.
        # The session.restore_on_startup preference alone doesn't do it: Chrome resets protected settings it didn't
        # write itself. --restore-last-session reopens the last session's tabs (and its session cookies) every start.
        if ($Persist) {
            $chromeOptions.AddUserProfilePreference("session.restore_on_startup", 1)
            $chromeOptions.AddArgument("--restore-last-session")
        }
        $chromeOptions.AddArgument("ignore-certificate-errors")
        $chromeOptions.AddArgument("--ignore-ssl-errors=yes")
        $chromeOptions.AddArgument("--ignore-certificate-errors-spki-list")
        # One combined switch -- Chrome keeps only the last --disable-blink-features, so these must share it.
        # AutomationControlled: Chrome no longer sets navigator.webdriver = true.
        $chromeOptions.AddArgument("--disable-blink-features=BlockCredentialedSubresources,AutomationControlled")
        # Drop ChromeDriver's --enable-automation switch: no "controlled by automated software" banner.
        $chromeOptions.AddExcludedArgument("enable-automation")
        # Suppress Chrome popups (search engine choice in EU, etc.)
        $chromeOptions.AddArgument("--disable-search-engine-choice-screen")
        # Tabs that aren't in front run at full speed (timers, rendering), so agents can work in background tabs.
        $chromeOptions.AddArgument("--disable-background-timer-throttling")
        $chromeOptions.AddArgument("--disable-renderer-backgrounding")
        $chromeOptions.AddArgument("--disable-backgrounding-occluded-windows")
        # Window label, so several automation windows (CWeb instances) can be told apart.
        if ($WindowName) { $chromeOptions.AddArgument("--window-name=$WindowName") }

        # Running from a network drive (mapped letter or \\server path): Chrome crashes on start with its sandbox on
        # (verified 2026-10-02: N: copy + known-good profile + sandbox = "Chrome failed to start: crashed"; same
        # setup with --no-sandbox starts). So the sandbox is turned off only in that case; local disks keep it.
        $onNetwork = $chromePath.StartsWith('\\')
        if (-not $onNetwork) {
            try { $onNetwork = ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($chromePath)).DriveType -eq [IO.DriveType]::Network) } catch { }
        }
        if ($onNetwork) {
            $chromeOptions.AddArgument("--no-sandbox")
            Write-Host "  Chrome is on a network drive ($chromePath) -- starting with --no-sandbox." -ForegroundColor Yellow
        }

        if ($Hidden) {
            $chromeOptions.AddArgument("--headless=new")
            $chromeOptions.AddArgument("--disable-gpu")
            $chromeOptions.AddArgument("--window-size=1920,1080")
        }

        $chromeDriverPath = Join-Path $script:ChromeScriptRoot "chromedriver-win64"
        $driverService = [OpenQA.Selenium.Chrome.ChromeDriverService]::CreateDefaultService($chromeDriverPath)
        # ChromeDriver's own log (why Chrome failed to launch / crashed) when the server set a log folder: warnings and
        # errors only. One file per start (a restart used to overwrite the day's file, losing why the last start
        # failed), kept 7 days like the other logs.
        if ($env:CWEB_LOGDIR) {
            try {
                # Day files (chromedriver-<date>.log) are from versions before 2026.10.27.022, which logged every command
                # (about 1 GB a day): removed at once.
                Get-ChildItem $env:CWEB_LOGDIR -Filter 'chromedriver-*.log' -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '^chromedriver-\d{4}-\d{2}-\d{2}\.log$' -or $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
                    Remove-Item -Force -ErrorAction SilentlyContinue
                $driverService.LogPath = Join-Path $env:CWEB_LOGDIR "chromedriver-$(Get-Date -Format yyyy-MM-dd-HHmmss).log"
                $driverService.EnableVerboseLogging = $false
                $driverService.LogLevel = [OpenQA.Selenium.Chromium.ChromiumDriverLogLevel]::Warning
            } catch { }
        }
        # Command timeout 330 s (Selenium's default is 60): with a saved profile Chrome reopens the last session's tabs,
        # and ChromeDriver's first commands wait for those pages to load. Heavy sites can take over a minute, which
        # used to fail the start and leave Chrome running without CWeb.
        $driver = New-Object OpenQA.Selenium.Chrome.ChromeDriver($driverService, $chromeOptions, [TimeSpan]::FromSeconds(330))
        # Stealth (default on; the selenium-stealth idea, done natively -- no Python): small patches injected before
        # every page's own scripts, each applied only where the browser actually gives itself away.
        if ($Stealth) {
            try {
                $stealthJs = @'
(function () {
  try { if (navigator.webdriver) { Object.defineProperty(Navigator.prototype, 'webdriver', { get: () => false, configurable: true }); } } catch (e) {}
  try { if (!navigator.languages || !navigator.languages.length) { Object.defineProperty(Navigator.prototype, 'languages', { get: () => ['en-US', 'en'], configurable: true }); } } catch (e) {}
  try {
    if (window.Notification && navigator.permissions && navigator.permissions.query) {
      const orig = navigator.permissions.query.bind(navigator.permissions);
      navigator.permissions.query = function (p) {
        return (p && p.name === 'notifications') ? Promise.resolve({ state: Notification.permission, onchange: null }) : orig(p);
      };
    }
  } catch (e) {}
})();
'@
                $cdp = New-Object 'System.Collections.Generic.Dictionary[string,object]'
                $cdp['source'] = $stealthJs
                $driver.ExecuteCdpCommand('Page.addScriptToEvaluateOnNewDocument', $cdp) | Out-Null
                if ($Hidden) {
                    # Headless reports "HeadlessChrome" in the user agent -- report plain "Chrome".
                    $ua = [string]$driver.ExecuteScript('return navigator.userAgent')
                    if ($ua -match 'HeadlessChrome') {
                        $uaArgs = New-Object 'System.Collections.Generic.Dictionary[string,object]'
                        $uaArgs['userAgent'] = $ua -replace 'HeadlessChrome', 'Chrome'
                        $driver.ExecuteCdpCommand('Network.setUserAgentOverride', $uaArgs) | Out-Null
                    }
                }
            } catch {
                Write-Host "  Stealth patches not applied: $($_.Exception.Message)" -ForegroundColor DarkYellow
            }
        }
        # A fresh start shows Chrome's new-tab page: make it blank. A tab reopened from the last session is left as it is.
        if ($driver.Url -notmatch '^https?:') { $driver.Navigate().GoToUrl("about:blank") | Out-Null }

        $tabs = @{
            main = $driver.CurrentWindowHandle
        }

        return @{
            Driver = $driver
            Service = $driverService
            Tabs = $tabs
            TempPath = $tempPath
            UserDataPath = $userDataPath
            Persist = [bool]$Persist
        }
    } catch {
        # Full error chain (inner exceptions carry the real cause, e.g. blocked/missing chromedriver, version mismatch).
        $msg = $_.Exception.Message; $inner = $_.Exception.InnerException
        while ($inner) { $msg += " | " + $inner.Message; $inner = $inner.InnerException }
        $script:ChromeStartError = $msg
        Write-Host "Failed to start Chrome: $msg" -ForegroundColor Red
        # Don't leave the Chrome this start opened running without anyone driving it: close it cleanly.
        if ($driver) { try { $driver.Quit() } catch { } }
        if ($driverService) { try { $driverService.Dispose() } catch { } }
        if ($userDataPath) { Close-ChromeProfile -UserDataPath $userDataPath -Force | Out-Null }
        # Safety net: Chrome crashed on start with the saved profile -> set the profile aside and retry once fresh.
        if ($Persist -and -not $IsRetry -and $msg -match 'crashed|not reachable|DevToolsActivePort') {
            try {
                if ($tempPath -and (Test-Path $tempPath)) { Remove-Item $tempPath -Recurse -Force -ErrorAction SilentlyContinue }
                Write-Host "  Retrying once with a fresh profile..." -ForegroundColor Yellow
                $bak = Backup-ChromeProfile -Path $userDataPath -Reason 'crash'
                $env:TEMP = $originalTemp; $env:TMP = $originalTmp
                $retry = Chrome-Start -Hidden $Hidden -Persist $Persist -ProfileName $ProfileName -UserDataPath $userDataPath -WorkRoot $WorkRoot -WindowName $WindowName -IsRetry $true -Stealth $Stealth
                if (-not $retry -and $bak -and (Test-Path $bak)) {
                    # A fresh profile crashed too, so the profile wasn't the cause -- put the original (logins) back.
                    Get-ChromeProfileProcess -UserDataPath $userDataPath | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
                    Start-Sleep -Seconds 1
                    if (Test-Path $userDataPath) { Remove-Item -LiteralPath $userDataPath -Recurse -Force -ErrorAction SilentlyContinue }
                    Rename-Item -LiteralPath $bak -NewName (Split-Path $userDataPath -Leaf) -ErrorAction SilentlyContinue
                    Write-Host "  Fresh profile crashed too -- the profile wasn't the cause; original profile restored." -ForegroundColor Yellow
                }
                return $retry
            } catch {
                $script:ChromeStartError = "$msg | profile reset failed: $($_.Exception.Message)"
            }
        }
        Write-Host ($_.ScriptStackTrace) -ForegroundColor DarkGray
        Write-Error "Failed to start Chrome with error: $msg"
        return $null
    } finally {
        $env:TEMP = $originalTemp
        $env:TMP = $originalTmp
    }
}

function Remove-ChromeArtifact {
    # Helper for Chrome-Stop. Retries Remove-Item so Chrome subprocesses have a moment
    # to release file handles after Driver.Quit(). Logs the real failure if it can't delete.
    param([string]$Path, [string]$Label)
    if (-not $Path -or -not (Test-Path $Path)) { return }
    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            return
        } catch {
            $lastError = $_
            Start-Sleep -Milliseconds 500
        }
    }
    Write-Warning "Failed to clean up $Label after 3 attempts: $Path -- $($lastError.Exception.Message)"
}

function Chrome-Stop {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser
    )
    # Quit sends Chrome a clean Browser.close. If the driver doesn't answer, Close-ChromeProfile asks Chrome directly.
    # Either way this waits until Chrome has really exited, so a restart right after (an update) finds the profile free.
    try { $Browser.Driver.Quit() } catch { Write-Host "  ChromeDriver didn't quit ($($_.Exception.Message)); closing Chrome directly." -ForegroundColor DarkYellow }
    try { $Browser.Service.Dispose() } catch { }
    if ($Browser.UserDataPath) { Close-ChromeProfile -UserDataPath $Browser.UserDataPath -TimeoutSeconds 30 -Force | Out-Null }

    Remove-ChromeArtifact -Path $Browser.TempPath -Label "temp path"
    # A persistent profile is kept (logins, cookies) -- only throwaway profiles are deleted.
    if (-not $Browser.Persist) { Remove-ChromeArtifact -Path $Browser.UserDataPath -Label "user data path" }
}

function Chrome-NewTab {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser,
        [string]$Url = "about:blank",
        [string]$Name
    )
    
    # Prevent duplicate tab names
    if ($Name -and $Browser.Tabs.ContainsKey($Name)) {
        throw "A tab with the name '$Name' already exists. Please choose a unique name."
    }

    $driver = $Browser.Driver
    $initialHandles = $driver.WindowHandles

    $driver.ExecuteScript("window.open('about:blank', '_blank');") | Out-Null

    $newHandle = ($driver.WindowHandles | Where-Object { $initialHandles -notcontains $_ } | Select-Object -First 1)
    if (-not $newHandle) {
        throw "Failed to create and identify a new tab handle."
    }

    $driver.SwitchTo().Window($newHandle) | Out-Null

    if ($Url -ne "about:blank") {
        Chrome-Navigate -Browser $Browser -Url $Url | Out-Null
    }

    if ($Name) {
        $Browser.Tabs[$Name] = $newHandle
    }
}

function Chrome-SwitchTab {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser,
        [Parameter(Mandatory=$true)]
        [string]$Name
    )
    if (-not $Browser.Tabs.ContainsKey($Name)) {
        throw "No tab with the name '$Name' exists in the tracking list."
    }
    
    $handle = $Browser.Tabs[$Name]
    
    # Verify the handle is still valid before trying to switch
    if ($handle -notin $Browser.Driver.WindowHandles) {
        $Browser.Tabs.Remove($Name)
        throw "The tab '$Name' appears to have been closed. It has been removed from the tracking list."
    }

    try {
        $Browser.Driver.SwitchTo().Window($handle) | Out-Null
    } catch {
        # If the switch fails, the handle is invalid. Remove it and report error.
        $Browser.Tabs.Remove($Name)
        Write-Error "Failed to switch to tab '$Name'. The handle was invalid. Removing it from the list."
        throw $_
    }
}

function Chrome-ListTabs {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser
    )
    return $Browser.Tabs.Keys
}

function Chrome-CloseTab {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser
    )
    $driver = $Browser.Driver
    if ($driver.WindowHandles.Count -le 1) {
        Write-Warning "This is the last tab. Use Chrome-Stop to close the browser."
        return
    }

    $currentHandle = $driver.CurrentWindowHandle
    $tabNameToRemove = ($Browser.Tabs.GetEnumerator() | Where-Object { $_.Value -eq $currentHandle }).Name
    
    if ($tabNameToRemove) {
        $Browser.Tabs.Remove($tabNameToRemove)
    }

    $driver.Close()
    
    # Safely switch to the last available tab
    try {
        $driver.SwitchTo().Window($driver.WindowHandles[-1]) | Out-Null
    } catch {
        Write-Warning "Could not switch to the last tab after closing. It may have also been closed."
    }
}

function Chrome-Navigate {
    [CmdletBinding()]
    param (
        # This now accepts the standard hashtable
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser,
        [string]$Url
    )
    try {
        # Extract the driver from the hashtable
        $Driver = $Browser.Driver
        
        $Driver.Navigate().GoToUrl($Url) | Out-Null
        
        # Call Chrome-Wait with the Browser hashtable
        Chrome-Wait -Browser $Browser
    } catch {
        Write-Error "Failed to navigate to $Url with error: $_"
    }
}

function Chrome-Wait {
    [CmdletBinding()]
    param (
        # This function now accepts the standard hashtable
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser,
        [int]$TimeoutInSeconds = 30
    )
    # Extract the driver from the hashtable
    $Driver = $Browser.Driver

    $startTime = Get-Date
    do {
        Start-Sleep -Milliseconds 500
        try {
            $currentState = $Driver.ExecuteScript("return document.readyState")
        } catch {
            # If the page context is lost (e.g., during navigation), assume it's complete to avoid a hang
            $currentState = "complete" 
        }
        $elapsed = (Get-Date) - $startTime
    } while ($currentState -ne 'complete' -and $elapsed.TotalSeconds -lt $TimeoutInSeconds)

    if ($currentState -ne 'complete') {
        throw "Timeout waiting for page to load"
    }
}

function Chrome-GetPageSource {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser
    )
    return $Browser.Driver.PageSource
}

function Chrome-GetCurrentUrl {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser
    )
    return $Browser.Driver.Url
}

function Chrome-GetTitle {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser
    )
    return $Browser.Driver.Title
}

function Chrome-FindElement {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser,
        [Parameter(Mandatory=$true)]
        [ValidateSet("Id", "Name", "ClassName", "TagName", "CssSelector", "XPath", "LinkText", "PartialLinkText")]
        [string]$By,
        [Parameter(Mandatory=$true)]
        [string]$Value
    )
    $locator = switch ($By) {
        "Id"              { [OpenQA.Selenium.By]::Id($Value) }
        "Name"            { [OpenQA.Selenium.By]::Name($Value) }
        "ClassName"       { [OpenQA.Selenium.By]::ClassName($Value) }
        "TagName"         { [OpenQA.Selenium.By]::TagName($Value) }
        "CssSelector"     { [OpenQA.Selenium.By]::CssSelector($Value) }
        "XPath"           { [OpenQA.Selenium.By]::XPath($Value) }
        "LinkText"        { [OpenQA.Selenium.By]::LinkText($Value) }
        "PartialLinkText" { [OpenQA.Selenium.By]::PartialLinkText($Value) }
    }
    return $Browser.Driver.FindElement($locator)
}

function Chrome-FindElements {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser,
        [Parameter(Mandatory=$true)]
        [ValidateSet("Id", "Name", "ClassName", "TagName", "CssSelector", "XPath", "LinkText", "PartialLinkText")]
        [string]$By,
        [Parameter(Mandatory=$true)]
        [string]$Value
    )
    $locator = switch ($By) {
        "Id"              { [OpenQA.Selenium.By]::Id($Value) }
        "Name"            { [OpenQA.Selenium.By]::Name($Value) }
        "ClassName"       { [OpenQA.Selenium.By]::ClassName($Value) }
        "TagName"         { [OpenQA.Selenium.By]::TagName($Value) }
        "CssSelector"     { [OpenQA.Selenium.By]::CssSelector($Value) }
        "XPath"           { [OpenQA.Selenium.By]::XPath($Value) }
        "LinkText"        { [OpenQA.Selenium.By]::LinkText($Value) }
        "PartialLinkText" { [OpenQA.Selenium.By]::PartialLinkText($Value) }
    }
    return $Browser.Driver.FindElements($locator)
}

function Chrome-Click {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser,
        [Parameter(Mandatory=$true)]
        [ValidateSet("Id", "Name", "ClassName", "TagName", "CssSelector", "XPath", "LinkText", "PartialLinkText")]
        [string]$By,
        [Parameter(Mandatory=$true)]
        [string]$Value,
        [int]$TimeoutInSeconds = 5
    )
    # Retries while the element is missing, not yet clickable, or covered (e.g. a modal still fading in), and
    # scrolls it into view first. Throws the last Selenium error if it never becomes clickable.
    $deadline = (Get-Date).AddSeconds($TimeoutInSeconds)
    $lastErr = $null
    do {
        try {
            $element = Chrome-FindElement -Browser $Browser -By $By -Value $Value
            try { $Browser.Driver.ExecuteScript("arguments[0].scrollIntoView({block:'center',inline:'nearest'});", $element) | Out-Null } catch { }
            $element.Click()
            return
        } catch {
            $lastErr = $_
            $retry = $_.Exception.GetType().Name -match 'NotInteractable|ClickIntercepted|StaleElement|NoSuchElement' -or $_.Exception.Message -match 'not interactable|click intercepted|stale element|no such element'
            if (-not $retry) { throw }
            Start-Sleep -Milliseconds 250
        }
    } while ((Get-Date) -lt $deadline)
    throw $lastErr
}

function Chrome-SendKeys {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser,
        [Parameter(Mandatory=$true)]
        [ValidateSet("Id", "Name", "ClassName", "TagName", "CssSelector", "XPath", "LinkText", "PartialLinkText")]
        [string]$By,
        [Parameter(Mandatory=$true)]
        [string]$Value,
        [Parameter(Mandatory=$true)]
        [string]$Text,
        [switch]$Clear
    )
    $element = Chrome-FindElement -Browser $Browser -By $By -Value $Value
    if ($Clear) {
        $element.Clear()
    }
    $element.SendKeys($Text)
}

function Chrome-ExecuteScript {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser,
        [Parameter(Mandatory=$true)]
        [string]$Script,
        [array]$Arguments = @()
    )
    return $Browser.Driver.ExecuteScript($Script, $Arguments)
}

function Chrome-Screenshot {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser,
        [Parameter(Mandatory=$true)]
        [string]$FilePath
    )
    $screenshot = $Browser.Driver.GetScreenshot()
    $screenshot.SaveAsFile($FilePath)
    return $FilePath
}

function Chrome-Back {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser
    )
    $Browser.Driver.Navigate().Back()
    Chrome-Wait -Browser $Browser
}

function Chrome-Forward {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser
    )
    $Browser.Driver.Navigate().Forward()
    Chrome-Wait -Browser $Browser
}

function Chrome-Refresh {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser
    )
    $Browser.Driver.Navigate().Refresh()
    Chrome-Wait -Browser $Browser
}

function Chrome-WaitForElement {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser,
        [Parameter(Mandatory=$true)]
        [ValidateSet("Id", "Name", "ClassName", "TagName", "CssSelector", "XPath", "LinkText", "PartialLinkText")]
        [string]$By,
        [Parameter(Mandatory=$true)]
        [string]$Value,
        [int]$TimeoutInSeconds = 30,
        [bool]$Visible = $false
    )
    $locator = switch ($By) {
        "Id"              { [OpenQA.Selenium.By]::Id($Value) }
        "Name"            { [OpenQA.Selenium.By]::Name($Value) }
        "ClassName"       { [OpenQA.Selenium.By]::ClassName($Value) }
        "TagName"         { [OpenQA.Selenium.By]::TagName($Value) }
        "CssSelector"     { [OpenQA.Selenium.By]::CssSelector($Value) }
        "XPath"           { [OpenQA.Selenium.By]::XPath($Value) }
        "LinkText"        { [OpenQA.Selenium.By]::LinkText($Value) }
        "PartialLinkText" { [OpenQA.Selenium.By]::PartialLinkText($Value) }
    }

    # Polls with the core WebDriver API (WebDriverWait / ExpectedConditions live in Selenium.Support, which isn't
    # bundled). -Visible waits until the element is displayed, not just present in the page.
    $deadline = (Get-Date).AddSeconds($TimeoutInSeconds)
    do {
        foreach ($el in $Browser.Driver.FindElements($locator)) {
            try { if (-not $Visible -or $el.Displayed) { return $el } } catch { }
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw "Timed out after $TimeoutInSeconds s waiting for element ($By = $Value)$(if ($Visible) { ' to be visible' })."
}

function Chrome-GetText {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser,
        [Parameter(Mandatory=$true)]
        [ValidateSet("Id", "Name", "ClassName", "TagName", "CssSelector", "XPath", "LinkText", "PartialLinkText")]
        [string]$By,
        [Parameter(Mandatory=$true)]
        [string]$Value
    )
    $element = Chrome-FindElement -Browser $Browser -By $By -Value $Value
    return $element.Text
}

function Chrome-GetAttribute {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser,
        [Parameter(Mandatory=$true)]
        [ValidateSet("Id", "Name", "ClassName", "TagName", "CssSelector", "XPath", "LinkText", "PartialLinkText")]
        [string]$By,
        [Parameter(Mandatory=$true)]
        [string]$Value,
        [Parameter(Mandatory=$true)]
        [string]$Attribute
    )
    $element = Chrome-FindElement -Browser $Browser -By $By -Value $Value
    return $element.GetAttribute($Attribute)
}

function Chrome-SelectOption {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser,
        [Parameter(Mandatory=$true)]
        [ValidateSet("Id", "Name", "ClassName", "TagName", "CssSelector", "XPath", "LinkText", "PartialLinkText")]
        [string]$By,
        [Parameter(Mandatory=$true)]
        [string]$Value,
        [Parameter(Mandatory=$true)]
        [ValidateSet("Text", "Value", "Index")]
        [string]$SelectBy,
        [Parameter(Mandatory=$true)]
        $Option
    )
    # Core WebDriver only (SelectElement lives in Selenium.Support, which isn't bundled): pick the option in the
    # page and fire input + change, as a real selection does, so the page's own handlers run.
    $element = Chrome-FindElement -Browser $Browser -By $By -Value $Value
    $js = @'
var s = arguments[0], mode = arguments[1], want = String(arguments[2]);
if (!s || s.tagName !== 'SELECT') { return 'not a <select> element'; }
var idx = -1;
for (var i = 0; i < s.options.length; i++) {
  var o = s.options[i];
  if ((mode === 'Text' && o.text.trim() === want.trim()) || (mode === 'Value' && o.value === want) || (mode === 'Index' && i === parseInt(want, 10))) { idx = i; break; }
}
if (idx < 0) { return 'no option with ' + mode.toLowerCase() + ' "' + want + '"'; }
s.selectedIndex = idx;
s.dispatchEvent(new Event('input', { bubbles: true }));
s.dispatchEvent(new Event('change', { bubbles: true }));
return 'ok';
'@
    $r = $Browser.Driver.ExecuteScript($js, $element, $SelectBy, [string]$Option)
    if ($r -ne 'ok') { throw "selectoption: $r" }
}

function Chrome-SwitchToFrame {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser,
        [string]$FrameId,
        [string]$FrameName,
        [int]$FrameIndex = -1,
        [switch]$Default
    )

    if ($Default) {
        $Browser.Driver.SwitchTo().DefaultContent() | Out-Null
        return
    }

    if ($FrameId) {
        $element = Chrome-FindElement -Browser $Browser -By Id -Value $FrameId
        $Browser.Driver.SwitchTo().Frame($element) | Out-Null
    }
    elseif ($FrameName) {
        $Browser.Driver.SwitchTo().Frame($FrameName) | Out-Null
    }
    elseif ($FrameIndex -ge 0) {
        $Browser.Driver.SwitchTo().Frame($FrameIndex) | Out-Null
    }
    else {
        throw "Must specify -FrameId, -FrameName, -FrameIndex, or -Default"
    }
}

function Chrome-Hover {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser,
        [Parameter(Mandatory=$true)]
        [ValidateSet("Id", "Name", "ClassName", "TagName", "CssSelector", "XPath", "LinkText", "PartialLinkText")]
        [string]$By,
        [Parameter(Mandatory=$true)]
        [string]$Value
    )
    $element = Chrome-FindElement -Browser $Browser -By $By -Value $Value
    $actions = New-Object OpenQA.Selenium.Interactions.Actions($Browser.Driver)
    $actions.MoveToElement($element).Perform()
}

function Chrome-GetPageText {
    <#
    .SYNOPSIS
        Extracts readable text content from the current page.
    .DESCRIPTION
        Returns the visible text content of the page, stripped of HTML tags.
        Optionally can extract text from a specific element only.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser,
        [ValidateSet("Id", "Name", "ClassName", "TagName", "CssSelector", "XPath", "LinkText", "PartialLinkText")]
        [string]$By,
        [string]$Value
    )

    if ($By -and $Value) {
        # Get text from specific element
        $element = Chrome-FindElement -Browser $Browser -By $By -Value $Value
        return $element.Text
    } else {
        # Get all visible text from body
        $body = $Browser.Driver.FindElement([OpenQA.Selenium.By]::TagName("body"))
        return $body.Text
    }
}

function Chrome-Scroll {
    <#
    .SYNOPSIS
        Scrolls the page or scrolls to a specific element.
    .DESCRIPTION
        Can scroll by pixels, to top/bottom, or to a specific element.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser,
        [ValidateSet("Up", "Down", "Top", "Bottom", "ToElement")]
        [string]$Direction = "Down",
        [int]$Pixels = 500,
        [ValidateSet("Id", "Name", "ClassName", "TagName", "CssSelector", "XPath", "LinkText", "PartialLinkText")]
        [string]$By,
        [string]$Value
    )

    switch ($Direction) {
        "Up" {
            $Browser.Driver.ExecuteScript("window.scrollBy(0, -$Pixels);")
        }
        "Down" {
            $Browser.Driver.ExecuteScript("window.scrollBy(0, $Pixels);")
        }
        "Top" {
            $Browser.Driver.ExecuteScript("window.scrollTo(0, 0);")
        }
        "Bottom" {
            $Browser.Driver.ExecuteScript("window.scrollTo(0, document.body.scrollHeight);")
        }
        "ToElement" {
            if (-not $By -or -not $Value) {
                throw "Must specify -By and -Value when using -Direction ToElement"
            }
            $element = Chrome-FindElement -Browser $Browser -By $By -Value $Value
            $Browser.Driver.ExecuteScript("arguments[0].scrollIntoView({behavior: 'smooth', block: 'center'});", $element)
        }
    }
}

function Chrome-GetElementHtml {
    <#
    .SYNOPSIS
        Gets the outer HTML of an element.
    .DESCRIPTION
        Returns the full HTML of an element including the element itself and all children.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser,
        [Parameter(Mandatory=$true)]
        [ValidateSet("Id", "Name", "ClassName", "TagName", "CssSelector", "XPath", "LinkText", "PartialLinkText")]
        [string]$By,
        [Parameter(Mandatory=$true)]
        [string]$Value
    )

    $element = Chrome-FindElement -Browser $Browser -By $By -Value $Value
    return $Browser.Driver.ExecuteScript("return arguments[0].outerHTML;", $element)
}

function Chrome-GetAllLinks {
    <#
    .SYNOPSIS
        Gets all links on the current page.
    .DESCRIPTION
        Returns an array of objects with href, text, and title for each link.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser
    )

    $links = $Browser.Driver.FindElements([OpenQA.Selenium.By]::TagName("a"))
    $results = @()
    foreach ($link in $links) {
        $href = $link.GetAttribute("href")
        if ($href) {
            $results += @{
                href = $href
                text = $link.Text
                title = $link.GetAttribute("title")
            }
        }
    }
    return $results
}

function Chrome-GetAllForms {
    <#
    .SYNOPSIS
        Gets all forms and their fields on the current page.
    .DESCRIPTION
        Returns an array of form objects, each containing form attributes and field details.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser
    )

    $script = @"
        var forms = document.querySelectorAll('form');
        var results = [];
        forms.forEach(function(form, formIndex) {
            var fields = [];
            var inputs = form.querySelectorAll('input, select, textarea, button');
            inputs.forEach(function(input) {
                fields.push({
                    tag: input.tagName.toLowerCase(),
                    type: input.type || null,
                    name: input.name || null,
                    id: input.id || null,
                    placeholder: input.placeholder || null,
                    value: input.value || null,
                    required: input.required || false
                });
            });
            results.push({
                index: formIndex,
                id: form.id || null,
                name: form.name || null,
                action: form.action || null,
                method: form.method || null,
                fields: fields
            });
        });
        return JSON.stringify(results);
"@

    $json = $Browser.Driver.ExecuteScript($script)
    return $json | ConvertFrom-Json
}

function Chrome-AcceptAlert {
    <#
    .SYNOPSIS
        Accepts (clicks OK on) a JavaScript alert, confirm, or prompt dialog.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser,
        [string]$PromptText
    )

    $alert = $Browser.Driver.SwitchTo().Alert()
    if ($PromptText) {
        $alert.SendKeys($PromptText)
    }
    $alert.Accept()
}

function Chrome-DismissAlert {
    <#
    .SYNOPSIS
        Dismisses (clicks Cancel on) a JavaScript alert, confirm, or prompt dialog.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser
    )

    $alert = $Browser.Driver.SwitchTo().Alert()
    $alert.Dismiss()
}

function Chrome-GetAlertText {
    <#
    .SYNOPSIS
        Gets the text of the current JavaScript alert, confirm, or prompt dialog.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser
    )

    $alert = $Browser.Driver.SwitchTo().Alert()
    return $alert.Text
}

function Chrome-GetCookies {
    <#
    .SYNOPSIS
        Gets all cookies for the current domain.
    .DESCRIPTION
        Returns an array of cookie objects with name, value, domain, path, expiry, etc.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser,
        [string]$Name
    )

    if ($Name) {
        $cookie = $Browser.Driver.Manage().Cookies.GetCookieNamed($Name)
        if ($cookie) {
            return @{
                name = $cookie.Name
                value = $cookie.Value
                domain = $cookie.Domain
                path = $cookie.Path
                expiry = $cookie.Expiry
                secure = $cookie.Secure
                httpOnly = $cookie.IsHttpOnly
            }
        }
        return $null
    } else {
        $cookies = $Browser.Driver.Manage().Cookies.AllCookies
        $results = @()
        foreach ($cookie in $cookies) {
            $results += @{
                name = $cookie.Name
                value = $cookie.Value
                domain = $cookie.Domain
                path = $cookie.Path
                expiry = $cookie.Expiry
                secure = $cookie.Secure
                httpOnly = $cookie.IsHttpOnly
            }
        }
        return $results
    }
}

function Chrome-SetCookie {
    <#
    .SYNOPSIS
        Sets a cookie for the current domain.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser,
        [Parameter(Mandatory=$true)]
        [string]$Name,
        [Parameter(Mandatory=$true)]
        [string]$Value,
        [string]$Domain,
        [string]$Path = "/",
        [datetime]$Expiry,
        [switch]$Secure,
        [switch]$HttpOnly
    )

    $cookieBuilder = New-Object OpenQA.Selenium.Cookie($Name, $Value, $Domain, $Path, $Expiry)
    $Browser.Driver.Manage().Cookies.AddCookie($cookieBuilder)
}

function Chrome-DeleteCookie {
    <#
    .SYNOPSIS
        Deletes a cookie by name, or all cookies if no name specified.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser,
        [string]$Name
    )

    if ($Name) {
        $Browser.Driver.Manage().Cookies.DeleteCookieNamed($Name)
    } else {
        $Browser.Driver.Manage().Cookies.DeleteAllCookies()
    }
}

function Chrome-WaitForUrl {
    <#
    .SYNOPSIS
        Waits for the URL to match a pattern or change.
    .DESCRIPTION
        Can wait for URL to contain a string, match a regex, or simply change from current.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser,
        [string]$Contains,
        [string]$Matches,
        [switch]$Changed,
        [int]$TimeoutInSeconds = 30
    )

    $startTime = Get-Date
    $startUrl = $Browser.Driver.Url

    while ($true) {
        $currentUrl = $Browser.Driver.Url

        if ($Contains -and $currentUrl -like "*$Contains*") {
            return $currentUrl
        }
        if ($Matches -and $currentUrl -match $Matches) {
            return $currentUrl
        }
        if ($Changed -and $currentUrl -ne $startUrl) {
            return $currentUrl
        }

        $elapsed = (Get-Date) - $startTime
        if ($elapsed.TotalSeconds -ge $TimeoutInSeconds) {
            throw "Timeout waiting for URL condition after $TimeoutInSeconds seconds"
        }

        Start-Sleep -Milliseconds 250
    }
}

function Chrome-GetWindowSize {
    <#
    .SYNOPSIS
        Gets the current browser window size.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser
    )

    $size = $Browser.Driver.Manage().Window.Size
    return @{
        width = $size.Width
        height = $size.Height
    }
}

function Chrome-SetWindowSize {
    <#
    .SYNOPSIS
        Sets the browser window size.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser,
        [Parameter(Mandatory=$true)]
        [int]$Width,
        [Parameter(Mandatory=$true)]
        [int]$Height
    )

    $size = New-Object System.Drawing.Size($Width, $Height)
    $Browser.Driver.Manage().Window.Size = $size
}

function Chrome-Maximize {
    <#
    .SYNOPSIS
        Maximizes the browser window.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser
    )

    $Browser.Driver.Manage().Window.Maximize()
}

function Chrome-GetElementInfo {
    <#
    .SYNOPSIS
        Gets detailed information about an element.
    .DESCRIPTION
        Returns tagName, text, all attributes, size, location, and visibility.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$Browser,
        [Parameter(Mandatory=$true)]
        [ValidateSet("Id", "Name", "ClassName", "TagName", "CssSelector", "XPath", "LinkText", "PartialLinkText")]
        [string]$By,
        [Parameter(Mandatory=$true)]
        [string]$Value
    )

    $element = Chrome-FindElement -Browser $Browser -By $By -Value $Value

    # Get all attributes via JavaScript
    $attrScript = @"
        var el = arguments[0];
        var attrs = {};
        for (var i = 0; i < el.attributes.length; i++) {
            attrs[el.attributes[i].name] = el.attributes[i].value;
        }
        return JSON.stringify(attrs);
"@
    $attributesJson = $Browser.Driver.ExecuteScript($attrScript, $element)
    $attributes = $attributesJson | ConvertFrom-Json -AsHashtable

    return @{
        tagName = $element.TagName
        text = $element.Text
        attributes = $attributes
        displayed = $element.Displayed
        enabled = $element.Enabled
        selected = $element.Selected
        location = @{
            x = $element.Location.X
            y = $element.Location.Y
        }
        size = @{
            width = $element.Size.Width
            height = $element.Size.Height
        }
    }
}
