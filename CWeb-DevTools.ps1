# Reads and runs scripts in any tab over Chrome's own DevTools connection, without switching the driver to it.
# A Selenium switch brings the tab to the front, so the keep-alive used to flip the window the user and other agents
# were working in. Over DevTools a tab stays where it is, in the background. ChromeDriver starts Chrome with a
# debugging port on 127.0.0.1 and names it in the session's capabilities; window handles are DevTools target ids.

function Get-DevToolsAddress {
    if (-not $script:Browser) { throw 'The browser is not running.' }
    if ($script:Browser.DevTools) { return $script:Browser.DevTools }
    $opts = $script:Browser.Driver.Capabilities.GetCapability('goog:chromeOptions')
    $addr = if ($opts) { [string]$opts['debuggerAddress'] }
    if (-not $addr) { throw "Chrome's DevTools address is not known (no goog:chromeOptions.debuggerAddress)." }
    $script:Browser.DevTools = $addr -replace '^localhost:', '127.0.0.1:'   # Chrome listens on IPv4 only
    return $script:Browser.DevTools
}

function Get-DevToolsTabs {
    # Every open tab: id (= window handle), url, title. Touches no tab.
    $list = Invoke-RestMethod "http://$(Get-DevToolsAddress)/json/list" -TimeoutSec 5
    $tabs = @{}
    foreach ($t in @($list | Where-Object type -eq 'page')) { $tabs[[string]$t.id] = $t }
    return $tabs
}

function New-DevToolsTab {
    # Opens a tab in the background (the user's tab stays in front) and returns its id (= window handle).
    param([string]$Url)
    $ver = Invoke-RestMethod "http://$(Get-DevToolsAddress)/json/version" -TimeoutSec 5
    $r = Invoke-DevToolsCall -WsUrl $ver.webSocketDebuggerUrl -Method 'Target.createTarget' -Params @{ url = $Url; background = $true }
    return [string]$r.targetId
}

function Close-DevToolsTab {
    param([string]$TabId)
    try { Invoke-RestMethod "http://$(Get-DevToolsAddress)/json/close/$TabId" -TimeoutSec 5 | Out-Null } catch { }
}

function Invoke-DevToolsScript {
    # Runs an expression in the tab's top-level page and returns its value (promises are awaited). A script that throws
    # throws here, with the page's message.
    param([string]$TabId, [string]$Expression, [int]$TimeoutSeconds = 20)
    $tab = (Get-DevToolsTabs)[$TabId]
    if (-not $tab -or -not $tab.webSocketDebuggerUrl) { throw 'That tab is not open.' }
    $res = Invoke-DevToolsCall -WsUrl $tab.webSocketDebuggerUrl -Method 'Runtime.evaluate' -TimeoutSeconds $TimeoutSeconds `
        -Params @{ expression = $Expression; returnByValue = $true; awaitPromise = $true }
    if ($res.exceptionDetails) {
        $e = $res.exceptionDetails
        $why = if ($e.exception.description) { ($e.exception.description -split "`n")[0] } else { $e.text }
        throw $why
    }
    return $res.result.value
}

function Invoke-DevToolsCall {
    # One DevTools command over a tab's (or the browser's) WebSocket; returns its result.
    param([string]$WsUrl, [string]$Method, [hashtable]$Params = @{}, [int]$TimeoutSeconds = 20)
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
    try {
        [void]$ws.ConnectAsync([Uri]$WsUrl, $cts.Token).GetAwaiter().GetResult()
        $msg = @{ id = 1; method = $Method; params = $Params } | ConvertTo-Json -Depth 6 -Compress
        $out = [Text.Encoding]::UTF8.GetBytes($msg)
        [void]$ws.SendAsync([ArraySegment[byte]]::new($out), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult()
        $buf = [byte[]]::new(65536)
        while ($true) {
            # One message can arrive in several frames; events from the page (if any) are skipped.
            $ms = [IO.MemoryStream]::new()
            do {
                $r = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), $cts.Token).GetAwaiter().GetResult()
                if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { throw 'Chrome closed the DevTools connection.' }
                $ms.Write($buf, 0, $r.Count)
            } until ($r.EndOfMessage)
            $reply = [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
            if ($reply.id -eq 1) { break }
        }
        if ($reply.error) { throw "DevTools: $($reply.error.message)" }
        return $reply.result
    } catch [OperationCanceledException] {
        throw "DevTools $Method did not finish within ${TimeoutSeconds}s."
    } finally {
        if ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            try { $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, '', [Threading.CancellationToken]::None).Wait(2000) | Out-Null } catch { }
        }
        $ws.Dispose(); $cts.Dispose()
    }
}
