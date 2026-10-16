# Desk Console App

Start Menu > **Desk Console** (or `Desk-Console.cmd` in the shared folder, without installing).

## The window

- **One card per PC** from `machines.csv`, refreshed every 15 s without freezing the window
  (all checks run at once; results read after 2 s):
  - **Online** -- ping, or RustDesk's port, or file sharing answers (Windows drops ping by default).
  - **Keyboard + mouse** -- the PC's role from `kvm.json`; for the PC you are on, live state:
    *Deskflow server: N connected* / *Deskflow client: connected*.
  - **RustDesk** -- direct IP port 21118 reachable.
  - **View + control** -- opens the PC in RustDesk by IP (tabs in one RustDesk window), with the
    saved password.
  - **Wake** -- Wake-on-LAN magic packet to the PC's MAC (enable WoL in its BIOS/network card).
- **Toolbar** -- Refresh, *Connect all*, *RustDesk password...* (saved in this PC's Credential
  Manager as `DeskConsole:RustDesk`), *Open share*.
- **This PC panel** -- keyboard/mouse program, role, service state, hotkeys, automatic sign-in
  state, the screen layout, and buttons: open the program, restart it, *Automatic sign-in...*,
  re-run setup.

Desk Console never connects to Deskflow's port 24800: Deskflow logs every plain connection
there as *failed to accept secure socket*.

## Self-update

On launch an installed copy compares its version with `version.txt` in the shared folder. If
the share is newer, it runs the share's `Install-DeskConsole.ps1 -Quiet` (copies the new files and
`site.json`) and reopens. Raise `version.txt` **and** `$AppVersion` in `Desk-Console.ps1` together.

If the shared folder is offline, the app uses its cached `machines.csv` and says
*SHARE OFFLINE, cached list*.

## Command line

```powershell
powershell -ExecutionPolicy Bypass -File Desk-Console.ps1 -Check            # text status, no window
powershell -ExecutionPolicy Bypass -STA -File Desk-Console.ps1 -Snapshot x.png   # render off-screen
```
