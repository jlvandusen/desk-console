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
once, then run setup on each PC. The program not chosen is switched off, not uninstalled.

## Moving between screens

- Push the mouse off a screen edge into the neighbour from `kvm.json` `row`.
- **Ctrl+Alt+Left / Ctrl+Alt+Right** jump to the screen on the left / right.
- **Scroll Lock** locks the cursor to the current screen.

The hotkeys live in the server's layout file (Deskflow) or Synergy's `synergy.conf` -- Synergy's
app may rewrite that file when you change its layout; re-run setup on the server to put them back.

## Adding a PC

Run the installer on it as a **Client**. It publishes its fingerprint, trusts the server, and
appears on the server's right within two minutes. To place it elsewhere, reorder `row` in
`kvm.json`.

## Different resolutions

Deskflow does not care: each PC keeps its own screen and resolution. For viewing a PC remotely
at a different size, see [Remote Control](Remote-Control#full-screen-and-resolutions).
