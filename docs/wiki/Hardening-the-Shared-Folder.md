# Hardening the Shared Folder

Every PC saves a login for the shared folder and updates its own scripts from it. That makes the
folder's permissions Desk Console's security boundary: **whoever can write its code runs code on
every PC** -- as the signed-in user within minutes (self-update, then the 2-minute task), and as
administrator the next time someone approves a setup prompt ([Security](Security#what-access-to-the-shared-folder-means)).
And the login the PCs save can be used by anything running on any of them.

Two changes contain that:

1. The PCs save a **share-only account** -- not the NAS administrator, and not your own account.
2. That account can **read** everything, but **change** only what the PCs write: `kvm.json`,
   `machines.csv`, `fingerprints\`, `logs\`, `status\`, `commands\`. The code -- the scripts,
   `version.txt`, `site.json`, `DeskConsoleSetup-*.exe`, `installer\`, `mobile\` -- only you can change.

## Who needs what

| Who | Where | Rights |
|---|---|---|
| **You**: your own NAS account, saved on no PC | the whole `DeskConsole` folder | Full control |
| The NAS's administrators | the whole folder | Full control (to keep managing the NAS) |
| **The share account** (for example `deskconsole`), saved on every PC | the folder, its subfolders and files | Read (read and execute) |
| The share account | the `DeskConsole` folder itself (this folder only) | Create files |
| *Creator Owner* | files in the folder (files only) | Modify |
| The share account | `kvm.json`, `machines.csv` | Modify |
| The share account | `fingerprints\`, `logs\`, `status\`, `commands\` (folder, subfolders and files) | Modify |
| Everyone else | -- | nothing |

Why each write is needed:

| Path | Written by |
|---|---|
| `kvm.json` | setup's User step (provider, server, a new PC at the end of `row`); Desk Console's `<` `>` buttons |
| `machines.csv` | setup's Admin step and every PC's 2-minute task -- each its own row, written to `machines.csv.<PC>.tmp` in the folder and then renamed over `machines.csv`, so a reader never sees half a file. That is what *Create files* and *Creator Owner* are for: a PC can create its temp file and replace `machines.csv`, and can touch no file it did not create |
| `fingerprints\<PC>.txt` | setup and the 2-minute task (Deskflow trust) |
| `logs\` | every setup run's transcript; `tools\Diag-Smb.ps1` |
| `status\<PC>.json` | the 2-minute task on that PC |
| `commands\<PC>\` | Desk Console on any PC writes a request; that PC's task deletes it |

## On a Synology NAS (DSM 7)

The names below are DSM 7's; other NAS systems have the same pieces under similar names.

1. **The account.** Control Panel > User & Group > **Create**: name `deskconsole`, a long random
   password (each PC saves it once; nobody types it again). Groups: *users* only. Shared folder
   permissions: *Read/Write* on the shared folder that holds `DeskConsole`, *No access* on every
   other. Applications: *Deny* everything except **SMB** (no DSM, File Station, FTP, ...).
2. **The folder.** File Station > right-click `DeskConsole` > Properties > **Permission**:
   - Untick **Inherit permissions from the parent folder** and remove the inherited entries, so the
     family's accounts stop having write access here. Keep or add *administrators* and **your own
     account**: Full control, applied to this folder, child folders and child files.
   - Add `deskconsole`: **Read** (traverse folders / execute files, list folders / read data, read
     attributes, read extended attributes, read permissions), applied to this folder, child folders
     and child files.
   - Add `deskconsole`: **Create files / write data**, applied to **this folder** only.
   - Add **Owner**: **Read & Write** (all write and delete rights), applied to **child files** only.
3. **The data.** Create `status` and `commands` beside `fingerprints` and `logs` if they are not
   there yet. Then for each of `kvm.json`, `machines.csv` (files) and `fingerprints`, `logs`,
   `status`, `commands` (folders): Properties > Permission > add `deskconsole`: **Read & Write**
   (for the folders: this folder, child folders and child files).
4. Leave the shared folder itself (*Control Panel > Shared Folder*) as it is: the `DeskConsole`
   folder's own permissions decide.

## On a Windows file server

In an elevated PowerShell **on the server**, with your names:

```powershell
$d   = 'D:\Shares\DeskConsole'
$me  = 'FILESERVER\you'           # you
$pcs = 'FILESERVER\deskconsole'   # the share account
icacls $d /inheritance:r /grant:r 'BUILTIN\Administrators:(OI)(CI)F' 'NT AUTHORITY\SYSTEM:(OI)(CI)F' "${me}:(OI)(CI)F" "${pcs}:(OI)(CI)RX"
icacls $d /grant "${pcs}:(WD)"          # create files in this folder (machines.csv.<PC>.tmp)
icacls $d /grant '*S-1-3-0:(OI)(IO)M'   # CREATOR OWNER: Modify on the files it creates
icacls "$d\kvm.json" "$d\machines.csv" /grant "${pcs}:M"
foreach ($s in 'fingerprints', 'logs', 'status', 'commands') {
    New-Item -ItemType Directory -Force "$d\$s" | Out-Null
    icacls "$d\$s" /grant "${pcs}:(OI)(CI)M"
}
```

The share's own permission (Share > Advanced Sharing > Permissions) can stay *Change* for
authenticated users: the folder's permissions above decide.

## Switch the PCs to the share account

1. In the shared folder's `site.json` (as yourself), set `"credentialUser": "deskconsole"` -- the
   wizard then fills it in -- and make sure `shareRoot` is a `\\server\share\...` path: setup turns a
   drive-letter path into one by rewriting `site.json`, which the PCs can no longer do.
2. On each PC, from the shared folder: **`Setup-Synergy.cmd -Phase User -ResetCredential`**. It asks
   for the login and saves it for every `credentialHosts` name. (Or run the installer, *Change
   settings*, and type it on the *Shared folder login* page.)
3. **Sign out and back in** on that PC. Windows keeps its open connection to the NAS with the old
   account until then, and refuses a second login to the same server (error 1219).
4. `cmdkey /list` should now show `deskconsole` for each host.
5. If the PCs used to save the NAS administrator's login: change that password now. Any
   administrator of any of those PCs could have read it.

Keep no passwords in the shared folder (a README with a password, for instance): every PC, and
everyone with a PC's saved login, can read every file there.

## Check that it worked

On a PC, signed in as usual (the share account saved):

```powershell
$s = '\\nas\share\DeskConsole'
'x' | Set-Content "$s\logs\acl-test.txt"; Remove-Item "$s\logs\acl-test.txt"   # works
[IO.File]::Open("$s\Install-DeskConsole.ps1", 'Open', 'Write').Close()        # must fail: access denied
```

The second line only opens the file for writing (it changes nothing even if it is allowed). Then,
within 4 minutes, every card in Desk Console should say *Reported ... ago*, and *Repair / update this
PC* on one PC should end without a *machines.csv* error.

## Deploying a new version

Copy as **yourself**, not as the share account. Windows allows one login per server in a signed-in
session, so either use the NAS's web interface (File Station: upload), or open a PowerShell window
that uses your account for the network only:

```powershell
runas /netonly /user:NAS\you powershell.exe
# in that window:
Copy-Item C:\path\to\desk-console\src\* \\nas\share\DeskConsole -Recurse -Force -Exclude version.txt
Copy-Item C:\path\to\desk-console\src\version.txt \\nas\share\DeskConsole -Force   # last
```

Files that you did not put there are owned by the share account. Before deploying a release, and
before clicking *Repair / update this PC*, a quick look shows them:

```powershell
Get-ChildItem \\nas\share\DeskConsole -File | ForEach-Object { '{0,-36} {1}' -f $_.Name, (Get-Acl $_.FullName).Owner }
```

Only `machines.csv` (and a leftover `machines.csv.<PC>.tmp`) and `kvm.json` should belong to the share
account in the folder itself; everything else to you or the administrators.

## What this does not stop

- **New files.** The share account can still create files in the folder -- setup needs that for
  `machines.csv`. Someone using a PC's saved login could put a `DeskConsoleSetup-9.9.9.exe` there for
  *Repair / update this PC* to run with your UAC approval, or a script under a name a future release
  adds. That is what the owner check above is for.
- **The data.** It can still edit `kvm.json`, `machines.csv`, `fingerprints\` and `commands\`: restart,
  sleep, lock or sign out the PCs, point the clients' keyboard and mouse at a machine of its choosing,
  or fake status reports.

So the PCs themselves still need looking after. What the hardening changes is the worst case: one
PC's saved login no longer means code on every PC -- only disruption of the others.
