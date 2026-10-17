@echo off
rem Remove Synergy from this PC once no PC uses it (kvm.json provider Deskflow or None): uninstalls it and
rem deletes its firewall rules and parked sign-in entries. The keyboard/mouse port rule stays (Deskflow
rem uses the same port). Refuses while kvm.json says Synergy, or when kvm.json cannot be read. One UAC prompt.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-Synergy.ps1" -Phase RemoveSynergy
