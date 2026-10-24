# Keyboard and Mouse

## Deskflow or Synergy

| | Deskflow | Synergy 3 |
|---|---|---|
| Cost | Free, open source (GPL-2.0) | Paid licence (Symless) |
| Relationship | The upstream project Synergy is built on | Commercial build with its own app and account sign-in |
| Bundled in the installer | Yes (with the Visual C++ runtime it needs) | No -- put your licensed MSI in the shared folder's `installer\` |
| Layout | Generated from `kvm.json` | Arranged in Synergy's own app (it names screens by its own IDs) |
| Pairing | Automatic (fingerprint exchange) | Synergy's own |

Choose on the installer's first page, or `Setup-Synergy.cmd -Kvm Deskflow` (or `Synergy`/`None`)
once, then run setup on each PC. The program not chosen is switched off, not uninstalled (see
[Removing Synergy](#removing-synergy) to remove it for good).

## Moving between screens

- Push the mouse off a screen edge into the neighbour from `kvm.json` (`row`, or `grid`).
- **Ctrl+Alt+Left / Ctrl+Alt+Right** jump to the screen on the left / right (with a `grid`, also
  **Ctrl+Alt+Up / Ctrl+Alt+Down**).
- **Ctrl+Alt+Shift+1** ... **9** jump straight to the 1st ... 9th PC, in the order of Desk
  Console's cards (Deskflow; `"hotkeys": false` in `kvm.json` turns these off).
- **Scroll Lock** locks the cursor to the current screen.

The hotkeys live in the server's layout file (Deskflow) or Synergy's `synergy.conf` -- Synergy's
app may rewrite that file when you change its layout; re-run setup on the server to put them back.
Desk Console's panel lists the hotkeys the server has loaded.

## Layout: a row, or a grid

`row` in `kvm.json` lists the screens left to right. For screens above and below each other, add
a `grid`: rows top to bottom, each left to right. Each row spans the full width, shared evenly
between its screens, and a screen's top or bottom edge leads to whatever overlaps it in the row
above or below. A laptop below a row of three:

```json
"grid": [ [ "BUILD-01", "DESK-SERVER", "BUILD-02" ],
          [ "LAPTOP" ] ]
```

Moving down from any of the three reaches the laptop; moving up from the laptop's left, middle or
right third reaches BUILD-01, DESK-SERVER or BUILD-02. **Ctrl+Alt+Up / Ctrl+Alt+Down** then switch
rows. The grid also sets the order of Desk Console's cards and of the number hotkeys, and every PC
must be in it (setup warns about a PC that is not). See [Configuration](Configuration#kvmjson).

## Clipboard, switch delay and other options

`kvm.json` `options` sets the Deskflow server options -- clipboard sharing and its size limit, a
delay or a double tap before the mouse crosses, the heartbeat
([the list and units](Configuration#kvmjson)). The server's 2-minute task writes them into
Deskflow's settings and reloads it. Change them there rather than in Deskflow's window, which the
next sync overwrites.

## Deskflow's window

Deskflow runs from the notification area: setup starts it hidden at sign-in, so it has no taskbar
button, and closing its window keeps it running. Click its tray icon to open the window, and use
the tray icon's menu to quit it.

## Adding a PC

Run the installer on it as a **Client**. It publishes its fingerprint, trusts the server, and is
added at the **right end** of `kvm.json` `row`; within two minutes the server trusts it and adds it
to the layout. To place it elsewhere, use the arrow buttons on its card in Desk Console (below).

## Moving and removing a PC

- **Moving:** the `<` and `>` buttons in the corner of each Desk Console card swap that PC with its
  neighbour in `row` (*Layout saved -- the server applies it within 2 minutes*). They are off while
  `kvm.json` has a `grid`: edit the grid instead.
- **Removing** a PC from the layout: take it out of `row` (or `grid`). It stays out -- only setup
  adds a PC, the 2-minute task never puts it back (before 1.7.0 every PC's task re-added itself).
  For a PC that is gone for good, also delete its row in `machines.csv`, its `fingerprints\<PC>.txt`
  and its line in the server's `C:\ProgramData\Deskflow\tls\trusted-clients`.

## When the server's address changes

Nothing to do. The server re-registers its new address in `machines.csv` and every client's
2-minute task points its Deskflow there and restarts the Deskflow window -- within about four
minutes ([Fleet Status](Fleet-Status-and-Actions#addresses-heal-themselves)).

## Different resolutions

Deskflow does not care: each PC keeps its own screen and resolution. For viewing a PC remotely
at a different size, see [Remote Control](Remote-Control#full-screen-and-resolutions).

## Removing Synergy

Switching to Deskflow leaves Synergy installed but switched off. Once you no longer use it, run
**`Remove-Synergy.cmd`** (install folder or shared folder; one UAC prompt) on each PC:

- it refuses while `kvm.json` still says `"provider": "Synergy"`, or cannot be read;
- uninstalls the Synergy MSI;
- deletes Synergy's firewall rules -- its own and Desk Console's *Synergy 3 (...)* program rules --
  but not the keyboard/mouse port rule, which Deskflow uses too (it is called *Desk Console
  keyboard/mouse (TCP 24800, LAN)* now, so a clean-up matching "Synergy" cannot cut Deskflow off);
- deletes Synergy's parked sign-in entries.

Then the Synergy installers in the shared folder's `installer\` can go.
