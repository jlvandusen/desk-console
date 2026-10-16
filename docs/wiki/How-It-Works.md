# How It Works

## The pieces

```
Installer (Inno Setup, per-user, no admin)
  ├─ copies Desk Console to %LOCALAPPDATA%\Programs\DeskConsole (+ site.json)
  └─ runs src\Setup-Synergy.ps1 three times:
       User   (as you)       share login → Credential Manager, drive map, kvm.json choice
       Admin  (one UAC)      keyboard/mouse program, RustDesk, firewall, automatic sign-in, machines.csv
       Finish (as you)       Deskflow user settings, trust sync task
```

`Setup-Synergy.ps1` can also be run on its own (`Setup-Synergy.cmd` in the shared folder); it
then elevates itself for the Admin step.

## Why three steps

- **User before Admin:** drive mappings and saved logins belong to a logon token. A drive mapped
  from an elevated window is invisible in Explorer, and an elevated window cannot see the
  user's mapped drives -- so the user step maps, and every path handed to the elevated step is
  converted to UNC.
- **Finish after Admin:** Deskflow's per-user settings and the trust-sync task belong to the
  signed-in user, and Deskflow must be installed first.

## Always 64-bit

Inno Setup is a 32-bit program; launching a bare `powershell.exe` from it starts the 32-bit
PowerShell. That one sees the 32-bit registry view (`WOW6432Node`: a different `Run` key, a
different `Winlogon` key), cannot read 64-bit processes' paths, and has no `Get-LocalUser`. The
installer calls `{sys}\WindowsPowerShell\v1.0\powershell.exe` in 64-bit mode, and the script
re-launches itself under `sysnative` if it ever finds itself 32-bit.

## Keyboard and mouse (Deskflow)

- The Admin step installs the Visual C++ runtime if needed, then Deskflow, writes the
  machine-wide `C:\ProgramData\Deskflow\Deskflow.conf` and starts Deskflow for every user.
- Deskflow 1.27 takes the **computer list** from `Deskflow.conf` (`[computer_<NAME>] name=<NAME>`),
  not from the layout file's `section: screens` (ignored). The layout file holds only
  `section: links` (left/right neighbours) and `section: options` (hotkeys).
- **Trust without dialogs:** every PC publishes the SHA-256 of its Deskflow certificate
  (`C:\ProgramData\Deskflow\tls\deskflow.pem`) to `fingerprints\<PC>.txt` as
  `v2:sha256:<hex>`. The server's `trusted-clients` and each client's `trusted-servers` are
  filled from there. Deskflow re-reads those files on every connection, so a new client is
  accepted without a restart.
- **The 2-minute trust sync** (scheduled task *DeskConsole Deskflow trust sync*, as the signed-in
  user, no admin) repeats the fingerprint exchange and, on the server, rebuilds the layout in
  the user's own `%APPDATA%\Deskflow\deskflow-server.conf` when `kvm.json` changed. Deskflow
  reads its settings only when its core starts, so after a change the task restarts the Deskflow
  window -- and only then.

## Remote control (RustDesk)

Installed as a service (works at the lock screen), **direct IP access** turned on (TCP/UDP
21118), firewall open to the local subnet only. No relay or ID server is needed on a LAN.
The unattended password is set from the wizard; Desk Console keeps a copy in Credential
Manager so *View + control* connects without asking.

## Switching keyboard/mouse programs

"Switching off" Synergy or Deskflow stops and disables its service, parks its sign-in entries in
`HKLM\SOFTWARE\DeskConsole\DisabledRun` and ends its processes. Switching back restores exactly
that. Nothing is uninstalled.
