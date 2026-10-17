# Installation

## Before you start

- Every PC runs **Windows 10/11 x64** and is on the **same LAN** (wired is best -- see
  [Troubleshooting](Troubleshooting#a-pc-shows-offline-or-registered-the-wrong-address)).
- You have a **network share** every PC can reach. Create a folder in it, for example
  `\\nas\share\DeskConsole`. This is the **shared folder**. Make a **share-only account** for the
  PCs to save, rather than the NAS administrator, and keep write access to the code to yourself:
  [Hardening the Shared Folder](Hardening-the-Shared-Folder).
- You can approve **one UAC prompt** on each PC (an administrator account).

## 1. Put the installer and the scripts in the shared folder

From the [releases](https://github.com/jlvandusen/desk-console/releases), download into the
shared folder:

- `DeskConsoleSetup-<version>.exe` -- the installer. Running it *from* the shared folder pre-fills
  that folder as the location.
- `DeskConsole-<version>-scripts.zip` -- unzip it there (`version.txt` last). Installed copies
  update themselves from these scripts, and *Repair / update this PC* and the share's
  `Setup-Synergy.cmd` use them. With the installer alone, PCs only change when you run a newer
  installer on each.

Optional: add a `site.json` beside them (see [Configuration](Configuration)) to save the share's
login for extra host names, map a drive letter or name your home network (`lanCidr`). With a
`site.json` there, the "Shared folder" page is skipped on every PC.

## 2. The server first

On the PC the **keyboard and mouse are plugged into**, run the installer:

| Page | Choose |
|---|---|
| Shared folder | The shared folder (pre-filled when run from it). A folder on this PC is questioned: other PCs cannot reach it |
| Keyboard and mouse sharing | **Deskflow** (free) -- or Synergy 3 if you own a licence and put its MSI in `installer\`. Switching every PC to another program asks first |
| This PC's role | **Server**. When another PC is already the server, setup asks before taking over |
| Shared folder login | The share-only account and its password. A blank password keeps a login already saved -- if this PC cannot open the folder and you leave it blank, setup asks first |
| RustDesk password | The password other PCs will use to control this one -- **use the same on every PC**. Desk Console on this PC saves it too, so *View + control* does not ask |
| Automatic sign-in | See [Automatic Sign-In](Automatic-Sign-In); "Leave it as it is" is fine. The page says what is set now; an existing account's password is checked here |
| Dev box (optional) | Reopen VS Code / resume Claude Code at sign-in, and the folder -- see [Dev Box](Dev-Box) |
| Phone or tablet | QR codes to install RustDesk on a phone -- see [Remote Control](Remote-Control#from-a-phone-or-tablet) |
| Options | Desktop shortcut, start Desk Console in the notification area at sign-in, lock after automatic sign-in, [Windows Update](Windows-Update) restarts (ticked) |

The **Ready** page lists what setup is about to do: the shared folder, the program and this PC's
role, the logins, automatic sign-in and the dev box. Approve the UAC prompt. A PowerShell window
shows each step; setup closes it when done.

The **last page** says how it went: *Desk Console is installed*, or the problems and notes the
steps reported (the first four, and where the logs are), or *The admin step did not finish (Windows
prompt declined or failed) -- run setup again*.

## 3. Then each client

Run the same installer on each other PC and choose **Client**. Everything else as above.
Within **two minutes** of a client finishing, the server's 2-minute task trusts it and adds it to
the layout, at the **right end** of the row. Move the mouse off the server's edge to reach it, or
change its place with the arrow buttons on its card in Desk Console.

If a PC cannot read the shared folder yet when you run the wizard (no saved login), the wizard
cannot see who the server is. Choosing *Server* there then only makes this PC the server if
`kvm.json` names none yet -- a new PC can no longer take the role, or the program, over from
the rest by accident.

## 4. Check

Open **Desk Console** (Start Menu). Each PC's card should say *Online: yes*, *RustDesk:
reachable (LAN only)* and *Reported ... ago*, the server's card *Deskflow server: N of N clients*.
See [Fleet Status and Actions](Fleet-Status-and-Actions) for everything a card can say.

## Updating

Put the new `DeskConsoleSetup-<version>.exe` and the new scripts in the shared folder (scripts
first, `version.txt` last). Each installed Desk Console updates itself the next time it starts.
For new bundled programs (a newer RustDesk or Deskflow), run the new installer on each PC, or use
Desk Console > **Repair / update this PC...** there.

On a PC that is already set up the installer starts with **Update and keep this PC's settings**:
one click to the Ready page, and nothing about the PC changes except Desk Console's files and what
the admin step repairs. Choose *Change settings* for the full wizard.

Re-running the installer on a PC is always safe -- including over a RustDesk session (setup never
restarts RustDesk while you are connected through it). An older installer asks before it replaces
a newer Desk Console, and the scripts never downgrade a PC by themselves.

## Uninstalling

Settings > Apps > **Desk Console** removes the app, its shortcuts, the 2-minute task, the dev box
task and Desk Console's files in the install folder. The uninstaller is the one the last
`DeskConsoleSetup` run wrote -- a self-update does not replace it -- so on a PC set up before 1.7.0,
run the 1.7.0 installer once (*Update and keep this PC's settings*) before uninstalling; the older
uninstaller leaves both tasks behind. What stays, on purpose:

- **Automatic sign-in** and its screen lock (the uninstaller asks first when it is on): turn it off
  in Desk Console (*Automatic sign-in... > Turn off*) before uninstalling.
- RustDesk, Deskflow and Synergy, their firewall rules and the Windows Update policy (each program
  keeps its own uninstaller; `Set-NoAutoRestart.cmd -Disable` removes the policy).
- The Credential Manager entries: the share login and `DeskConsole:RustDesk`
  (`cmdkey /delete:<host>`, `cmdkey /delete:DeskConsole:RustDesk`).
- `HKLM\SOFTWARE\DeskConsole`: setup's record of what it changed on the PC.
- The PC's row in `machines.csv` and its `status\` report in the shared folder (delete them there
  when the PC is gone for good).
