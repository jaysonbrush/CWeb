# CWeb-Common.ps1 -- shared by CWeb-Server.ps1, Start-CWeb.ps1, CWeb-Client.ps1 and Setup-CWeb.ps1.
# Finds the data folder, looks up instances, starts servers.
# Must also run in Windows PowerShell 5.1 (no -AsHashtable, no ?? or ternaries).
#
# Data folder: everything CWeb stores on this machine (profiles, keys, logs, machine-added instances) lives in one
# folder outside the repo: %USERPROFILE%\CWebData, or the folder in the user environment variable CWEB_DATA (set by
# Setup-CWeb.ps1 -DataRoot). The registry value is read each time, so a change applies at once, even to processes
# started before it.
# Not under AppData: packaged (MSIX) apps such as the Claude desktop app redirect AppData writes into a private copy,
# so an agent started from the app and a server started from Explorer would each see a different data folder.
# Installs from before 2026.10.26.015 used %LOCALAPPDATA%\CWeb; that folder is still used while the new one doesn't
# exist, and Setup-CWeb.ps1 moves it.
#
# Instances: instances.json in the repo holds the defaults (in git); <data folder>\instances.json holds the ones this
# machine added (+ New on the status page); the "instances" section of <data folder>\config.json holds the user's own
# changes (a custom port, say). All three are merged field by field, later ones winning.
#
# Settings: <data folder>\config.json, edited by hand (Setup-CWeb.ps1 writes the defaults):
#   portFallback  true (default): if an instance's port is taken by another program, use the next free one
#   firstPort     where + New (and nothing else) starts looking for a free port; default 9380
#   instances     per-instance overrides, e.g. { "work": { "port": 9480 } }
# The port a server really listens on is in its server.json; clients read it from there.

function Get-CWebDefaultDataRoot { return Join-Path $env:USERPROFILE 'CWebData' }
function Get-CWebLegacyDataRoot  { return Join-Path $env:LOCALAPPDATA 'CWeb' }   # before 2026.10.26.015

