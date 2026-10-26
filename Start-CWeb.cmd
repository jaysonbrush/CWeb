@echo off
rem Starts a CWeb instance and its Chrome window. No argument = the 'work' instance.
rem   Start-CWeb.cmd            (work)
rem   Start-CWeb.cmd personal
rem Finds Start-CWeb.ps1 next to this file, so the folder works from anywhere.
rem For a desktop icon: right-click this file > Send to > Desktop (create shortcut), then add the
rem instance name to the end of the shortcut's Target if it isn't 'work'.
where pwsh >nul 2>nul
if errorlevel 1 (
    echo PowerShell 7 ^(pwsh^) is required. Install it with:
    echo   winget install --id Microsoft.PowerShell --source winget
    pause
    exit /b 1
)
set "CWEB_INSTANCE=%~1"
if "%CWEB_INSTANCE%"=="" set "CWEB_INSTANCE=work"
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-CWeb.ps1" -Instance "%CWEB_INSTANCE%"
rem Close this window even when it was opened with "start" (cmd /K). On failure the
rem launcher has already waited for Enter, so its message has been read.
exit
