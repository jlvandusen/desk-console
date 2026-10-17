@echo off
rem Desk Console: one window for every PC in machines.csv -- status, RustDesk view + control and
rem keyboard + mouse sharing (Deskflow or Synergy). Add -Tray to start in the notification area.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Desk-Console.ps1" %*
