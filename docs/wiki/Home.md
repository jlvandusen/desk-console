# Desk Console

Desk Console sets up and watches a small group of Windows PCs that share **one keyboard and
mouse** (Deskflow, or Synergy 3) and can each be **viewed and controlled remotely** (RustDesk).

- **One installer per PC** -- `DeskConsoleSetup-<version>.exe` installs and configures everything.
- **One shared folder** holds the group's state: the PC list, the screen layout, Deskflow
  fingerprints and setup logs.
- **One window** -- the Desk Console app -- shows every PC and opens any of them in RustDesk.

## Pages

| Page | What it covers |
|---|---|
| [Installation](Installation) | First-time setup, server first, then clients; what each wizard page means |
| [Configuration](Configuration) | `site.json`, `kvm.json`, `machines.csv` -- what lives where |
| [How It Works](How-It-Works) | The three setup steps, the 2-minute trust sync, why each design choice |
| [Desk Console App](Desk-Console-App) | The window, its buttons, self-update, `-Check` |
| [Keyboard and Mouse](Keyboard-and-Mouse) | Deskflow vs Synergy, switching, hotkeys, adding a PC |
| [Remote Control](Remote-Control) | RustDesk direct IP, passwords, phones and tablets (QR codes), full screen |
| [Automatic Sign-In](Automatic-Sign-In) | Signing in at boot safely, existing vs dedicated account |
| [Windows Update](Windows-Update) | Stop Windows Update restarting a PC while someone is signed in |
| [Dev Box](Dev-Box) | Reopen VS Code and resume Claude Code at sign-in |
| [Security](Security) | What is stored where, what is opened on the firewall, trade-offs |
| [Troubleshooting](Troubleshooting) | Every failure met so far, with its cause and fix |
| [Building](Building) | Building the installer from source, releasing |
