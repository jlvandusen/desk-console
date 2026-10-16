# Configuration

All shared state lives in the **shared folder**. Each PC keeps only a copy of `site.json`
(so it can find the share) and a cache of `machines.csv` (so the app works while the share is
offline).

| File | Where | Written by | Purpose |
|---|---|---|---|
| `site.json` | shared folder + each install folder | you / the installer | Where the shared folder is; share login hosts; optional drive mapping |
| `kvm.json` | shared folder | setup | Keyboard/mouse provider, which PC is the server, screen order |
| `machines.csv` | shared folder | setup (each PC registers itself) | Name, IP, MAC, RustDesk ID per PC |
| `fingerprints\<PC>.txt` | shared folder | setup / trust sync | Each PC's Deskflow TLS fingerprint |
| `logs\<PC>-<step>.log` | shared folder | setup | Full transcript of every setup run |
| `installer\` | shared folder | you | Optional: MSIs for script-only setup, and Synergy's MSI if you use Synergy |

## site.json

```json
{
  "shareRoot": "\\\\nas\\share\\DeskConsole",
  "credentialHosts": [ "nas", "nas.example.lan", "10.0.0.10" ],
  "credentialUser": "admin",
  "mapDrive": "Z:",
  "mapPath": "\\\\nas\\share"
}
```

| Field | Required | Meaning |
|---|---|---|
| `shareRoot` | yes | The shared folder, as a UNC path (`\\server\share\folder`). A drive-letter path is converted to UNC on first run, because elevated windows cannot see mapped drives. |
| `credentialHosts` | no | Every name the share's server is reached by. Setup saves the share login in Credential Manager for each, so `\\nas`, `\\nas.example.lan` and `\\10.0.0.10` all work. Default: the server name in `shareRoot`. |
| `credentialUser` | no | Pre-fills the user name on the login page. |
| `mapDrive`, `mapPath` | no | Map a drive letter (persistent, reconnects at sign-in). Leave out to skip. |

Put one `site.json` in the shared folder: the installer copies it to every PC. Without it, the
installer writes a minimal one from the "Shared folder" page. **Never commit your `site.json`** --
it names your network (it is in `.gitignore`).

## kvm.json

```json
{
  "provider": "Deskflow",
  "server": "DESK-SERVER",
  "row": [ "BUILD-01", "DESK-SERVER", "BUILD-02" ]
}
```

- `provider` -- `Deskflow`, `Synergy` or `None`. Changing it changes **every** PC the next time
  its setup runs (the installer's first page writes it).
- `server` -- the PC with the keyboard and mouse.
- `row` -- screens **left to right**. A PC set up later is appended on the right. Reorder the
  list to match your desks; the server's trust sync rebuilds the layout and reloads Deskflow
  within two minutes. No setup re-run needed.

## machines.csv

`Name, IP, MAC, RustDeskId, Updated`. Each PC writes its own row during setup, choosing its
**wired** adapter with a default gateway first (a sleeping Wi-Fi address made a PC look offline).
Desk Console reads it for the cards, *View + control* (by IP) and *Wake* (by MAC).
