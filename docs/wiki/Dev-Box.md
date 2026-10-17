# Dev Box

For a development PC: every time you sign in -- including after an
[automatic sign-in](Automatic-Sign-In) -- reopen VS Code on your project folder and resume your
last Claude Code conversation there.

## Turning it on

- **Installer** > *Dev box (optional)* page: tick *Reopen VS Code*, *Also open a terminal running
  claude --continue*, or both, then pick the folder. Leaving both unticked keeps the PC's current
  setting.
- **Desk Console** > **Dev box...** on that PC: the same choices, plus *Run now* (try it without
  signing out) and *Turn off*.
- **Command line** (as the user who signs in):

  ```powershell
  Start-DevBox.ps1 -Configure -Folder D:\repos\myproject -Claude          # VS Code + Claude
  Start-DevBox.ps1 -Configure -Folder D:\repos\myproject -Claude -NoCode  # Claude only
  Start-DevBox.ps1 -Disable
  ```

## What happens at sign-in

A per-user scheduled task, **DeskConsole dev box resume** (at log on, no admin), waits 20 seconds
for the desktop to settle, then:

1. **Opens VS Code** on the folder. VS Code's `window.restoreWindows` setting -- `"all"` by default --
   brings back your other windows too; configuring the dev box sets it back to `"all"` if it had
   been changed (a backup of `settings.json` is kept).
2. **Resumes Claude Code** with `claude --continue` in a terminal in that folder (a Windows
   Terminal tab when available, otherwise a PowerShell window). `--continue` picks up the most
   recent conversation in that folder. The VS Code extension does not start a chat by itself,
   so the CLI is what resumes; you can also reconnect from your phone with Remote Control.

The settings live in `devbox.json` beside `Start-DevBox.ps1` in the install folder; the last run
is logged to `devbox.log` there.

## Notes

- The task belongs to the account that set it up. If automatic sign-in uses a different account
  (for example a dedicated `BuildRunner`), set up the dev box while signed in as that account.
- With *lock the screen after automatic sign-in*, VS Code and the terminal open behind the lock
  screen and are waiting when you unlock or connect with RustDesk.
- Needs VS Code and/or the `claude` command on the PC; configuring warns if either is missing
  (it looks in PATH, `%USERPROFILE%\.local\bin` and `%APPDATA%\npm`).
