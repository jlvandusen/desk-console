# Desk Console App

Start Menu > **Desk Console** (or `Desk-Console.cmd` in the shared folder, without installing).
There is one copy per sign-in: starting it again brings the running one to the front. It opens
where you last left it (if that screen is still there).

## The window

- **Toolbar** -- *Refresh* (also F5), *Connect all* (opens every other PC in RustDesk; PCs whose
  RustDesk did not answer the last check are skipped, and named), *RustDesk password...* (save or
  remove the password, kept in this PC's Credential Manager as `DeskConsole:RustDesk`),
  **Phone / tablet...** (QR codes to install RustDesk on a phone, plus every PC's address -- see
  [Remote Control](Remote-Control#from-a-phone-or-tablet)), *Open share*.
- **Cards** -- one per PC, in desk order (`kvm.json` `row`, or `grid`; PCs not in the layout come
  last), refreshed every 15 s without freezing the window: online, keyboard + mouse link, RustDesk,
  the PC's own report and its warnings, *View + control*, *Wake*, *Actions* (restart, sleep, lock,
  sign out) and the `<` `>` desk-order buttons. Everything on a card is explained on
  [Fleet Status and Actions](Fleet-Status-and-Actions).
- **This PC (NAME)** -- one line each: the keyboard/mouse program, its role and service; the layout
  Deskflow actually loaded (*Layout (left to right): A | B | C*, with *kvm.json says ... -- the
  server applies it within 2 minutes* while the two differ); hotkeys; automatic sign-in; Windows
  Update restarts; RustDesk reach and whether its password is saved; [dev box](Dev-Box). Notes in
  amber: *Windows now names X: re-apply* (another account's sign-in changed whom Windows signs in),
  *sign-in notice: click OK after a restart (RustDesk works there)*, *Fast Startup is on*, *a restart
  is pending*, *incomplete* Windows Update policy. The buttons stay at the bottom:
  - **Open Deskflow** / **Restart Deskflow** -- the restart restarts Deskflow's window as you, which
    makes it reload its settings, with no admin prompt; only when the Deskflow service is not
    running is the service restarted (one UAC prompt). For Synergy: the service, with UAC.
  - **Automatic sign-in...** -- see [Automatic Sign-In](Automatic-Sign-In).
  - **Windows Update...** -- turn the no-restart policy on or off, or re-apply it when it shows
    *incomplete* ([Windows Update](Windows-Update)).
  - **Dev box...** -- folders to reopen at sign-in ([Dev Box](Dev-Box)).
  - **Repair / update this PC...** -- below.
- **Status bar** -- the last message (*Updated 10:42:05*, or what a button just did), *Shared
  folder: online / OFFLINE*, *RustDesk password: saved / not saved*, and **What's new** (below).
- **Shared folder offline** -- a yellow bar says *Shared folder not reachable -- showing the copy
  from ...* with *Retry* and *Open folder*; the cards come from the last good copies of
  `machines.csv` and `kvm.json` in the install folder. Desk Console checks the share's server
  (2 seconds, TCP 445) before every read, so an asleep NAS no longer freezes the window for 40 s.
- **First run** (no PCs yet) -- what to do, with *Run setup on this PC* and *Open shared folder*.

Desk Console never connects to Deskflow's port 24800: Deskflow logs every plain connection
there as *failed to accept secure socket*.

## Admin steps without a frozen window

*Automatic sign-in...* and *Windows Update...* show the current state, then run setup elevated (one
UAC prompt) while the window stays usable. When it finishes the result is shown: *done*, *done, with
N note(s)*, *FAILED* with the reason, or *did not finish* with the log to read
(`logs\<PC>-<phase>.log` in the shared folder). Declining
the UAC prompt just says *cancelled*. (Before 1.7.0 the window hung until you found the hidden
console and pressed Enter.)

## Repair / update this PC

Runs the highest-numbered `DeskConsoleSetup-<version>.exe` in the shared folder -- the wizard, which
on a PC that is already set up offers *Update and keep this PC's settings*. Without one there, it
runs the installed setup script in a console (`Setup-Synergy.ps1 -Phase All`). Either way the
admin step re-applies everything it manages: the bundled programs (upgraded when older), the
firewall scope, RustDesk's whitelist, the automatic sign-in lock and Fast Startup setting, the
Windows Update policy and the machines.csv row.

## Tray icon

Closing the window keeps Desk Console in the notification area, still watching every PC and
announcing changes ([notifications](Fleet-Status-and-Actions#notifications)). Click the icon to open
the window; right-click for *Open Desk Console*, *Refresh* and *Exit*. The installer's *Start Desk
Console in the notification area when I sign in* starts it there with `-Tray`.

## Self-update

`version.txt` beside the script is the app's only version number. On launch an installed copy
compares it with `version.txt` in the shared folder (once the share's server has answered). If the
share is newer, it runs the share's `Install-DeskConsole.ps1 -Quiet`, which copies the new files --
`version.txt` last, so a copy that stops halfway is retried at the next launch -- and `site.json`,
notes it in `update.log` in the install folder and reopens once (with `-Updated`, so the new copy
never updates again in the same launch). `Install-DeskConsole.ps1` does not replace a newer
installed version with an older one from the share.

Self-update needs the scripts in the shared folder, not only the installer: copy `src\*` (or the
release's `DeskConsole-<version>-scripts.zip`) there ([Building](Building#deploying-to-a-shared-folder)).

## What's new

After an update -- by itself or by the installer -- Desk Console shows what changed once: the first
time its window opens, or, when it started in the notification area, as a notification to click.
**What's new** at the right of the status bar shows it again any time, with a link to the release
notes. The text is `whats-new.txt` in the install folder (the [What's New](Whats-New) page has the
same list); the version it was last shown for is `WhatsNewSeen` in `HKCU\Software\DeskConsole`.

## Keyboard and accessibility

Tab moves through the toolbar, the cards and the panel in screen order; a refresh no longer takes
the focus away. F5 refreshes; Alt+R, Alt+C, Alt+P, Alt+H and Alt+O press the toolbar buttons.
Screen readers hear each card's buttons by PC (*View and control PC-A*). Long card lines end in
"..." and show in full on hover. An error in any button is a *Desk Console* message with the
reason, not .NET's crash dialog.

## Command line

```powershell
powershell -ExecutionPolicy Bypass -File Desk-Console.ps1 -Check                  # text status, no window
powershell -ExecutionPolicy Bypass -File Desk-Console.ps1 -Tray                   # start in the notification area
powershell -ExecutionPolicy Bypass -STA -File Desk-Console.ps1 -Snapshot x.png         # render the window off-screen
powershell -ExecutionPolicy Bypass -STA -File Desk-Console.ps1 -SnapshotMobile x.png   # the phone dialog
powershell -ExecutionPolicy Bypass -STA -File Desk-Console.ps1 -SnapshotWhatsNew x.png # the What's new dialog
```

`-Updated` is internal (the self-update relaunch). `-Check` and the snapshots show real addresses,
MAC addresses and account names: take them out before posting one anywhere.
