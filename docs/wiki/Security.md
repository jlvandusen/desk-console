# Security

## What is stored where

| Secret | Where | Never |
|---|---|---|
| Shared folder login | Windows Credential Manager on each PC, one entry per `credentialHosts` name | on the share, in a file |
| RustDesk unattended password | RustDesk's own config; Desk Console's copy in Credential Manager (`DeskConsole:RustDesk`), saved by the installer or the *RustDesk password...* dialog | on the share |
| Automatic sign-in password | LSA secret `DefaultPassword` | the plain-text `Winlogon\DefaultPassword` value |

Passwords travel from the installer wizard to the script through a file in the installer's
private temp folder (deleted when setup finishes; Inno Setup removes the whole folder on exit), and
from Desk Console's dialogs through a `%TEMP%` file the elevated script deletes on reading.

`logs\` transcripts and `status\` reports contain account, PC and network names, never passwords.

### Passwords on command lines

Three places still hand a password to another program on its command line, where other programs
running as you (and administrators, and process-creation auditing or an EDR product, when one is
on) can see it:

1. **Setup saves the share login** with `cmdkey /add:<host> /user:<user> /pass:<password>`, once per
   host name (User step).
2. **Setup sets the RustDesk password** with `rustdesk.exe --password <password>` (Admin step,
   elevated), only when you typed one.
3. **Desk Console's View + control and Connect all** start
   `rustdesk.exe --connect <address> --password <saved password>` when a RustDesk password is
   saved on that PC. Remove the saved password (*RustDesk password... > Remove*) to have RustDesk
   ask instead.

On a PC where command lines are collected centrally, prefer RustDesk's own *Remember password* per
connection and keep no saved password in Desk Console.

## What access to the shared folder means

**Whoever can write the shared folder can run code as the signed-in user on every PC, and as
administrator the next time someone approves a setup prompt.** That is how updates reach the PCs:

- Each installed Desk Console checks the shared folder's `version.txt` when it starts. When it is
  higher, it runs the shared folder's `Install-DeskConsole.ps1`, which copies the shared folder's
  scripts into the install folder.
- The 2-minute task on every PC then runs the installed `Setup-Synergy.ps1` and `Agent.ps1`.
- *Repair / update this PC* runs the highest-numbered `DeskConsoleSetup-*.exe` in the shared folder;
  re-running setup, *Automatic sign-in...*, *Windows Update...* and `Remove-Synergy.cmd` run setup
  elevated after a UAC prompt.
- `commands\<PC>\` makes that PC restart, sleep, lock or sign out (those four only; anything else is
  refused, and a command expires after 10 minutes).
- `kvm.json`, `machines.csv` and `fingerprints\` decide which PC is the keyboard/mouse server, where
  the clients connect (they follow the server's address by themselves within 2 minutes) and which
  certificates Deskflow trusts -- enough to point the clients' keyboard and mouse at another machine.

Keep write access to your own accounts, and save a share-only account on the PCs instead of the
NAS administrator: [Hardening the Shared Folder](Hardening-the-Shared-Folder) has the steps and says
what that does and does not contain.

Read access shows PC names, addresses, MAC addresses, RustDesk IDs and the automatic sign-in
account names (in `machines.csv`, `status\` and `logs\`). With the RustDesk whitelist on, an ID is
of no use from outside your home network. Keep no passwords in the shared folder: every PC, and
everyone with a PC's saved login, can read every file there.

## Network

| Port | Program | Firewall rule (all profiles, from your home network only) |
|---|---|---|
| TCP 24800 | Deskflow / Synergy | *Desk Console keyboard/mouse (TCP 24800, LAN)* |
| TCP/UDP 21118 | RustDesk direct IP | *RustDesk direct IP (TCP 21118, LAN)*, *(UDP 21118, LAN)* |
| ICMPv4 echo | ping, for Desk Console's online check | *Desk Console ping (ICMPv4, LAN)* |
| any port, by program | `rustdesk.exe`, `deskflow*.exe`, `synergy*.exe` | Desk Console's program rules, and the rules the vendors' installers add (*RustDesk Service*, *Deskflow Server*, *Deskflow Client*, *Synergy Core*, *Synergy 3 Service*) |

- **Home network only** means the `lanCidr` ranges in `site.json`, or, without them, the network of
  the PC's own address; when neither can be worked out, Windows' *local subnet*.
- **The vendors' rules are scoped too.** The RustDesk, Deskflow and Synergy installers add inbound
  Allow rules for any address on every profile, and Windows lets traffic in when any one rule allows
  it -- so a "local subnet" rule beside them restricted nothing. Setup now gives those rules the same
  scope, on every Admin run, because an installer upgrade puts them back.
- **All profiles, on purpose.** A laptop often files its home network as *Public*; rules for
  *Private* only would cut it off at home. On a laptop, *local subnet* is whatever network it is on
  now -- a hotel's, a cafe's -- which is why `lanCidr` (your home ranges, wherever the laptop is) is
  the better scope there.
- **RustDesk's ID service is outside the firewall's view.** A relayed RustDesk connection is one the
  PC opens itself. RustDesk's own IP whitelist covers it
  ([Remote Control](Remote-Control#who-can-connect-home-network-only-or-anywhere)).
- The old port rule *Synergy 3 (TCP 24800, LAN)* is renamed; setup removes the old name.

Deskflow traffic is TLS-encrypted and each side only accepts fingerprints listed in its trust file,
filled from the shared folder.

## Integrity of what is installed

The installer bundles exact, hash-pinned builds: RustDesk (signed), Deskflow (upstream does not
sign; the hash is GitHub's published digest), and the Microsoft Visual C++ runtime (signed by
Microsoft). `Setup-Synergy.ps1` re-checks each SHA-256 before running it, and a build fails when the
pins disagree anywhere (`tools\Test-Pins.ps1`). Synergy's MSI, if you supply one, is hash-checked too.

The release `DeskConsoleSetup-<version>.exe` is **not code-signed**, so SmartScreen shows *unknown
publisher* (More info > Run anyway). Check its SHA-256 against the release notes. From 1.7.0 on,
releases are built by GitHub Actions from the tag and carry a build-provenance attestation:

```powershell
gh attestation verify DeskConsoleSetup-<version>.exe --repo jlvandusen/desk-console
```

The scripts in the shared folder are not signed either: their integrity is the shared folder's
permissions ([Hardening the Shared Folder](Hardening-the-Shared-Folder)).

## Automatic sign-in

- The password is stored the way Sysinternals Autologon stores it: as the LSA secret
  `DefaultPassword`. Any administrator of that PC, or any program running as SYSTEM, can read it
  back in clear. Setup warns when the account is a local administrator or a domain account: do not
  use a password you use anywhere else.
- Anyone at the PC after a restart gets that account's desktop until the screen locks; see
  [Automatic Sign-In](Automatic-Sign-In#trade-off).

## Optional changes with trade-offs

- **`tools\Diag-Smb.ps1 -Fix`** sets `LocalAccountTokenFilterPolicy = 1`, so a local administrator
  can open `\\PC\C$` over the network. It applies to **every local administrator account on that
  PC** and stays on until you run `-Undo`: any device on the LAN that knows (or has the hash of) a
  local administrator's password then gets full administrator access over the network -- the way
  attacks move from one PC to the next. RustDesk's file transfer avoids the need; if you use `-Fix`,
  run `-Undo` when you are done.
