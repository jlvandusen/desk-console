# Fleet Status and Actions

Every PC reports its own state to the shared folder, so every Desk Console shows every PC as it
really is -- not just whether it answers a ping -- and can ask any PC to restart, sleep, lock or
sign out. Until 1.7.0 the dashboard knew the real state only of the PC it ran on; every other
PC's keyboard/mouse line was green whatever happened there.

## The report: `status\<PC>.json`

The 2-minute task on each PC (*DeskConsole Deskflow trust sync*, as the signed-in user; see
[How It Works](How-It-Works#the-2-minute-task-on-every-pc)) writes `status\<PC>.json` in the shared
folder:

- when anything in it changes, and at least every 4 minutes otherwise (the heartbeat);
- next to the old file first, then moved over it, so a reader never sees half a report;
- only when the shared folder's server answers (a 3-second check), so an asleep NAS costs nothing.

Desk Console treats a report **older than 6 minutes** as stale: the card says *Status N min old*
in grey and no longer vouches for that PC's keyboard/mouse link. *No report yet (agent not
running?)* means that PC has not run 1.7.x setup, or nobody is signed in there -- the task runs as
the signed-in user.

The task belongs to the account that ran setup, and it reports and runs actions only while that
account is the one at the PC's own screen (the console session; a second account signed in by
fast user switching stays quiet). So on a PC whose [automatic sign-in](Automatic-Sign-In) uses a
different account -- a dedicated `BuildRunner`, say -- run setup once while signed in as that
account, or the PC shows *No report yet* after every restart.

