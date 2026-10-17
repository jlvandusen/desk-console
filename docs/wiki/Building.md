# Building

## Requirements

- Windows with Windows PowerShell 5.1 (built in)
- [Inno Setup 6](https://jrsoftware.org/isinfo.php) (6.7.1 is what releases are built with)
- Optional: PowerShell 7 and the PSScriptAnalyzer module, for the full set of checks; Python with
  `segno`, only to regenerate the phone QR codes

## Steps

```powershell
git clone https://github.com/jlvandusen/desk-console
cd desk-console
powershell -ExecutionPolicy Bypass -File tools\Test-Repo.ps1      # the static checks (below)
powershell -ExecutionPolicy Bypass -File tools\Get-Redist.ps1     # bundled installers, hash-checked
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\DeskConsole.iss
# -> dist\DeskConsoleSetup-<version>.exe
```

`Get-Redist.ps1` downloads RustDesk, Deskflow and the Visual C++ runtime into `installer\redist\`
and refuses any file whose SHA-256 (and, where the vendor signs, its signer) does not match. It
then runs `tools\Test-Pins.ps1`, so a build never ships a pin that setup would refuse halfway
through on a PC.

If ISCC fails with *EndUpdateResource failed (110)*, the output folder is on a network drive or
being scanned: build to a local folder (`ISCC /O<local folder> ...`).

## Layout

```
src\                       what gets installed, and what the shared folder holds
  Desk-Console.ps1         the app: window, tray icon, -Check, -Snapshot
  Setup-Synergy.ps1        setup: phases All, User, Admin, Finish, AutoLogon, Updates, RemoveSynergy
                           and TrustSync (the 2-minute task)
  Agent.ps1                what the 2-minute task does on every PC: status report, address
                           self-healing, Deskflow clients following the server, queued actions
  Install-DeskConsole.ps1  script-only install, self-update, -Uninstall
  Start-DevBox.ps1         dev box: reopen VS Code / resume Claude Code at sign-in
  Set-NoAutoRestart.cmd    Windows Update setting in one click
  Remove-Synergy.cmd       uninstall Synergy once you no longer use it
  Desk-Console.cmd, Setup-Synergy.cmd, Install-DeskConsole.cmd
                           launchers for the shared folder (not installed)
  desk-console.ico
  version.txt              THE version number (see Versions)
  whats-new.txt            what changed, for people: Desk Console shows it once after an update
  mobile\*.png             phone QR codes shown by Desk Console
installer\
  DeskConsole.iss          Inno Setup definition
  mobile\*.bmp             the same QR codes at installer size (*.png beside them: their source)
  redist\                  downloaded by Get-Redist.ps1, never committed
tools\
  Get-Redist.ps1           download + verify the bundled installers; -CheckLatest; -ListPins
  Test-Pins.ps1            the bundled versions and hashes agree everywhere (and the QR codes)
  Test-Repo.ps1            every static check, before each build and in CI
  PSScriptAnalyzerSettings.psd1
  Make-MobileQr.py, Convert-QrBmp.ps1   regenerate the QR codes (pip install segno)
  Make-Icon.ps1, Diag-Smb.ps1
.github\workflows\         ci.yml, release.yml, upstream-watch.yml
docs\wiki\                 these pages
site.example.json          template for the shared folder's site.json
CHANGELOG.md               the release notes; each release publishes its section
```

## The checks (tools\Test-Repo.ps1)

Run it before every build; CI runs it on every push. It reads files and runs nothing from `src\`.

| Check | Why |
|---|---|
| Every `*.ps1` parses with 0 errors, and no PowerShell 7-only parameter is used | The PCs run Windows PowerShell 5.1; CI parses in 5.1 **and** 7 |
| `*.ps1`, `*.cmd`, `*.iss` are ASCII only | 5.1 reads a script without a BOM in the ANSI code page: one smart quote corrupts a string |
| `src\version.txt` is the only version | A hard-coded `$AppVersion` that missed a bump would make every installed copy reinstall and relaunch itself forever, out of sight |
| The three installed-file lists agree | `DeskConsole.iss` `[Files]`, its `AppFile` list (files set aside before copying: the *file locked mid-install* fix) and `Install-DeskConsole.ps1` `$Files` (self-update); `version.txt` is copied last |
| `CHANGELOG.md` has a section for the version | The release notes come from it |
| The first line of `src\whats-new.txt` names the version, and it is ASCII | Desk Console shows it once after every update: a stale one would greet every PC with the last release's news |
| Every parameter the installer, the `.cmd` launchers and Desk Console pass to `Setup-Synergy.ps1` is one it declares (with an allowed value) | The installer runs the steps hidden: an unknown parameter would fail or be ignored with nothing on screen |
| `Setup-Synergy.ps1` still has the functions and variables `Agent.ps1` uses | The agent skips a step quietly when one is missing, which would switch address self-healing off on every PC |
| `tools\Test-Pins.ps1` | Versions, hashes, APK links and QR codes agree (below) |
| PSScriptAnalyzer, when installed | `PSUseCompatibleSyntax` for 5.1 plus every Error-severity rule. Without the module it is skipped locally; CI installs it |

## Versions

`src\version.txt` is the only place the version is written. Desk Console reads it at start, the
installer takes `AppVersion` and the exe's file version from it, and self-update compares it.
Installed copies update themselves when the shared folder's `version.txt` is higher, so deploy the
scripts **before** raising `version.txt` there.

## Bumping a bundled program

`tools\Get-Redist.ps1` `$items` decides every bundled version and hash. Change `Version`, `Tag`,
`Name`, `Url` and `Sha` there, then make the other places agree -- `tools\Test-Pins.ps1` names each
one that does not:

- `src\Setup-Synergy.ps1` `$Installers` (and `$VcRedist`): setup re-checks each hash on every PC
- `THIRD-PARTY-NOTICES.md`: version, tag, SHA-256
- RustDesk only: the phone APK links in `src\Desk-Console.ps1`, `installer\DeskConsole.iss` and
  `tools\Make-MobileQr.py`, then regenerate the QR codes: `python tools\Make-MobileQr.py`, then
  `powershell -File tools\Convert-QrBmp.ps1`

Existing PCs pick the new version up the next time setup runs there (setup upgrades a bundled
program that is older than the bundle; RustDesk not while you are connected through it).

**Is anything newer?** `tools\Get-Redist.ps1 -CheckLatest` asks GitHub (RustDesk, Deskflow) and
Microsoft's permalink (Visual C++ runtime), prints the newest beside each pin and exits 1 when one
is behind. The *Upstream watch* workflow runs it every Monday and opens one issue per component
with the checklist above. GitHub switches scheduled workflows off after 60 days without activity
in the repository; re-enable it under Actions if the issues stop.

## Releasing

Releases are built by GitHub Actions from the tag, not on a PC (`.github\workflows\release.yml`):

1. Raise `src\version.txt`, add a `## [x.y.z] - <date>` section to `CHANGELOG.md` (no addresses,
   IDs or PC names), rewrite `src\whats-new.txt` for the people using it (first line
   `Desk Console x.y.z -- what's new since <previous>`) and the wiki's *What's New* page to match,
   commit and push.
