# Remote Control (RustDesk)

## How it is set up

- RustDesk is installed as a **service**, so it works at the sign-in and lock screens and UAC
  prompts can be approved remotely.
- **Direct IP access** (TCP/UDP 21118) is on; the firewall allows it from the **local subnet
  only**. On a LAN no relay or ID server is used.
- The **unattended password** comes from the installer (same on every PC is easiest). Change it
  with `Setup-Synergy.cmd -ResetRemotePassword` or RustDesk > Settings > Security.

## Connecting

Desk Console > a PC's **View + control** (or *Connect all*). Or in RustDesk, type the PC's IP from
`machines.csv` into *Control Remote Desktop*. Save the password once in Desk Console
(*RustDesk password...*) and connections stop asking.

Setup never restarts RustDesk while someone is connected through it, so you can re-run the
installer on a PC from a RustDesk session.

## Full screen and resolutions

In the RustDesk session toolbar:

1. **Display > Resolution** -- pick the remote PC's best mode (RustDesk can change it).
2. **Display > View style > Scale adaptive**.
3. **Fullscreen**.

Make *Scale adaptive* the default: RustDesk > Settings > Display > Default view style.

If your local monitor's shape differs from the remote's (an ultrawide 3440×1440 viewing a
2560×1440 PC), you get black bars at the sides at full height -- sharp, one-to-one. Options to
fill the width:

- An **HDMI/DisplayPort display emulator ("dummy plug")** on the remote PC that reports the
  size you want -- Windows only offers modes the attached display reports.
- RustDesk's **virtual display** -- but its driver (Amyuni) offers only 1024×768, 1360×768,
  1440×900, 1600×900, 1600×1200, 1920×1080, 1920×1200, 2560×1440 and 3840×2160; no ultrawide modes.

## File transfer

RustDesk > enter the IP > **File Transfer**: both PCs' drives side by side, no shares needed.
