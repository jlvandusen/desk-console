# Desk Console

Desk Console sets up and watches a small group of Windows PCs that share **one keyboard and
mouse** (Deskflow, or Synergy 3) and can each be **viewed and controlled remotely** (RustDesk).

- **One installer per PC** -- `DeskConsoleSetup-<version>.exe` installs and configures everything.
- **One shared folder** holds the group's state: the PC list, the screen layout, Deskflow
  fingerprints, each PC's status report, queued actions and setup logs.
- **One window** -- the Desk Console app, also in the notification area -- shows every PC as it
  really is, opens any of them in RustDesk, and restarts, sleeps, locks or signs out any of them.

## Pages

| Page | What it covers |
|---|---|
| [What's New](Whats-New) | Everything that changed in 1.7.0, and what to do once on every PC after updating |
| [Installation](Installation) | First-time setup, server first, then clients; what each wizard page means; updating, uninstalling |
| [Configuration](Configuration) | `site.json`, `kvm.json`, `machines.csv`, the status and command folders -- what lives where |
| [How It Works](How-It-Works) | The setup steps, the 2-minute task on every PC, why each design choice |
| [Desk Console App](Desk-Console-App) | The window, the tray icon, its buttons, self-update, `-Check` |
| [Fleet Status and Actions](Fleet-Status-and-Actions) | What each PC reports, how the cards use it, Restart / Sleep / Lock / Sign out from any PC |
| [Keyboard and Mouse](Keyboard-and-Mouse) | Deskflow vs Synergy, layout and grid, hotkeys, options, adding and removing a PC |
| [Remote Control](Remote-Control) | RustDesk direct IP, home-network-only reach, passwords, phones and tablets |
| [Automatic Sign-In](Automatic-Sign-In) | Signing in at boot safely, the lock, Fast Startup, existing vs dedicated account |
| [Windows Update](Windows-Update) | Stop Windows Update restarting a PC while someone is signed in |
| [Dev Box](Dev-Box) | Reopen VS Code and resume Claude Code sessions at sign-in |
| [Security](Security) | What is stored where, what is opened on the firewall, what share access means, trade-offs |
| [Hardening the Shared Folder](Hardening-the-Shared-Folder) | A share-only account and read-only code: the steps for a NAS or a Windows server |
| [Troubleshooting](Troubleshooting) | Every failure met so far, with its cause and fix |
| [Building](Building) | Building the installer, the checks, bumping a bundled program, releasing |