2. `git tag v<x.y.z>` and `git push origin v<x.y.z>`.

The workflow checks that the tag matches `version.txt`, runs `Test-Repo.ps1` and `Get-Redist.ps1`,
installs Inno Setup when the runner lacks it, builds the exe, zips `src\*` as
`DeskConsole-<version>-scripts.zip` (what the shared folder needs for self-update and *Repair /
update this PC*), attaches the source of the bundled RustDesk and Deskflow tags (submodules
included -- their licences make the distributor responsible for it), writes `SHA256SUMS.txt`,
attests the build provenance and publishes the release with the `CHANGELOG.md` section and the
hashes. Anyone can check that an exe came from that workflow:

```powershell
gh attestation verify DeskConsoleSetup-<version>.exe --repo jlvandusen/desk-console
```

By hand, if Actions is unavailable: build as above, then
`gh release create v<version> dist\DeskConsoleSetup-<version>.exe --title "Desk Console <version>" --notes-file <notes>`
with the exe's SHA-256 in the notes (it is not code-signed).

## CI

`.github\workflows\ci.yml` runs on every push and pull request: `Test-Repo.ps1` in Windows
PowerShell 5.1, then again in PowerShell 7 with PSScriptAnalyzer. It builds nothing.

## Deploying to a shared folder

Copy `src\*` into the shared folder **except** `version.txt`, then `version.txt` last (or unzip the
release's scripts zip the same way), and put `DeskConsoleSetup-<version>.exe` beside them -- *Repair /
update this PC* runs the highest-numbered one there. Never overwrite the shared folder's
`site.json`, `kvm.json` or `machines.csv`; they are not in `src\`. On a hardened share, copy as
your own maintainer account
([Hardening the Shared Folder](Hardening-the-Shared-Folder#deploying-a-new-version)).

## Wiki

The wiki is published from `docs\wiki\`: push those files to the `<repo>.wiki.git` repository.
Change the page in the same commit as the behaviour it describes.
