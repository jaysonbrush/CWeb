# Test-CWeb.ps1 -- quick check that CWeb's files are in place and instances.json is valid. Changes nothing.

$root = $PSScriptRoot
$chromeFunctionsPath = Join-Path $root 'browser\Browser-Functions.ps1'

Write-Host 'CWeb Test' -ForegroundColor Cyan
Write-Host '========='
Write-Host "Folder: $root"

if (-not (Test-Path $chromeFunctionsPath)) {
    Write-Host "ERROR: Chrome module not found at $chromeFunctionsPath" -ForegroundColor Red
    exit 1
}
. $chromeFunctionsPath
$count = (Get-Command -Name 'Chrome-*' | Measure-Object).Count
Write-Host "Chrome module found, $count Chrome functions loaded" -ForegroundColor Green

. (Join-Path $root 'CWeb-Common.ps1')
try {
    foreach ($name in @((Get-CWebInstanceTable -Root $root).Keys)) {   # also validates every instance's port
        $i = Get-CWebInstance -Name $name -Root $root
        $state = if (Get-CWebRunningServer -Instance $i) { 'running' } else { 'stopped' }
        Write-Host ("  {0,-10} port {1}  {2,-8} {3}" -f $i.Name, $i.Port, $state, $i.DataDir)
    }
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
Write-Host ''
Write-Host 'Start an instance with: Start-CWeb.cmd <instance>' -ForegroundColor Cyan
