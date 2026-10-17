# Windows Update

PCs you reach only remotely should not restart by themselves in the middle of a build or a
session. Desk Console can set the Group Policy that makes Windows Update wait for you:

> Computer Configuration > Administrative Templates > Windows Components > Windows Update >
> **No auto-restart with logged on users for scheduled automatic updates installations** = Enabled

Updates still download and install; only the restart waits, and you restart when it suits you.
Together with [automatic sign-in](Automatic-Sign-In) someone is always signed in, so the PC never
restarts from under you.

## Turning it on

- **Installer** > *Options* page: *Windows Update: don't restart this PC by itself while someone is
  signed in* (ticked by default).
- **`Set-NoAutoRestart.cmd`** in the shared folder or install folder: one UAC prompt, no full
  setup. `Set-NoAutoRestart.cmd -Disable` returns to the Windows default.
- `Setup-Synergy.ps1 -NoAutoRestart Enable|Disable` (Admin step).

Desk Console's panel shows the state for the PC you are on: *Windows Update restarts: no automatic
restart while someone is signed in*.

## Details

- It writes `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU\NoAutoRebootWithLoggedOnUsers
  = 1` -- the value that `gpedit.msc` sets. Because it is written directly, `gpedit.msc` still shows
  the policy as *Not configured* although it is in force.
- **Pro, Enterprise and Education** honour it; **Home ignores it** (setup warns).
- On a **domain-joined** PC a domain Group Policy can override it (setup warns).
- Keep restarting regularly yourself: updates that are installed but waiting for a restart are not
  protecting the PC yet.
