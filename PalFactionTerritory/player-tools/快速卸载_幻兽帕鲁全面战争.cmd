@echo off
setlocal
chcp 65001 >nul
call "%~dp0Quick-Uninstall-PalFactionTerritory.cmd"
exit /b %ERRORLEVEL%
