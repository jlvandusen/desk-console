# Third-party software

The Desk Console release installer (`DeskConsoleSetup-<version>.exe`) bundles the unmodified
installers below and runs them on the PC it sets up. Each keeps its own license; Desk Console's
MIT license does not apply to them. `tools/Get-Redist.ps1` downloads the same files from the
same sources and checks the hashes listed here (`tools/Test-Pins.ps1` keeps this table, the build
and the setup script in agreement).

| Program | Version | License | Source code / download | SHA-256 of the bundled file |
|---|---|---|---|---|
| **RustDesk** (remote desktop) | 1.5.0 | GNU AGPL-3.0 | https://github.com/rustdesk/rustdesk (tag `1.5.0`) | `624FE792AB1D76B35134DAB84BFF97A6BCD14043FFD090A2C6A2800F77580495` |
| **Deskflow** (keyboard + mouse sharing) | 1.27.0 | GNU GPL-2.0 (with OpenSSL exception) | https://github.com/deskflow/deskflow (tag `v1.27.0`) | `0CA5668C4731F5477D0B189BDB11196A2CA51281985D9D8C0757BF7F3B782D64` |
| **Microsoft Visual C++ 2015-2022 Redistributable (x64)** | 14.44.35211.0 | Microsoft Visual C++ Redistributable license terms | https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist | `CC0FF0EB1DC3F5188AE6300FAEF32BF5BEEBA4BDD6E8E445A9184072096B713B` |

**Source code.** The complete corresponding source code of RustDesk and Deskflow for these exact
versions is attached to every Desk Console release from 1.7.0 on, as
`rustdesk-<version>-source.tar.gz` and `deskflow-<version>-source.tar.gz` -- cloned from the tags
above with their git submodules (GitHub's automatic tag archives leave out RustDesk's
`libs/hbb_common`). The same source is at the tags above. Their license texts ship inside their
own installers and are installed alongside each program.

**Synergy** is commercial software from Symless and is **not** bundled or redistributed. Desk
Console can switch a PC to Synergy if you provide your own licensed installer.

RustDesk, Deskflow, Synergy and Microsoft are trademarks of their respective owners; Desk
Console is not affiliated with or endorsed by them.
