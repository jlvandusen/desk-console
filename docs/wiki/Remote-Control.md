# Remote Control (RustDesk)

## How it is set up

- RustDesk is installed as a **service**, so it works at the sign-in and lock screens, and UAC
  prompts can be approved remotely.
- **Direct IP access** (TCP/UDP 21118) is on: Desk Console and phones connect to a PC by its
  address, with no relay in between.
- **Reach: your home network only** (the default since 1.7.0) -- see below.
- The **unattended password** comes from the installer (the same on every PC is easiest). Change it
  with `Setup-Synergy.cmd -ResetRemotePassword` or RustDesk > Settings > Security. The installer also
  saves it for Desk Console, so *View + control* connects without asking.
- Setup **upgrades RustDesk** when the installer bundles a newer version -- but never while you are
  connected through it (the upgrade waits for the next setup run).

## Who can connect: home network only, or anywhere

RustDesk always registers each PC with RustDesk's public ID server, and a PC also accepts
connections **by its ID** relayed through RustDesk's servers -- from anywhere on the internet, by
anyone who knows the ID and the password. The firewall cannot stop that: a relayed connection is
one the PC opens itself. (Versions before 1.7.0 said "LAN only" here; that was not true.)

So setup sets RustDesk's **IP whitelist** to your home network. RustDesk checks the address of every
incoming connection against it -- relayed ones too, by the address RustDesk's server saw -- before
the password is asked, and turns everything else away with *Your ip is blocked by the peer*. Desk
Console, the other PCs and phones on your Wi-Fi are inside it. The PCs stay registered with the ID
server; that no longer lets anyone in from outside.

**At home, connect by address, not by ID.** A connection by ID that RustDesk routes through its
relay is refused too, even from the next room: the address RustDesk's server saw is your router's
public one, which is not in the whitelist. A direct connection by IP address (21118) always works
inside the home network -- that is what Desk Console's *View + control* and the phone instructions
use.

| `site.json` | What setup does |
|---|---|
| nothing, or `"rustdeskReach": "lan"` | Whitelist = `lanCidr`; when `lanCidr` is absent, the network of this PC's own address (for example `192.168.1.0/24`) |
| `"lanCidr": "192.168.1.0/24"`, or a list `[ "192.168.1.0/24", "192.168.2.0/24" ]` | Those ranges -- add a second router's network here if its phones or PCs should connect |
| `"rustdeskReach": "anywhere"` | Clears the whitelist: reachable by ID and password from the internet again |

- The whitelist is applied by every Admin step (installer, *Repair / update this PC*) and recorded
  in `HKLM\SOFTWARE\DeskConsole` (`RustDeskReach`, `RustDeskWhitelist`). Each PC's
  [status report](Fleet-Status-and-Actions) shows its reach, so a card tells you when a PC is still
  open to the internet.
- **It never locks you out.** Setup is often run over a RustDesk session. If you are connected
  through RustDesk from an address the new whitelist would refuse -- or through RustDesk's relay,
  where the PC cannot see the address -- setup leaves the whitelist as it is and warns instead (run
  it again at the PC, or over a direct-IP connection from Desk Console); and it never restarts
  RustDesk while a session is open. The firewall scope (below) is held back the same way for that
  run.
- **Without `lanCidr`**, setup works the home network out from this PC's address only when that is
  a plausible home network (a prefix from /8 to /30) **and** the shared folder's server is inside
  it. Otherwise -- a laptop on someone else's Wi-Fi, a VPN address, a second router -- it sets no
  whitelist, keeps the firewall at *local subnet* and asks you to set `lanCidr` in `site.json`.
- **Check it** from outside: a phone on mobile data (Wi-Fi off), connecting by the PC's RustDesk ID,
  must get *Your ip is blocked by the peer*.

The firewall is scoped the same way: RustDesk's port 21118 -- and the allow-any rules RustDesk's own
installer adds -- accept only addresses in `lanCidr` (or the local subnet). See
[Security](Security#network).

## Connecting

Desk Console > a PC's **View + control** (or *Connect all*). Or in RustDesk, type the PC's address
from `machines.csv` into *Control Remote Desktop*. If the password was not saved by the installer,
save it once in Desk Console (*RustDesk password...*) and connections stop asking.

Desk Console hands the saved password to `rustdesk.exe` on its command line when it opens a
connection; other programs running as you can see that command line (see
[Security](Security#passwords-on-command-lines)).

Setup never restarts RustDesk while someone is connected through it, so you can re-run the
installer on a PC from a RustDesk session.

## From a phone or tablet

RustDesk has Android and iOS apps, so you can control the PCs from a phone -- a foldable unfolded
is close to a small tablet.

- **Installer** > *Phone or tablet* page and **Desk Console** > **Phone / tablet...** show QR codes:
  scan with the phone's camera to open the download.
  - **Android:** RustDesk is **not on Google Play** (it was removed in 2023). Install the APK from
    RustDesk's GitHub release (the QR code links the arm64 APK of the same version the PCs run) or
    from [F-Droid](https://f-droid.org/packages/com.carriez.flutter_hbb/). Android asks you to allow
    the browser to install apps.
  - **iPhone / iPad:** [App Store](https://apps.apple.com/app/rustdesk-remote-desktop/id1581225015).
- Put the phone on the **same network as the PCs**. The whitelist and the firewall accept your home
  network only, so a phone on a guest network or a second router's Wi-Fi cannot connect unless that
  network is in `lanCidr`. Desk Console's dialog shows the address prefix to expect and every PC's
  address.
- In RustDesk, type a PC's address, connect with the RustDesk password and add it to Favourites.
- Unfolded and sideways with *Display > Scale adaptive* works best. Touch mode taps to click; mouse
  mode behaves like a trackpad. A Bluetooth keyboard and mouse paired with the phone work too.
- PC addresses can change (a new DHCP lease, another dock): each PC re-registers its address within
  two minutes ([Fleet Status](Fleet-Status-and-Actions#addresses-heal-themselves)), so the list in
  Desk Console stays right; the Favourites in the phone do not. Router DHCP reservations avoid that.

Away from home is not supported: it would need a private network between your devices rather than
RustDesk's public ID service (`"rustdeskReach": "anywhere"` reopens that, with the password as the
only protection).

## Full screen and resolutions

In the RustDesk session toolbar:

1. **Display > Resolution** -- pick the remote PC's best mode (RustDesk can change it).
2. **Display > View style > Scale adaptive**.
3. **Fullscreen**.

Make *Scale adaptive* the default: RustDesk > Settings > Display > Default view style.

If your local monitor's shape differs from the remote's (an ultrawide 3440x1440 viewing a
2560x1440 PC), you get black bars at the sides at full height -- sharp, one-to-one. Options to
fill the width:

- An **HDMI/DisplayPort display emulator ("dummy plug")** on the remote PC that reports the
  size you want -- Windows only offers modes the attached display reports.
- RustDesk's **virtual display** -- but its driver (Amyuni) offers only 1024x768, 1360x768,
  1440x900, 1600x900, 1600x1200, 1920x1080, 1920x1200, 2560x1440 and 3840x2160; no ultrawide modes.

## File transfer

RustDesk > enter the address > **File Transfer**: both PCs' drives side by side, no shares needed.
