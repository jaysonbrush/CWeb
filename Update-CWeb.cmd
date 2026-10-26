@echo off
rem Updates CWeb on this machine (double-click, or run from a prompt): asks before stopping running instances, pulls
rem the new version, runs setup, and starts again what was running. Arguments pass through, e.g.
rem   Update-CWeb.cmd -Yes      (don't ask)
where pwsh >nul 2>nul
if errorlevel 1 (
    echo CWeb needs PowerShell 7 ^(pwsh^). Install it with:
    echo   winget install --id Microsoft.PowerShell --source winget
    echo then run this again.
    pause
    exit /b 1
)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-CWeb.ps1" %*
echo.
pause
