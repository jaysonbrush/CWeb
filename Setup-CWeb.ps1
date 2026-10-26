#Requires -Version 7.0
<#
.SYNOPSIS
    Sets CWeb up on this machine after a git clone, and removes it again with -Uninstall.

.DESCRIPTION
    - Installs the exact Chrome for Testing, ChromeDriver and Selenium versions pinned in browser\version.json, so
      every machine runs the same tested versions. Skips what's already right; safe to run again.
    - Creates the data folder (default %USERPROFILE%\CWebData): profiles, keys, logs and this machine's own instances
      live there, never in the repo folder. An older install's %LOCALAPPDATA%\CWeb is moved there.
    - Checks itself: Test-CWeb, then a short headless start and stop of the 'test' instance.

    Runs from any folder; it prints the exact paths for this machine at the end.

.EXAMPLE
    pwsh -File .\Setup-CWeb.ps1                     # set up (or check) this machine
    pwsh -File .\Setup-CWeb.ps1 -DataRoot D:\CWebData   # keep the data folder somewhere else (moves existing data)
    pwsh -File .\Setup-CWeb.ps1 -Uninstall          # list everything CWeb stored on this machine
    pwsh -File .\Setup-CWeb.ps1 -Uninstall -Yes     # ...and remove it

.NOTES
    Upgrading Chrome is a separate, deliberate step: run browser\Update-Browser.ps1 -UpdateSelenium on one machine,
    test, commit browser\version.json; other machines run this script again.
#>
param(
    [string]$DataRoot,     # put the data folder here (sets the user environment variable CWEB_DATA)
    [switch]$Uninstall,    # list what CWeb stored on this machine; with -Yes, remove it
    [switch]$Yes,
    [switch]$Force,        # reinstall Chrome, ChromeDriver and Selenium even if the versions match
    [switch]$SkipTest      # don't start the test instance at the end
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path $root 'CWeb-Common.ps1')

function Say($msg, $color = 'Gray') { Write-Host $msg -ForegroundColor $color }
function Step($msg) { Write-Host ''; Write-Host "== $msg" -ForegroundColor Cyan }
function Get-SizeMB($p) { if (Test-Path $p) { [math]::Round(((Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB), 1) } else { 0 } }

function Get-RunningCWebServers {
    # CWeb servers of this repo, running now (any data folder).
    @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf((Join-Path $root 'CWeb-Server.ps1'), [StringComparison]::OrdinalIgnoreCase) -ge 0 })
}

