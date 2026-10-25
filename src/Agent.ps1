<#
  Agent.ps1 -- what every PC does every 2 minutes, as the signed-in user (no admin, no window).

  Setup-Synergy.ps1 -Phase TrustSync (the 'DeskConsole Deskflow trust sync' task, registered for
  every provider) dot-sources this file after the Deskflow trust and layout sync:
      $ag = Join-Path $PSScriptRoot 'Agent.ps1'; if (Test-Path $ag) { . $ag; Invoke-DeskAgent }
  It uses only what Setup-Synergy guarantees (spec contract C-10): Get-Kvm, Get-DeskflowValues
  -NoAppend, Set-Ini, Find-Exe, Get-PreferredIPv4, Update-MachineRow, $Root, $Me, $DeskflowDir,
  $InstallDir, $RustDeskExe. Every name defined here contains "DeskAgent" and nothing runs at
  dot-source time, so loading it cannot replace anything of Setup-Synergy's.

  Each run, every step on its own (a failure is logged and the next step still runs):
    1. registration self-heal -- this PC's address or network card changed (another dock, a new
       DHCP lease): rewrite its machines.csv row, so View + control, Wake and the clients follow.
       RustDesk's id is re-read only when the address changed, or hourly.
    2. client reconcile (Deskflow clients) -- %APPDATA%\Deskflow\Deskflow.conf client/remoteHost
       follows the server's machines.csv address (coreMode is never changed: a role change needs setup); the Deskflow
       window is restarted only when something changed. Before this, a server that moved
       left every client dialling the old address until setup was re-run on each client.
    3. command queue -- commands\<PC>\<id>.json from Desk Console (restart, sleep, lock, signout;
       anything else is refused), oldest first, each at most once, within its 10 minutes.
    4. heartbeat -- status\<PC>.json (written as .tmp, then moved over) when anything but
       "updated" changed, else every 4 minutes: Desk Console greys a status older than 6.
  It never throws, never prompts and keeps well under 30 s (the task stops it at 1 minute).
  Invoke-DeskAgent -DryRun computes everything, prints the status JSON and what it would do,
  and writes nothing: no share file, no Deskflow change, no command, no local state, and it does
  not run rustdesk.exe (--get-id rewrites RustDesk's own per-user config).
  Local state (when RustDesk's id was last read) and a log of what the agent changed: agent.json
  and agent.log in the install folder.
#>

function Invoke-DeskAgent {
    param([switch]$DryRun)
    $ctx = @{ DryRun = [bool]$DryRun; Sw = [Diagnostics.Stopwatch]::StartNew(); State = @{}; StateDirty = $false
              Lines = New-Object Collections.Generic.List[string]; Events = New-Object Collections.Generic.List[string] }
    try {
        Initialize-DeskAgent $ctx
        if ($ctx.ShareOk) {
            # Only the console user reports and runs commands: with two users signed in (console +
            # remote desktop) both tasks would write one status file from different views, and a
            # queued lock or sign-out would hit whichever session got there first.
            $steps = @('Update-DeskAgentRegistration', 'Sync-DeskAgentClient')
            if ($ctx.Console) { $steps += 'Invoke-DeskAgentQueue' } else { Add-DeskAgentNote $ctx 'not the console session: status and commands left to the console user' }
            foreach ($step in $steps) {
                if ($ctx.Sw.Elapsed.TotalSeconds -gt 20) { Add-DeskAgentNote $ctx "$step skipped: out of time" -Log; continue }
                try { $null = & $step $ctx } catch { Add-DeskAgentNote $ctx "$step failed: $($_.Exception.Message)" -Log }
            }
            if ($ctx.Console) { try { Write-DeskAgentStatus $ctx } catch { Add-DeskAgentNote $ctx "status not written: $($_.Exception.Message)" -Log } }
        } elseif ($ctx.DryRun) {
            try { $ctx.Status = Get-DeskAgentStatus $ctx } catch { Add-DeskAgentNote $ctx "status: $($_.Exception.Message)" }
        }
        Save-DeskAgentState $ctx
    } catch {
        try { Add-DeskAgentNote $ctx "agent failed: $($_.Exception.Message)" -Log } catch {}
    }
    try { Complete-DeskAgent $ctx } catch {}
}

# ---------------------------------------------------------------- context
function Initialize-DeskAgent($ctx) {
    $ctx.StateDir = $env:TEMP
    if ($InstallDir -and (Test-Path -LiteralPath $InstallDir)) { $ctx.StateDir = $InstallDir }
    $st = Read-DeskAgentJson (Join-Path $ctx.StateDir 'agent.json')
    if ($st) { $ctx.State = @{ idChecked = $st.idChecked; idCandidate = $st.idCandidate } }
    $ctx.Version = Get-DeskAgentVersion
    $ctx.LastBoot = $null
    try { $ctx.LastBoot = [DateTimeOffset](Get-CimInstance Win32_OperatingSystem -Property LastBootUpTime -OperationTimeoutSec 3 -ErrorAction Stop).LastBootUpTime } catch {}
    $ctx.Lock = Test-DeskAgentTask 'DeskConsole lock after auto sign-in'
    $ctx.Console = $true   # this user is the one at the PC's own screen (RustDesk shows that screen too)
    try {
        $cu = "$((Get-CimInstance Win32_ComputerSystem -Property UserName -OperationTimeoutSec 3 -ErrorAction Stop).UserName)"
        if ($cu) { $ctx.Console = $cu -ieq "$env:USERDOMAIN\$env:USERNAME" }
    } catch {}

    $ctx.ShareOk = Test-DeskAgentShare
    if (-not $ctx.ShareOk) {
        Add-DeskAgentNote $ctx "share '$Root' is not reachable -- nothing to do this run"
        if (-not $ctx.DryRun) { return }
    }
    $ctx.IP = $null
    if (Get-Command Get-PreferredIPv4 -ErrorAction SilentlyContinue) {
        try { $ctx.IP = Get-PreferredIPv4 } catch { Add-DeskAgentNote $ctx "address: $($_.Exception.Message)" }
    }
    if (-not $ctx.ShareOk) { return }

    # Without kvm.json, Get-Kvm answers "this PC is the Deskflow server": a default for setup,
    # not a fact to report or act on (R6) -- provider and role stay unknown.
    $k = $null
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'kvm.json'))) { Add-DeskAgentNote $ctx 'kvm.json: not in the shared folder -- keyboard/mouse role unknown' }
    else { try { $k = Get-Kvm } catch { Add-DeskAgentNote $ctx "kvm.json unreadable: $($_.Exception.Message)" -Log } }
    $ctx.Kvm = $k
    $prov = ''; if ($k) { $prov = "$($k.provider)" }
    $ctx.Provider = switch -Regex ($prov) { '^deskflow$' { 'Deskflow' } '^synergy$' { 'Synergy' } '^none$' { 'None' } default { $null } }
    $ctx.Role = if (-not $k) { $null } elseif ($ctx.Provider -eq 'None') { 'none' } elseif ("$($k.server)" -eq $Me) { 'server' } else { 'client' }

    # $null = could not read it (then nothing is registered); @() = there is no file yet
    $ctx.Rows = $null; $ctx.MyRow = $null; $ctx.ServerRow = $null
    $csv = Join-Path $Root 'machines.csv'
    try {
        if (Test-Path -LiteralPath $csv) { $ctx.Rows = @(Import-Csv -LiteralPath $csv -ErrorAction Stop | Where-Object { $_.Name }) }
        else { $ctx.Rows = @() }
    } catch { Add-DeskAgentNote $ctx "machines.csv unreadable: $($_.Exception.Message)" }
    if ($null -ne $ctx.Rows) {
        $ctx.MyRow = @($ctx.Rows | Where-Object { $_.Name -eq $Me })[0]
        if ($k) { $ctx.ServerRow = @($ctx.Rows | Where-Object { $_.Name -eq "$($k.server)" })[0] }
    }

    $ctx.StatusFile = Join-Path $Root "status\$Me.json"
    $ctx.OldStatus = Read-DeskAgentJson $ctx.StatusFile
    $ctx.LastCommand = $null   # kept from the last status file until a new command runs
    if ($ctx.OldStatus -and $ctx.OldStatus.lastCommand) {
        $lc = $ctx.OldStatus.lastCommand
        $ctx.LastCommand = [ordered]@{ id = $lc.id; action = $lc.action; result = $lc.result; at = $lc.at }
    }
}

