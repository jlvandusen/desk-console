# Dev Box

For a development PC: every time you sign in -- including after an
[automatic sign-in](Automatic-Sign-In) -- reopen VS Code on your project folders and resume your
last Claude Code conversation in each.

## Turning it on

- **Installer** > *Dev box (optional)* page: tick *Reopen VS Code*, *Also open a terminal running
  claude --continue*, or both, then pick the folder. Leaving both unticked keeps the PC's current
  setting. (The installer sets the first folder; other folders already in the list stay.)
- **Desk Console** > **Dev box...** on that PC: a list of folders, each with *VS Code* and *claude
  --continue* ticks; *Add folder...*, *Remove*, then *Apply*, *Apply and run now* (try it without
  signing out) or *Turn off*. If VS Code or the `claude` command is not found, it says so.
- **Command line** (as the user who signs in):

  ```powershell
  Start-DevBox.ps1 -Configure -Folder D:\repos\myproject -Claude          # first folder: VS Code + Claude
  Start-DevBox.ps1 -Configure -AddFolder D:\repos\tools -Claude -NoCode   # another folder: Claude only
  Start-DevBox.ps1 -Configure -RemoveFolder D:\repos\tools
  Start-DevBox.ps1 -Configure -Items '[{"path":"D:\\repos\\app","code":true,"claude":true}]'   # the whole list
  Start-DevBox.ps1 -Disable
  Start-DevBox.ps1 -Now                                                   # what sign-in does, now
  ```

## What happens at sign-in

A per-user scheduled task, **DeskConsole dev box resume** (at log on, no admin), waits 20 seconds
for the desktop to settle, then for each folder in the list:

1. **Opens VS Code** on the folder. VS Code's `window.restoreWindows` setting -- `"all"` by default --
   brings back your other windows too; configuring the dev box sets it back to `"all"` if it had
   been changed (a backup of `settings.json` is kept).
2. **Resumes Claude Code** with `claude --continue` in that folder: one tab per folder in a Windows
   Terminal window named *devbox* (without Windows Terminal, one PowerShell window each).
   `--continue` picks up the most recent conversation in that folder. The VS Code extension does
   not start a chat by itself, so the CLI is what resumes; you can also reconnect from your phone
   with Remote Control.

A folder that is missing at sign-in (an unplugged drive) is skipped and logged; the others still
open. A folder must exist when you add it.

Each folder is opened **once**: `claude --continue` resumes the most recent conversation in its
folder, so a folder listed twice (a hand-edited `devbox.json`) would open the same conversation in
two tabs. A repeat is merged into the first entry, with both entries' ticks.

The settings live in `devbox.json` beside `Start-DevBox.ps1` in the install folder:

```json
{ "items": [ { "path": "D:\\repos\\app", "code": true, "claude": true },
             { "path": "E:\\site", "code": true, "claude": false } ],
  "delaySec": 20 }
```

`delaySec` is the wait before the first folder opens: 0 to 300 seconds (a larger value is read as
300; Windows stops a sign-in task after 10 minutes, and the folders still have to open). A 1.6.0
file (`folder`, `openCode`, `resumeClaude`) still works as the first item, and the first item is
also written in that form for older copies. Each run is logged to `devbox.log` there. A
drive root such as `D:\` works as a folder (it used to turn into `D:`, the current folder on D:).

## Notes

- The task belongs to the account that set it up. If automatic sign-in uses a different account
  (for example a dedicated `BuildRunner`), set up the dev box while signed in as that account.
- With *lock the screen after automatic sign-in*, VS Code and the terminals open behind the lock
  screen and are waiting when you unlock or connect with RustDesk.
- Needs VS Code and/or the `claude` command on the PC; configuring warns if either is missing
  (it looks in PATH, `%USERPROFILE%\.local\bin` and `%APPDATA%\npm`).
- Uninstalling Desk Console removes the task and `devbox.json` / `devbox.log`.
