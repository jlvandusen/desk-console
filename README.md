# Desk Console

[![CI](https://github.com/jlvandusen/desk-console/actions/workflows/ci.yml/badge.svg)](https://github.com/jlvandusen/desk-console/actions/workflows/ci.yml)

One keyboard and mouse across several Windows PCs, a remote view of every screen, and one
window to watch and drive them all -- set up on each PC by a single installer.

Desk Console ties together three free tools and handles the fiddly parts between them:

| Need | Tool | What Desk Console adds |
|---|---|---|
| Share one keyboard + mouse | **[Deskflow](https://github.com/deskflow/deskflow)** (free) or **Synergy 3** (paid) | Installs and configures it on every PC, builds the screen layout (a row, or a grid), pairs the PCs' TLS fingerprints automatically -- no trust dialogs, no restarts when a PC joins -- and keeps the clients pointed at the server when its address changes |
| See and control a PC's screen | **[RustDesk](https://github.com/rustdesk/rustdesk)** | Direct IP on your LAN, reachable from your home network only (RustDesk's IP whitelist and the firewall), runs as a service so it works at the lock screen, one password for every PC |
| Watch everything | **Desk Console** (this app) | One card per PC with its real state, reported by the PC itself: online, keyboard/mouse link, RustDesk, version, pending restart, sign-in problems. *View + control*, *Wake*, *Restart / Sleep / Lock / Sign out*, *Connect all*, notifications from the tray |

Plus, per PC:

- **Automatic sign-in** at boot (password stored in the LSA secret store, like Sysinternals
  Autologon -- never as plain text), optionally locking the screen straight after.
- **No surprise restarts:** Windows Update waits for you while someone is signed in.
- **Dev box:** reopen VS Code on your project folders and resume Claude Code (`claude --continue`)
  at sign-in.
- **Phones and tablets:** QR codes in the installer and the app to install RustDesk on a phone
  (even a foldable) and control the PCs from it.

## What's new in 1.8

- **Each PC opens on its own display.** *View + control* and *Connect all* put every PC's RustDesk
  window on the display that matches its place in your desk layout -- the displays counted left to
  right as Windows arranges them, scaled displays included. Prefer one window with a tab per PC?
  Untick *Each PC in its own window* in the toolbar.
- **Unattended updates.** Every PC updates Desk Console by itself within about 2 minutes of a new
  version reaching the shared folder -- even where nobody opens Desk Console.
- **Out of the way on the taskbar:** Deskflow lives in the notification area, RustDesk's "someone is
  connected" window is hidden on the PCs you control (per PC, from a card's *Actions*), and Desk
  Console has its own taskbar icon instead of PowerShell's.
- **Fixes:** *Connect all* opens every PC (it opened only the first); a PC no longer lands on the
  main display after another session was closed.

Copy the new scripts to the shared folder once; from 1.8.4 on the PCs take it from there.
Everything, with what to expect: **[What's New](../../wiki/Whats-New)** -- the same list Desk
Console shows once after it updates -- and the [changelog](CHANGELOG.md).

## Quick start

1. Make a **shared folder** every PC can reach, e.g. `\\nas\share\DeskConsole`, and a share-only
   account for the PCs ([Hardening the Shared Folder](../../wiki/Hardening-the-Shared-Folder)).
2. From [Releases](../../releases), download **`DeskConsoleSetup-<version>.exe`** and
   **`DeskConsole-<version>-scripts.zip`** into that folder, and unzip the scripts there (the PCs
   update themselves from them).
3. Run the installer on the PC the keyboard and mouse are plugged into first (choose **Server**),
   then on every other PC (choose **Client**). Each run asks for one UAC approval, and its last page
   says what, if anything, needs attention.
4. Open **Desk Console** from the Start Menu.

Within two minutes of a client's setup finishing, the server trusts it and the mouse crosses
over. Full walkthrough: **[Installation](../../wiki/Installation)**.

## Documentation

The **[wiki](../../wiki)** covers installation, configuration (`site.json`, `kvm.json`), how the
pieces fit, the Desk Console app, fleet status and actions, automatic sign-in, security, hardening
the shared folder, troubleshooting and building from source.

## Requirements

- Windows 10/11 x64 on every PC, on the same LAN
- A network share for the shared folder (any SMB share: NAS, Windows share)
- An administrator account on each PC for the one-time setup

## Security

Whoever can write the shared folder can run code on every PC -- keep its write access to yourself
([Security](../../wiki/Security), [Hardening the Shared Folder](../../wiki/Hardening-the-Shared-Folder)).
Report vulnerabilities privately: [SECURITY.md](SECURITY.md).

## Build

```powershell
powershell -ExecutionPolicy Bypass -File tools\Test-Repo.ps1      # the static checks
powershell -ExecutionPolicy Bypass -File tools\Get-Redist.ps1     # bundled installers, hash-checked
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\DeskConsole.iss
# -> dist\DeskConsoleSetup-<version>.exe
```

Releases are built by GitHub Actions from a `v<version>` tag, with build provenance; see
[Building](../../wiki/Building) and [CONTRIBUTING.md](CONTRIBUTING.md). Changes: [CHANGELOG.md](CHANGELOG.md).

## License

Desk Console is [MIT](LICENSE). The release installer bundles RustDesk (AGPL-3.0), Deskflow
(GPL-2.0) and the Microsoft Visual C++ runtime under their own licenses -- see
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md); each release also carries their source. Synergy
is commercial and is never bundled. Not affiliated with RustDesk, Deskflow, Symless or Microsoft.
