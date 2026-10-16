# Building

## Requirements

- Windows, PowerShell 5.1+
- [Inno Setup 6](https://jrsoftware.org/isinfo.php)

## Steps

```powershell
git clone https://github.com/jlvandusen/desk-console
cd desk-console
powershell -ExecutionPolicy Bypass -File tools\Get-Redist.ps1
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\DeskConsole.iss
```

`Get-Redist.ps1` downloads RustDesk, Deskflow and the Visual C++ runtime into
`installer\redist\` and refuses any file whose SHA-256 (and, where signed, signer) does not match.
The output is `dist\DeskConsoleSetup-<version>.exe`.

If ISCC fails with *EndUpdateResource failed (110)*, the output folder is on a network drive or
being scanned: build to a local folder (`ISCC /O<local folder> ...`).

## Layout

```
src\                     what gets installed and what lives in the shared folder
  Desk-Console.ps1       the app
  Setup-Synergy.ps1      setup (User / Admin / Finish / AutoLogon / TrustSync)
  Install-DeskConsole.ps1  script-only install, self-update
  *.cmd, desk-console.ico, version.txt
installer\DeskConsole.iss  Inno Setup definition
tools\                   Get-Redist.ps1, Diag-Smb.ps1, Make-Icon.ps1
docs\wiki\               these pages
site.example.json        template for the shared folder's site.json
```

## Versions

`src\version.txt` and `$AppVersion` in `src\Desk-Console.ps1` must match; the installer takes
its version from `version.txt`. Installed copies update themselves when the shared folder's
`version.txt` is higher, so deploy the scripts **before** raising `version.txt` there.

## Deploying to a shared folder

Copy `src\*` (and `tools\` if wanted) into the shared folder with your `site.json`, copy
`version.txt` last, and put the built `DeskConsoleSetup-<version>.exe` beside them.

## Releasing

```powershell
gh release create v<version> dist\DeskConsoleSetup-<version>.exe --title "Desk Console <version>" --notes-file <notes>
```

Include the exe's SHA-256 in the notes (it is not code-signed).

## Wiki

The wiki is published from `docs\wiki\` (push those files to the `<repo>.wiki.git` repository).
