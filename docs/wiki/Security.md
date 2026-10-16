# Security

## What is stored where

| Secret | Where | Never |
|---|---|---|
| Shared folder login | Windows Credential Manager on each PC (`cmdkey`) | on the share, in a file, on a command line |
| RustDesk unattended password | RustDesk's own config (set via `rustdesk --password`); Desk Console's copy in Credential Manager (`DeskConsole:RustDesk`) | on the share |
| Automatic sign-in password | LSA secret `DefaultPassword` | the plain-text `Winlogon\DefaultPassword` value |

Passwords travel from the installer wizard to the script through a file in the installer's
private temp folder, deleted when setup finishes, and from Desk Console's sign-in dialog through
a `%TEMP%` file the elevated script deletes on reading -- never on a command line, where other
processes could read them.

`logs\` transcripts contain account and PC names, never passwords.

## Network

| Port | Program | Firewall rule |
|---|---|---|
| TCP 24800 | Deskflow / Synergy | local subnet only, all profiles |
| TCP/UDP 21118 | RustDesk direct IP | local subnet only |
| ICMPv4 echo | ping, for Desk Console's online check | local subnet only |

Deskflow traffic is TLS-encrypted and each side only accepts fingerprints listed in its trust
file. Those lists are filled from the shared folder, so **whoever can write the shared folder
can add a trusted Deskflow peer** -- keep the share's write access to your own accounts.

## Integrity of what is installed

The installer bundles exact, hash-pinned builds: RustDesk (signed), Deskflow (upstream does not
sign; the hash is GitHub's published digest), and the Microsoft Visual C++ runtime (signed by
Microsoft). `Setup-Synergy.ps1` re-checks each SHA-256 before running it. Synergy's MSI, if you
supply one, is hash-checked too.

The release `DeskConsoleSetup-<version>.exe` itself is **not code-signed**, so SmartScreen shows
*unknown publisher* (More info > Run anyway). Check its SHA-256 against the release notes.

## Optional changes with trade-offs

- **Automatic sign-in** -- see [Automatic Sign-In](Automatic-Sign-In#trade-off).
- **`tools\Diag-Smb.ps1 -Fix`** sets `LocalAccountTokenFilterPolicy = 1` so a local
  administrator can open `\\PC\C$` over the network. That removes remote UAC filtering for
  local accounts -- weaker against network attacks. `-Undo` restores the default. RustDesk's file
  transfer avoids the need.
