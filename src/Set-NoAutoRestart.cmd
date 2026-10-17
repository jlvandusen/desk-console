@echo off
rem Windows Update: install updates by itself (every day, 03:00) but never restart this PC while someone
rem is signed in (Pro / Enterprise / Education). Microsoft applies "no restart" only together with that
rem install schedule (AUOptions 4); the values set before are kept and put back by -Disable.
rem   Set-NoAutoRestart.cmd            turn it on   (one UAC prompt)
rem   Set-NoAutoRestart.cmd -Disable   back to how it was (Windows default)
setlocal
set DC_ARG=Enable
if /i "%~1"=="-Disable" set DC_ARG=Disable
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-Synergy.ps1" -Phase Updates -NoAutoRestart %DC_ARG%
