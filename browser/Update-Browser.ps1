# Update-Browser.ps1
# Downloads and updates Chrome for Testing, ChromeDriver, and Selenium WebDriver
# Ensures all components stay in sync

[CmdletBinding()]
param (
    [ValidateSet("Stable", "Beta", "Dev", "Canary")]
    [string]$Channel = "Stable",

    [switch]$UpdateSelenium,

    [switch]$SeleniumOnly,

    [switch]$Force,

    [switch]$WhatIf,

    # Pinned install (used by Setup-CWeb.ps1): these exact versions instead of the latest. version.json is left
    # alone, since it already holds the pin. To upgrade on purpose, run without these and commit version.json.
    [string]$ChromeVersion,

    [string]$SeleniumVersion
)

$ErrorActionPreference = "Stop"
$script:ScriptRoot = $PSScriptRoot
if (-not $script:ScriptRoot) {
    $script:ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

# Configuration
$ChromeFolder = Join-Path $script:ScriptRoot "chrome-win64"
$ChromeDriverFolder = Join-Path $script:ScriptRoot "chromedriver-win64"
$SeleniumFolder = Join-Path $script:ScriptRoot "Selenium"
$TempFolder = Join-Path $script:ScriptRoot "temp_update"
$BackupFolder = Join-Path $script:ScriptRoot "backup"
$VersionFile = Join-Path $script:ScriptRoot "version.json"
$ChromeVersionsUrl = "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json"
$SeleniumNugetUrl = "https://api.nuget.org/v3-flatcontainer/selenium.webdriver"

function Write-Status {
    param([string]$Message, [string]$Type = "Info")
    $colors = @{
        "Info" = "Cyan"
        "Success" = "Green"
        "Warning" = "Yellow"
        "Error" = "Red"
    }
    Write-Host "[$Type] $Message" -ForegroundColor $colors[$Type]
}

function Get-CurrentVersion {
    # No browser or driver on disk (e.g. a fresh git checkout, where version.json is present but the binaries
    # aren't): nothing is installed, whatever version.json says.
    if (-not (Test-Path (Join-Path $ChromeFolder 'chrome.exe')) -or -not (Test-Path (Join-Path $ChromeDriverFolder 'chromedriver.exe'))) {
        return $null
    }
    if (Test-Path $VersionFile) {
        try {
            $versionInfo = Get-Content $VersionFile -Raw | ConvertFrom-Json
            return $versionInfo
        } catch {
            Write-Status "Could not read version file: $_" -Type "Warning"
        }
    }

    # Try to get version from Chrome executable
    $chromeExe = Join-Path $ChromeFolder "chrome.exe"
    if (Test-Path $chromeExe) {
        try {
            $version = (Get-Item $chromeExe).VersionInfo.ProductVersion
            return @{ Version = $version; Channel = "Unknown" }
        } catch {
            Write-Status "Could not read Chrome version: $_" -Type "Warning"
        }
    }

    return $null
}

function Get-CurrentSeleniumVersion {
    # Selenium 4.4x+ names it Selenium.WebDriver.dll; older releases WebDriver.dll.
    $webDriverDll = Get-ChildItem $SeleniumFolder -Filter '*WebDriver.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($webDriverDll) {
        # Check if we have version in version.json
        if (Test-Path $VersionFile) {
            try {
                $versionInfo = Get-Content $VersionFile -Raw | ConvertFrom-Json
                if ($versionInfo.SeleniumVersion) {
                    return $versionInfo.SeleniumVersion
                }
            } catch { }
        }

        # Try to find version from nupkg filename
        $nupkg = Get-ChildItem $SeleniumFolder -Filter "selenium.webdriver.*.nupkg" | Select-Object -First 1
        if ($nupkg) {
            if ($nupkg.Name -match 'selenium\.webdriver\.(\d+\.\d+\.\d+)\.nupkg') {
                return $Matches[1]
            }
        }

        return "Unknown"
    }
    return $null
}

function Get-PinnedChromeVersion {
    param([string]$Version)
    Write-Status "Looking up Chrome for Testing $Version..."
    $list = Invoke-RestMethod -Uri 'https://googlechromelabs.github.io/chrome-for-testing/known-good-versions-with-downloads.json' -UseBasicParsing
    $v = $list.versions | Where-Object { $_.version -eq $Version } | Select-Object -First 1
    if (-not $v) { throw "Chrome for Testing $Version is not in Google's list of downloadable versions." }
    $chromeUrl = ($v.downloads.chrome | Where-Object { $_.platform -eq 'win64' }).url
    $driverUrl = ($v.downloads.chromedriver | Where-Object { $_.platform -eq 'win64' }).url
    if (-not $chromeUrl -or -not $driverUrl) { throw "Chrome for Testing $Version has no win64 Chrome or ChromeDriver download." }
    return @{ Version = $v.version; Revision = $v.revision; ChromeUrl = $chromeUrl; ChromeDriverUrl = $driverUrl }
}

