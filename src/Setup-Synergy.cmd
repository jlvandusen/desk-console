@echo off
rem Double-click on each PC, or run from the shared folder in Explorer: \\<server>\<share>\DeskConsole\Setup-Synergy.cmd
rem Works before Z: is mapped -- Windows asks for the NAS login when you open the UNC path.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-Synergy.ps1" %*
pause
