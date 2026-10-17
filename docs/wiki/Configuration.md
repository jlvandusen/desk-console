# Configuration

All shared state lives in the **shared folder**. Each PC keeps only a copy of `site.json` (so it can
find the share) and caches of `machines.csv` and `kvm.json` (so the app works while the share is
offline).

| File | Where | Written by | Purpose |
|---|---|---|---|
| `site.json` | shared folder + each install folder | you / the installer | Where the shared folder is; share login hosts; drive mapping; RustDesk reach |
| `kvm.json` | shared folder | setup, Desk Console's move buttons | Keyboard/mouse provider, which PC is the server, screen order or grid, Deskflow options |
| `machines.csv` | shared folder | setup and the 2-minute task (each PC its own row) | Name, IP, MAC, RustDesk ID per PC |
| `fingerprints\<PC>.txt` | shared folder | setup / trust sync | Each PC's Deskflow TLS fingerprint |
| `status\<PC>.json` | shared folder | the 2-minute task on that PC | Its live state, for every other PC's Desk Console ([Fleet Status](Fleet-Status-and-Actions)) |
| `commands\<PC>\<id>.json` | shared folder | Desk Console (any PC) | A restart, sleep, lock or sign-out waiting for that PC ([Fleet Status](Fleet-Status-and-Actions#actions-restart-sleep-lock-sign-out)) |
| `logs\<PC>-<step>.log` | shared folder | setup | Full transcript of every setup run |
| `installer\` | shared folder | you | Optional: MSIs for script-only setup, and Synergy's MSI if you use Synergy |
| `DeskConsoleSetup-<version>.exe` | shared folder | you | The installer; *Repair / update this PC* runs the highest-numbered one |

Who may write which of these: [Hardening the Shared Folder](Hardening-the-Shared-Folder).

## site.json

```json
{
  "shareRoot": "\\\\nas\\share\\DeskConsole",
  "credentialHosts": [ "nas", "nas.example.lan", "10.0.0.10" ],
  "credentialUser": "deskconsole",
  "mapDrive": "Z:",
  "mapPath": "\\\\nas\\share",
  "rustdeskReach": "lan",
  "lanCidr": [ "10.0.0.0/24" ]
}
```

| Field | Required | Meaning |
|---|---|---|
| `shareRoot` | yes | The shared folder, as a UNC path (`\\server\share\folder`). A drive-letter path is converted to UNC on first run, because elevated windows cannot see mapped drives. |
| `credentialHosts` | no | Every name the share's server is reached by. Setup saves the share login in Credential Manager for each, so `\\nas`, `\\nas.example.lan` and `\\10.0.0.10` all work. Default: the server name in `shareRoot`. |
| `credentialUser` | no | Pre-fills the user name on the login page. **Use a share-only account, never the NAS administrator**: its login is saved on every PC ([Hardening](Hardening-the-Shared-Folder)). |
| `mapDrive`, `mapPath` | no | Map a drive letter (persistent, reconnects at sign-in). Leave out to skip. |
| `rustdeskReach` | no | `"lan"` (default): RustDesk accepts connections from your home network only. `"anywhere"`: also by ID from the internet. See [Remote Control](Remote-Control#who-can-connect-home-network-only-or-anywhere). |
| `lanCidr` | no | Your home network, as one range (`"192.168.1.0/24"`) or a list. Used for the RustDesk whitelist and the firewall scope. Default: the network of each PC's own address, when the shared folder's server is inside it (otherwise setup asks you to set this). Set it when the PCs or phones span two networks, or on a laptop that travels. |

Put one `site.json` in the shared folder: the installer copies it to every PC. Without it, the
installer writes a minimal one from the "Shared folder" page. **Never commit your `site.json`** --
it names your network (it is in `.gitignore`).

## kvm.json

```json
{
  "provider": "Deskflow",
  "server": "DESK-SERVER",
  "row": [ "BUILD-01", "DESK-SERVER", "BUILD-02" ],
  "hotkeys": true,
  "options": { "clipboardSharing": true, "clipboardSharingSize": 3072, "switchDelay": 250 }
}
```

- `provider` -- `Deskflow`, `Synergy` or `None`. Changing it changes **every** PC the next time
  its setup runs (the installer's first page writes it).
- `server` -- the PC with the keyboard and mouse. Setup only sets it when you choose *Server* on
  that PC; a new client never takes the role over, even when the shared folder was not readable yet.
- `row` -- screens **left to right**. A PC set up later is added at the **right end**. Reorder it
  with the arrow buttons on Desk Console's cards, or edit the list; the server's 2-minute task
  rebuilds the layout and reloads Deskflow -- no setup re-run needed. A PC you take out of `row`
  stays out (only setup adds a PC, the 2-minute task never does).
- `grid` -- optional, for screens above and below each other: rows top to bottom, each left to
  right, for example `"grid": [ [ "TOP-PC" ], [ "BUILD-01", "DESK-SERVER", "BUILD-02" ] ]`. Each row
  spans the full width, shared evenly ([how the edges link](Keyboard-and-Mouse#layout-a-row-or-a-grid)).
  When present it decides the links and the card order instead of `row`, every PC must be in it,
  and Desk Console's arrow buttons are off.
- `hotkeys` -- `true` (default): **Ctrl+Alt+Shift+1** ... **9** jump straight to the 1st ... 9th PC
  in card order, besides Ctrl+Alt+Left/Right. `false` turns the number hotkeys off.
- `options` -- Deskflow server options. Only these names are used (anything else is ignored):

  | Option | Unit | Deskflow default | Meaning |
  |---|---|---|---|
  | `clipboardSharing` | true/false | true | Copy on one PC, paste on another |
  | `clipboardSharingSize` | KB, rounded up to whole MB | 3072 (3 MB) | Largest clipboard that is shared; 0 turns clipboard sharing off |
  | `switchDelay` | ms, 0 = off | off (250 when on) | Hold the mouse at the edge this long before it crosses |
  | `switchDoubleTap` | ms, 0 = off | off (250 when on) | Cross only after tapping the edge twice within this time |
  | `heartbeat` | ms, 0 = off | off (5000 when on) | How often the server checks that clients are still there |

  Deskflow 1.27 takes these from its own settings, not from the layout file (whose options section
  it reads only for hotkeys), so the server writes them into its `Deskflow.conf` -- at setup and
  from its 2-minute task when `kvm.json` changes. Edit them here, not in Deskflow's window: the next
  sync puts `kvm.json`'s values back. A name not in the table, or a value of the wrong kind, is
  ignored with a warning in the setup log.

Saved by setup and Desk Console as plain JSON; nested `grid` and `options` survive.

## machines.csv

`Name, IP, MAC, RustDeskId, Updated`. Each PC writes its own row: at setup (Admin step) and again
from its 2-minute task whenever its address or network card changes (another dock, a new DHCP
lease), so *View + control*, *Wake* and the Deskflow clients follow it. Its RustDesk ID is re-read
when the address changed, or hourly.

The address is the one this PC uses to reach the shared folder (the route Windows picks to the
share's server); if that cannot be worked out, the first Up adapter that is not virtual (Hyper-V,
WSL, VPN), preferring one with a default gateway, then wired before Wi-Fi, then the lowest metric.
(A desktop once registered its Wi-Fi address, which sleeps; a VPN adapter would win on metric.)
A row is never written without an address. A row with the same name -- or the same MAC under an
old name, after a PC is renamed -- is replaced, not duplicated.

Desk Console reads it for the cards, *View + control* (by IP) and *Wake* (by MAC).

## status\ and commands\

Written and read by the PCs themselves; nothing to edit. Their fields and rules are on
[Fleet Status and Actions](Fleet-Status-and-Actions).

## On each PC

| What | Where | Purpose |
|---|---|---|
| Install folder | `%LOCALAPPDATA%\Programs\DeskConsole` | The app and scripts, `site.json`, the cached `machines.csv` / `kvm.json`, `agent.json` + `agent.log` (the 2-minute task's own state and changes), `devbox.json` + `devbox.log` |
| `HKLM\SOFTWARE\DeskConsole` | registry, written by setup's elevated steps | `AutoLogonUser` (the account automatic sign-in was set up for), `RustDeskReach` and `RustDeskWhitelist`, the values to restore later (`PasswordLessWas`, `HiberbootWas`, `AUOptionsWas`, `ScheduledInstallDayWas`, `ScheduledInstallTimeWas`) and `DisabledRun` (sign-in entries of a switched-off keyboard/mouse program) |
| `HKCU\Software\DeskConsole` | registry | Desk Console's own window position |