function Get-LatestChromeVersion {
    param([string]$Channel)
    if ($ChromeVersion) { return Get-PinnedChromeVersion -Version $ChromeVersion }

    Write-Status "Fetching latest Chrome version from API..."

    try {
        $response = Invoke-RestMethod -Uri $ChromeVersionsUrl -UseBasicParsing
        $channelData = $response.channels.$Channel

        if (-not $channelData) {
            throw "Channel '$Channel' not found in API response"
        }

        return @{
            Version = $channelData.version
            Revision = $channelData.revision
            ChromeUrl = ($channelData.downloads.chrome | Where-Object { $_.platform -eq "win64" }).url
            ChromeDriverUrl = ($channelData.downloads.chromedriver | Where-Object { $_.platform -eq "win64" }).url
        }
    } catch {
        throw "Failed to fetch Chrome version info: $_"
    }
}

function Get-LatestSeleniumVersion {
    if ($SeleniumVersion) {
        return @{ Version = $SeleniumVersion; DownloadUrl = "$SeleniumNugetUrl/$SeleniumVersion/selenium.webdriver.$SeleniumVersion.nupkg" }
    }
    Write-Status "Fetching latest Selenium version from NuGet..."

    try {
        $indexUrl = "$SeleniumNugetUrl/index.json"
        $response = Invoke-RestMethod -Uri $indexUrl -UseBasicParsing

        # Get the latest stable version (exclude pre-release versions with - in them)
        $stableVersions = $response.versions | Where-Object { $_ -notmatch '-' }
        $latestVersion = $stableVersions | Select-Object -Last 1

        $downloadUrl = "$SeleniumNugetUrl/$latestVersion/selenium.webdriver.$latestVersion.nupkg"

        return @{
            Version = $latestVersion
            DownloadUrl = $downloadUrl
        }
    } catch {
        throw "Failed to fetch Selenium version info: $_"
    }
}

function Get-FileWithProgress {
    param(
        [string]$Url,
        [string]$OutFile,
        [string]$Description
    )

    Write-Status "Downloading $Description..."
    Write-Status "  URL: $Url" -Type "Info"

    try {
        # Use BITS for better download handling, fall back to Invoke-WebRequest
        $useBits = $true
        try {
            Import-Module BitsTransfer -ErrorAction Stop
        } catch {
            $useBits = $false
        }

        if ($useBits) {
            Start-BitsTransfer -Source $Url -Destination $OutFile -Description $Description -DisplayName $Description
        } else {
            # Fallback with progress
            $ProgressPreference = 'SilentlyContinue'  # Speeds up Invoke-WebRequest significantly
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
            $ProgressPreference = 'Continue'
        }

        if (Test-Path $OutFile) {
            $size = (Get-Item $OutFile).Length / 1MB
            Write-Status "  Downloaded: $([math]::Round($size, 2)) MB" -Type "Success"
            return $true
        }
    } catch {
        Write-Status "  Download failed: $_" -Type "Error"
        return $false
    }

    return $false
}

function Expand-ChromeArchive {
    param(
        [string]$ZipPath,
        [string]$DestinationPath,
        [string]$Description
    )

    Write-Status "Extracting $Description..."

    try {
        # Remove destination if it exists
        if (Test-Path $DestinationPath) {
            Remove-Item $DestinationPath -Recurse -Force
        }

        # Create parent directory
        $parentPath = Split-Path $DestinationPath -Parent
        if (-not (Test-Path $parentPath)) {
            New-Item -ItemType Directory -Path $parentPath -Force | Out-Null
        }

        # Extract to temp location first
        $extractTemp = Join-Path $TempFolder "extract_temp"
        if (Test-Path $extractTemp) {
            Remove-Item $extractTemp -Recurse -Force
        }

        Expand-Archive -Path $ZipPath -DestinationPath $extractTemp -Force

        # The zip contains a folder like "chrome-win64" or "chromedriver-win64"
        # Move the contents to the destination
        $extractedFolder = Get-ChildItem $extractTemp | Select-Object -First 1
        if ($extractedFolder) {
            Move-Item $extractedFolder.FullName $DestinationPath -Force
        }

        Write-Status "  Extracted to: $DestinationPath" -Type "Success"
        return $true
    } catch {
        Write-Status "  Extraction failed: $_" -Type "Error"
        return $false
    }
}

