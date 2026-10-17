# Security policy

## Reporting a vulnerability

Please report security problems **privately**, through GitHub's private vulnerability reporting:
**[Report a vulnerability](https://github.com/jlvandusen/desk-console/security/advisories/new)**
(the repository's *Security* tab > *Report a vulnerability*). Please do not open a public issue.

Say what an attacker needs (a place on the network, access to the shared folder, an account on a
PC), what they get, and the steps. Leave your own IP addresses, RustDesk IDs and account names out.

Desk Console is maintained by one person: expect a first answer within a week. A fix ships as a new
release, and the advisory is published once it is out.

## Supported versions

Only the latest release. Installed copies update themselves from the shared folder, so a fix reaches
every PC the next time Desk Console starts there.

## Scope

In scope: the scripts in `src\`, the installer definition (`installer\DeskConsole.iss`), the tools in
`tools\` and the release workflow. The bundled programs are reported to their own projects:

- RustDesk: <https://github.com/rustdesk/rustdesk/security>
- Deskflow: <https://github.com/deskflow/deskflow/security>
- Synergy (never bundled): Symless

## Known trade-offs (documented, by design)

The wiki's [Security](https://github.com/jlvandusen/desk-console/wiki/Security) page lists each one
with its reason, and [Hardening the shared folder](https://github.com/jlvandusen/desk-console/wiki/Hardening-the-Shared-Folder)
gives the steps that contain the first. Please read them before reporting:

- Whoever can **write the shared folder** can run code on every PC (self-update and the 2-minute task
  run scripts from it). The shared folder must be writable only by you.
- The **automatic sign-in password** can be read back by any administrator of that PC (the LSA secret
  that Sysinternals Autologon also uses).
- Some passwords cross a **command line** at setup (`cmdkey`, `rustdesk --password`), and View + control
  passes the saved RustDesk password to `rustdesk.exe`.
- The installer is **not code-signed**; each release lists its SHA-256 and carries a build-provenance
  attestation (`gh attestation verify`).
