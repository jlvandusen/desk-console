# Desk Console

One keyboard and mouse across several Windows PCs, a remote view of every screen, and one
window to watch and drive them all -- set up on each PC by a single installer.

Desk Console ties together three free tools and handles the fiddly parts between them:

| Need | Tool | What Desk Console adds |
|---|---|---|
| Share one keyboard + mouse | **[Deskflow](https://github.com/deskflow/deskflow)** (free) or **Synergy 3** (paid) | Installs and configures it on every PC, builds the screen layout, and pairs the PCs' TLS fingerprints automatically -- no trust dialogs, no restarts when a PC joins |
| See and control a PC's screen | **[RustDesk](https://github.com/rustdesk/rustdesk)** | Direct-IP on your LAN only (no relay), runs as a service so it works at the lock screen, one password for every PC |
| Watch everything | **Desk Console** (this app) | One card per PC: online, keyboard/mouse role, RustDesk reachable; *View + control*, *Wake-on-LAN*, *Connect all* |

Plus, per PC:

- **Automatic sign-in** at boot (password stored encrypted in the LSA store, like Sysinternals
  Autologon -- never as plain text), optionally locking the screen straight after.
- **No surprise restarts:** Windows Update waits for you while someone is signed in.
- **Dev box:** reopen VS Code on your project and resume Claude Code (`claude --continue`) at sign-in.
- **Phones and tablets:** QR codes in the installer and the app to install RustDesk on a phone
  (even a foldable) and control the PCs from it.

## Quick start

1. Make a **shared folder** every PC can reach, e.g. `\\nas\share\DeskConsole`.
2. Download **`DeskConsoleSetup-<version>.exe`** from [Releases](../../releases) into that folder.
3. Run it on the PC the keyboard and mouse are plugged into first (choose **Server**), then on
   every other PC (choose **Client**). Each run asks for one UAC approval.
4. Open **Desk Console** from the Start Menu.

Within two minutes of a client's setup finishing, the server trusts it and the mouse crosses
over. Full walkthrough: **[Installation](../../wiki/Installation)**.

## Documentation

The [wiki](../../wiki) covers installation, configuration (`site.json`, `kvm.json`), how the
pieces fit, the Desk Console app, automatic sign-in, security, troubleshooting and building
from source. The same pages live in [`docs/wiki/`](docs/wiki).

## Requirements

- Windows 10/11 x64 on every PC, on the same LAN
- A network share for the shared folder (any SMB share: NAS, Windows share)
- An administrator account on each PC for the one-time setup

## Build

```powershell
powershell -ExecutionPolicy Bypass -File tools\Get-Redist.ps1     # bundled installers, hash-checked
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\DeskConsole.iss
# -> dist\DeskConsoleSetup-<version>.exe
```

See [Building](../../wiki/Building).

## License

Desk Console is [MIT](LICENSE). The release installer bundles RustDesk (AGPL-3.0), Deskflow
(GPL-2.0) and the Microsoft Visual C++ runtime under their own licenses -- see
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). Synergy is commercial and is never bundled.
Not affiliated with RustDesk, Deskflow, Symless or Microsoft.