function Update-SeleniumPackage {
    param(
        [string]$Version,
        [string]$DownloadUrl
    )

    Write-Status "Updating Selenium WebDriver to $Version..."

    try {
        New-Item -ItemType Directory -Path $SeleniumFolder -Force | Out-Null   # missing on a fresh checkout
        # Download the nupkg (save as .zip since nupkg is just a zip file)
        $zipPath = Join-Path $TempFolder "selenium.webdriver.$Version.zip"
        $downloaded = Get-FileWithProgress -Url $DownloadUrl -OutFile $zipPath -Description "Selenium WebDriver $Version"

        if (-not $downloaded) {
            throw "Failed to download Selenium package"
        }

        # Extract the zip
        $extractPath = Join-Path $TempFolder "selenium_extract"
        if (Test-Path $extractPath) {
            Remove-Item $extractPath -Recurse -Force
        }

        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

        # Selenium 4.4x+ ships Selenium.WebDriver.dll (was WebDriver.dll) and adds a net8.0 build.
        # The server runs on PowerShell 7 (.NET 8+), so prefer net8.0, else netstandard2.0.
        $candidates = foreach ($fw in 'net8.0', 'netstandard2.0') {
            foreach ($name in 'Selenium.WebDriver.dll', 'WebDriver.dll') { Join-Path $extractPath "lib\$fw\$name" }
        }
        $dllSource = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $dllSource) {
            throw "Selenium WebDriver DLL not found in package (looked in lib\net8.0 and lib\netstandard2.0)"
        }
        # Keep only one WebDriver DLL in the folder, so the loader can't pick up the old one.
        Get-ChildItem $SeleniumFolder -Filter '*WebDriver.dll' | Remove-Item -Force
        $dllName = Split-Path $dllSource -Leaf
        Copy-Item $dllSource (Join-Path $SeleniumFolder $dllName) -Force
        Write-Status "  Updated $dllName ($(Split-Path (Split-Path $dllSource -Parent) -Leaf))" -Type "Success"

        # Copy the package for reference (rename back to .nupkg)
        $nupkgDest = Join-Path $SeleniumFolder "selenium.webdriver.$Version.nupkg"

        # Remove old nupkg files
        Get-ChildItem $SeleniumFolder -Filter "selenium.webdriver.*.nupkg" | Remove-Item -Force

        Copy-Item $zipPath $nupkgDest -Force
        Write-Status "  Saved package: selenium.webdriver.$Version.nupkg" -Type "Success"

        # Clean up old extracted folder if exists
        $oldExtracted = Get-ChildItem $SeleniumFolder -Directory -Filter "selenium.webdriver.*" | Select-Object -First 1
        if ($oldExtracted) {
            Remove-Item $oldExtracted.FullName -Recurse -Force
            Write-Status "  Removed old extracted folder" -Type "Info"
        }

        return $true
    } catch {
        Write-Status "  Selenium update failed: $_" -Type "Error"
        return $false
    }
}

