# What's New

## Desk Console 1.8.9 (since 1.7.1)

- **1.8.9: RustDesk sessions pause keyboard and mouse sharing** on the server, so the cursor and
  the focus stay in the RustDesk window and games get their key combinations back
  ([Keyboard and Mouse](Keyboard-and-Mouse#rustdesk-sessions-pause-keyboard-and-mouse-sharing)).

- **1.8.8:** the installer bundles the Microsoft Visual C++ runtime 14.51.36247.0 (was 14.44); PCs
  that already have 14.44 or newer are not touched.

- **1.8.7: each PC opens on its own display every time** -- also after another session was
  closed, and on a scaled (150% ...) display. Displays are matched left to right as Windows
  arranges them (*Settings > System > Display*), around the primary one.

- **1.8.6: Connect all opens every PC** -- one after another (it opened only the first).
- **1.8.6: Desk Console's own icon on the taskbar**, and "Desk Console" on its notifications,
  instead of PowerShell's.

- **1.8.5: RustDesk's connection window is hidden on every PC by default.** Untick a card's
  *Actions* > *Hide RustDesk's connection window there* to keep it on that PC
  ([kvm.json `showRustDeskWindow`](Configuration#kvmjson)).

- **1.8.4: every PC updates itself unattended**, within about 2 minutes of a new version reaching
  the shared folder, whether or not Desk Console is open there
  ([Self-update](Desk-Console-App#self-update)).
- **1.8.4: Deskflow in the notification area on every PC.** PCs whose Deskflow read the
  machine-wide settings were skipped by 1.8.1; they now switch over too.
- **1.8.4, optional: hide RustDesk's connection window on a PC.** A card's *Actions* > *Hide
  RustDesk's connection window there* hides the "someone is connected" window on that PC
  ([kvm.json `showRustDeskWindow`](Configuration#kvmjson) since 1.8.5).

- **1.8.2 + 1.8.3: every PC on its own display, or tabs.** A second PC used to open as a tab of
  the first one's window. Each PC now gets its own window on its display; untick *Each PC in its
  own window* in the toolbar (or the tray icon menu) for RustDesk's tabs instead. With sessions open when you
  update, close them once first.

- **1.8.1: Deskflow stays in the notification area.** It starts hidden at sign-in, closing its
  window keeps it running, and its tray icon opens it. Nothing to do: each PC's 2-minute task
  switches it over once after the update; a later change in Deskflow's own settings stays.
- **1.8.0: Each PC opens on its own display.** *View + control* (and *Open all*) put a PC's
  RustDesk window on the display that matches its place in your desk layout.
- **1.8.0, optional: hide RustDesk sessions from the taskbar.** Tray icon menu > *Hide RustDesk sessions
  from the taskbar* (off by default); open sessions are listed in the tray menu.

## Desk Console 1.7.1 (since 1.6.0)

### 1.7.1 fixes three things in 1.7.0

- The 2-minute task on each PC wrongly decided, on most runs, that the shared folder was
  unreachable, and quietly skipped its work: the status report, address healing, queued Restart /
  Sleep / Lock / Sign out, and the Deskflow sync. It now runs every time.
- A PC's status report could not be overwritten once written, so its card went grey (*Status N min
  old*) after the first one. Reports now refresh every 2 to 4 minutes, as intended.
- Turning automatic sign-in off now deletes the saved sign-in password instead of leaving an empty
  one in its place.

Desk Console shows this list once after it updates (the first time its window opens; started in
the notification area, a notification to click first), and any time from **What's new** in its
status bar. The full, technical list is in the [changelog](https://github.com/jlvandusen/desk-console/blob/main/CHANGELOG.md)
and the [release notes](https://github.com/jlvandusen/desk-console/releases).

### Do this once on every PC

- Run `DeskConsoleSetup-1.7.1.exe` and choose **Update and keep this PC's settings** (or Desk
  Console > *Repair / update this PC...*). It asks for admin once. Desk Console updates its own
  files, but only setup starts the status reports, limits RustDesk and the firewall to your home
  network, completes the Windows Update policy and turns on Wake-on-LAN.
- Running it over RustDesk is fine -- connect by address, as *View + control* does. Setup never
  makes a change that would cut off the session it runs under: what it has to hold back, it says,
  or does at the next restart.
- The Deskflow server restarts its window once to pick up the new hotkeys; the keyboard and mouse
  are back within seconds.

### Every PC reports its own state

- Each PC writes a short report to the shared folder (`status\<PC>.json`) every 2 to 4 minutes:
  version, keyboard/mouse link, automatic sign-in, sign-in notice, Fast Startup, pending restart,
  Windows Update policy, RustDesk reach, address and the last action. Its card shows it -- in grey
  once it is more than 6 minutes old, so a PC that went quiet is never shown as fine.
  ([Fleet Status and Actions](Fleet-Status-and-Actions))
- **Honest keyboard + mouse lines**: the server's own connections decide *connected* or *not
  connected*, and the server's card says *2 of 2 clients*. A line nobody can vouch for is grey, no
  longer green.
- **Addresses heal themselves**: a PC with a new address or network card fixes its own
  `machines.csv` row, and the Deskflow clients follow the server to its new address (about 4
  minutes, no setup run).

### Act on any PC from its card

- **Actions**: *Restart* (with a 60-second warning on that screen), *Sleep*, *Lock*, *Sign out*.
  The PC picks the request up within 2 minutes; one not run within 10 minutes expires, so a
  sleeping PC never restarts hours later. The card shows the result.
- **Wake** now goes out on the adapter on the target's network, and the card watches for 2
  minutes: *awake after 34 s* or *did not answer*.
- The `<` `>` buttons on a card move that PC left or right in the desk layout.

### Always watching

- Closing the window keeps Desk Console in the **notification area**. It tells you when a PC goes
  offline or comes back, when a client's keyboard and mouse disconnect, and when the shared folder
  stops answering. Right-click the icon > *Exit* to quit.
- The sign-in shortcut starts it in the notification area; one copy per sign-in; the window opens
  where you left it. ([Desk Console App](Desk-Console-App))

### Keyboard and mouse

- **Ctrl+Alt+Shift+1** ... **9** jumps straight to a PC, in desk order. Ctrl+Alt+Left / Right still
  step through them. ([Keyboard and Mouse](Keyboard-and-Mouse))
- `kvm.json` can describe a **grid** (screens above and below each other) and **options**:
  clipboard sharing and its size limit, switch delay, double tap, heartbeat.
- *Restart Deskflow* no longer asks for admin.

### Safer by default

- **RustDesk answers your home network only.** Until now every PC accepted its password by RustDesk
  ID from anywhere on the internet. To allow that again, set `"rustdeskReach": "anywhere"` in
  `site.json` (a VPN home is the safer way in). ([Remote Control](Remote-Control))
- **At home, connect by address, not by ID**: a connection by ID that goes through RustDesk's relay
  is refused even from the next room. Desk Console and the *Phone / tablet* page use addresses.
- **The firewall really is home-network-only**: the allow-anyone rules that RustDesk's, Deskflow's
  and Synergy's own installers add are now limited too, on every setup run.
- **Automatic sign-in**: the screen now also locks after a sign-out (Windows signs straight back
  in), and Fast Startup is turned off while the lock is on (shut down + power on used to skip the
  lock); turning the lock off puts it back. Setup warns when the account is an administrator, a
  domain or a Microsoft account, and no longer resets a dedicated account whose password already
  works. ([Automatic Sign-In](Automatic-Sign-In))
- **Windows Update**: *no restart while someone is signed in* now also sets the automatic-updates
  option Microsoft requires for it (install daily at 03:00). A card says *update policy incomplete*
  until setup re-applies it. ([Windows Update](Windows-Update))

### Setup and the installer

- *Update and keep this PC's settings* on a PC that is already set up; a Ready page that lists what
  will change; a last page that lists every warning and failure, with the log to open.
- Newer RustDesk and Deskflow versions in the installer now replace older ones (RustDesk not while
  you are connected through it).
- **Wake-on-LAN** is turned on for each PC's wired network adapter (Wake on LAN in the BIOS / UEFI
  is still yours to check).
- `Remove-Synergy.cmd` uninstalls Synergy 3 once no PC uses it -- for after you cancel the
  subscription.

### Smaller things

- Desk Console: *Windows Update...* and *RustDesk password...* dialogs (with *Remove*), a status
  bar, a yellow bar with *Retry* while the shared folder is unreachable, F5 to refresh, Alt-key
  shortcuts, names for screen readers, and this *What's new*.
- [Dev box](Dev-Box): several folders, each with VS Code and/or `claude --continue` in its own
  terminal tab; a folder listed twice opens once.

### Fixed

- Switching between Deskflow and Synergy could lose the other program's sign-in entries (a registry
  key was recreated in a way that deleted it), along with Desk Console's own records.
- `Setup-Synergy.cmd -NoAutoRestart`, `-AutoLogon` and the dev box options did nothing: the admin
  step dropped them.
- The installer said "installed" when a step had failed, and a hidden step could wait for Enter
  forever. One failing part of the admin step (Windows Update busy, a firewall error) skipped
  everything after it.
- Self-update can no longer relaunch in a loop, retries a copy that stopped half-way, and never
  downgrades a PC from an older shared folder.
- Desk Console no longer freezes for half a minute while the shared folder's server is asleep, and
  one PC without an address no longer blanks every card.
- Passwords and folders with accents, spaces or quotes reach Windows unchanged.
- Uninstalling removes both scheduled tasks and Desk Console's own files -- on a PC set up with an
  older installer, run this one once first ([Installation](Installation#uninstalling)).

### Good to know

- A PC reports for the account that ran setup there, while that account is signed in at the PC's
  own screen. If automatic sign-in uses a different account, run setup once while signed in as it.
- New page [Hardening the Shared Folder](Hardening-the-Shared-Folder): whoever can write the shared
  folder can run code on every PC, so use a share-only account rather than the NAS administrator.
- Each release now has a `SHA256SUMS.txt` and a GitHub build-provenance attestation, so you can
  check the installer was built from the repository ([Building](Building)).

## Earlier versions

- **1.6.0** -- Windows Update won't restart a PC by itself while someone is signed in; QR codes to
  put RustDesk on a phone or tablet; the dev box (reopen VS Code and resume Claude Code at sign-in).
- **1.5.0** -- first public release: one keyboard and mouse (Deskflow or Synergy 3), RustDesk on
  every PC, the Desk Console window, optional automatic sign-in.

When the in-app text and this page are updated for a release, `src\whats-new.txt` is the one
Desk Console shows; `tools\Test-Repo.ps1` fails until its first line names the new version.
