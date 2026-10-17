# Contributing

Thanks for helping. Desk Console runs with administrator rights on other people's PCs, so changes are
held to a few strict rules.

## The rules, and why

- **Windows PowerShell 5.1.** Every PC runs the PowerShell built into Windows, not PowerShell 7:
  no `??`, `?:`, `?.`, `&&`/`||` between commands, `ForEach-Object -Parallel` or other 7-only
  parameters. Scripts must still parse in 7 (CI checks both).
- **ASCII only** in `.ps1`, `.cmd` and `.iss`. Windows PowerShell 5.1 reads a script without a BOM in
  the ANSI code page, so one smart quote or arrow corrupts a string. Write `->`, `--`, `'`.
- **One version:** `src\version.txt`. Nothing else may hard-code the app version; the installer and
  the app read it, and a second copy once threatened an endless self-update loop.
- **Short functions, comments that say why** -- the incident, the measurement, the Microsoft page --
  not what the next line does.
- **Never block, never hang.** The 2-minute task and the hidden setup steps run without a window:
  no prompts there, every failure caught and written to the result file or the log.
- **No secrets on the share.** Passwords stay in Credential Manager, the LSA store or RustDesk's own
  config.

## Out of scope, by decision

So nobody spends a weekend on them: paid code signing (releases carry build provenance and
SHA-256 instead), Tailscale or other VPNs, RustDesk reachable from outside the home network by
default, restarts in a maintenance window, a web page for phones, and macOS or Linux PCs. Open an
issue first if you think one of these should change.

## Before you open a pull request

```powershell
powershell -ExecutionPolicy Bypass -File tools\Test-Repo.ps1
```

It parses every script, rejects non-ASCII bytes, checks the version, the three installed-file lists
and the bundled-installer pins (`tools\Test-Pins.ps1`), and runs PSScriptAnalyzer when it is installed.
CI runs the same on every push (`.github\workflows\ci.yml`).

Then try the change on a real PC and say in the pull request which step you ran (User, Admin, Finish,
TrustSync, the Desk Console window) and what happened. Test over a RustDesk session only when the
change cannot cut that session.

## Documentation is part of the change

- The wiki is published from `docs\wiki\`: update the page that describes the behaviour you changed, in
  the same pull request. A page says how it works **and why**.
- Add a line to `CHANGELOG.md` under the next version.
- The README stays short; details belong in the wiki.

## Privacy in issues and pull requests

Logs, `-Check` output, `machines.csv`, `status\*.json` and screenshots name your network: IP and MAC
addresses, RustDesk IDs, account names, the share's path. Replace them with placeholders before
posting. Report security problems privately ([SECURITY.md](SECURITY.md)).

## Releases (maintainer)

Raise `src\version.txt`, add the `## [x.y.z] - date` section to `CHANGELOG.md`, push, then push the tag
`v<x.y.z>`: `.github\workflows\release.yml` builds, hashes, attests and publishes. The wiki's Building
page has the details, including how to bump a bundled program.