# A share host that is asleep or gone makes the first file access hang for about 40 s (R11, seen
# in Desk Console); a TCP connect with a 3 s limit answers the same question.
function Test-DeskAgentShare {
    if (-not $Root) { return $false }
    # Without a shared folder in site.json, Setup-Synergy falls back to its own folder -- the
    # install folder. Acting there would rewrite Desk Console's caches as if they were the share.
    try { if ($InstallDir -and [IO.Path]::GetFullPath("$Root").TrimEnd('\') -eq [IO.Path]::GetFullPath("$InstallDir").TrimEnd('\')) { return $false } } catch {}
    if ("$Root" -match '^\\\\([^\\]+)\\') {
        $h = $Matches[1]; $cs = @(); $ts = @()
        foreach ($port in 445, 139) {   # SMB, or NetBIOS on an old NAS
            $c = New-Object Net.Sockets.TcpClient; $cs += $c
            try { $ts += $c.ConnectAsync($h, $port) } catch {}
        }
        $t0 = [Diagnostics.Stopwatch]::StartNew()
        while ($ts.Count -and $t0.ElapsedMilliseconds -lt 3000) {
            if (@($ts | Where-Object { $_.Status -eq 'RanToCompletion' }).Count) { break }
            if (-not @($ts | Where-Object { -not $_.IsCompleted }).Count) { break }   # refused, or no such host
            Start-Sleep -Milliseconds 50
        }
        # Decided from the final state. 1.7.0 decided inside the loop, and a connect that finished
        # between its two looks ("connected?" no, "all finished?" yes) read as unreachable -- a NAS
        # answering in a millisecond lost that race often, and those runs wrote no report at all.
        $ok = [bool]@($ts | Where-Object { $_.Status -eq 'RanToCompletion' }).Count
        foreach ($c in $cs) { try { $c.Close() } catch {} }
        if (-not $ok) { return $false }
    }
    Test-Path -LiteralPath $Root
}

# ---------------------------------------------------------------- 1. registration self-heal
function Update-DeskAgentRegistration($ctx) {
    if (-not (Get-Command Update-MachineRow -ErrorAction SilentlyContinue)) { Add-DeskAgentNote $ctx 'registration: this Setup-Synergy has no Update-MachineRow -- skipped'; return }
    if ($null -eq $ctx.Rows) { Add-DeskAgentNote $ctx 'registration: machines.csv unreadable -- skipped'; return }
    $ip = $ctx.IP
    if (-not $ip -or -not "$($ip.IPAddress)") { Add-DeskAgentNote $ctx 'registration: no usable IPv4 address -- skipped'; return }
    $row = $ctx.MyRow
    $newIp = "$($ip.IPAddress)"
    $newMac = "$($ip.MAC)"; if (-not $newMac -and $row) { $newMac = "$($row.MAC)" }
    $known = ''; if ($row) { $known = "$($row.RustDeskId)".Trim() }
    $what = @()
    $ipChanged = -not $row -or "$($row.IP)" -ne $newIp
    if (-not $row) { $what += "new row $newIp" }
    else {
        if ($ipChanged) { $what += "IP $($row.IP) -> $newIp" }
        if ((ConvertTo-DeskAgentMac $row.MAC) -ne (ConvertTo-DeskAgentMac $newMac)) { $what += "MAC $($row.MAC) -> $newMac" }
    }
    $id = Get-DeskAgentRustDeskId $ctx $known $ipChanged
    if ($id -and $id -ne $known) { $what += "RustDesk id $(if ($known) { $known } else { '(none)' }) -> $id" }
    if (-not $what.Count) { Add-DeskAgentNote $ctx "registration: machines.csv row is current ($newIp)"; return }
    if ($ctx.DryRun) { Add-DeskAgentNote $ctx "registration: would update machines.csv: $($what -join ', ')"; return }
    $rid = $known; if ($id) { $rid = $id }   # never blank a known id
    $null = Update-MachineRow -IP $newIp -MAC $newMac -RustDeskId $rid
    Add-DeskAgentNote $ctx "machines.csv updated: $($what -join ', ')" -Log
}

# RustDesk's id changes only on a reinstall or reset, so --get-id runs only when the address
# changed, or hourly. RustDesk 1.5.0 (src/core_main.rs -> src/ipc.rs get_id) asks its service
# over IPC and copies the answer into this user's own RustDesk config; with no answer it returns
# whatever id that per-user config holds. A wrong id in machines.csv would send the RustDesk
# password to someone else's PC, so: only with the service running, only an id-shaped answer,
# and a known id is replaced only after the same new id was read twice in a row.
function Get-DeskAgentRustDeskId($ctx, [string]$known, [bool]$ipChanged) {
    $st = $ctx.State
    $last = ConvertTo-DeskAgentTime $st.idChecked
    $due = $ipChanged -or $st.idCandidate -or -not $last -or ([DateTimeOffset]::Now - $last).TotalMinutes -ge 60
    if (-not $due -or -not $RustDeskExe -or -not (Test-Path -LiteralPath $RustDeskExe)) { return $known }
    if ("$((Get-Service RustDesk -ErrorAction SilentlyContinue).Status)" -ne 'Running') { Add-DeskAgentNote $ctx 'rustdesk id: the RustDesk service is not running -- not asked'; return $known }
    if ($ctx.Sw.Elapsed.TotalSeconds -gt 12) { return $known }
    if ($ctx.DryRun) { Add-DeskAgentNote $ctx "rustdesk id: would run rustdesk.exe --get-id ($(if ($ipChanged) { 'address changed' } else { 'hourly check' }))"; return $known }
    $st.idChecked = [DateTimeOffset]::Now.ToString('o'); $ctx.StateDirty = $true
    $got = ''
    try { $got = "$((Invoke-DeskAgentExe $RustDeskExe '--get-id' 5000).Out)".Trim() } catch {}
    if ($got -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{5,15}$') { Add-DeskAgentNote $ctx 'rustdesk id: no id in the answer -- kept the known one'; return $known }
    if (-not $known -or $got -eq $known) { $st.idCandidate = $null; return $got }
    # A known id is never replaced from here: when RustDesk's service does not answer, --get-id
    # falls back to (and creates) an id in this user's own config, which repeats every run and
    # would pass any "seen twice" test. A real id change is picked up by setup.
    if ($st.idCandidate -ne $got) { Add-DeskAgentNote $ctx "rustdesk id: RustDesk reports $got but machines.csv has $known -- kept; run setup on this PC if the id really changed" -Log }
    $st.idCandidate = $got
    $known
}

# ---------------------------------------------------------------- 2. client reconcile
function Sync-DeskAgentClient($ctx) {
    if ($ctx.Provider -ne 'Deskflow' -or $ctx.Role -ne 'client') { Add-DeskAgentNote $ctx 'client reconcile: not a Deskflow client'; return }
    $gdv = Get-Command Get-DeskflowValues -ErrorAction SilentlyContinue
    # without -NoAppend it would add this PC to kvm.json "row" -- only setup may (C-6)
    if (-not $gdv -or -not $gdv.Parameters.ContainsKey('NoAppend')) { Add-DeskAgentNote $ctx 'client reconcile: this Setup-Synergy has no Get-DeskflowValues -NoAppend -- skipped'; return }
    $v = Get-DeskflowValues -NoAppend
    if ($v.IsServer) { return }
    $want = "$($v.Ini['client/remoteHost'])".Trim()
    if (-not $want) { Add-DeskAgentNote $ctx "client reconcile: the server $($ctx.Kvm.server) has no machines.csv address yet"; return }
    $conf = Join-Path $DeskflowDir 'Deskflow.conf'
    if (-not (Test-Path -LiteralPath $conf)) { Add-DeskAgentNote $ctx "client reconcile: no $conf yet (setup's Finish step writes it)"; return }
    $lines = @(Get-Content -LiteralPath $conf -Encoding UTF8 -ErrorAction Stop)
    $vals = [ordered]@{}; $what = @()
    $have = Get-DeskAgentIni $lines 'client' 'remoteHost'
    if ($have -ne $want) { $vals['client/remoteHost'] = $want; $what += "client/remoteHost '$have' -> '$want'" }
    # core/coreMode is never changed here: demoting a server because kvm.json names another PC,
    # with nothing promoting that PC, could leave every PC a client (keyboard/mouse down
    # everywhere) after a hand edit or a half-finished setup. A role change needs setup.
    if ((Get-DeskAgentIni $lines 'core' 'coreMode') -ne '1') { Add-DeskAgentNote $ctx 'client reconcile: Deskflow here is not in client mode -- a role change needs setup'; return }
    if (-not $vals.Count) { Add-DeskAgentNote $ctx "client reconcile: Deskflow.conf already follows the server ($want)"; return }
    if ($ctx.DryRun) { Add-DeskAgentNote $ctx "client reconcile: would set Deskflow.conf $($what -join ', ') and restart deskflow.exe"; return }
    if ($ctx.Sw.Elapsed.TotalSeconds -gt 20) { Add-DeskAgentNote $ctx 'client reconcile: out of time -- next run' -Log; return }
    # The window first: it rewrites its settings when it exits; the core reads them only at start.
    Stop-DeskAgentDeskflow
    $started = $false
    try { Set-Ini $conf $vals }
    finally { $started = Start-DeskAgentDeskflow }   # never leave the Deskflow window stopped
    Add-DeskAgentNote $ctx "Deskflow client: $($what -join ', '); deskflow.exe $(if ($started) { 'restarted' } else { 'not found' })" -Log
}

function Get-DeskAgentIni([string[]]$lines, [string]$section, [string]$key) {
    $in = $false
    foreach ($l in $lines) {
        $t = "$l".Trim()
        if ($t -match '^\[(.+)\]$') { $in = $Matches[1] -eq $section; continue }
        if ($in -and $t -match "^$([regex]::Escape($key))\s*=(.*)$") { return $Matches[1].Trim().Trim('"') }
    }
    $null
}

# Only the GUI, only in this session. Never deskflow-daemon (the service) or deskflow-core:
# killing the daemon once left keyboard sharing down until a restart.
function Stop-DeskAgentDeskflow {
    $sid = (Get-Process -Id $PID).SessionId
    foreach ($p in @(Get-Process -Name deskflow -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sid })) {
        try { $p.Kill(); [void]$p.WaitForExit(3000) } catch {}
    }
}
function Start-DeskAgentDeskflow {
    $exe = Find-Exe 'C:\Program Files\Deskflow' 'deskflow.exe'
    if ($exe) { Start-Process -FilePath $exe }
    [bool]$exe
}

# ---------------------------------------------------------------- 3. command queue
# Share write access already means running code on every PC (self-update), so this queue adds
# nothing worse as long as it can only ever do these four things. A command file is deleted
# BEFORE it runs: a restart or sign-out that ran first would otherwise run again after the
# sign-in, for as long as the command lived.
function Invoke-DeskAgentQueue($ctx) {
    $dir = Join-Path $Root "commands\$Me"
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { Add-DeskAgentNote $ctx 'commands: none'; return }
    $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction Stop | Where-Object { $_.Extension -eq '.json' } |
               Sort-Object LastWriteTimeUtc | Select-Object -First 50)
    if (-not $files.Count) { Add-DeskAgentNote $ctx 'commands: none'; return }
    $all = @(foreach ($f in $files) { Read-DeskAgentCommand $f $ctx.LastBoot })
    # clean-up first, then the real ones oldest first: the newest result is the one left in lastCommand
    $order = @($all | Where-Object { $_.State -ne 'run' }) + @($all | Where-Object { $_.State -eq 'run' } | Sort-Object When)
    $done = @{}; $stop = $false
    foreach ($c in $order) {
        if ($c.State -eq 'wait') { Add-DeskAgentNote $ctx "commands: $($c.Name) is unreadable and new (still being written?) -- next run"; continue }
        if ($c.State -eq 'run' -and $stop -and -not $done.ContainsKey($c.Action)) {
            Add-DeskAgentNote $ctx "commands: $($c.Action) ($($c.Id)) waits for the next run"; continue
        }
        if ($ctx.DryRun) {
            if ($c.State -ne 'run') { Add-DeskAgentNote $ctx "commands: would delete $($c.Name) ($($c.State))"; continue }
            if ($done.ContainsKey($c.Action)) { Add-DeskAgentNote $ctx "commands: would delete $($c.Name) (same $($c.Action) again: runs once)"; continue }
            Add-DeskAgentNote $ctx "commands: would delete $($c.Name), then run $($c.Action) from $(if ($c.From) { $c.From } else { '?' }) ($($c.Id))"
            $done[$c.Action] = 'ok'; if ($c.Action -ne 'lock') { $stop = $true }
            continue
        }
        try { Remove-Item -LiteralPath $c.Path -Force -ErrorAction Stop }
        catch { Add-DeskAgentNote $ctx "commands: cannot delete $($c.Name), so it does not run: $($_.Exception.Message)" -Log; continue }
        $res = $c.State
        if ($c.State -eq 'run') {
            if ($done.ContainsKey($c.Action)) { $res = $done[$c.Action] }   # the same button twice: once is enough
            else {
                if ($c.Action -ne 'lock') {   # the PC is about to go away: report it first
                    $ctx.LastCommand = New-DeskAgentResult $c 'ok'
                    try { Write-DeskAgentStatus $ctx -Force } catch {}
                    $stop = $true
                }
                $res = Invoke-DeskAgentAction $c.Action $c.From
                $done[$c.Action] = $res
            }
        }
        if ($ctx.LastCommand -and $ctx.LastCommand.id -eq $c.Id) { $ctx.LastCommand.result = $res }   # same "at" as the report sent before it ran
        else { $ctx.LastCommand = New-DeskAgentResult $c $res }
        Add-DeskAgentNote $ctx "command $(if ($c.Action) { $c.Action } else { '?' }) from $(if ($c.From) { $c.From } else { '?' }) ($($c.Id)): $res" -Log
    }
}

function Read-DeskAgentCommand($f, $lastBoot) {
    $j = $null
    if ($f.Length -le 64KB) { try { $j = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json } catch {} }
    $has = { param($n) $j -and $j.PSObject.Properties[$n] }
    $age = ([DateTime]::UtcNow - $f.LastWriteTimeUtc).TotalSeconds
    $id = $f.BaseName; if (& $has 'id') { $id = "$($j.id)" }
    $id = $id -replace '[^A-Za-z0-9{}-]', ''; if ($id.Length -gt 64) { $id = $id.Substring(0, 64) }
    $action = ''
    if (& $has 'action') { $action = "$($j.action)".Trim().ToLowerInvariant(); if ($action -notmatch '^[a-z]{1,20}$') { $action = 'invalid' } }
    $from = ''; if (& $has 'from') { $from = "$($j.from)" -replace '[^A-Za-z0-9._-]', '' }   # it goes into shutdown.exe's /c text
    if ($from.Length -gt 63) { $from = $from.Substring(0, 63) }
    $created = $null; if (& $has 'created') { $created = ConvertTo-DeskAgentTime $j.created }
    $expires = $null; if (& $has 'expires') { $expires = ConvertTo-DeskAgentTime $j.expires }
    if ($created) { $cap = $created.AddMinutes(11); if (-not $expires -or $expires -gt $cap) { $expires = $cap } }   # never past Desk Console's 10 minutes (+1 for clocks)
    $now = [DateTimeOffset]::Now
    $state = if (-not $action) { if ($age -lt 30) { 'wait' } else { 'expired' } }
             elseif (-not $expires -or $now -gt $expires -or (-not $created -and $age -gt 900)) { 'expired' }
             elseif ($action -notin 'restart', 'sleep', 'lock', 'signout') { 'refused' }
             elseif (($action -in @('restart', 'sleep', 'signout')) -and $created -and $lastBoot -and ($created -lt $lastBoot)) { 'expired' }   # it has restarted since: never sign out / sleep right after a reboot
             else { 'run' }
    $when = $f.LastWriteTimeUtc; if ($created) { $when = $created.UtcDateTime }
    [pscustomobject]@{ Path = $f.FullName; Name = $f.Name; Id = $id; Action = $action; From = $from; When = $when; State = $state }
}

function New-DeskAgentResult($c, [string]$result) {
    $a = $null; if ($c.Action) { $a = $c.Action }
    [ordered]@{ id = $c.Id; action = $a; result = $result; at = [DateTimeOffset]::Now.ToString('o') }
}

function Invoke-DeskAgentAction([string]$action, [string]$from) {
    $sys = Join-Path $env:WINDIR 'System32'
    if (-not $from) { $from = 'another PC' }
    try {
        switch ($action) {
            'restart' {   # 60 s: whoever sits at the PC sees why, and can still run shutdown /a
                $r = Invoke-DeskAgentExe (Join-Path $sys 'shutdown.exe') "/r /t 60 /c `"Desk Console: restart requested from $from`""
                if ($r.Code -ne 0) { return "failed: shutdown.exe exit $($r.Code)" }
            }
            'signout' {
                $r = Invoke-DeskAgentExe (Join-Path $sys 'shutdown.exe') '/l'
                if ($r.Code -ne 0) { return "failed: shutdown.exe exit $($r.Code)" }
            }
            'lock'  { [void](Invoke-DeskAgentExe (Join-Path $sys 'rundll32.exe') 'user32.dll,LockWorkStation') }
            'sleep' {
                Add-Type -AssemblyName System.Windows.Forms   # an assembly load, no compile
                if (-not [Windows.Forms.Application]::SetSuspendState('Suspend', $false, $false)) { return 'failed: Windows did not go to sleep' }
            }
            default { return 'refused' }
        }
        'ok'
    } catch { "failed: $($_.Exception.Message)" }
}

# A native program with a time limit (a hung rustdesk.exe must not eat the task's minute);
# stdout is read asynchronously so a full pipe cannot block it.
function Invoke-DeskAgentExe([string]$exe, [string]$arguments, [int]$TimeoutMs = 5000) {
    $psi = New-Object Diagnostics.ProcessStartInfo $exe, $arguments
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutMs)) { try { $p.Kill() } catch {}; return [pscustomobject]@{ Code = $null; Out = '' } }
    $text = ''; if ($out.Wait(2000)) { $text = $out.Result }
    [pscustomobject]@{ Code = $p.ExitCode; Out = $text }
}

# ---------------------------------------------------------------- 4. heartbeat
function Write-DeskAgentStatus($ctx, [switch]$Force) {
    $s = Get-DeskAgentStatus $ctx
    $ctx.Status = $s
    $old = $ctx.OldStatus
    $changed = @(foreach ($key in @($s.Keys)) {
        if ($key -eq 'updated') { continue }
        $was = $null; if ($old) { $was = $old.$key }
        if ((ConvertTo-Json -InputObject $s[$key] -Depth 5 -Compress) -ne (ConvertTo-Json -InputObject $was -Depth 5 -Compress)) { $key }
    })
    $age = $null
    if ($old) { $u = ConvertTo-DeskAgentTime $old.updated; if ($u) { $age = [DateTimeOffset]::Now - $u } }
    $why = if ($Force) { 'before a command' } elseif (-not $old) { 'new' } elseif ($changed.Count) { 'changed: ' + ($changed -join ', ') }
           elseif (-not $age -or $age.TotalMinutes -ge 3.5 -or $age.TotalSeconds -lt -60) { 'heartbeat' }
           else { $null }
    if (-not $why) { Add-DeskAgentNote $ctx "status: unchanged, $([int]$age.TotalSeconds) s old (rewritten every 4 minutes)"; return }
    $json = ConvertTo-Json -InputObject $s -Depth 6
    if ($ctx.DryRun) { Add-DeskAgentNote $ctx "status: would write status\$Me.json ($why)"; return }
    Write-DeskAgentFile $ctx.StatusFile $json
    $ctx.OldStatus = $json | ConvertFrom-Json
    Add-DeskAgentNote $ctx "status: wrote status\$Me.json ($why)"
}

# Status file fields: spec contract C-2. null = unknown.
function Get-DeskAgentStatus($ctx) {
    $lm = 'HKEY_LOCAL_MACHINE\'
    $wl = $lm + 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $dc = $lm + 'SOFTWARE\DeskConsole'
    $au = $lm + 'SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    $sy = $lm + 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'

    # Windows rewrites DefaultUserName with whoever signed in last, so another account's sign-in
    # silently retargets the next automatic one (R13): compare with what setup recorded.
    $on = "$(Get-DeskAgentReg $wl 'AutoAdminLogon')" -eq '1'
    $user = $null
    if ($on) {
        $n = "$(Get-DeskAgentReg $wl 'DefaultUserName')".Trim(); $d = "$(Get-DeskAgentReg $wl 'DefaultDomainName')".Trim()
        if ($d -eq '.') { $d = $env:COMPUTERNAME }
        if ($n -and ($n -match '[\\@]' -or -not $d)) { $user = $n } elseif ($n) { $user = "$d\$n" }
    }
    $expected = "$(Get-DeskAgentReg $dc 'AutoLogonUser')".Trim(); if (-not $expected) { $expected = $null }
    $mismatch = if (-not $on) { $false } elseif (-not $expected) { $null } else { $user -ne $expected }

    $nar = Get-DeskAgentReg $au 'NoAutoRebootWithLoggedOnUsers'; $auo = Get-DeskAgentReg $au 'AUOptions'
    $updates = if ($nar -eq 1 -and $auo -eq 4) { 'complete' } elseif ($nar -eq 1) { 'incomplete' } else { 'off' }   # C-5
    $reach = "$(Get-DeskAgentReg $dc 'RustDeskReach')".Trim().ToLowerInvariant()
    if ($reach -notin 'lan', 'anywhere') { $reach = 'unknown' }
    # Fast Startup needs hibernation: with it off, a shutdown is a real one whatever HiberbootEnabled says
    $hb  = Get-DeskAgentReg ($lm + 'SYSTEM\CurrentControlSet\Control\Session Manager\Power') 'HiberbootEnabled'
    $hib = Get-DeskAgentReg ($lm + 'SYSTEM\CurrentControlSet\Control\Power') 'HibernateEnabled'
    $notice = [bool]("$(Get-DeskAgentReg $sy 'LegalNoticeCaption')".Trim() -or "$(Get-DeskAgentReg $sy 'LegalNoticeText')".Trim())

    $conns = @()   # .NET's own TCP table: no CIM call (about 30 ms here; Get-NetTCPConnection loads a CIM module)
    try { $conns = @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpConnections()) } catch {}
    $serverIp = $null; if ($ctx.ServerRow -and "$($ctx.ServerRow.IP)") { $serverIp = "$($ctx.ServerRow.IP)" }
    $boot = $null; if ($ctx.LastBoot) { $boot = $ctx.LastBoot.ToString("yyyy-MM-dd'T'HH:mm:sszzz") }   # whole seconds: a sub-second difference is no change
    $ip = $null; if ($ctx.IP -and "$($ctx.IP.IPAddress)") { $ip = "$($ctx.IP.IPAddress)" }
    [ordered]@{
        name          = $Me
        version       = $ctx.Version
        updated       = [DateTimeOffset]::Now.ToString('o')
        provider      = $ctx.Provider
        role          = $ctx.Role
        kvm           = Get-DeskAgentKvm $ctx.Role $serverIp $conns
        autoLogon     = [ordered]@{ on = $on; user = $user; expectedUser = $expected; mismatch = $mismatch; lock = $ctx.Lock }
        legalNotice   = $notice
        fastStartup   = ($hb -eq 1 -and $hib -ne 0)
        rebootPending = Test-DeskAgentRebootPending
        updates       = $updates
        rustdeskReach = $reach
        deskflowHidden = $(if ($ctx.Provider -eq 'Deskflow') { Get-DeskAgentDeskflowHidden } else { $null })
        rustdeskWindowWatcher = Get-DeskAgentCmWatcher
        lastBoot      = $boot
        ip            = $ip
        lastCommand   = $ctx.LastCommand
    }
}

# server: the distinct client addresses connected to its port 24800; client: connected to a
# server's 24800 (Deskflow and Synergy use the same port).
function Get-DeskAgentKvm($role, $serverIp, $conns) {
    if (-not $role) { return $null }
    $est = @($conns | Where-Object { $_ -and "$($_.State)" -eq 'Established' })
    if ($role -eq 'server') {
        $peers = @($est | Where-Object { $_.LocalEndPoint.Port -eq 24800 } | ForEach-Object { ConvertTo-DeskAgentIPv4 $_.RemoteEndPoint.Address } |
                   Where-Object { $_ -and $_ -notlike '127.*' } | Sort-Object -Unique)
        return [ordered]@{ connected = ($peers.Count -gt 0); peers = $peers }
    }
    if ($role -eq 'client') {
        $peers = @(); if ($serverIp) { $peers = @("$serverIp") }
        return [ordered]@{ connected = (@($est | Where-Object { $_.RemoteEndPoint.Port -eq 24800 }).Count -gt 0); peers = $peers }
    }
    [ordered]@{ connected = $false; peers = @() }
}

function ConvertTo-DeskAgentIPv4($a) {   # "::ffff:192.168.1.5" (a dual-stack socket) -> "192.168.1.5"; IPv6 -> $null
    if (-not $a) { return $null }
    if ($a -is [Net.IPAddress] -and $a.IsIPv4MappedToIPv6) { $a = $a.MapToIPv4() }
    $s = "$a" -replace '^::ffff:', ''
    if ($s -match '^\d{1,3}(\.\d{1,3}){3}$') { return $s }
    $null
}

function Test-DeskAgentRebootPending {
    $lm = [Microsoft.Win32.Registry]::LocalMachine
    foreach ($k in 'SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
                   'SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        try { $h = $lm.OpenSubKey($k); if ($h) { $h.Close(); return $true } } catch {}
    }
    $cn = 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\ComputerName\'
    $a = Get-DeskAgentReg ($cn + 'ActiveComputerName') 'ComputerName'; $p = Get-DeskAgentReg ($cn + 'ComputerName') 'ComputerName'
    [bool]($a -and $p -and $a -ne $p)   # a rename waits for the restart
}

# ---------------------------------------------------------------- helpers
# One named value; nothing else of the key is read (Winlogon can hold a plain-text DefaultPassword).
function Get-DeskAgentReg([string]$key, [string]$name) { try { [Microsoft.Win32.Registry]::GetValue($key, $name, $null) } catch { $null } }

# $true / $false, or $null when this user cannot tell (another account's task may be unreadable).
# The Task Scheduler COM API answers in about 60 ms here; Get-ScheduledTask loads a CIM module first.
function Test-DeskAgentTask([string]$name) {
    try { $svc = New-Object -ComObject Schedule.Service; $svc.Connect() } catch { return $null }
    try { [void]$svc.GetFolder('\').GetTask($name); $true }
    catch {
        $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
        if ($e.HResult -eq -2147024894) { $false } else { $null }   # 0x80070002 = no such task
    }
}

# Deskflow starts in the notification area (gui/autoHide) -- read from the file it loads: this
# user's own if there is one, else the machine-wide one (Settings.cpp, v1.27.0). $null: neither.
function Get-DeskAgentDeskflowHidden {
    foreach ($f in (Join-Path $env:APPDATA 'Deskflow\Deskflow.conf'), 'C:\ProgramData\Deskflow\Deskflow.conf') {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $sec = ''
        foreach ($l in [IO.File]::ReadAllLines($f)) {
            if ($l -match '^\s*\[(.+)\]\s*$') { $sec = $Matches[1] }
            elseif ($sec -eq 'gui' -and $l -match '^\s*autoHide\s*=\s*(\S+)') { return $Matches[1] -eq 'true' }
        }
        return $false
    }
    $null
}
# The RustDesk window watcher task (Setup-Synergy.ps1 Sync-CmWatcher): 'running', 'stopped' or 'off'.
function Get-DeskAgentCmWatcher {
    try { $t = Get-ScheduledTask -TaskName 'DeskConsole RustDesk window watcher' -ErrorAction Stop } catch { return 'off' }
    if ("$($t.State)" -eq 'Running') { 'running' } else { 'stopped' }
}

function Get-DeskAgentVersion {   # this PC's installed Desk Console, else the copy this file came from
    $here = $null; try { $here = Split-Path -Parent ${function:Invoke-DeskAgent}.File } catch {}
    foreach ($d in @($InstallDir, $here)) {
        if (-not $d) { continue }
        try {
            $v = "$(Get-Content -LiteralPath (Join-Path $d 'version.txt') -TotalCount 1 -ErrorAction Stop)".Trim()
            if ($v -match '^\d+(\.\d+){1,3}$') { return $v }
        } catch {}
    }
    $null
}

function ConvertTo-DeskAgentTime($v) {   # ISO text (Windows PowerShell) or DateTime (PowerShell 7's ConvertFrom-Json) -> DateTimeOffset
    if ($v -is [DateTimeOffset]) { return $v }
    if ($v -is [DateTime]) { return [DateTimeOffset]$v }
    $o = [DateTimeOffset]::MinValue
    if ("$v" -and [DateTimeOffset]::TryParse("$v", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$o)) { return $o }
    $null
}

function ConvertTo-DeskAgentMac($m) { ("$m" -replace '[^0-9A-Fa-f]', '').ToUpperInvariant() }

function Read-DeskAgentJson([string]$path) {
    try { if ($path -and (Test-Path -LiteralPath $path)) { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json) } } catch {}
    $null
}

# UTF-8 with a BOM, so Windows PowerShell's Get-Content reads any non-ASCII name right (R8);
# written beside the target and moved over it, so a reader never sees half a file.
function Write-DeskAgentFile([string]$path, [string]$text) {
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$path.tmp"
    [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding $true))
    for ($i = 1; ; $i++) {
        try {   # Replace swaps in one step; Move-Item -Force deletes the target first (a reader could find no file)
            if (Test-Path -LiteralPath $path) {
                # [NullString]::Value, not $null: Windows PowerShell 5.1 hands $null to a string
                # parameter as "", which Replace rejects ("The path is not of a legal form") -- in
                # 1.7.0 every report after a PC's first one failed that way and the cards went grey.
                try { [IO.File]::Replace($tmp, $path, [NullString]::Value, $true) }
                catch { Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop }   # a share that cannot swap in one step
            }
            else { Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop }
            return
        }
        catch {   # a reader holding the old file open: try again shortly
            if ($i -ge 3) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue; throw }
            Start-Sleep -Milliseconds 300
        }
    }
}

function Save-DeskAgentState($ctx) {
    if ($ctx.DryRun -or -not $ctx.StateDirty) { return }
    try {
        $st = [ordered]@{ idChecked = $ctx.State.idChecked; idCandidate = $ctx.State.idCandidate }
        Write-DeskAgentFile (Join-Path $ctx.StateDir 'agent.json') (ConvertTo-Json -InputObject $st)
    } catch { Add-DeskAgentNote $ctx "agent.json not saved: $($_.Exception.Message)" -Log }
}

# Lines: everything, printed by -DryRun. Events: what changed or failed, appended to agent.log.
function Add-DeskAgentNote($ctx, [string]$text, [switch]$Log) {
    [void]$ctx.Lines.Add($text)
    if ($Log) { [void]$ctx.Events.Add($text) }
}

function Complete-DeskAgent($ctx) {
    if ($ctx.DryRun) {
        "Desk Console agent on $Me -- dry run: nothing written, run or restarted"
        foreach ($l in $ctx.Lines) { "  $l" }
        if ($ctx.Status) { ConvertTo-Json -InputObject $ctx.Status -Depth 6 }
        "took {0:0.00} s" -f $ctx.Sw.Elapsed.TotalSeconds
        return
    }
    if (-not $ctx.Events.Count) { return }
    $log = Join-Path $ctx.StateDir 'agent.log'
    try {
        if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 256KB) { Move-Item -LiteralPath $log -Destination "$log.old" -Force }
        $t = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -LiteralPath $log -Value @($ctx.Events | ForEach-Object { "$t  $_" }) -Encoding UTF8
    } catch {}
}
