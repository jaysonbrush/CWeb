. "$PSScriptRoot\Browser-Functions.ps1"
Write-Host "Chrome Functions loaded"

Write-Host "Starting browser..."
$browser = Chrome-Start
if ($browser) {
    Write-Host "Browser started successfully"

    Write-Host "Navigating to example.com..."
    Chrome-Navigate -Browser $browser -Url "https://example.com"

    $title = Chrome-GetTitle -Browser $browser
    Write-Host "Page title: $title"

    $url = Chrome-GetCurrentUrl -Browser $browser
    Write-Host "Current URL: $url"

    Write-Host "Stopping browser..."
    Chrome-Stop -Browser $browser
    Write-Host "Test completed successfully!"
} else {
    Write-Host "Failed to start browser" -ForegroundColor Red
}