function Get-CWebDataRoot {
    $v = [Environment]::GetEnvironmentVariable('CWEB_DATA', 'User')
    if (-not $v) { $v = $env:CWEB_DATA }
    if (-not $v) {
        $v = Get-CWebDefaultDataRoot
        $legacy = Get-CWebLegacyDataRoot
        if (-not (Test-Path $v) -and (Test-Path $legacy)) { $v = $legacy }
    }
    return $v.TrimEnd('\')
}

function Get-CWebConfig {
    # This machine's settings (<data folder>\config.json) with the defaults filled in.
    $path = Join-Path (Get-CWebDataRoot) 'config.json'
    $cfg = $null
    if (Test-Path $path) {
        try { $cfg = Get-Content $path -Raw | ConvertFrom-Json } catch { throw "config.json isn't valid JSON ($path): $($_.Exception.Message)" }
    }
    $first = 9380
    if ($cfg -and $null -ne $cfg.firstPort) { $first = [int]$cfg.firstPort }
    if ($first -lt 1024 -or $first -gt 65535) { throw "config.json: firstPort $first is not valid (1024-65535)." }
    $fallback = $true
    if ($cfg -and $null -ne $cfg.portFallback) { $fallback = [bool]$cfg.portFallback }
    $instances = [pscustomobject]@{}
    if ($cfg -and $cfg.instances) { $instances = $cfg.instances }
    return [pscustomobject]@{ Path = $path; FirstPort = $first; PortFallback = $fallback; Instances = $instances }
}

function Get-CWebInstanceTable {
    # name -> settings: defaults, then this machine's instances, then config.json's overrides, merged field by field.
    # Validates ports.
    param([string]$Root = $PSScriptRoot)
    $table = [ordered]@{}
    $sources = @((Join-Path $Root 'instances.json'), (Join-Path (Get-CWebDataRoot) 'instances.json'))
    if (-not (Test-Path $sources[0])) { throw "instances.json not found in $Root." }
    $lists = @(foreach ($src in $sources) { if (Test-Path $src) { Get-Content $src -Raw | ConvertFrom-Json } })
    $lists += (Get-CWebConfig).Instances
    foreach ($list in $lists) {
        foreach ($p in $list.PSObject.Properties) {
            if (-not $table.Contains($p.Name)) { $table[$p.Name] = [pscustomobject]@{} }
            foreach ($f in $p.Value.PSObject.Properties) { $table[$p.Name] | Add-Member -NotePropertyName $f.Name -NotePropertyValue $f.Value -Force }
        }
    }
    # Ports must be unique.
    $ports = @{}
    foreach ($name in $table.Keys) {
        if ($null -eq $table[$name].port) { throw "Instance '$name' has no port." }
        $port = [int]$table[$name].port
        if ($port -lt 1024 -or $port -gt 65535) { throw "Instance '$name': port $port is not valid." }
        if ($ports.ContainsKey($port)) { throw "Instances '$($ports[$port])' and '$name' both use port $port." }
        $ports[$port] = $name
    }
    return $table
}

function Test-CWebPortFree {
    # True if nothing on this machine listens on the port.
    param([int]$Port)
    $listening = @([System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | ForEach-Object { $_.Port })
    return $Port -notin $listening
}

function Get-CWebInstance {
    param([string]$Name = 'work', [string]$Root = $PSScriptRoot)
    $Name = $Name.ToLowerInvariant()
    if ($Name -notmatch '^[a-z0-9-]{1,30}$') { throw "Instance name '$Name': use lowercase letters, digits and hyphens." }
    if ($Name -eq 'scripts') { throw "'scripts' is reserved (standalone scripts keep their profiles in <data folder>\scripts)." }

    $table = Get-CWebInstanceTable -Root $Root
    $names = @($table.Keys)
    if ($Name -notin $names) { throw "No instance '$Name'. Instances: $($names -join ', ')." }

    $cfg = $table[$Name]
    $label = $Name
    if ($cfg.label) { $label = [string]$cfg.label }
    $dataRoot = Get-CWebDataRoot
    $dataDir = Join-Path $dataRoot $Name   # outside the repo: profile, logs, keys
    # Lock per data folder and instance (two data folders may each have a 'test').
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($dataDir.ToLowerInvariant()))[0..3] | ForEach-Object { $_.ToString('x2') })
    $sha.Dispose()
    $ka = $cfg.keepAlive
    $serverFile = Join-Path $dataDir 'server.json'
    # Port: where the running server really listens (it may have moved off a taken port), else the configured one.
    $port = [int]$cfg.port
    $live = Get-CWebServerInfo -ServerFile $serverFile
    if ($live -and $live.port) { $port = [int]$live.port }
    return [pscustomobject]@{
        Name             = $Name
        Label            = $label
        Port             = $port
        ConfiguredPort   = [int]$cfg.port
        StartUrl         = [string]$cfg.startUrl
        Hidden           = [bool]$cfg.hidden
        ShowServerWindow = [bool]$cfg.showServerWindow
        KeepAliveEnabled = $(if ($null -ne $ka.enabled) { [bool]$ka.enabled } else { $true })
        KeepAliveTick    = $(if ($ka.tickSeconds) { [int]$ka.tickSeconds } else { 30 })
        KeepAliveMax     = $(if ($ka.maxCheckSeconds) { [int]$ka.maxCheckSeconds } else { 600 })
        DataDir          = $dataDir
        ProfileDir       = Join-Path $dataDir 'profile'
        LogDir           = Join-Path $dataDir 'logs'
        ServerFile       = $serverFile
        ClientsDir       = Join-Path $dataDir 'clients'      # keys (and waiting tickets) saved by Connect-CWeb
        DataRoot         = $dataRoot
        LockName         = "Local\CWeb-$Name-$hash"
        AllNames         = $names
    }
}

function Get-CWebServerInfo {
    # The server.json of a live CWeb server process (port, pid, ...), or $null. Reads files only (no HTTP), so it's
    # cheap enough for the status page's 2-second refresh. Checks the process name so a reused PID doesn't count.
    param([string]$ServerFile)
    if (-not (Test-Path $ServerFile)) { return $null }
    try { $info = Get-Content $ServerFile -Raw | ConvertFrom-Json } catch { return $null }
    $p = Get-Process -Id ([int]$info.pid) -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -eq 'pwsh') { return $info }
    return $null
}

function Test-CWebServerProcess {
    # True if the instance's server.json names a live CWeb server process.
    param($Instance)
    return [bool](Get-CWebServerInfo -ServerFile $Instance.ServerFile)
}

function Get-CWebInstanceList {
    # Every instance (defaults + this machine's) with its port and whether its server is running, for the switcher.
    param([string]$Root = $PSScriptRoot)
    foreach ($name in @((Get-CWebInstanceTable -Root $Root).Keys)) {
        $i = Get-CWebInstance -Name $name -Root $Root
        [pscustomobject]@{ name = $i.Name; label = $i.Label; port = $i.Port; running = (Test-CWebServerProcess -Instance $i) }
    }
}

function Get-CWebRunningServer {
    # The instance's server if it is running: server.json names a live process and the status page answers.
    # Returns the parsed status data, or $null.
    # Reads the port from server.json each time: the server may have started after $Instance was looked up.
    param($Instance)
    $info = Get-CWebServerInfo -ServerFile $Instance.ServerFile
    if (-not $info) { return $null }
    try { return Invoke-RestMethod -Uri "http://127.0.0.1:$([int]$info.port)/status.json" -TimeoutSec 5 } catch { return $null }
}

