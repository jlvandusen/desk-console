# Troubleshooting

Every setup run leaves `logs\<PC>-<step>.log` in the shared folder, with the failing line on
error. Start there.

## Setup

### Setup "hangs" and the window title starts with *Select*
A click in a console window starts QuickEdit selection, which **pauses** the script. Press
**Esc**. (Setup turns QuickEdit off for its own windows.)

### *msiexec exit 1603* installing Deskflow
Deskflow needs the **Microsoft Visual C++ runtime 14.44+** (`ShowVCRedistError` in the MSI log).
The installer bundles it and installs it only when missing or older.

### "Synergy switched off" but Synergy's tray app still runs
The setup step ran in **32-bit PowerShell** (SysWOW64): it saw the wrong registry view and
could not see 64-bit processes. Current versions always run 64-bit; re-run setup.

### *Automatic sign-in NOT changed: Get-LocalUser is not recognized*
Same cause -- 32-bit PowerShell has no LocalAccounts module. Re-run with a current installer.

### *Setup needs to replace these Desk Console files, but another program has them open*
A Desk Console window (possibly hidden, or mid self-update) holds a script. Close Desk Console
and any `powershell.exe` (Task Manager > Details) and click **Retry**. Cancel leaves the PC as it was.

### *Cannot process argument because the value of argument "name" is not valid*
Seen when a `.ps1` was started from the Run box through a file association. Start setup through
`DeskConsoleSetup.exe` or `Setup-Synergy.cmd` instead.

## Keyboard and mouse (Deskflow)

### Nothing listens on 24800; the daemon log says *unknown computer name*
Deskflow 1.27 ignores the layout file's `section: screens`; computers must be listed in
`Deskflow.conf` as `[computer_<NAME>]`. Current setup writes them -- re-run setup on the server.

### Server log: *fingerprint does not match trusted fingerprint*
The client's fingerprint is not in the server's `C:\ProgramData\Deskflow\tls\trusted-clients`.
The trust sync adds it within two minutes once the client has run setup (its
`fingerprints\<PC>.txt` exists). No restart needed.

### Server log: *unrecognised client name "X"*
X is not in the server's layout yet. The server's trust sync rebuilds it from `kvm.json` and
reloads Deskflow within two minutes.

### Server log: *failed to accept secure socket* every few seconds
Something is making plain TCP connections to port 24800 -- old Desk Console versions (< 1.4.11)
did. Update every PC's Desk Console. Harmless to connected clients.

## Desk Console app

### A PC shows offline, or registered the wrong address
A PC with Wi-Fi and Ethernet can register its Wi-Fi address, which sleeps. Setup now prefers
the wired adapter with a default gateway; re-run setup on that PC, or fix its row in
`machines.csv`. Checks wait 2 s: a just-woken PC can take over half a second to answer.

### The panel says *Using: Synergy* on a Deskflow PC
An old version could not read `kvm.json` (the shared folder moved) and guessed. Current versions
report the program actually enabled on the PC; update Desk Console.

### Installed copies cannot find the shared folder after it was moved
Leave a stub at the old path containing `version.txt` (higher), `Install-DeskConsole.ps1` and a
`site.json` pointing at the new place; old copies update themselves from there on next launch.

## Network shares

### `\\PC\C$` says *Access is denied* with the right password
Remote UAC: Windows strips administrator rights from **local** accounts over the network, and
admin shares need them. *Access is denied* (rather than *wrong password*) means the password was
accepted. Options: RustDesk file transfer; a normal shared folder; or `tools\Diag-Smb.ps1 -Fix`
(see [Security](Security#optional-changes-with-trade-offs)). Run `Diag-Smb.ps1` without
`-Fix` to see failed sign-ins with their reason codes.