function Test-SafeDataRoot {
    # A data folder must be a folder of its own: never a drive root, the user profile, AppData itself or the repo.
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $bad = @([IO.Path]::GetPathRoot($full).TrimEnd('\'), $env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA, $root) | ForEach-Object { $_.TrimEnd('\') }
    if ($full -in $bad) { throw "'$full' can't be the data folder: pick a folder of its own, e.g. D:\CWebData." }
    if ($full.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "The data folder can't be inside the CWeb folder ($root): git clean or a re-clone would delete every login and key."
    }
    return $full
}

Say "CWeb setup -- $(try { (Get-Content (Join-Path $root 'VERSION') -Raw).Trim() } catch { '?' }) -- $env:COMPUTERNAME" White
Say "  Folder: $root"
$standard = 'C:\CWeb'   # the path the docs and the cweb skill use
if ($root.TrimEnd('\') -ne $standard) {
    Say "  Note: the docs and the cweb skill use $standard. CWeb works from here too; tell agents the cweb.sh path printed at the end." Yellow
}

# Windows marks downloaded or cloned-from-zip files as blocked; unblock ours before running any of them.
Get-ChildItem $root -Recurse -File -Include *.ps1, *.psm1, *.cmd, *.sh, *.dll, *.exe -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

# ================================ Uninstall ================================
if ($Uninstall) {
    $dataRoot = Get-CWebDataRoot
    $userVar = [Environment]::GetEnvironmentVariable('CWEB_DATA', 'User')
    $bins = @('chrome-win64', 'chromedriver-win64', 'Selenium', 'backup', 'temp_update') | ForEach-Object { Join-Path $root "browser\$_" } | Where-Object { Test-Path $_ }

    Step 'What CWeb stored on this machine'
    if (Test-Path $dataRoot) {
        Say "  Data folder $dataRoot ($(Get-SizeMB $dataRoot) MB): profiles and sign-ins, keys, approvals, logs, this machine's instances"
        Get-ChildItem $dataRoot -Force | ForEach-Object { Say ("    {0,-28} {1,8} MB" -f $_.Name, $(if ($_.PSIsContainer) { Get-SizeMB $_.FullName } else { [math]::Round($_.Length / 1MB, 2) })) }
    } else { Say "  Data folder ${dataRoot}: not there" }
    if ($userVar) { Say "  User environment variable CWEB_DATA = $userVar" }
    foreach ($b in $bins) { Say "  Downloaded: $b ($(Get-SizeMB $b) MB)" }
    Say ''
    Say '  Not touched: this CWeb folder itself (delete it yourself, or keep it for git).' DarkGray

    if (-not $Yes) { Say ''; Say 'Nothing removed. Run again with -Yes to remove the items above.' Yellow; exit 0 }

    $running = Get-RunningCWebServers
    if ($running.Count) { throw "$($running.Count) CWeb server(s) still running. Stop them (status page: Stop server), then run this again." }
    if (Test-Path $dataRoot) {
        $safe = Test-SafeDataRoot $dataRoot
        $chrome = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($safe, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
        if ($chrome.Count) { throw "A Chrome window is still using a profile in $safe. Close it, then run this again." }
    }
    Step 'Removing'
    if (Test-Path $dataRoot) { Remove-Item -LiteralPath $dataRoot -Recurse -Force; Say "  Removed $dataRoot" }
    if ($userVar) { [Environment]::SetEnvironmentVariable('CWEB_DATA', $null, 'User'); Say '  Removed CWEB_DATA' }
    foreach ($b in $bins) { Remove-Item -LiteralPath $b -Recurse -Force; Say "  Removed $b" }
    Say ''; Say "Done. To remove CWeb completely, delete $root." Green
    exit 0
}

# ================================ Data folder ================================
Step 'Data folder'
$current = Get-CWebDataRoot
# Installs from before 2026.10.26.015 kept the data under AppData, which packaged apps (the Claude desktop app) redirect
# into a private copy. Move it to the new default, unless the user chose a folder with CWEB_DATA.
$chosen = [Environment]::GetEnvironmentVariable('CWEB_DATA', 'User'); if (-not $chosen) { $chosen = $env:CWEB_DATA }
if (-not $DataRoot -and -not $chosen -and $current -eq (Get-CWebLegacyDataRoot).TrimEnd('\')) {
    Say "  The data folder is still the old $current (under AppData); moving it to $(Get-CWebDefaultDataRoot)." Yellow
    $DataRoot = Get-CWebDefaultDataRoot
}
if ($DataRoot) {
    $new = Test-SafeDataRoot $DataRoot
    $default = Get-CWebDefaultDataRoot
    if ($new -ne $current) {
        $running = Get-RunningCWebServers
        if ($running.Count) { throw "Stop every CWeb instance first (status page: Stop server); the data folder can't move while one runs." }
        $hasOld = (Test-Path $current) -and @(Get-ChildItem $current -Force).Count
        $hasNew = (Test-Path $new) -and @(Get-ChildItem $new -Force).Count
        if ($hasOld -and $hasNew) { throw "Both $current and $new already hold data. Move or empty one of them first; nothing was changed." }
        if ($hasOld) {
            Say "  Moving $current -> $new ..."
            New-Item -ItemType Directory -Path (Split-Path $new -Parent) -Force | Out-Null
            if ((Test-Path $new) -and -not $hasNew) { Remove-Item -LiteralPath $new -Force }
            if ([IO.Path]::GetPathRoot($current) -eq [IO.Path]::GetPathRoot($new)) {
                Move-Item -LiteralPath $current -Destination $new
            } else {
                & robocopy $current $new /E /MOVE /R:1 /W:1 /NP /NFL /NDL | Out-Null
                if ($LASTEXITCODE -ge 8) { throw "Moving the data failed (robocopy exit $LASTEXITCODE). $current is unchanged where the copy failed." }
                if (Test-Path $current) { Remove-Item -LiteralPath $current -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }
        if ($new -eq $default.TrimEnd('\')) { [Environment]::SetEnvironmentVariable('CWEB_DATA', $null, 'User') }
        else { [Environment]::SetEnvironmentVariable('CWEB_DATA', $new, 'User') }
        $current = Get-CWebDataRoot
    }
}
New-Item -ItemType Directory -Path $current -Force | Out-Null
Say "  $current$(if ([Environment]::GetEnvironmentVariable('CWEB_DATA', 'User')) { '  (set by CWEB_DATA)' } else { '  (default)' })"
# Settings file with the defaults, for the user to edit (custom ports, port fallback). An existing one is kept.
$configPath = Join-Path $current 'config.json'
if (-not (Test-Path $configPath)) {
    Set-Content -LiteralPath $configPath -Encoding utf8 -Value @(
        '{'
        '  "portFallback": true,'
        '  "firstPort": 9380,'
        '  "instances": {}'
        '}')
    Say "  Settings: $configPath (new, defaults)"
} else {
    $null = Get-CWebConfig   # throws if it doesn't parse
    Say "  Settings: $configPath"
}

# ================================ Chrome, ChromeDriver, Selenium ================================
Step 'Chrome for Testing, ChromeDriver, Selenium'
$pin = Get-Content (Join-Path $root 'browser\version.json') -Raw | ConvertFrom-Json
$chromeDir = Join-Path $root 'browser'
function Get-Installed {
    $c = Join-Path $chromeDir 'chrome-win64\chrome.exe'
    $d = Join-Path $chromeDir 'chromedriver-win64\chromedriver.exe'
    $s = @('Selenium\Selenium.WebDriver.dll', 'Selenium\WebDriver.dll') | ForEach-Object { Join-Path $chromeDir $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1
    [pscustomobject]@{
        Chrome   = if (Test-Path $c) { (Get-Item $c).VersionInfo.ProductVersion } else { $null }
        Driver   = if (Test-Path $d) { try { ((& $d --version) -split ' ')[1] } catch { 'unknown' } } else { $null }
        Selenium = if ($s) { ((Get-Item $s).VersionInfo.ProductVersion -split '[+ ]')[0] } else { $null }
    }
}
$have = Get-Installed
$ok = $have.Chrome -eq $pin.Version -and $have.Driver -eq $pin.Version -and $have.Selenium -eq $pin.SeleniumVersion
Say "  Pinned:    Chrome/ChromeDriver $($pin.Version), Selenium $($pin.SeleniumVersion)"
Say "  Installed: Chrome $(if ($have.Chrome) { $have.Chrome } else { '-' }), ChromeDriver $(if ($have.Driver) { $have.Driver } else { '-' }), Selenium $(if ($have.Selenium) { $have.Selenium } else { '-' })"
if ($ok -and -not $Force) {
    Say '  Up to date.' Green
} else {
    $running = Get-RunningCWebServers
    if ($running.Count) { throw "Stop every CWeb instance first: Chrome's files are locked while one runs." }
    Say '  Installing the pinned versions (about 200 MB to download)...'
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $chromeDir 'Update-Browser.ps1') -UpdateSelenium -Force -ChromeVersion $pin.Version -SeleniumVersion $pin.SeleniumVersion
    if ($LASTEXITCODE) { throw "Update-Browser.ps1 failed (exit $LASTEXITCODE). See the messages above." }
    Get-ChildItem $chromeDir -Recurse -File -Include *.dll, *.exe -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
    $have = Get-Installed
    if (-not ($have.Chrome -eq $pin.Version -and $have.Driver -eq $pin.Version -and $have.Selenium -eq $pin.SeleniumVersion)) {
        throw "After installing, the versions still don't match the pin: Chrome $($have.Chrome), ChromeDriver $($have.Driver), Selenium $($have.Selenium)."
    }
    Say "  Installed Chrome/ChromeDriver $($have.Chrome), Selenium $($have.Selenium)." Green
}

# ================================ Self-check ================================
Step 'Self-check'
& pwsh -NoProfile -File (Join-Path $root 'Test-CWeb.ps1') | ForEach-Object { "  $_" }
if ($LASTEXITCODE) { throw 'Test-CWeb.ps1 found a problem (above).' }
if (-not $SkipTest) {
    $test = Get-CWebInstance -Name 'test' -Root $root
    if (Get-CWebRunningServer -Instance $test) {
        Say "  The 'test' instance is already running; not starting it again." Yellow
    } else {
        Say "  Starting the 'test' instance (headless) to check Chrome starts..."
        $st = Start-CWebServer -Instance $test -Root $root -WaitSeconds 120
        $okStart = [bool]$st.browser.running
        $testPort = [int]$st.server.port   # may differ from the configured port if that one was taken
        try {
            Invoke-RestMethod "http://127.0.0.1:$testPort/status/stopserver" -Method POST -ContentType 'application/json' -Body '{}' `
                -Headers @{ 'X-Status-Request' = '1'; 'Origin' = "http://127.0.0.1:$testPort" } | Out-Null
        } catch { }
        if (-not $okStart) { throw "The test instance started but Chrome didn't: $($st.browser.startError). Logs: $($test.LogDir)" }
        Start-Sleep -Seconds 4
        Say '  Chrome started and stopped cleanly.' Green
    }
}

Step 'Ready'
$work = Get-CWebInstance -Name 'work' -Root $root
Say "  Start an instance:  Start-CWeb.cmd   (or: Start-CWeb.cmd <name>)" White
Say "  Status page:        http://127.0.0.1:$($work.Port)/status   (work)" White
Say "  Settings:           $configPath   (custom ports: see claude.md, Settings)" White
Say "  Agents connect with: $($root -replace '^([A-Za-z]):', { '/' + $_.Groups[1].Value.ToLower() } -replace '\\', '/')/cweb.sh <instance> <client-name> connect" White
Say "  Data folder:        $current" White
