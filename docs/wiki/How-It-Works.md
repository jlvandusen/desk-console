# How It Works

## The pieces

```
Installer (Inno Setup, per-user, no admin)
  +- copies Desk Console to %LOCALAPPDATA%\Programs\DeskConsole (+ site.json)
  +- runs src\Setup-Synergy.ps1 three times:
       User   (as you)      share login -> Credential Manager, drive map, kvm.json choice
       Admin  (one UAC)     keyboard/mouse program, RustDesk + its reach, firewall,
                            automatic sign-in, Windows Update, machines.csv
       Finish (as you)      Deskflow user settings, the 2-minute task, dev box
  +- lists every warning and failure of the three on its last page

Every 2 minutes on every PC (task "DeskConsole Deskflow trust sync", as the signed-in user):
  Setup-Synergy.ps1 -Phase TrustSync
       Deskflow trust sync          fingerprints\ -> trusted-clients / trusted-servers
       Deskflow server layout       kvm.json -> the server's layout and options
       Agent.ps1                    status\<PC>.json, own machines.csv row, client follows
                                    the server's address, commands\<PC>\ actions
```

`Setup-Synergy.ps1` can also be run on its own (`Setup-Synergy.cmd` in the shared folder); it
then elevates itself for the Admin step and passes every option on (before 1.7.0 the elevated step
silently dropped `-NoAutoRestart`, `-AutoLogon` and the dev box options).

Phases: `All` (the default: User, then Admin elevated, then Finish), `User`, `Admin`, `Finish`,
`AutoLogon` and `Updates` (Desk Console's dialogs and `Set-NoAutoRestart.cmd`; they elevate
themselves), `RemoveSynergy` (`Remove-Synergy.cmd`) and `TrustSync` (the 2-minute task).

## Why three steps

- **User before Admin:** drive mappings and saved logins belong to a logon token. A drive mapped
  from an elevated window is invisible in Explorer, and an elevated window cannot see the
  user's mapped drives -- so the user step maps, and every path handed to the elevated step is
  converted to UNC.
- **Finish after Admin:** Deskflow's per-user settings and the 2-minute task belong to the
  signed-in user, and Deskflow must be installed first.

## Every failure is reported

Each step appends `<step>|WARN|<text>` or `<step>|FAIL|<text>` to a result file for each yellow or red
line it prints, and `<step>|OK|` when it finishes (`-ResultFile`). The installer reads it on its last
page: *Installed, but N things need attention* with the lines and the log to open, or *The admin
step did not finish (Windows prompt declined or failed) -- run setup again* when the Admin step
never got to its end. Desk Console's *Automatic sign-in...* and *Windows Update...* dialogs read
the same file and show the result. With `-NoPause` (and from the installer) no step ever waits for
Enter, so a hidden step can never hang.

Within the Admin step, each part is on its own: a RustDesk install that fails (for example
*another installation is in progress* while Windows Update installs), or a firewall error, is
reported and the rest -- automatic sign-in, Windows Update, the machines.csv row -- still runs.

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
  `section: links` (neighbours) and `section: options` -- of which 1.27 reads only the hotkey
  (`keystroke`) lines; the other options live in `Deskflow.conf` too.
- **Trust without dialogs:** every PC publishes the SHA-256 of its Deskflow certificate
  (`C:\ProgramData\Deskflow\tls\deskflow.pem`) to `fingerprints\<PC>.txt` as
  `v2:sha256:<hex>`. The server's `trusted-clients` and each client's `trusted-servers` are
  filled from there. Deskflow re-reads those files on every connection, so a new client is
  accepted without a restart.
- **The 2-minute task** repeats the fingerprint exchange and, on the server, rebuilds the layout
  in the user's own `%APPDATA%\Deskflow\deskflow-server.conf` when `kvm.json` changed. Deskflow
  reads its settings only when its core starts, so after a change the task restarts the Deskflow
  window -- and only then. It reads `kvm.json` and never adds to it (only setup adds a PC to `row`).
- **Clients follow the server.** When the server's address in `machines.csv` changes, each
  client's task points `client/remoteHost` at the new one and restarts its Deskflow window --
  before, every client kept dialling the old address until setup was re-run on it.

## The 2-minute task on every PC

The same task runs on every PC, whatever the keyboard/mouse program (before 1.7.0 only on Deskflow
PCs). First it updates Desk Console on this PC when the shared folder has a newer version (then
that run ends; [Self-update](Desk-Console-App#self-update)). Besides the Deskflow steps above, it
starts or stops the RustDesk window watcher (kvm.json `hideRustDeskWindow`) and runs `Agent.ps1`,
which in under 30 seconds and without ever prompting:

1. rewrites this PC's `machines.csv` row when its address or network card changed;
2. on a Deskflow client, follows the server's address (above);
3. runs the actions queued for this PC in `commands\<PC>\` (restart, sleep, lock, sign out);
4. writes `status\<PC>.json`: version, keyboard/mouse link, automatic sign-in, Windows Update,
   pending restart, RustDesk reach, address, the last action's result.

It first checks that the shared folder's server answers (a 3-second TCP probe), so an asleep NAS
costs nothing. Steps 3 and 4 run only for the account signed in at the PC's own screen (the console
session), so a second account signed in by fast user switching does not report for the PC or run
its actions. The task never changes a PC's role: a Deskflow client is only pointed at the server's
new address, and switching a PC between server and client needs setup. Details:
[Fleet Status and Actions](Fleet-Status-and-Actions).

## Remote control (RustDesk)

Installed as a service (works at the lock screen), **direct IP access** turned on (TCP/UDP
21118), and reachable from your home network only: RustDesk's IP whitelist plus the firewall, both
from `lanCidr` ([Remote Control](Remote-Control#who-can-connect-home-network-only-or-anywhere)).
RustDesk still registers with its public ID server; the whitelist is what turns connections by ID
from outside away -- and a connection by ID that goes through RustDesk's relay is refused even from
home, so connect by address (Desk Console does). The unattended password is set from the wizard, and saved for Desk Console in
Credential Manager so *View + control* connects without asking.

## Firewall

Setup opens TCP 24800 (keyboard/mouse), TCP/UDP 21118 (RustDesk) and ping, from your home network
only, on all profiles. It also scopes the allow-any rules the RustDesk, Deskflow and Synergy
installers add for their programs -- otherwise they would let everyone in regardless -- and does so
on every Admin run, because an installer upgrade recreates them. While you are connected through
RustDesk from outside the home network, or through its relay, setup leaves all of these rules as
they are for that run rather than cut the session off. See [Security](Security#network).

## Upgrading the bundled programs

When the installer bundles a newer RustDesk or Deskflow than a PC has, the Admin step upgrades it
(not just "already installed"): the fleet stays on one version. RustDesk is not upgraded while you
are connected through it; the next setup run does it.

## Switching keyboard/mouse programs

"Switching off" Synergy or Deskflow stops and disables its service, parks its sign-in entries in
`HKLM\SOFTWARE\DeskConsole\DisabledRun` and ends its processes. Switching back restores exactly
that -- including the other program's parked entries, which setup used to wipe by recreating the
registry key. Nothing is uninstalled.

Once you no longer use Synergy, `Remove-Synergy.cmd` (one UAC prompt) uninstalls it, deletes its
firewall rules and its parked sign-in entries. It refuses while `kvm.json` still says `Synergy`,
and leaves the shared keyboard/mouse port rule alone, which Deskflow needs.
