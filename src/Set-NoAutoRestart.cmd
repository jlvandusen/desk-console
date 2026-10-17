@echo off
rem Windows Update: no automatic restart while someone is signed in (Pro / Enterprise / Education).
rem   Set-NoAutoRestart.cmd            turn it on   (one UAC prompt)
rem   Set-NoAutoRestart.cmd -Disable   back to the Windows default
set DC_ARG=Enable
if /i "%~1"=="-Disable" set DC_ARG=Disable
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-Synergy.ps1" -Phase Updates -NoAutoRestart %DC_ARG%