function Start-CWebServerProcess {
    # Launches the instance's server and returns at once (no waiting). A second server for a running instance
    # exits by itself (the instance lock), so a double start is harmless.
    param($Instance, [string]$Root = $PSScriptRoot)
    if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
        throw 'PowerShell 7 (pwsh) is not installed -- the server needs it. Install: winget install --id Microsoft.PowerShell --source winget'
    }
    $server = Join-Path $Root 'CWeb-Server.ps1'
    # Hidden by default: its output is in the server log and its controls are on the status page.
    # "showServerWindow": true on the instance in instances.json brings the window back.
    if ($Instance.ShowServerWindow) {
        Start-Process pwsh -WorkingDirectory $Root -ArgumentList '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', $server, '-Instance', $Instance.Name
    } else {
        Start-Process pwsh -WorkingDirectory $Root -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $server, '-Instance', $Instance.Name
    }
}

function New-CWebInstance {
    # Adds an instance to this machine's list (<data folder>\instances.json, not the repo's) with the next free port
    # from firstPort (config.json, default 9380) up, and returns it. A lock keeps two servers from editing the file at the same moment.
    param([string]$Name, [string]$Label, [string]$Root = $PSScriptRoot)
    $Name = ([string]$Name).Trim().ToLowerInvariant()
    $Label = ([string]$Label).Trim()
    if ($Name -notmatch '^[a-z0-9][a-z0-9-]{0,29}$') { throw 'Name: 1-30 lowercase letters, digits and hyphens, e.g. social.' }
    if ($Name -eq 'scripts') { throw "'scripts' is reserved; pick another name." }
    if (-not $Label) { $Label = (Get-Culture).TextInfo.ToTitleCase($Name) }
    if ($Label.Length -gt 30 -or $Label -match '[\x00-\x1f]') { throw 'Label: up to 30 characters.' }

    $lock = [System.Threading.Mutex]::new($false, 'Local\CWeb-instances-json')
    try { $got = $lock.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $got = $true }
    if (-not $got) { $lock.Dispose(); throw 'instances.json is busy; try again.' }
    try {
        $all = Get-CWebInstanceTable -Root $Root
        if ($all.Contains($Name)) { throw "There's already an instance named '$Name'." }
        $used = @($all.Values | ForEach-Object { [int]$_.port })
        $dataRoot = Get-CWebDataRoot
        New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
        $path = Join-Path $dataRoot 'instances.json'
        $list = if (Test-Path $path) { Get-Content $path -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
        $port = (Get-CWebConfig).FirstPort
        while ($port -le 65535 -and ($port -in $used -or -not (Test-CWebPortFree $port))) { $port++ }
        if ($port -gt 65535) { throw 'No free port.' }

        # Write it back one instance per line, the way the file is laid out by hand.
        $list | Add-Member -NotePropertyName $Name -NotePropertyValue ([pscustomobject][ordered]@{ port = $port; label = $Label })
        $props = @($list.PSObject.Properties)
        $width = ($props | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum + 3
        $lines = for ($i = 0; $i -lt $props.Count; $i++) {
            $key = ('"' + $props[$i].Name + '":').PadRight($width)
            $fields = @($props[$i].Value.PSObject.Properties | ForEach-Object { (ConvertTo-Json $_.Name -Compress) + ': ' + (ConvertTo-Json $_.Value -Compress -Depth 5) })
            "  $key { $($fields -join ', ') }$(if ($i -lt $props.Count - 1) { ',' })"
        }
        $tmp = "$path.tmp"
        Set-Content -LiteralPath $tmp -Value (@('{') + $lines + @('}')) -Encoding utf8
        $null = Get-Content $tmp -Raw | ConvertFrom-Json   # never swap in a file that doesn't parse
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } finally {
        try { $lock.ReleaseMutex() } catch { }
        $lock.Dispose()
    }
    return Get-CWebInstance -Name $Name -Root $Root
}

function Start-CWebServer {
    # Starts the instance's server unless it's already running, and waits until it answers (it opens Chrome before
    # serving requests). Returns the status data. Throws if it doesn't answer in time.
    # The server gets its own (hidden) console via Start-Process, so it outlives the session that started it.
    param($Instance, [string]$Root = $PSScriptRoot, [int]$WaitSeconds = 120)
    $st = Get-CWebRunningServer -Instance $Instance
    if ($st) { return $st }
    Start-CWebServerProcess -Instance $Instance -Root $Root
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 1
        $st = Get-CWebRunningServer -Instance $Instance
        if ($st) { return $st }
    }
    throw "CWeb '$($Instance.Name)' did not answer within $WaitSeconds seconds. Logs: $($Instance.LogDir)"
}
