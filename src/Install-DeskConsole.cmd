@echo off
rem Installs Desk Console for this Windows user (no admin). Options:
rem   -AutoStart (start in the notification area at sign-in)  -NoAutoStart (stop that)  -NoDesktop  -Force (allow an older version)  -Uninstall
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-DeskConsole.ps1" %*
pause
