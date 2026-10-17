# Troubleshooting

Every setup run leaves `logs\<PC>-<step>.log` in the shared folder, with the failing line on
error, and the installer's last page lists what each step reported. The 2-minute task logs what it
changed to `agent.log`, and self-update to `update.log`, in the install folder
(`%LOCALAPPDATA%\Programs\DeskConsole`). Start there.

## Setup

### The installer's last page lists problems, or says a step did not finish
Each line names the step (`[User]`, `[Admin]`, `[Finish]`) and the problem; the logs it names have
the details. Common ones: *The admin step did not finish (Windows prompt declined or failed)* -- run
setup again and approve the prompt; an MSI exit 1618 -- another installation was running (often
Windows Update): wait, then *Repair / update this PC*. A failed part no longer stops the rest of
the step: sign-in, Windows Update and the machines.csv row are still done.

### Setup "hangs" and the window title starts with *Select*
A click in a console window starts QuickEdit selection, which **pauses** the script. Press
**Esc**. (Setup turns QuickEdit off for its own windows.)

### *msiexec exit 1603* installing Deskflow
Deskflow needs the **Microsoft Visual C++ runtime 14.44+** (`ShowVCRedistError` in the MSI log).
The installer bundles it and installs it only when missing or older.

### "Synergy switched off" but Synergy's tray app still runs
The setup step ran in **32-bit PowerShell** (SysWOW64): it saw the wrong registry view and
could not see 64-bit processes. Current versions always run 64-bit; re-run setup.

### Synergy no longer starts at sign-in after switching back to it
Versions before 1.7.0 erased the parked sign-in entries when they parked the next one, so a
Deskflow -> Synergy switch had nothing to restore. Fixed; on a PC where it already happened,
reinstall Synergy's MSI once (it recreates its entry).

### *Automatic sign-in NOT changed: Get-LocalUser is not recognized*
Same cause -- 32-bit PowerShell has no LocalAccounts module. Re-run with a current installer.

### *Setup needs to replace these Desk Console files, but another program has them open*
A Desk Console window or tray icon (possibly mid self-update) holds a script. Close Desk Console
(tray icon > *Exit*) and any `powershell.exe` (Task Manager > Details) and click **Retry**. Cancel
leaves the PC as it was.

### *Cannot process argument because the value of argument "name" is not valid*
Not explained yet. It has been seen when a `.ps1` was started from the Run box through a file
association, and once when `Setup-Synergy.cmd` was double-clicked. Run setup through
`DeskConsoleSetup-<version>.exe` or Desk Console's *Repair / update this PC*, and if it happens
again, keep the whole log for an issue. (Setup now reports an argument it does not know instead of
stopping on it.)

## Keyboard and mouse (Deskflow)

### Nothing listens on 24800; the daemon log says *unknown computer name*
Deskflow 1.27 ignores the layout file's `section: screens`; computers must be listed in
`Deskflow.conf` as `[computer_<NAME>]`. Current setup writes them -- re-run setup on the server.

### Server log: *fingerprint does not match trusted fingerprint*
The client's fingerprint is not in the server's `C:\ProgramData\Deskflow\tls\trusted-clients`.
The trust sync adds it within two minutes once the client has run setup (its
`fingerprints\<PC>.txt` exists). No restart needed.

### Server log: *unrecognised client name "X"*
X is not in the server's layout yet. The server's 2-minute task rebuilds it from `kvm.json` and
reloads Deskflow within two minutes.

### Server log: *failed to accept secure socket* every few seconds
Something is making plain TCP connections to port 24800 -- old Desk Console versions (< 1.4.11)
did. Update every PC's Desk Console. Harmless to connected clients.

### The clients lost the keyboard and mouse after the server got a new address
They follow by themselves within about four minutes. If not: the server's row in `machines.csv`
must show its new address (its 2-minute task writes it; see its `agent.log`), and each client's
`agent.log` says when it repointed Deskflow.

### A PC I took out of `row` came back
Versions before 1.7.0 re-added every PC to `row` from its 2-minute task. Update that PC.

## Desk Console app

