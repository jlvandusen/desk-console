# Windows Update

PCs you reach only remotely should not restart by themselves in the middle of a build or a
session. Desk Console can set the Group Policy that makes Windows Update wait for you:

> Computer Configuration > Administrative Templates > Windows Components > Windows Update >
> **No auto-restart with logged on users for scheduled automatic updates installations** = Enabled

Updates still download and install; only the restart waits, and you restart when it suits you.
Together with [automatic sign-in](Automatic-Sign-In) someone is always signed in, so the PC never
restarts from under you.

## Turning it on

- **Installer** > *Options* page: *Windows Update: don't restart this PC by itself while someone is
  signed in* (ticked by default).
- **Desk Console** > **Windows Update...** on that PC: on, or back to the Windows default (one UAC
  prompt; the result is shown when it is done). Choose *on* again to repair an *incomplete* policy.
- **`Set-NoAutoRestart.cmd`** in the shared folder or install folder: one UAC prompt, no full
  setup. `Set-NoAutoRestart.cmd -Disable` returns to the Windows default.
- `Setup-Synergy.cmd -NoAutoRestart Enable` (or `Disable`) from a normal window: setup elevates
  itself for the Admin step and passes the option on. (Before 1.7.0 the elevation dropped it, and
  the command silently did nothing.)

Desk Console shows the state for the PC you are on (*Windows Update restarts: no automatic restart
while someone is signed in*), and every PC's card shows *update policy incomplete* or *restart
pending* from that PC's own report ([Fleet Status](Fleet-Status-and-Actions)).

## Details

- Microsoft documents that this policy only applies when **Configure Automatic Updates** is set to
  option 4 (*auto download and schedule the install*). So setup writes, under
  `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU`:

  | Value | Set to | Why |
  |---|---|---|
  | `NoAutoRebootWithLoggedOnUsers` | 1 | the policy itself |
  | `AUOptions` | 4 | what Microsoft says the policy needs |
  | `ScheduledInstallDay` | 0 | every day |
  | `ScheduledInstallTime` | 3 | 03:00 |

  The values it replaces are remembered (`AUOptionsWas`, `ScheduledInstallDayWas`,
  `ScheduledInstallTimeWas` under `HKLM\SOFTWARE\DeskConsole`) and put back when you turn it off.
  Desk Console calls the policy **complete** when both `NoAutoRebootWithLoggedOnUsers` = 1 and
  `AUOptions` = 4, **incomplete** with the first only (what versions before 1.7.0 set -- re-apply it),
  and the Windows default otherwise.
- The keys are written directly, so `gpedit.msc` still shows the policy as *Not configured* although
  it is in force. Setup changes only these values: other Windows Update policies in that key are kept
  (an earlier version recreated the key on every run, which wiped them).
- **Pro, Enterprise and Education** honour it; **Home ignores it** (setup warns).
- On a **domain-joined** PC a domain Group Policy can override it (setup warns).
- The elevated step writes its own log, `logs\<PC>-Updates.log`, with the values it read back.
- Keep restarting regularly yourself: updates that are installed but waiting for a restart are not
  protecting the PC yet. A card says *restart pending* while one waits, and its *Actions > Restart...*
  restarts that PC from any other ([Fleet Status](Fleet-Status-and-Actions#actions-restart-sleep-lock-sign-out)).
