@echo off
setlocal
set "PS=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not exist "%PS%" set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Repair-Rewasd.ps1"
