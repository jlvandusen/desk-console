# Installation

## Before you start

- Every PC runs **Windows 10/11 x64** and is on the **same LAN** (wired is best -- see
  [Troubleshooting](Troubleshooting#a-pc-shows-offline-or-registered-the-wrong-address)).
- You have a **network share** every PC can reach. Create a folder in it, for example
  `\\nas\share\DeskConsole`. This is the **shared folder**.
- You can approve **one UAC prompt** on each PC (an administrator account).

## 1. Put the installer in the shared folder

Download `DeskConsoleSetup-<version>.exe` from the
[releases](https://github.com/jlvandusen/desk-console/releases) into the shared folder.
Running it *from* the shared folder pre-fills that folder as the location.

Optional: add a `site.json` beside it (see [Configuration](Configuration)) to save the share's
login for extra host names or to map a drive letter. With a `site.json` there, the
"Shared folder" page is skipped on every PC.

## 2. The server first

On the PC the **keyboard and mouse are plugged into**, run the installer:

| Page | Choose |
|---|---|
| Shared folder | The shared folder (pre-filled when run from it) |
| Keyboard and mouse sharing | **Deskflow** (free) -- or Synergy 3 if you own a licence and put its MSI in `installer\` |
| This PC's role | **Server** |
| Shared folder login | The share's user name and password (blank password = keep a login already saved) |
| RustDesk password | The password other PCs will use to control this one -- **use the same on every PC** |
| Automatic sign-in | See [Automatic Sign-In](Automatic-Sign-In); "Leave it as it is" is fine |
| Options | Desktop shortcut, open at sign-in, lock after automatic sign-in |

Approve the UAC prompt. A PowerShell window shows each step; setup closes it when done and
offers to open Desk Console.

## 3. Then each client

Run the same installer on each other PC and choose **Client**. Everything else as above.
Within **two minutes** of a client finishing, the server's trust sync accepts it and adds it to
the layout (to the server's **right**). Move the mouse off the server's edge to reach it.

## 4. Check

Open **Desk Console** (Start Menu). Each PC's card should say *Online: yes*, *RustDesk:
reachable*, and the server's card *Deskflow server: N connected*.

## Updating

Copy a newer `DeskConsoleSetup-<version>.exe` *and* its scripts into the shared folder (or just
the scripts and `version.txt`). Each installed Desk Console updates itself the next time it
opens. Re-running the installer on a PC is always safe -- including over a RustDesk session
(setup never restarts RustDesk while you are connected through it).

## Uninstalling

Settings > Apps > **Desk Console** removes the app, its shortcuts and the Deskflow trust-sync
task. RustDesk, Deskflow and Synergy keep their own uninstallers. Automatic sign-in is turned
off from Desk Console (*Automatic sign-in... > Turn off*) before uninstalling.