function Backup-CurrentVersion {
    param([string]$Version)

    if (-not (Test-Path $BackupFolder)) {
        New-Item -ItemType Directory -Path $BackupFolder -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupName = "backup_${Version}_$timestamp"
    $backupPath = Join-Path $BackupFolder $backupName

    Write-Status "Backing up current version to: $backupPath"

    New-Item -ItemType Directory -Path $backupPath -Force | Out-Null

    if (Test-Path $ChromeFolder) {
        Copy-Item $ChromeFolder (Join-Path $backupPath "chrome-win64") -Recurse -Force
    }
    if (Test-Path $ChromeDriverFolder) {
        Copy-Item $ChromeDriverFolder (Join-Path $backupPath "chromedriver-win64") -Recurse -Force
    }
    if (Test-Path $SeleniumFolder) {
        Copy-Item $SeleniumFolder (Join-Path $backupPath "Selenium") -Recurse -Force
    }
    if (Test-Path $VersionFile) {
        Copy-Item $VersionFile (Join-Path $backupPath "version.json") -Force
    }

    Write-Status "  Backup complete" -Type "Success"
}

function Save-VersionInfo {
    param(
        [string]$ChromeVersion,
        [string]$Channel,
        [string]$Revision,
        [string]$SeleniumVersion
    )

    # Read existing version info if available
    $versionInfo = @{}
    if (Test-Path $VersionFile) {
        try {
            $existing = Get-Content $VersionFile -Raw | ConvertFrom-Json
            # Convert to hashtable
            $existing.PSObject.Properties | ForEach-Object {
                $versionInfo[$_.Name] = $_.Value
            }
        } catch { }
    }

    # Update with new values
    if ($ChromeVersion) {
        $versionInfo["Version"] = $ChromeVersion
        $versionInfo["Channel"] = $Channel
        $versionInfo["Revision"] = $Revision
    }
    if ($SeleniumVersion) {
        $versionInfo["SeleniumVersion"] = $SeleniumVersion
    }
    $versionInfo["UpdatedAt"] = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    $versionInfo["Platform"] = "win64"

    $versionInfo | ConvertTo-Json | Set-Content $VersionFile -Encoding UTF8
    Write-Status "Version info saved to: $VersionFile" -Type "Success"
}

function Remove-OldBackups {
    param([int]$KeepCount = 3)

    if (-not (Test-Path $BackupFolder)) {
        return
    }

    $backups = Get-ChildItem $BackupFolder -Directory | Sort-Object CreationTime -Descending

    if ($backups.Count -gt $KeepCount) {
        $toRemove = $backups | Select-Object -Skip $KeepCount
        foreach ($backup in $toRemove) {
            Write-Status "Removing old backup: $($backup.Name)" -Type "Info"
            Remove-Item $backup.FullName -Recurse -Force
        }
    }
}

# Main execution
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Chrome & Selenium Update Script" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

try {
    $updateChrome = -not $SeleniumOnly
    $updateSel = $UpdateSelenium -or $SeleniumOnly

    # Get current versions
    $currentVersion = Get-CurrentVersion
    $currentSeleniumVersion = Get-CurrentSeleniumVersion

    if ($currentVersion) {
        Write-Status "Current Chrome: $($currentVersion.Version) ($($currentVersion.Channel))"
    } else {
        Write-Status "Chrome: Not installed" -Type "Warning"
    }

    if ($currentSeleniumVersion) {
        Write-Status "Current Selenium: $currentSeleniumVersion"
    } else {
        Write-Status "Selenium: Not installed" -Type "Warning"
    }

    Write-Host ""

    # Get latest versions
    $latestChromeVersion = $null
    $latestSeleniumVersion = $null

    if ($updateChrome) {
        $latestChromeVersion = Get-LatestChromeVersion -Channel $Channel
        Write-Status "Latest Chrome ($Channel): $($latestChromeVersion.Version)"
    }

    if ($updateSel) {
        $latestSeleniumVersion = Get-LatestSeleniumVersion
        Write-Status "Latest Selenium: $($latestSeleniumVersion.Version)"
    }

    # Check if updates are needed
    $chromeNeedsUpdate = $updateChrome -and ($Force -or -not $currentVersion -or $currentVersion.Version -ne $latestChromeVersion.Version)
    $seleniumNeedsUpdate = $updateSel -and ($Force -or -not $currentSeleniumVersion -or $currentSeleniumVersion -eq "Unknown" -or $currentSeleniumVersion -ne $latestSeleniumVersion.Version)

    if (-not $chromeNeedsUpdate -and -not $seleniumNeedsUpdate) {
        Write-Host ""
        Write-Status "Everything is up to date!" -Type "Success"
        Write-Host ""
        exit 0
    }

    # WhatIf mode
    if ($WhatIf) {
        Write-Host ""
        Write-Status "WhatIf Mode - No changes will be made" -Type "Warning"
        Write-Host ""
        Write-Host "Would perform the following actions:"
        $step = 1
        if ($chromeNeedsUpdate) {
            Write-Host "  $step. Download Chrome $($latestChromeVersion.Version)"
            $step++
            Write-Host "  $step. Download ChromeDriver $($latestChromeVersion.Version)"
            $step++
        }
        if ($seleniumNeedsUpdate) {
            Write-Host "  $step. Download Selenium WebDriver $($latestSeleniumVersion.Version)"
            $step++
        }
        if ($currentVersion -or $currentSeleniumVersion) {
            Write-Host "  $step. Backup current versions"
        }
        Write-Host ""
        exit 0
    }

    # Create temp folder
    if (Test-Path $TempFolder) {
        Remove-Item $TempFolder -Recurse -Force
    }
    New-Item -ItemType Directory -Path $TempFolder -Force | Out-Null

    # Backup current versions
    if (($chromeNeedsUpdate -and $currentVersion) -or ($seleniumNeedsUpdate -and $currentSeleniumVersion)) {
        $backupVersion = if ($currentVersion) { $currentVersion.Version } else { "selenium-$currentSeleniumVersion" }
        Backup-CurrentVersion -Version $backupVersion
    }

    # Update Chrome and ChromeDriver
    if ($chromeNeedsUpdate) {
        Write-Host ""
        Write-Status "--- Updating Chrome ---" -Type "Info"

        # Download Chrome
        $chromeZip = Join-Path $TempFolder "chrome-win64.zip"
        $chromeDownloaded = Get-FileWithProgress -Url $latestChromeVersion.ChromeUrl -OutFile $chromeZip -Description "Chrome $($latestChromeVersion.Version)"

        if (-not $chromeDownloaded) {
            throw "Failed to download Chrome"
        }

        # Download ChromeDriver
        $driverZip = Join-Path $TempFolder "chromedriver-win64.zip"
        $driverDownloaded = Get-FileWithProgress -Url $latestChromeVersion.ChromeDriverUrl -OutFile $driverZip -Description "ChromeDriver $($latestChromeVersion.Version)"

        if (-not $driverDownloaded) {
            throw "Failed to download ChromeDriver"
        }

        # Extract Chrome
        $chromeExtracted = Expand-ChromeArchive -ZipPath $chromeZip -DestinationPath $ChromeFolder -Description "Chrome"
        if (-not $chromeExtracted) {
            throw "Failed to extract Chrome"
        }

        # Extract ChromeDriver
        $driverExtracted = Expand-ChromeArchive -ZipPath $driverZip -DestinationPath $ChromeDriverFolder -Description "ChromeDriver"
        if (-not $driverExtracted) {
            throw "Failed to extract ChromeDriver"
        }
    }

    # Update Selenium
    if ($seleniumNeedsUpdate) {
        Write-Host ""
        Write-Status "--- Updating Selenium ---" -Type "Info"

        $seleniumUpdated = Update-SeleniumPackage -Version $latestSeleniumVersion.Version -DownloadUrl $latestSeleniumVersion.DownloadUrl
        if (-not $seleniumUpdated) {
            throw "Failed to update Selenium"
        }
    }

    # Save version info
    Write-Host ""
    $chromeVer = if ($chromeNeedsUpdate) { $latestChromeVersion.Version } elseif ($currentVersion) { $currentVersion.Version } else { $null }
    $chromeChannel = if ($chromeNeedsUpdate) { $Channel } elseif ($currentVersion) { $currentVersion.Channel } else { $null }
    $chromeRev = if ($chromeNeedsUpdate) { $latestChromeVersion.Revision } elseif ($currentVersion -and $currentVersion.Revision) { $currentVersion.Revision } else { $null }
    $selVer = if ($seleniumNeedsUpdate) { $latestSeleniumVersion.Version } else { $currentSeleniumVersion }

    # A pinned install leaves version.json alone: it already holds the pin, and rewriting it (UpdatedAt) would show
    # up as a change in git on every machine that runs setup.
    if (-not $ChromeVersion -and -not $SeleniumVersion) {
        Save-VersionInfo -ChromeVersion $chromeVer -Channel $chromeChannel -Revision $chromeRev -SeleniumVersion $selVer
    }

    # Cleanup temp folder
    Write-Status "Cleaning up temporary files..."
    Remove-Item $TempFolder -Recurse -Force

    # Remove old backups (keep last 3)
    Remove-OldBackups -KeepCount 3

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Status "Update complete!" -Type "Success"
    if ($chromeNeedsUpdate) {
        Write-Status "Chrome/ChromeDriver: $($latestChromeVersion.Version)" -Type "Success"
    }
    if ($seleniumNeedsUpdate) {
        Write-Status "Selenium WebDriver: $($latestSeleniumVersion.Version)" -Type "Success"
    }
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""

} catch {
    Write-Host ""
    Write-Status "Update failed: $_" -Type "Error"
    Write-Host ""

    # Cleanup temp folder if it exists
    if (Test-Path $TempFolder) {
        Remove-Item $TempFolder -Recurse -Force -ErrorAction SilentlyContinue
    }

    exit 1
}
