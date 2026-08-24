@echo off
setlocal
chcp 65001 >nul
set "PWFT_SCRIPT=%~dp0Quick-Uninstall-PalFactionTerritory.ps1"
if not exist "%PWFT_SCRIPT%" (
  echo Missing Quick-Uninstall-PalFactionTerritory.ps1
  echo Keep the CMD and PS1 files in the same folder.
  pause
  exit /b 1
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PWFT_SCRIPT%"
set "PWFT_EXIT=%ERRORLEVEL%"
echo.
if not "%PWFT_EXIT%"=="0" echo Uninstall did not complete. Exit code: %PWFT_EXIT%
pause
exit /b %PWFT_EXIT%