| Field | Meaning (`null` = unknown) |
|---|---|
| `name`, `version` | The PC, and the Desk Console version installed there |
| `updated` | When the report was written |
| `provider`, `role` | `Deskflow` / `Synergy` / `None`; `server` / `client` / `none` |
| `kvm.connected`, `kvm.peers` | Server: the client addresses connected to its port 24800. Client: connected to the server, and the server's address |
| `autoLogon` | `on`; `user` (whom Windows will sign in); `expectedUser` (the account setup set it up for); `mismatch` when those differ; `lock` (the lock task exists) |
| `legalNotice` | A sign-in notice policy is set: automatic sign-in stops at its OK button |
| `fastStartup` | Fast Startup is on: *Shut down* + power on skips the lock after an automatic sign-in |
| `rebootPending` | A restart is pending (Windows Update, servicing, or a rename) |
| `updates` | `complete`, `incomplete` or `off` -- the [Windows Update](Windows-Update) restart policy |
| `rustdeskReach` | `lan`, `anywhere` or `unknown` ([Remote Control](Remote-Control#who-can-connect-home-network-only-or-anywhere)) |
| `lastBoot`, `ip` | When Windows started; the address the PC uses on the LAN |
| `lastCommand` | `id`, `action`, `result` (`ok`, `refused`, `expired`, `failed: ...`) and `at` of the last action it ran |

No passwords. It does name the automatic sign-in account and the PC's address, like `machines.csv`.

## What a card shows

- **Online** -- ping, RustDesk's port or file sharing answers (Windows drops ping by default).
- **Keyboard + mouse** -- green or red only when someone can vouch for it. On the **server**, each
  client's line comes from the server's own connection table: *Deskflow client: connected* or *not
  connected*, and the server's own card says *Deskflow server: 2 of 3 clients*. Elsewhere it comes
  from that PC's fresh report. Anything else is grey *(state unknown)*.
- **RustDesk** -- reachable, with *(LAN only)* or *(any network)* from the report.
- **The report line** -- *Reported 1 min ago (v1.7.0)*, or the grey *Status 9 min old*.
- **Amber notes** (hover for the full text): *restart pending*, *sign-in notice* (click OK after a
  restart; RustDesk works there), *auto sign-in user changed*, *Fast Startup on*, *update policy
  incomplete*, *RustDesk: any network*, *old version 1.6.0*, *address now ...* (the PC reports another
  address than `machines.csv`), and the last action's result.
- **Buttons** -- *View + control* (while RustDesk is reachable), *Wake* (instead of it, while the PC
  is off), *Actions* (while it is online and the shared folder is reachable). The `<` `>` buttons in
  the corner move the PC left or right in the desk layout ([Keyboard and
  Mouse](Keyboard-and-Mouse#moving-and-removing-a-pc)).

The card for the PC you are on uses the same rules, from its own registry, and has no remote
buttons.

## Notifications

Closing the window keeps Desk Console running in the notification area. It shows a notification
when a PC goes offline or comes back, when a client's keyboard and mouse disconnect or reconnect,
and when the shared folder stops or starts answering -- each only after two refreshes in a row agree,
so one lost ping is not news. It can only watch while it runs: tick *Start Desk Console in the
notification area when I sign in* in the installer (it then starts with `-Tray`). Right-click the
icon > *Exit* to quit.

## Actions: Restart, Sleep, Lock, Sign out

A card's **Actions** button (any other PC):

| Action | What happens there |
|---|---|
| **Restart...** | A 60-second warning on its screen (*Desk Console: restart requested from PC-A*), then a restart; whoever sits there can still cancel with `shutdown /a` |
| **Sleep...** | It goes to sleep; wake it with *Wake* (needs Wake-on-LAN) |
| **Lock...** | Its screen locks |
| **Sign out...** | It signs out; unsaved work is lost. With automatic sign-in on, Windows signs straight back in |

Desk Console asks first, then writes `commands\<PC>\<id>.json` in the shared folder:

```json
{ "id": "<guid>", "action": "restart", "from": "PC-A",
  "created": "2026-10-17T10:00:00-04:00", "expires": "2026-10-17T10:10:00-04:00" }
```

The PC's 2-minute task picks it up within 2 minutes and reports the result in its status file,
which the card then shows (*restart: ok*). The rules, so nothing happens twice or late:

- **Ten minutes, then never.** A request that was not run within 10 minutes expires -- a PC that was
  asleep or off does not restart hours later. A restart requested before the PC's last boot is
  expired too.
- **Only these four.** Any other action is refused; a file that cannot be read is discarded.
- **Once.** The file is deleted before the action runs, so a restart cannot repeat after the
  sign-in; the same action sent twice runs once; after a restart, sleep or sign-out the rest waits
  for the next run.
- **Reported first.** Before a restart, sleep or sign-out the PC writes its report, so the card
  shows *restart: ok* even though the PC is about to go away.

With a sign-in notice on that PC, a restart stops at the notice: connect with RustDesk and click OK.
A PC whose report is missing or stale may not be running the task; Desk Console says so before
sending.

Anyone who can write `commands\` can do these four things to any PC -- the same people who can
already run code on every PC through the shared folder
([Security](Security#what-access-to-the-shared-folder-means)).

## Addresses heal themselves

- On every run, the task compares this PC's address and network card with its `machines.csv` row
  and rewrites the row when they changed: another dock, a new DHCP lease, a new USB network adapter.
  The address is the one the PC uses to reach the shared folder.
- The RustDesk ID is re-read when the address changed, or hourly, and a changed ID is written only
  after it was read the same twice in a row (a wrong ID would send the RustDesk password to someone
  else's PC).
- **Deskflow clients follow the server**: when the server's row changes, each client's task points
  its Deskflow at the new address and restarts the Deskflow window -- only then.

So when the server gets a new address, the clients are back within about 4 minutes (2 for the
server to re-register, 2 for the clients to follow), with no setup re-run. What the task changed is
in `agent.log` in the install folder.

## Wake

*Wake* sends the Wake-on-LAN packet from this PC's adapter on the target's network, to that
network's broadcast address and to 255.255.255.255, on ports 9 and 7. (It used to send one packet
out of whichever adapter Windows picked -- on a laptop with Wi-Fi on another router, often the wrong
one.) The card then watches for 2 minutes: *PC-B is awake after 34 s*, or *did not answer within 2
minutes of Wake* -- then check that Wake-on-LAN is on in that PC's BIOS and network card (USB
network adapters often cannot wake a PC).

Setup (the Admin step, 1.7.0) turns on the Windows half on each PC: *Wake on Magic Packet* on the
wired network adapter it uses for the LAN, and permission for that adapter to wake the PC
(`powercfg /deviceenablewake`). It leaves Wi-Fi adapters alone (they cannot be woken this way from
sleep or off on most PCs) and skips an adapter that is already set. Many drivers reset the network
card when *Wake on Magic Packet* changes, which would drop a RustDesk session -- so when setup runs
under one, it leaves that one change to a task that runs once at the next start, as SYSTEM, and
deletes itself (*DeskConsole Wake-on-LAN*). The BIOS / UEFI setting (*Wake on LAN*, *Power On By
PCI-E*, *Resume by LAN*...) is yours to check once.
