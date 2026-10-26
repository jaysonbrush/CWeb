# CWeb-Profiles.ps1 -- leftover instance profiles (Restore / Delete on the status page).
# Dot-sourced by CWeb-Server.ps1 after CWeb-Common.ps1 and browser\Browser-Functions.ps1 (needs Get-ChromeProfileProcess).
#
# Every instance keeps its data in <data folder>\<instance>\ (profile\, logs\, clients\, ...). A "leftover" is
# such a folder whose name is no longer an instance (default or this machine's). Recreating it reuses the folder.

$script:CWebDataRoot = Get-CWebDataRoot   # fixed for the life of the server (Setup-CWeb won't move it while one runs)
$script:CWebDeletedDir = Join-Path $script:CWebDataRoot '_deleted'

function Get-FolderSizeMB {
    param([string]$Path)
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    return [math]::Round(($sum / 1MB), 1)
}

function Get-CWebLeftoverProfiles {
    param([string]$Root)
    if (-not (Test-Path $script:CWebDataRoot)) { return }
    $names = @((Get-CWebInstanceTable -Root $Root).Keys)
    foreach ($d in Get-ChildItem $script:CWebDataRoot -Directory) {
        if ($d.Name -notmatch '^[a-z0-9][a-z0-9-]{0,29}$' -or $d.Name -eq 'scripts' -or $d.Name -in $names) { continue }
        $prof = Join-Path $d.FullName 'profile'
        if (-not (Test-Path $prof)) { continue }
        $last = @(Get-Item (Join-Path $prof 'Local State'), (Join-Path $prof 'Default\Preferences') -ErrorAction SilentlyContinue | ForEach-Object LastWriteTime) + $d.LastWriteTime |
            Sort-Object -Descending | Select-Object -First 1
        [ordered]@{
            name     = $d.Name
            sizeMB   = Get-FolderSizeMB $d.FullName
            lastUsed = $last.ToString('yyyy-MM-dd HH:mm')
            inUse    = [bool](@(Get-ChromeProfileProcess -UserDataPath $prof).Count)
        }
    }
}

function Remove-CWebLeftoverProfile {
    # Moves a leftover instance folder to _deleted\ (purged after 30 days) so a mistake can be undone.
    param([string]$Name, [string]$Root)
    $left = @(Get-CWebLeftoverProfiles -Root $Root) | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if (-not $left) { return @{ success = $false; error = "'$Name' isn't a leftover profile (it's in the instance list, or there's no such folder)." } }
    if ($left.inUse) { return @{ success = $false; error = "A Chrome window is still using the '$Name' profile. Close it first." } }
    New-Item -ItemType Directory -Path $script:CWebDeletedDir -Force | Out-Null
    Get-ChildItem $script:CWebDeletedDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $dest = Join-Path $script:CWebDeletedDir "$Name-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Move-Item -LiteralPath (Join-Path $script:CWebDataRoot $Name) -Destination $dest
    (Get-Item $dest).LastWriteTime = Get-Date   # the 30 days count from the delete
    return @{ success = $true; deleted = $Name; keptAt = $dest; message = "Moved to $dest (removed for good after 30 days)." }
}
