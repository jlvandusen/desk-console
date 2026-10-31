# Changelog

What changed in each release. The release workflow publishes a version's section as its release
notes, so each entry is written for the people running Desk Console. Format:
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow `src/version.txt`.

## [1.8.9] - 2026-10-31

Copy the new scripts to the shared folder: installed copies update themselves (unattended).

### Added

- **RustDesk sessions pause keyboard and mouse sharing.** While a RustDesk session is open on the
  keyboard/mouse server, Desk Console removes Deskflow's links and hotkeys there, so RustDesk is the
  only input path; they come back 5 s after the last session closes. Deskflow's edge links had been
  throwing the cursor -- and the focus -- to the other PC whenever it touched the desk's outer edge
  in a RustDesk window (711 switches in one server's log, nearly all bounces of under a second),
  and its hotkeys took Ctrl+Alt+arrow keys from games. On by default; tray icon menu > *Pause
  keyboard/mouse sharing while a RustDesk session is open* turns it off for a desk where every PC
  has its own monitor. Quitting Desk Console resumes Deskflow; if it stops unexpectedly, the
  2-minute task does.

### Fixed

- **A layout change could be written but never loaded.** Deskflow's engine reloads only when
  `Deskflow.conf` changes, and restarting its window does not always rewrite that file, so a new
  layout from the server's 2-minute task (a PC added or moved) could wait for the next restart.
  Every layout change now stamps `Deskflow.conf`, which restarts the engine with it.

## [1.8.8] - 2026-10-25

Copy the new scripts to the shared folder: installed copies update themselves (unattended).

### Changed

- **Microsoft Visual C++ runtime 14.51.36247.0** in the installer (was 14.44.35211.0; signed by
  Microsoft, SHA-256 `843068991DAAA1F73AD9F6239BCE4D0F6A07A51F18C37EA2A867E9BECA71295C`). Setup
  still installs it only where the runtime is missing or older than 14.44, which Deskflow needs,
  so PCs that have it are unchanged.

## [1.8.7] - 2026-10-25

Copy the new scripts to the shared folder: installed copies update themselves (unattended).

### Fixed

- **A PC opened on the main display instead of its own after another session was closed.**
  RustDesk reuses a closed session's window for the next one, and Desk Console skipped that window
  as already placed. Windows not showing are now forgotten, so a reused one is placed again.
- **Placement on a scaled display.** The displays are now measured in real pixels (a 150% display
  was seen at 2/3 of its size), counted left to right as Windows arranges them, and for 10 s after
  it opens a window that RustDesk moves elsewhere is put back on its display.

## [1.8.6] - 2026-10-25

Copy the new scripts to the shared folder: installed copies update themselves (unattended).

### Fixed

- **Connect all opened only the first PC.** A second RustDesk launch hands its connection to the
  RustDesk that is already running, and one sent while that RustDesk was still starting was lost.
  Connect all now opens the PCs one after another, each once the previous one's window is up.
- **Desk Console showed PowerShell's icon on the taskbar** and its notifications said "Windows
  PowerShell". It now has its own taskbar identity (Windows app ID `JamesVanDusen.DeskConsole`),
  and its shortcuts carry the same ID -- set by the update itself on existing shortcuts.

## [1.8.5] - 2026-10-25

Copy the new scripts to the shared folder: installed copies update themselves (unattended, from
1.8.4 on).

### Changed

- **RustDesk's connection window is hidden on every PC by default.** A card's *Actions* > *Hide
  RustDesk's connection window there* is now ticked unless you untick it; kvm.json
  `showRustDeskWindow` lists the PCs that keep the window. 1.8.4's opt-in `hideRustDeskWindow` list
  is no longer used (Desk Console removes it at the next change).

## [1.8.4] - 2026-10-25

Copy the new scripts to the shared folder: installed copies update themselves.

### Fixed

- **Deskflow still on the taskbar on some PCs.** 1.8.1 changed only the signed-in user's own
  Deskflow settings file, and a PC whose Deskflow reads the machine-wide one was skipped. The
  2-minute task now starts the user's own file from the machine-wide one, then applies the
  notification-area settings (once; Deskflow's window restarts, the keyboard and mouse stay
  connected).

### Added

- **Every PC updates itself unattended.** The 2-minute task compares the shared folder's version
  with its own on every run and updates Desk Console when the share is newer -- no one needs to
  open Desk Console there. A PC is on a new version within about 2 minutes of it reaching the
  shared folder (`update.log` in the install folder records it).
- **Optional: hide RustDesk's connection window on a PC.** A card's *Actions* > *Hide RustDesk's
  connection window there* (kvm.json `hideRustDeskWindow`, off by default). That PC's 2-minute
  task starts a small watcher that hides RustDesk's "someone is connected" window -- the taskbar
  button that shows while you control it; RustDesk's tray icon stays. Someone at that PC then
  cannot see that it is controlled.
- Status reports say whether Deskflow starts in the notification area (`deskflowHidden`) and
  whether the RustDesk window watcher runs (`rustdeskWindowWatcher`).

## [1.8.3] - 2026-10-25

Copy the new scripts to the shared folder: installed copies update themselves.

### Added

- **Separate windows or tabs, in the window too.** The toolbar has an *Each PC in its own window*
  checkbox, the same choice as the tray icon menu item (either one updates the other). The status
  bar says when the change takes effect.

## [1.8.2] - 2026-10-25

Copy the new scripts to the shared folder: installed copies update themselves.

### Fixed

- **A second PC opened as a tab, not on its own display.** RustDesk adds every new connection as
  a tab of its open remote window, so only the first PC reached its display. *View + control* now
  turns RustDesk's *Open connection in new tab* off, so each PC gets a window that can be placed.
  With sessions already open it waits until they are closed.

### Added

- **Separate windows or tabs.** Tray icon menu > *Open each PC in its own window (on its
  display)*: on by default; off keeps RustDesk's tabs in one window.

## [1.8.1] - 2026-10-24

Copy the new scripts to the shared folder: installed copies update themselves, and no setup run
is needed.

### Changed

- **Deskflow stays in the notification area.** Its window no longer opens at sign-in or sits on
  the taskbar: Deskflow starts hidden, closing its window keeps it running, and its tray icon
  opens it. On a PC set up earlier, the 2-minute task applies this once for each user, within a
  few minutes of the update (Deskflow's window restarts once; the keyboard and mouse stay
  connected). Change it afterwards in Deskflow's own settings and it stays changed. Setup applies
  it as well.

## [1.8.0] - 2026-10-24

Copy the new scripts to the shared folder: installed copies update themselves.

### Added

- **Each PC opens on its own display.** *View + control* (and *Open all*) now put a PC's RustDesk
  window on the display that matches its place in your desk layout, relative to this PC on the
  primary display: with the server in the centre, a PC on its left opens on the left display and
  one on its right opens on the right. With no display in that direction, or a single display, the
  window opens normally and you can move it.
- **Optional: hide RustDesk sessions from the taskbar.** Tray icon menu > *Hide RustDesk sessions
  from the taskbar* (off by default).   Open RustDesk sessions are listed in the tray menu: click
  one to bring it back.

## [1.7.1] - 2026-10-17

Copy the new scripts to the shared folder: installed copies update themselves. On a PC that has
not run 1.7.x setup yet, run `DeskConsoleSetup-1.7.1.exe` (*Update and keep this PC's settings*),
as the 1.7.0 notes below say.

### Fixed

- **The 2-minute task skipped its work on most runs.** Its check that the shared folder's server
  answers (new in 1.7.0) looked at the connection attempts twice -- "connected?", then "all
  finished?" -- and a NAS that answered between the two looks read as unreachable. On a fast home
  network that was nearly every run (10 of 10 in a test, 0 of 10 now), so the status report,
  address healing, the Deskflow clients following the server, queued actions and the Deskflow
  trust and layout sync were all skipped, silently. Both checks (the agent's and setup's) now
  decide from the final state.
- **Status reports could not be refreshed.** A run that got past that check still failed to
  overwrite the PC's earlier report, so every card turned grey (*Status N min old*) after the first
  one: Windows PowerShell 5.1 passed the agent's `$null` backup-file argument to `File.Replace` as
  an empty path ("The path is not of a legal form"). Reports now refresh on change and at least
  every 4 minutes; `agent.json` is written again too.
- Turning automatic sign-in off left an empty saved password (the LSA secret `DefaultPassword`)
  instead of deleting it, for the same reason. No password stayed stored; now the secret is gone.

## [1.7.0] - 2026-10-17

Run the new installer once on every PC -- or Desk Console > *Repair / update this PC* -- after
copying the new scripts to the shared folder (the release has them as
`DeskConsole-1.7.0-scripts.zip`). Installed copies update their own files, but only setup
registers the 2-minute task on every PC, scopes the firewall, sets RustDesk's whitelist and brings
the automatic sign-in lock up to date. The installer offers *Update and keep this PC's settings*.

### Security

- **RustDesk answers your home network only.** Every PC used to accept its password by RustDesk ID
  from anywhere on the internet, whatever the firewall said. Setup now sets RustDesk's IP whitelist
  to `lanCidr` from `site.json`, or the PC's own network. `"rustdeskReach": "anywhere"` opts out.
  Setup never sets a whitelist that would cut the RustDesk session it is running over.
- **The firewall is really home-network-only.** The allow-any rules the RustDesk, Deskflow and
  Synergy installers add are now limited too (they made Desk Console's own rules meaningless), again
  on every setup run. The keyboard/mouse port rule is now *Desk Console keyboard/mouse (TCP 24800,
  LAN)*.
- **The screen locks after every automatic sign-in**: also after a sign-out (Windows signs
  straight back in), and Fast Startup is turned off while the lock is on (shut down + power on
  skipped the lock). The old setting comes back when the lock is turned off.
- Setup warns when the automatic sign-in account is an administrator, a domain or a Microsoft
  account: any administrator of that PC can read its password back.
- A dedicated automatic sign-in account is no longer reset on every run, which lost its saved
  passwords: its password is checked first, and setup never resets the signed-in account or an
  administrator.
- New wiki page *Hardening the Shared Folder*: a share-only account instead of the NAS
  administrator, and code only you can change. The *Security* page now says plainly that whoever
  can write the shared folder runs code on every PC, and where a password still crosses a command
  line.
- Releases are built by GitHub Actions from the tag, with a build-provenance attestation, a
  `SHA256SUMS.txt` and the full source of the bundled RustDesk and Deskflow.

### Added

- **Every PC reports its own state.** The 2-minute task now runs on every PC, whatever the
  keyboard/mouse program, and writes `status\<PC>.json`: version, keyboard/mouse link, automatic
  sign-in (and when Windows now names another account), sign-in notice, Fast Startup, pending
  restart, Windows Update policy, RustDesk reach, address, last action. Each card shows it, in grey
  once it is older than 6 minutes.
- **Restart, Sleep, Lock and Sign out** any other PC from its card (*Actions*). The request waits
  in the shared folder; that PC runs it within 2 minutes or never (it expires after 10), and the card
  shows the result. Restart gives a 60-second warning on that PC's screen.
- **Honest keyboard/mouse lines.** On the server, each client's card comes from the server's own
  connections (*connected* / *not connected*; the server's card says *2 of 3 clients*). A line
  nobody can vouch for is grey, no longer green.
- **Addresses heal themselves.** A PC rewrites its `machines.csv` row when its address or network
  card changes, and the Deskflow clients follow the server's new address by themselves.
- **Tray icon and notifications.** Closing the window keeps Desk Console watching: a notification
  when a PC goes offline or comes back, a client's keyboard and mouse disconnect, or the shared
  folder stops answering. One copy per sign-in; the window opens where you left it; the sign-in
  shortcut starts it in the tray.
- Cards in desk order, with `<` `>` buttons that move a PC in the layout.
- `kvm.json`: a `grid` for screens above and below each other, `options` (clipboard sharing and
  size, switch delay, double tap, heartbeat), and **Ctrl+Alt+Shift+1..9** to jump straight to a PC.
- **Wake** goes out on the adapter that is on the target's network (directed broadcast, ports 9 and
  7), and the card watches for 2 minutes and says whether the PC woke. Setup turns Wake-on-LAN on
  for each PC's wired adapter -- at the next restart when it runs under a RustDesk session, since
  the change can reset the network card.
- Desk Console: *Repair / update this PC* (runs the newest installer in the shared folder),
  *Windows Update...*, *Restart Deskflow* without an admin prompt, a RustDesk password dialog with
  *Remove*, a status bar, a yellow bar with *Retry* while the shared folder is unreachable, F5 and
  Alt-key shortcuts, names for screen readers.
- **What's new**: after an update Desk Console shows what changed once (a notification to click
  when it started in the notification area), and again from *What's new* in its status bar. The
  text is `src\whats-new.txt`; the wiki has it as *What's New*.
- Installer: *Update and keep this PC's settings* on a PC that is set up; a Ready page that lists
  what will change; a last page that lists every warning and failure of the setup steps; the
  automatic sign-in password checked on its page; a question before a local folder, a missing share
  login, another server or another program for every PC; the RustDesk password saved for *View +
  control*; no licence page.
- `Remove-Synergy.cmd`: uninstalls Synergy once no PC uses it, without touching the port Deskflow
  needs.
- Dev box: several folders, each with VS Code and/or `claude --continue` (one terminal tab each).
- For the repository: `tools\Test-Repo.ps1` and `tools\Test-Pins.ps1` (also in CI on every push),
  `tools\Get-Redist.ps1 -CheckLatest` with a weekly upstream check that opens an issue, a release
  workflow, `SECURITY.md`, `CONTRIBUTING.md`, issue and pull request templates.

### Changed

- **Windows Update** "no restart while someone is signed in" now also sets *Configure Automatic
  Updates* to option 4 (install daily at 03:00), which Microsoft documents as required; the previous
  values come back when it is turned off. A policy without it shows as *incomplete* -- re-apply it.
- A newer RustDesk or Deskflow in the installer is now installed over an older one on PCs that
  were set up before (RustDesk not while you are connected through it).
- The version is written only in `src\version.txt`; the setup exe's file version comes from it too.
- A PC that could not read `kvm.json` when the wizard ran can no longer make itself the server, or
  switch every PC to another program.
- The 2-minute task never adds a PC back to `kvm.json`; only setup adds a PC.
- `machines.csv` holds the address each PC uses to reach the shared folder (virtual and VPN adapters
  last), a renamed PC replaces its old row, and a row is never written without an address.

### Fixed

- Setup recreated registry keys in a way that deletes them, wiping the other keyboard/mouse
  program's parked sign-in entries (so switching back did not start it), Desk Console's own records
  and other Windows Update policies.
- `Setup-Synergy.cmd -NoAutoRestart`, `-AutoLogon` and the dev box options silently did nothing:
  the step that asks for admin dropped them. The elevated Windows Update step now writes its own log.
- The installer said "installed" when a step had failed, and a hidden step could fail without a
  trace or wait for Enter forever. Desk Console's admin dialogs froze its window until a hidden
  console was found.
- One failing part of the admin step (an installer busy with Windows Update, a firewall error)
  ended the step before automatic sign-in, Windows Update and registration.
- Self-update can no longer relaunch in a loop, retries a copy that stopped halfway, and never
  downgrades a PC from an older shared folder.
- Uninstalling removes the dev box task and Desk Console's own files; `Install-DeskConsole.ps1
  -Uninstall` removes both tasks.
- Desk Console no longer freezes for half a minute when the shared folder's server is asleep; one
  row without an address no longer blanks every card; the server's card no longer reads "client: not
  connected" while the shared folder is offline; status messages are visible at the default window
  size; an error shows a message instead of .NET's crash dialog.
- Passwords and folders with accented characters, spaces or quotes reach Windows unchanged; a dev
  box on a drive root works.
- `LICENSE` is the plain MIT text again, so GitHub recognises it.

## [1.6.0] - 2026-10-17

### Added

- **Windows Update won't restart a PC by itself while someone is signed in**: an installer option
  (on by default), `Set-NoAutoRestart.cmd`, and the state in Desk Console. It sets the *No
  auto-restart with logged on users* policy (Pro / Enterprise / Education).
- **Phones and tablets**: QR codes on a new installer page and in Desk Console > *Phone / tablet...*
  to install RustDesk (the Android APK or F-Droid -- RustDesk is not on Google Play -- and the iOS
  App Store), with every PC's address to connect to.
- **Dev box**: reopen VS Code on a project folder and resume Claude Code (`claude --continue`) at
  every sign-in; an installer page and Desk Console > *Dev box...* (Apply / Run now / Turn off).

## [1.5.0] - 2026-10-16

First public release.

- **Keyboard and mouse sharing** with Deskflow (bundled, free) or Synergy 3 (bring your own
  licensed installer); the layout and the TLS pairing are automatic -- a new PC is accepted within
  two minutes, with no dialogs and no restarts.
- **RustDesk** as a service with direct-IP access and one password for every PC.
- **Desk Console**, a window with every PC: *View + control*, *Wake-on-LAN* and *Connect all*; it
  updates itself from the shared folder.
- Optional **automatic sign-in** (the password in the LSA secret store, checked first), with an
  optional lock right after.
- Bundled, unmodified and hash-pinned: RustDesk 1.5.0 (AGPL-3.0), Deskflow 1.27.0 (GPL-2.0) and
  the Microsoft Visual C++ runtime 14.44.35211.0.