### A PC shows offline, or registered the wrong address
A PC with Wi-Fi and Ethernet could register its Wi-Fi address, which sleeps, or a virtual adapter
(WSL, Hyper-V, VPN). Setup now registers the address the PC uses to reach the shared folder, and
its 2-minute task corrects the row within two minutes whenever it changes. Checks wait 2 s: a
just-woken PC can take over half a second to answer.

### A card says *No report yet* or *Status N min old*
That PC's 2-minute task is not reporting: it has not run 1.7.x setup yet (Desk Console updates
itself, but the task is registered by setup -- use *Repair / update this PC* there), nobody is
signed in there (the task runs as the signed-in user), or it cannot reach the shared folder.
`schtasks /Query /TN "DeskConsole Deskflow trust sync"` on that PC shows the task, and
`agent.log` in its install folder says why a report was not written.

On a PC running **1.7.0**, a card that goes grey a few minutes after its first report is a 1.7.0
bug, fixed in 1.7.1: the task judged the shared folder unreachable on most runs (nothing in
`agent.log`), and when it did get through it could not overwrite the report (`agent.log`: *status
not written: ... The path is not of a legal form*). That PC updates itself from the shared folder
once 1.7.1's scripts are there.

The PC can also simply be **asleep**: *Online: no* with *RustDesk: not reachable* too. A sleeping
client also drops its keyboard and mouse link; *Wake* brings it back only with Wake-on-LAN on in
its BIOS and network card ([Fleet Status and Actions](Fleet-Status-and-Actions#wake)).

### *Actions* did nothing
The card shows the result once that PC reports it (*restart: ok*, *expired*, *refused*). A request
runs within 2 minutes or never: one sent to a PC that is asleep, off or not reporting expires after
10 minutes. That PC's `agent.log` lists every request it handled.

### The panel says *Using: Synergy* on a Deskflow PC
An old version could not read `kvm.json` (the shared folder moved) and guessed. Current versions
report the program actually enabled on the PC; update Desk Console.

### Desk Console seems not to start
It may be running in the notification area already (a second start brings it to the front), or
updating itself from the shared folder (see `update.log`). If the shared folder's server is asleep
it waits at most 2 seconds for it, then shows the cached list with a yellow bar.

### Installed copies cannot find the shared folder after it was moved
Leave a stub at the old path containing `version.txt` (higher), `Install-DeskConsole.ps1` and a
`site.json` pointing at the new place; old copies update themselves from there on next launch.

## RustDesk

### *Your ip is blocked by the peer*
The device connecting is outside your home network as setup knows it (`lanCidr`, or the PC's own
network): a phone on a guest network or a second router's Wi-Fi, or on mobile data. Add that
network to `lanCidr` in the shared folder's `site.json` and run *Repair / update this PC* on each PC
([Remote Control](Remote-Control#who-can-connect-home-network-only-or-anywhere)).

### Setup warns that it left RustDesk's whitelist alone
You were connected through RustDesk from an address the new whitelist would refuse, so setup did
not cut your own session. Run setup at the PC, or over RustDesk from inside the home network.

## Network shares

### `\\PC\C$` says *Access is denied* with the right password
Remote UAC: Windows strips administrator rights from **local** accounts over the network, and
admin shares need them. *Access is denied* (rather than *wrong password*) means the password was
accepted. Options: RustDesk file transfer; a normal shared folder; or `tools\Diag-Smb.ps1 -Fix`
(see [Security](Security#optional-changes-with-trade-offs) -- it applies to every local
administrator and stays until `-Undo`). Run `Diag-Smb.ps1` without `-Fix` to see failed sign-ins
with their reason codes.

### *machines.csv* or *Access is denied* errors after hardening the shared folder
The share account lacks one of the rights on
[Hardening the Shared Folder](Hardening-the-Shared-Folder#who-needs-what) -- most often *Create files*
on the folder itself or the *Creator Owner* entry, which setup needs to replace `machines.csv`.

### *Multiple connections to a server ... by the same user, using more than one user name* (1219)
Windows already has a connection to that server with another account (after switching the PCs
to a share-only account, or when copying as yourself). Sign out and back in, or use
`runas /netonly` ([Hardening](Hardening-the-Shared-Folder#deploying-a-new-version)).
