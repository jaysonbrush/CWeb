@echo off
rem Sets CWeb up on this machine (double-click, or run from a prompt). Arguments pass through, e.g.
rem   Setup-CWeb.cmd -Uninstall
where pwsh >nul 2>nul
if errorlevel 1 (
    echo CWeb needs PowerShell 7 ^(pwsh^). Install it with:
    echo   winget install --id Microsoft.PowerShell --source winget
    echo then run this again.
    pause
    exit /b 1
)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-CWeb.ps1" %*
echo.
pause
