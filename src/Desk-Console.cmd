@echo off
rem Desk Console: status + RustDesk view/control + Synergy for every machine in machines.csv
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Desk-Console.ps1" %*
