<!-- What changes, and why: the incident, measurement or request behind it. -->

## Checks

- [ ] `tools\Test-Repo.ps1` passes (parse in Windows PowerShell 5.1, ASCII only, version, installed-file lists, pins)
- [ ] Windows PowerShell 5.1 syntax only (no `??`, `?:`, `?.`, `&&`, `-Parallel`) and ASCII only in `.ps1` / `.cmd` / `.iss`
- [ ] Tried on a PC: which step (User / Admin / Finish / TrustSync / the Desk Console window) and what happened
- [ ] The docs changed with the behaviour: the page in `docs/wiki/` and a line in `CHANGELOG.md`
- [ ] No IP or MAC addresses, RustDesk IDs, account or PC names, or passwords in the diff, logs or screenshots
