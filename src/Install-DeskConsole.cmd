@echo off
rem Installs Desk Console for this Windows user (no admin). Options: -AutoStart  -NoDesktop  -Uninstall
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-DeskConsole.ps1" %*
pause
