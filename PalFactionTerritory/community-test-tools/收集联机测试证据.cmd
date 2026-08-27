@echo off
chcp 65001 >nul
set "SCRIPT_DIR=%~dp0"
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Collect-Multiplayer-Test-Evidence.ps1"
echo.
pause
