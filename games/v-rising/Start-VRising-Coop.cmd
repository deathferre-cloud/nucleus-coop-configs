@echo off
setlocal
powershell.exe -NoProfile -File "%~dp0..\..\tools\Start-Coop.ps1" -Config "%~dp0..\..\setup.local.json"
if errorlevel 1 (
  echo Check setup.local.json and connect both controllers, then try again.
  pause
  exit /b 1
)
exit /b 0
