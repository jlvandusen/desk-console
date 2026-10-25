<#
  Desk-Console.ps1 -- one window for every PC: the keyboard/mouse server and its clients.
  Launch with Desk-Console.cmd or the Start Menu shortcut. Flags:
    -Tray             start hidden in the notification area (the sign-in shortcut passes it)
    -Check            print the same status without a window
    -Snapshot <png>   render the window off-screen and exit (-SnapshotMobile <png>: the phone dialog)
    -Updated          internal: the self-update relaunch passes it, so a launch updates at most once

  Machines come from machines.csv in the shared folder (written by setup on each PC), the desk
  order from kvm.json (row, or grid), and each PC's own report from status\<PC>.json (written by
  its 2-minute agent). Per machine: online (ping / RustDesk / SMB), its keyboard + mouse link,
  RustDesk direct IP reachable (TCP 21118), its Desk Console version and warnings.
  "View + control" opens it in RustDesk by IP; "Wake" sends Wake-on-LAN on that PC's network;
  "Actions" queues a restart, sleep, lock or sign-out in commands\<PC>\ for that PC's agent.
  The RustDesk password is kept in THIS PC's Windows Credential Manager (DeskConsole:RustDesk),
  never on the share.
  The installed copy updates itself from the shared folder: at start, hourly while it sits in the
  notification area, and when it is opened again (update.log beside it records each update).
#>
param([switch]$Check, [string]$Snapshot, [string]$SnapshotMobile, [string]$SnapshotWhatsNew, [switch]$Tray, [switch]$Updated)
$ErrorActionPreference = 'Stop'

# site.json next to this script (install folder or shared folder) names the shared folder
function Get-DeskSite {
    foreach ($p in (Join-Path $PSScriptRoot 'site.json'), (Join-Path (Split-Path $PSScriptRoot -Parent) 'site.json')) {
        if (Test-Path $p) { try { return (Get-Content $p -Raw | ConvertFrom-Json) } catch {} }
    }
    $null
}
# An elevated window cannot see mapped drives: turn "Z:\x" into "\\server\share\x".
function ConvertTo-Unc([string]$path) {
    if ($path -match '^([A-Za-z]):(.*)$') {
        $d = Get-PSDrive -Name $Matches[1] -PSProvider FileSystem -ErrorAction SilentlyContinue
        if ($d.DisplayRoot) { return $d.DisplayRoot.TrimEnd('\') + $Matches[2] }
    }
    $path
}
$Site        = Get-DeskSite
$InstallDir  = Join-Path $env:LOCALAPPDATA 'Programs\DeskConsole'
$Root        = if ($Site.shareRoot) { ConvertTo-Unc "$($Site.shareRoot)" }
               elseif ((ConvertTo-Unc $PSScriptRoot) -ne $InstallDir) { ConvertTo-Unc $PSScriptRoot }
               else { $PSScriptRoot }
$ShareHost   = if ($Root -match '^\\\\([^\\]+)\\') { $Matches[1] } else { $null }
$Csv         = Join-Path $Root 'machines.csv'
$KvmPath     = Join-Path $Root 'kvm.json'
$StatusDir   = Join-Path $Root 'status'       # status\<PC>.json, each PC's agent report (C-2)
$CommandDir  = Join-Path $Root 'commands'     # commands\<PC>\<id>.json, run by that PC's agent (C-3)
$RustDeskExe = 'C:\Program Files\RustDesk\rustdesk.exe'
$SynergyExe  = 'C:\Program Files\Synergy\Synergy.exe'
$SynergyConf = 'C:\ProgramData\Synergy\config\synergy.conf'
$SynergyCore = 'C:\ProgramData\Synergy\config\synergy-core.conf'
$CredTarget  = 'DeskConsole:RustDesk'
$DcKey       = 'HKLM:\SOFTWARE\DeskConsole'   # written by setup: AutoLogonUser, RustDeskReach, RustDeskWhitelist
$UiKey       = 'HKCU:\Software\DeskConsole'   # this app's own settings (window position)
$LockTask    = 'DeskConsole lock after auto sign-in'
$DevTask     = 'DeskConsole dev box resume'
$Me          = $env:COMPUTERNAME
$Installed   = $PSScriptRoot -eq $InstallDir
$Headless    = [bool]($Check -or $Snapshot -or $SnapshotMobile -or $SnapshotWhatsNew)
$WhatsNewFile = Join-Path $PSScriptRoot 'whats-new.txt'   # shown once per version, and from the status bar
$ProjectUrl  = 'https://github.com/jlvandusen/desk-console'
$StaleMin    = 6        # a status report older than this is shown grey, not vouched for (C-2)
$ProbeMs     = 2000     # probe deadline (a desktop on Wi-Fi power save showed offline at 0.6 s)

# One source for the version: version.txt beside this script (the installer and the self-update
# copy it, last). A second, hard-coded copy that drifted from it would make every installed copy
# reinstall and relaunch itself forever, out of sight (E1).
function Get-AppVersion {
    try { [version](Get-Content (Join-Path $PSScriptRoot 'version.txt') -TotalCount 1 -ErrorAction Stop).Trim() }
    catch { [version]'0.0' }
}
$AppVersion = Get-AppVersion

# ---------------------------------------------------------------- one copy per sign-in
# A second launch (the Start Menu while the tray copy runs, or a double click while the hidden
# console is still starting) asks the running copy to show itself, then exits.
$script:Mutex = $null; $script:ShowEvent = $null
if (-not $Headless) {
    $script:ShowEvent = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::AutoReset, 'Local\DeskConsole.Show')
    $created = $false
    foreach ($try in 1..$(if ($Updated) { 20 } else { 1 })) {   # a self-update relaunch waits for the old copy to exit
        $script:Mutex = [Threading.Mutex]::new($true, 'Local\DeskConsole', [ref]$created)
        if ($created) { break }
        $script:Mutex.Dispose(); $script:Mutex = $null; Start-Sleep -Milliseconds 500
    }
    if (-not $created) { [void]$script:ShowEvent.Set(); return }
}

# ---------------------------------------------------------------- self-update
function Write-UpdateLog($m) {   # the relaunch is hidden: this file is the only trace of an update
    try {
        $f = Join-Path $InstallDir 'update.log'
        if ((Test-Path $f) -and (Get-Item $f).Length -gt 256KB) { Remove-Item $f -Force }
        Add-Content $f "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')  $m" -Encoding ascii
    } catch {}
}
# $true when the share host answers SMB within $Ms (or the shared folder is local). An asleep or
# offline host blocks each first SMB read for 20-40 s, and that read ran on the UI thread (R11).
function Test-ShareHost([int]$Ms = 2000) {
    if (-not $ShareHost) { return [bool](Test-Path $Root) }
    $c = New-Object Net.Sockets.TcpClient
    try { $t = $c.ConnectAsync($ShareHost, 445); [bool]($t.Wait($Ms) -and $t.Status -eq 'RanToCompletion') }
    catch { $false } finally { $c.Dispose() }
}
# The installed copy updates itself when the share's version.txt is newer: it runs the share's
# Install-DeskConsole.ps1 -Quiet, then relaunches once (-Updated). It checks before the window
# opens and again while it runs -- hourly while hidden, and when it is opened again (Request-Show).
# Since 1.7.0 closing the window only hides it and the sign-in copy starts in the tray (C-9), so a
# check at start alone left a desktop on the old version -- and with it the installed
# Setup-Synergy.ps1 and Agent.ps1 its 2-minute task runs, which only this copies -- until its next
# sign-in: weeks, on a PC with automatic sign-in and no automatic restarts.
$script:UpdateAt = [datetime]::MinValue   # the last comparison with the share's version.txt
function Invoke-SelfUpdate([string]$why, [bool]$tray) {   # $true: the new copy is starting and this one must exit
    if (-not $Installed -or $Headless) { return $false }
    $script:UpdateAt = Get-Date
    $vf = Join-Path $Root 'version.txt'
    try {
        if (-not (Test-Path -LiteralPath $vf)) { return $false }   # a shared folder without releases: nothing to log every hour
        $remote = [version](Get-Content -LiteralPath $vf -TotalCount 1 -ErrorAction Stop).Trim()
        if ($remote -le $AppVersion) { return $false }
        & (Join-Path $Root 'Install-DeskConsole.ps1') -Quiet
        $now = Get-AppVersion
        # Relaunch only once the installed version.txt has moved on (it is copied last): a copy that
        # stopped half-way is tried again by the next check, never relaunched in a loop (E1, R3).
        if ($now -le $AppVersion) { Write-UpdateLog "update to $remote from $Root ($why) left version.txt at $now -- trying again later"; return $false }
        Write-UpdateLog "updated $AppVersion -> $now from $Root ($why)"
        $a = @('--headless', 'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
               '-File', "`"$InstallDir\Desk-Console.ps1`"", '-Updated')
        if ($tray) { $a += '-Tray' }
        Start-Process (Join-Path $env:WINDIR 'System32\conhost.exe') -ArgumentList $a
        # released only now: if that start failed, this copy keeps running as the one copy; the new
        # one waits up to 10 s for the mutex
        if ($script:Mutex) { $script:Mutex.ReleaseMutex(); $script:Mutex.Dispose(); $script:Mutex = $null }
        $true
    } catch { Write-UpdateLog "update from $Root ($why) failed: $($_.Exception.Message)"; $false }
}
$script:StartShareUp = $null   # this probe, reused by the first load: an asleep share host costs 2 s once, not twice
if ($Updated) { $script:UpdateAt = Get-Date }
elseif ($Installed -and -not $Headless) {
    $script:StartShareUp = Test-ShareHost
    if ($script:StartShareUp -and (Invoke-SelfUpdate 'start' ([bool]$Tray))) { return }
}

Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class DeskWin {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int cx, uint f);
    // Visible top-level windows owned by any of the given processes.
    public static long[] ForPids(int[] pids) {
        var l = new System.Collections.Generic.List<long>();
        EnumWindows((h, p) => { uint pid; GetWindowThreadProcessId(h, out pid);
            if (IsWindowVisible(h) && Array.IndexOf(pids, (int)pid) >= 0) l.Add(h.ToInt64()); return true; }, IntPtr.Zero);
        return l.ToArray();
    }
    public static string Title(long h) { var b = new StringBuilder(256); GetWindowText((IntPtr)h, b, 256); return b.ToString(); }
    // A tool window has no taskbar button (and is not in Alt+Tab); the style only applies on a re-show.
    public static void HideFromTaskbar(long h) {
        var w = (IntPtr)h; ShowWindow(w, 0);
        SetWindowLong(w, -20, (GetWindowLong(w, -20) | 0x80) & ~0x40000);
        ShowWindow(w, 5);
    }
    public static void Activate(long h) { ShowWindow((IntPtr)h, 9); SetForegroundWindow((IntPtr)h); }
    // Restore, then fill the rectangle (maximize would pick the monitor it was last on).
    public static void Place(long h, int x, int y, int w, int ht) {
        ShowWindow((IntPtr)h, 9); SetWindowPos((IntPtr)h, IntPtr.Zero, x, y, w, ht, 0x0044);
        ShowWindow((IntPtr)h, 3);
    }
}
public static class DeskCred {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct CREDENTIAL {
        public int Flags; public int Type; public string TargetName; public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize; public IntPtr CredentialBlob; public int Persist;
        public int AttributeCount; public IntPtr Attributes; public string TargetAlias; public string UserName;
    }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredRead(string target, int type, int flags, out IntPtr cred);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredWrite(ref CREDENTIAL cred, int flags);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredDelete(string target, int type, int flags);
    [DllImport("advapi32.dll")] static extern void CredFree(IntPtr p);
    public static string Read(string target) {
        IntPtr p; if (!CredRead(target, 1, 0, out p)) return null;
        try { var c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
              return c.CredentialBlobSize == 0 ? "" : Marshal.PtrToStringUni(c.CredentialBlob, c.CredentialBlobSize / 2); }
        finally { CredFree(p); }
    }
    public static void Write(string target, string user, string secret) {
        var b = Encoding.Unicode.GetBytes(secret);
        var c = new CREDENTIAL { Type = 1, TargetName = target, UserName = user, CredentialBlobSize = b.Length, Persist = 2 };
        c.CredentialBlob = Marshal.AllocCoTaskMem(b.Length);
        try { Marshal.Copy(b, 0, c.CredentialBlob, b.Length); if (!CredWrite(ref c, 0)) throw new System.ComponentModel.Win32Exception(); }
        finally { Marshal.FreeCoTaskMem(c.CredentialBlob); }
    }
    public static bool Delete(string target) { return CredDelete(target, 1, 0); }
}
'@

# ---------------------------------------------------------------- small helpers
function Get-RegValue($key, $name) { try { (Get-ItemProperty $key -Name $name -ErrorAction Stop).$name } catch { $null } }
# Task Scheduler through COM: Get-ScheduledTask (CIM) took 1.1 s per call on the UI thread (U5).
$script:Sched = $null
function Test-Task($name) {
    try {
        if (-not $script:Sched) { $script:Sched = New-Object -ComObject Schedule.Service; $script:Sched.Connect() }
        [void]$script:Sched.GetFolder('\').GetTask($name); $true
    } catch { $false }
}
# Status files carry ISO 8601 times; Windows PowerShell 5.1 leaves them strings, 7 makes DateTimes.
function ConvertTo-LocalTime($v) {
    if ($null -eq $v -or "$v" -eq '') { return $null }
    if ($v -is [datetime]) { return $v.ToLocalTime() }
    try { [DateTimeOffset]::Parse("$v", [Globalization.CultureInfo]::InvariantCulture).LocalDateTime } catch { $null }
}
function Format-Minutes([double]$min) {   # rounded down: an age is "at least"
    if ($min -lt 90) { "$([int][math]::Floor($min)) min" } elseif ($min -lt 2880) { "$([int][math]::Floor($min / 60)) h" } else { "$([int][math]::Floor($min / 1440)) days" }
}
# One quoted command-line argument (MSVC rules: backslashes before a quote are doubled). Start-Process
# joins an -ArgumentList array with bare spaces, so a password with a space arrived in two pieces (R8).
function ConvertTo-NativeArg([string]$s) { '"' + ($s -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }
function Find-Index($list, $name) { $l = @($list); for ($i = 0; $i -lt $l.Count; $i++) { if ($l[$i] -eq $name) { return $i } }; -1 }

# ---------------------------------------------------------------- model
# The share is read here, once per refresh, and only after its host answered on TCP 445 (see
# Test-ShareHost). When it does not, the last good copies stand in, and the window says so.
$script:Machines = @(); $script:Kvm = $null; $script:Reports = @{}
$script:ShareUp = $true; $script:FromCache = $false; $script:LastRead = $null

# The last good machines.csv / kvm.json, for when the share is offline, live beside the installed
# copy and only it writes them; a copy started from the share or a repo just reads them.
function Save-CacheFile($name, $text) {
    if (-not $Installed) { return }
    try {
        $f = Join-Path $InstallDir $name
        if ((Test-Path $f) -and [IO.File]::ReadAllText($f) -eq $text) { return }   # unchanged: no write every 15 s
        [IO.File]::WriteAllText($f, $text)
    } catch {}
}
function Read-ShareFile($name, [bool]$up) {
    if ($up) {
        try {
            $text = [IO.File]::ReadAllText((Join-Path $Root $name)); Save-CacheFile $name $text
            return [pscustomobject]@{ Text = $text; Cached = $false; At = Get-Date }
        } catch {}
    }
    $f = Join-Path $InstallDir $name
    if (Test-Path $f) { try { return [pscustomobject]@{ Text = [IO.File]::ReadAllText($f); Cached = $true; At = (Get-Item $f).LastWriteTime } } catch {} }
    $null
}
# machines.csv rows. A row without a usable IPv4 becomes a "no address" card: a blank IP made
# SendPingAsync throw and blanked every card, and -Check with it (R12).
function ConvertTo-Machines($text) {
    if (-not $text) { return @() }
    $dup = @{}
    @($text -split "\r?\n" | Where-Object { $_ } | ConvertFrom-Csv | Where-Object { "$($_.Name)".Trim() } | ForEach-Object {
        $n = "$($_.Name)".Trim(); $ip = "$($_.IP)".Trim(); $o = $null
        $ok = $ip -match '^\d{1,3}(\.\d{1,3}){3}$' -and [Net.IPAddress]::TryParse($ip, [ref]$o)
        if (-not $dup.ContainsKey($n)) {
            $dup[$n] = 1
            [pscustomobject]@{ Name = $n; IP = $(if ($ok) { $ip } else { '' }); MAC = "$($_.MAC)".Trim(); RustDeskId = "$($_.RustDeskId)"; HasIP = [bool]$ok }
        }
    })
}
function Read-StatusFiles {   # status\<PC>.json from each PC's agent; no folder = no agent yet
    $map = @{}
    foreach ($f in @(Get-ChildItem $StatusDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
        try { $map[$f.BaseName] = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json } catch {}
    }
    $map
}
function Update-ShareData([bool]$up) {
    $script:ShareUp = $up
    $m = Read-ShareFile 'machines.csv' $up
    $k = Read-ShareFile 'kvm.json' $up
    $script:Machines = @(ConvertTo-Machines $(if ($m) { $m.Text }))
    $kv = if ($k) { try { $k.Text | ConvertFrom-Json } catch { $null } }
    if ($kv) { $script:Kvm = $kv } elseif (-not $k) { $script:Kvm = $null }   # a torn read keeps the last layout
    $script:FromCache = if ($m) { $m.Cached } else { -not $up }
    if ($m -and (-not $m.Cached -or -not $script:LastRead)) { $script:LastRead = $m.At }
    if ($up) { $script:Reports = Read-StatusFiles }   # offline: keep the last reports; they age into grey
}

# Desk order: kvm.json "grid" (rows top to bottom, each left to right) wins over "row" (C-6).
# PCs not in the layout come last, in machines.csv order (setup sorts that by name, not by desk).
# The same reading of "grid" as setup's Get-KvmGrid: a flat list of names is ONE row; names are
# kept once (ignoring case), blanks dropped.
function Get-LayoutRows($kvm) {
    if (-not $kvm -or -not $kvm.grid) { return $null }
    $g = @($kvm.grid)
    $nested = @($g | Where-Object { $_ -is [Array] -or $_ -is [Collections.IList] }).Count -gt 0
    $rowsIn = New-Object Collections.Generic.List[object]   # lists, not pipeline output: PowerShell would unroll nested arrays
    if ($nested) { foreach ($r in $g) { $rowsIn.Add(@($r)) } } else { $rowsIn.Add($g) }
    $seen = @{}; $out = New-Object Collections.Generic.List[object]
    foreach ($r in $rowsIn) {
        $clean = New-Object Collections.Generic.List[string]
        foreach ($n in @($r)) { $s = "$n".Trim(); $u = $s.ToUpperInvariant(); if ($s -and -not $seen.ContainsKey($u)) { $seen[$u] = 1; $clean.Add($s) } }
        if ($clean.Count) { $out.Add($clean.ToArray()) }
    }
    , $out.ToArray()   # an array of rows (each a string[]), kept whole by the leading comma
}
function Get-LayoutNames($kvm) {
    if (-not $kvm) { return @() }
    $rows = Get-LayoutRows $kvm
    if ($null -ne $rows) { return @($rows | ForEach-Object { $_ }) }
    @($kvm.row | Where-Object { $_ } | ForEach-Object { "$_" })
}
function Get-LayoutText($kvm) {
    if (-not $kvm) { return '' }
    $rows = Get-LayoutRows $kvm
    if ($null -ne $rows) { return (@($rows | ForEach-Object { @($_) -join ' | ' }) -join '  /  ') }
    @($kvm.row | Where-Object { $_ }) -join ' | '
}
function Get-OrderedMachines {
    $byName = @{}; foreach ($m in $script:Machines) { $byName[$m.Name] = $m }
    $names = @(Get-LayoutNames $script:Kvm)
    # kvm.json never read (offline first run): the desk order Deskflow actually loaded, if known
    if (-not $names.Count -and $script:Info -and $script:Info.Rows) { $names = @($script:Info.Rows | ForEach-Object { $_ } | ForEach-Object { "$_" }) }
    $out = @(foreach ($n in $names) { if ($byName.ContainsKey($n)) { $byName[$n]; $byName.Remove($n) } })
    $out + @($script:Machines | Where-Object { $byName.ContainsKey($_.Name) })
}
function Get-Machine($name) { $script:Machines | Where-Object { $_.Name -eq $name } | Select-Object -First 1 }

# ---------------------------------------------------------------- probes
# All probes start at once and are read later, so the window never blocks.
function Start-Probes($machines) {
    foreach ($m in $machines) {
        if (-not $m.HasIP) { continue }
        # No probe of 24800: Deskflow logs every plain connect there as "failed to accept secure
        # socket" (a burst every few seconds with four Desk Consoles open).
        try {
            $r = New-Object Net.Sockets.TcpClient; $f = New-Object Net.Sockets.TcpClient; $g = New-Object Net.NetworkInformation.Ping
            [pscustomobject]@{ Name = $m.Name; Rc = $r; Fc = $f; Pg = $g
                P = $g.SendPingAsync($m.IP, $ProbeMs)
                R = $r.ConnectAsync($m.IP, 21118)
                F = $f.ConnectAsync($m.IP, 445) }   # Windows firewall drops ping by default; SMB answers
        } catch {}   # one bad row must not sink the other cards
    }
}
function Get-ProbeTasks($probes) { [Threading.Tasks.Task[]]@($probes | ForEach-Object { $_.P; $_.R; $_.F }) }
function Read-Probes($probes) {
    $out = @{}
    foreach ($p in $probes) {
        $out[$p.Name] = [pscustomobject]@{
            Online   = ($p.P.Status -eq 'RanToCompletion' -and $p.P.Result.Status -eq 'Success') -or ('RanToCompletion' -in $p.R.Status, $p.F.Status)
            RustDesk = $p.R.Status -eq 'RanToCompletion' }
        $p.Rc.Dispose(); $p.Fc.Dispose(); $p.Pg.Dispose()
    }
    $out
}
function Start-ShareProbe {
    if (-not $ShareHost) { return $null }
    $c = New-Object Net.Sockets.TcpClient
    $t = try { $c.ConnectAsync($ShareHost, 445) } catch { $null }
    [pscustomobject]@{ C = $c; T = $t }
}
function Test-ShareProbe($sp) {
    if (-not $sp) { return [bool](Test-Path $Root) }   # a local shared folder
    $up = [bool]($sp.T -and $sp.T.Status -eq 'RanToCompletion'); $sp.C.Dispose(); $up
}
# This PC's TCP table: who is connected to its keyboard/mouse port (server), which server it
# reaches (client). IPGlobalProperties takes ~70 ms; Get-NetTCPConnection took 1.4 s (CIM).
function Get-KvmTcp {
    $p = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
    $in = @(); $out = @()
    foreach ($c in $p.GetActiveTcpConnections()) {
        if ($c.State -ne 'Established') { continue }
        $ra = $c.RemoteEndPoint.Address; if ($ra.IsIPv4MappedToIPv6) { $ra = $ra.MapToIPv4() }   # ::ffff:a.b.c.d
        if ($c.LocalEndPoint.Port -eq 24800) { $in += "$ra" } elseif ($c.RemoteEndPoint.Port -eq 24800) { $out += "$ra" }
    }
    [pscustomobject]@{ Listen = [bool]@($p.GetActiveTcpListeners() | Where-Object { $_.Port -eq 24800 }).Count
                       In = @($in | Select-Object -Unique); Out = @($out | Select-Object -Unique) }
}

# ---------------------------------------------------------------- this PC
function Find-DeskflowExe {   # cached: a recursive search of Program Files on every refresh is slow
    if ($script:DeskflowExe -and (Test-Path $script:DeskflowExe)) { return $script:DeskflowExe }
    $p = 'C:\Program Files\Deskflow\deskflow.exe'
    $script:DeskflowExe = if (Test-Path $p) { $p } else { (Get-ChildItem 'C:\Program Files\Deskflow' -Filter 'deskflow.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1).FullName }
    $script:DeskflowExe
}
# kvm.json unreachable and never cached: say what THIS PC actually runs, never guess.
# (1.4.8 guessed "Synergy" after the share folder was renamed, on PCs running Deskflow.)
function Get-LocalProvider {
    $on = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { "$($_.StartType)" -ne 'Disabled' -and $_.DisplayName -match 'deskflow|synergy' })
    if ($on | Where-Object { $_.DisplayName -match 'deskflow' }) { 'Deskflow' }
    elseif ($on | Where-Object { $_.DisplayName -match 'synergy' }) { 'Synergy' }
    else { 'None' }
}
# The desk layout in one line (U3): start where nothing is to the left, follow "right"; a grid's
# rows come in order of how many "up" links lead to the top.
function Get-LinkRows($map) {
    $depth = { param($n) $d = 0; $c = $n; while ($map[$c] -and $map[$c].up -and $d -lt 50) { $c = $map[$c].up; $d++ }; $d }
    $rows = @()
    foreach ($s in @($map.Keys | Where-Object { -not $map[$_].left } | Sort-Object { & $depth $_ })) {
        $row = @(); $c = $s; $guard = 0
        while ($c -and $guard++ -lt 50) { $row += $c; $c = if ($map[$c]) { $map[$c].right } else { $null } }
        $rows += , $row
    }
    , $rows
}
function Get-KvmInfo {
    $prov = if ($script:Kvm -and "$($script:Kvm.provider)") { "$($script:Kvm.provider)" } else { Get-LocalProvider }
    switch ($prov) {
        'Deskflow' { $core = Join-Path $env:APPDATA 'Deskflow\Deskflow.conf'
                     if (-not (Test-Path $core)) { $core = 'C:\ProgramData\Deskflow\Deskflow.conf' }   # what Deskflow itself falls back to
                     # the layout this user's Deskflow reads (setup moved it into the profile in 1.4.10)
                     $conf = Join-Path $env:APPDATA 'Deskflow\deskflow-server.conf'
                     if (-not (Test-Path $conf)) { $conf = 'C:\ProgramData\Deskflow\deskflow-server.conf' }
                     $exe = Find-DeskflowExe }
        'Synergy'  { $core = $SynergyCore; $conf = $SynergyConf; $exe = $SynergyExe }
        default    { return [pscustomobject]@{ Provider = 'None'; Exe = $null; Service = '-'; Running = $false; Mode = $null; Links = @(); Rows = @()
                         Role = 'keyboard + mouse sharing is off (kvm.json provider None)'; Hotkeys = '-' } }
    }
    $svc  = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $prov -or $_.Name -match $prov } | Select-Object -First 1
    $mm   = if (Test-Path $core) { Select-String -Path $core -Pattern '^coreMode=(\d+)' | Select-Object -First 1 }
    $mode = if ($mm) { $mm.Matches[0].Groups[1].Value } else { $null }
    $role = switch ($mode) { '2' { 'SERVER (keyboard + mouse here)' } '1' { 'client' } $null { 'not installed / not configured' } default { "mode $mode" } }
    # Links from the layout file Deskflow loaded, not kvm.json: a row the 2-minute task has not
    # applied yet then shows as a difference. Only the server has one; a client's is a leftover.
    $links = @(); $map = @{}; $text = ''
    if ($mode -eq '2' -and (Test-Path $conf)) {
        $text = Get-Content $conf -Raw; $cur = $null; $inLinks = $false
        foreach ($l in ($text -split "\r?\n")) {
            if ($l -match '^section: links') { $inLinks = $true; continue }
            if ($l -match '^end') { $inLinks = $false; continue }
            if ($inLinks -and $l -match '^\t(\S+):\s*$') { $cur = $Matches[1]; $map[$cur] = @{}; continue }
            if ($inLinks -and $cur -and $l -match '^\t\t(\w+)(\([^)]*\))?\s*=\s*([^(\s]+)') {
                $links += "$cur  $($Matches[1]) ->  $($Matches[3])"; $map[$cur][$Matches[1]] = $Matches[3]
            }
        }
    }
    $hot = @()
    if ($text -match 'switchInDirection') { $hot += 'Ctrl+Alt+Left / Ctrl+Alt+Right switch screens' }
    $jump = [regex]::Matches($text, 'switchToScreen').Count
    if ($jump) { $hot += "Ctrl+Alt+Shift+1..$jump jump to a PC" }
    [pscustomobject]@{
        Provider = $prov; Exe = $exe; Mode = $mode; Role = $role; Links = $links; Rows = (Get-LinkRows $map)
        Service  = if ($svc) { "$($svc.Status) / $($svc.StartType)" } else { 'missing' }
        Running  = [bool]($svc -and "$($svc.Status)" -eq 'Running')
        Hotkeys  = if ($hot) { ($hot + 'Scroll Lock locks the cursor') -join '; ' }
                   elseif ($mode -eq '2') { 'none yet -- use Repair / update this PC' } else { 'set on the server' }
    }
}

# This PC's warnings, read the way its agent reports them in status\<PC>.json (C-2): registry
# only, no CIM. Windows Update "complete" = the no-restart policy plus AUOptions=4, which
# Microsoft says the policy needs (C-5, R2).
function Get-UpdatesState($au) {
    if ($au.NoAutoRebootWithLoggedOnUsers -eq 1 -and $au.AUOptions -eq 4) { 'complete' }
    elseif ($au.NoAutoRebootWithLoggedOnUsers -eq 1) { 'incomplete' } else { 'off' }
}
function Get-LocalStatus {   # same rules as Agent.ps1's report, so this PC's card reads like the others
    $w   = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
    $dc  = Get-ItemProperty $DcKey -ErrorAction SilentlyContinue
    $pol = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue
    $au  = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -ErrorAction SilentlyContinue
    $on  = "$($w.AutoAdminLogon)" -eq '1'
    $user = $null
    if ($on) {
        $n = "$($w.DefaultUserName)".Trim(); $d = "$($w.DefaultDomainName)".Trim(); if ($d -eq '.') { $d = $Me }
        if ($n -and ($n -match '[\\@]' -or -not $d)) { $user = $n } elseif ($n) { $user = "$d\$n" }
    }
    # what setup set (C-4): another account's console sign-in rewrites Winlogon's name (R13)
    $exp = "$($dc.AutoLogonUser)".Trim(); if (-not $exp) { $exp = $null }
    $reach = "$($dc.RustDeskReach)".Trim().ToLowerInvariant()
    $cn = 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName'
    $rename = "$(Get-RegValue "$cn\ActiveComputerName" 'ComputerName')" -ne "$(Get-RegValue "$cn\ComputerName" 'ComputerName')"
    [pscustomobject]@{
        version   = "$AppVersion"
        autoLogon = [pscustomobject]@{ on = $on; user = $user; expectedUser = $exp; lock = Test-Task $LockTask
                                       mismatch = $(if (-not $on) { $false } elseif (-not $exp) { $null } else { $user -ne $exp }) }
        legalNotice   = [bool]("$($pol.LegalNoticeCaption)".Trim() -or "$($pol.LegalNoticeText)".Trim())
        # Fast Startup needs hibernation: with it off, a shutdown is a real one whatever HiberbootEnabled says
        fastStartup   = (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled') -eq 1 -and
                        (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled') -ne 0
        rebootPending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
                        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or $rename
        updates       = Get-UpdatesState $au
        rustdeskReach = $(if ($reach -in 'lan', 'anywhere') { $reach } else { 'unknown' })
        whitelist     = "$($dc.RustDeskWhitelist)"
    }
}

# Dev box (Start-DevBox.ps1, a per-user sign-in task, no admin): reopen VS Code and resume Claude
# Code in one or more folders. Prefer the installed copy, so the task survives the share.
$DevScript = @((Join-Path $InstallDir 'Start-DevBox.ps1'), (Join-Path $PSScriptRoot 'Start-DevBox.ps1')) |
             Where-Object { Test-Path $_ } | Select-Object -First 1
function Get-DevBoxPath { if ($DevScript) { Join-Path (Split-Path $DevScript -Parent) 'devbox.json' } }
function Get-DevBoxConf {
    $f = Get-DevBoxPath
    if ($f -and (Test-Path $f)) { try { return ([IO.File]::ReadAllText($f) | ConvertFrom-Json) } catch {} }
    $null
}
# devbox.json (Start-DevBox.ps1 writes it): { items: [{ path, code, claude }], delaySec } since 1.7.0,
# where claude = run `claude --continue` there; the 1.6.0 { folder, openCode, resumeClaude } is item 1.
function ConvertTo-DevBoxFlag($v) { if ($v -is [string]) { $v.Trim() -match '^(1|true|yes|on)$' } else { [bool]$v } }
function Get-DevBoxItems($c) {
    if (-not $c) { return @() }
    $raw = if ($null -ne $c.items) { @($c.items) } elseif ($c.folder) { @($c) } else { @() }
    @($raw | Where-Object { $_ } | ForEach-Object {
        $p = $_.path; if ($null -eq $p) { $p = $_.folder }
        $k = $_.code; if ($null -eq $k) { $k = $_.openCode }; if ($null -eq $k) { $k = $true }
        $l = $_.claude; if ($null -eq $l) { $l = $_.resumeClaude }
        [pscustomobject]@{ Path = "$p"; Code = ConvertTo-DevBoxFlag $k; Claude = ConvertTo-DevBoxFlag $l } })
}
function Get-DevBoxInfo {
    $items = @(Get-DevBoxItems (Get-DevBoxConf))
    if (-not $items.Count -or -not (Test-Task $DevTask)) { return 'off' }
    $f = $items[0]; $w = @()
    if ($f.Code) { $w += 'VS Code' }; if ($f.Claude) { $w += 'claude --continue' }
    $more = if ($items.Count -gt 1) { " (+$($items.Count - 1) more folder$(if ($items.Count -gt 2) { 's' }))" } else { '' }
    "$($w -join ' + ') in $($f.Path)$more, at sign-in"
}

# The This-PC lines, shared by the window and -Check: T = text, W = an amber note.
function Get-PanelText($si, $st) {
    $t = [ordered]@{}
    $t.Kvm = @{ T = "$($si.Provider): $($si.Role)$(if ($si.Provider -ne 'None') { "      Service: $($si.Service)" })"
                W = $(if ($si.Provider -ne 'None' -and -not $si.Running) { 'the service is not running' }) }
    $kvmTxt = Get-LayoutText $script:Kvm
    $live = (@($si.Rows) | ForEach-Object { @($_) -join ' | ' }) -join '  /  '
    $t.Layout = if ($si.Mode -eq '2' -and $live) {
                    @{ T = "Layout (left to right): $live"; W = $(if ($kvmTxt -and $kvmTxt -ne $live) { "kvm.json says $kvmTxt -- the server applies it within 2 minutes" }) }
                } elseif ($kvmTxt) { @{ T = "Layout (left to right, kvm.json): $kvmTxt"; W = $null } }
                else { @{ T = 'Layout: not set yet (kvm.json)'; W = $null } }
    $t.Hotkeys = @{ T = "Hotkeys: $($si.Hotkeys)"; W = $null }
    $a = $st.autoLogon; $w = @()
    if ($a.on) {
        $who = if ($a.expectedUser) { $a.expectedUser } else { $a.user }
        if ($a.mismatch) { $w += "Windows now names $($a.user): re-apply" }
        # James keeps the sign-in notice on the desktops: information, not an error
        if ($st.legalNotice) { $w += 'sign-in notice: click OK after a restart (RustDesk works there)' }
        if ($a.lock -and $st.fastStartup) { $w += 'Fast Startup is on: shut down + power on skips the lock (Restart is fine)' }
        $t.Auto = @{ T = "Automatic sign-in at boot: ON for $who$(if ($a.lock) { ', then the screen locks' })"; W = ($w -join '; ') }
    } else { $t.Auto = @{ T = 'Automatic sign-in at boot: off'; W = $null } }
    $w = @()
    if ($st.updates -eq 'incomplete') { $w += 'incomplete: Windows may ignore it without AUOptions=4 (Windows Update... re-applies it)' }
    if ($st.rebootPending) { $w += 'a restart is pending' }
    $t.Updates = @{ T = "Windows Update restarts: $(if ($st.updates -eq 'off') { 'Windows default (may restart by itself)' } else { 'no automatic restart while someone is signed in' })"; W = ($w -join '; ') }
    $pw = "password saved on this PC: $(if ([DeskCred]::Read($CredTarget)) { 'yes' } else { 'no' })"
    $t.RustDesk = switch ($st.rustdeskReach) {
        'lan'      { @{ T = "RustDesk: home LAN only$(if ($st.whitelist) { " ($($st.whitelist))" }); $pw"; W = $null } }
        'anywhere' { @{ T = "RustDesk: $pw"; W = 'also reachable from the internet by its ID + password (site.json rustdeskReach "anywhere")' } }
        default    { @{ T = "RustDesk: $pw"; W = 'reach not recorded yet (Repair / update this PC sets home LAN only)' } }
    }
    $t.DevBox = @{ T = "Dev box resume: $(Get-DevBoxInfo)"; W = $null }
    $t
}

# ---------------------------------------------------------------- card state
# Short warnings for a card, from that PC's report (or this PC's registry), each with the long
# text for the tooltip.
function New-Flag($short, $long) { [pscustomobject]@{ Short = $short; Long = $long } }
function Get-Flags($m, $st, [bool]$isMe) {
    $f = @()
    if ($st) {
        if ($st.rebootPending) { $f += New-Flag 'restart pending' 'Windows Update is waiting for a restart.' }
        if ($st.autoLogon -and $st.autoLogon.on -and $st.legalNotice) { $f += New-Flag 'sign-in notice' 'sign-in notice: click OK after a restart (RustDesk works there)' }
        if ($st.autoLogon -and $st.autoLogon.mismatch) {
            $f += New-Flag 'auto sign-in user changed' "Automatic sign-in was set for $($st.autoLogon.expectedUser), but Windows now names $($st.autoLogon.user): re-apply it there."
        }
        if ($st.autoLogon -and $st.autoLogon.lock -and $st.fastStartup) { $f += New-Flag 'Fast Startup on' 'Fast Startup is on: shut down + power on skips the lock after automatic sign-in (Restart is fine).' }
        if ("$($st.updates)" -eq 'incomplete') { $f += New-Flag 'update policy incomplete' 'The no-restart policy is set without AUOptions=4, which Windows needs to honour it: re-apply Windows Update there.' }
        if ("$($st.rustdeskReach)" -eq 'anywhere') { $f += New-Flag 'RustDesk: any network' 'RustDesk accepts its password from anywhere by ID (site.json rustdeskReach "anywhere").' }
        $v = $null
        if (-not $isMe -and [version]::TryParse("$($st.version)", [ref]$v) -and $v -lt $AppVersion) {
            $f += New-Flag "old version $($st.version)" "That PC runs Desk Console $($st.version); this one is $AppVersion."
        }
        if (-not $isMe -and $st.ip -and $m.HasIP -and "$($st.ip)" -ne $m.IP) {
            $f += New-Flag "address now $($st.ip)" "That PC reports $($st.ip); machines.csv says $($m.IP)."
        }
    }
    $c = Get-CommandNote $m.Name $st
    if ($c) { $f += $c }
    $f
}
# A command sent from here (C-3) until that PC's report shows its result; else that PC's last
# command while it is recent.
$script:Sent = @{}
function Get-CommandNote($name, $st) {
    $sent = $script:Sent[$name]; $last = if ($st) { $st.lastCommand } else { $null }
    if ($sent -and ((Get-Date) - $sent.At).TotalMinutes -gt 30) { $script:Sent.Remove($name); $sent = $null }
    if ($sent -and $last -and "$($last.id)" -eq $sent.Id) {
        return New-Flag "$($sent.Action): $($last.result)" "$($sent.Action) requested from here at $($sent.At.ToString('HH:mm')): $($last.result)"
    }
    if ($sent) { return New-Flag "$($sent.Action) requested $($sent.At.ToString('HH:mm'))" "$($sent.Action) requested at $($sent.At.ToString('HH:mm')); its agent runs it within 2 minutes, or it expires after 10." }
    $at = if ($last) { ConvertTo-LocalTime $last.at } else { $null }
    if ($at -and ((Get-Date) - $at).TotalMinutes -lt 30) { return New-Flag "$($last.action): $($last.result)" "Last command: $($last.action) at $($at.ToString('HH:mm')): $($last.result)" }
    $null
}
function Get-StatusAge($st) {
    if (-not $st) { return $null }
    $t = ConvertTo-LocalTime $st.updated
    if (-not $t) { return $null }
    [math]::Max(0, ((Get-Date) - $t).TotalMinutes)
}
function Test-KvmPeer($name, $ctx) {   # an IPv4 of that PC (machines.csv, or its own report) among the connected peers
    $ips = @(@($script:Machines | Where-Object { $_.Name -eq $name } | ForEach-Object { $_.IP }) + @("$($script:Reports[$name].ip)") | Where-Object { $_ })
    [bool]@($ips | Where-Object { $ctx.Tcp.In -contains $_ }).Count
}
# Keyboard/mouse line for one card (F3). Green or red only when someone can vouch for it: this
# PC's own TCP table (on the server it sees every client), or a fresh report from that PC.
# Anything else is grey "state unknown" -- a green the dashboard cannot vouch for was the bug.
function Get-KvmLine($m, $online, $st, [bool]$fresh, $ctx) {
    $p = $ctx.Provider
    if (-not $p -or $p -eq 'None') { return @{ T = 'Keyboard + mouse: off'; S = 'unknown'; C = $null } }
    if ($m.Name -eq $Me) {
        if ($ctx.MeServer) {
            if (-not $ctx.Tcp.Listen) { return @{ T = "$p server: NOT running"; S = 'bad'; C = $null } }
            $want = @($ctx.Layout | Where-Object { $_ -ne $Me })
            $n = @($want | Where-Object { Test-KvmPeer $_ $ctx }).Count
            $s = if ($n -ge $want.Count) { 'ok' } elseif ($n -gt 0) { 'warn' } else { 'bad' }   # green only when every client is there
            return @{ T = "$p server: $n of $($want.Count) clients"; S = $s; C = $null }
        }
        if (-not $ctx.MeClient) { return @{ T = "${p}: not configured on this PC"; S = 'unknown'; C = $null } }
        $up = $ctx.Tcp.Out.Count -gt 0
        return @{ T = "$p client: $(if ($up) { 'connected' } else { 'not connected' })"; S = $(if ($up) { 'ok' } else { 'bad' }); C = $up }
    }
    if ($ctx.MeServer) {
        if (-not $m.HasIP -and -not "$($script:Reports[$m.Name].ip)") { return @{ T = "$p client (no address)"; S = 'unknown'; C = $null } }
        $up = Test-KvmPeer $m.Name $ctx
        $s = if ($up) { 'ok' } elseif ($online -ne $true) { 'unknown' } else { 'bad' }
        return @{ T = "$p client: $(if ($up) { 'connected' } else { 'not connected' })"; S = $s; C = $up }
    }
    if ($st -and $st.kvm) {
        $con = [bool]$st.kvm.connected; $role = "$($st.role)"
        $t = switch ($role) {
            'server' { "$p server: $(@($st.kvm.peers | Where-Object { $_ }).Count) of $(@($ctx.Layout | Where-Object { $_ -ne $m.Name }).Count) clients" }
            'none'   { 'Keyboard + mouse: off' }
            default  { "$p client: $(if ($con) { 'connected' } else { 'not connected' })" }
        }
        if (-not $fresh) { return @{ T = $t; S = 'unknown'; C = $null } }   # stale: shown grey, not vouched for
        $s = if ($role -eq 'none') { 'unknown' } elseif ($con) { 'ok' } elseif ($role -eq 'server') { 'unknown' } else { 'bad' }
        return @{ T = $t; S = $s; C = $(if ($role -eq 'client') { $con } else { $null }) }
    }
    $role = if ($m.Name -eq $ctx.Server) { 'server' } else { 'client' }
    if ($ctx.MeClient -and $role -eq 'server' -and $m.HasIP -and $ctx.Tcp.Out -contains $m.IP) {
        return @{ T = "$p server: this PC connected"; S = 'ok'; C = $null }
    }
    @{ T = "$p $role (state unknown)"; S = 'unknown'; C = $null }
}
function Get-KvmContext {
    $layout = @(Get-LayoutNames $script:Kvm)
    if (-not $layout.Count) { $layout = @($script:Machines | ForEach-Object { $_.Name }) }
    [pscustomobject]@{
        Provider = $script:Info.Provider
        Server   = "$($script:Kvm.server)"
        MeServer = $script:Info.Mode -eq '2'   # this PC's role from its own Deskflow settings, not kvm.json (U7)
        MeClient = $script:Info.Mode -eq '1'
        Tcp      = Get-KvmTcp
        Layout   = $layout
        Local    = $script:Local
    }
}
# What one card says, shared by the window and -Check. S: ok green, bad red, warn amber,
# unknown grey, text black.
$script:Waking = @{}
function Get-CardState($m, $probe, $ctx) {
    $isMe = $m.Name -eq $Me
    $st = if ($isMe) { $ctx.Local } else { $script:Reports[$m.Name] }
    $age = if ($isMe) { 0 } else { Get-StatusAge $st }
    $fresh = $null -ne $age -and $age -le $StaleMin
    $online = if ($probe) { $probe.Online } else { $null }
    $s = @{ OnlineRaw = $online; Stale = [bool]($st -and -not $fresh) }
    $s.Online = if (-not $m.HasIP) { @{ T = 'Online: no address'; S = 'unknown' } }
                elseif ($null -eq $online) { @{ T = 'Online: ...'; S = 'unknown' } }
                elseif ($online) { @{ T = 'Online: yes'; S = 'ok' } } else { @{ T = 'Online: no'; S = 'bad' } }
    $s.Kvm = Get-KvmLine $m $online $st $fresh $ctx; $s.KvmUp = $s.Kvm.C
    $reach = switch ("$($st.rustdeskReach)") { 'lan' { ' (LAN only)' } 'anywhere' { ' (any network)' } default { '' } }
    $s.Rd = if (-not $probe) { @{ T = 'RustDesk: -'; S = 'unknown' } }
            elseif ($probe.RustDesk) { @{ T = "RustDesk: reachable$reach"; S = 'ok' } } else { @{ T = 'RustDesk: not reachable'; S = 'bad' } }
    $w = $script:Waking[$m.Name]
    $ver = if ($st -and $st.version) { " (v$($st.version))" } else { '' }
    $s.Status = if ($isMe) { @{ T = "This PC: Desk Console $AppVersion"; S = 'text' } }
                elseif ($w) { @{ T = "Waking: no answer yet ($([int]((Get-Date) - $w.Start).TotalSeconds) s)"; S = 'warn' } }
                elseif (-not $st) { @{ T = 'No report yet (agent not running?)'; S = 'unknown' } }
                elseif ($fresh) { @{ T = "Reported $(if ($age -lt 1) { 'just now' } else { "$(Format-Minutes $age) ago" })$ver"; S = 'text' } }
                elseif ($null -eq $age) { @{ T = "Report has no time$ver"; S = 'unknown' } }
                else { @{ T = "Status $(Format-Minutes $age) old$ver"; S = 'unknown' } }
    $s.Flags    = @(Get-Flags $m $st $isMe)
    $s.ShowWake = [bool]($m.MAC -and ((-not $m.HasIP) -or ($probe -and -not $online)))   # Wake only for a PC that is off (U11)
    $s.CanView  = [bool]($m.HasIP -and (-not $probe -or $probe.RustDesk))
    $s.CanAct   = [bool]($m.HasIP -and (-not $probe -or $online) -and $script:ShareUp)
    $s
}

# ---------------------------------------------------------------- actions
function Connect-Machine($m) {
    if (-not $m) { return }
    if (-not (Test-Path $RustDeskExe)) { throw 'RustDesk is not installed on this PC. Use Repair / update this PC.' }
    $a = '--connect ' + (ConvertTo-NativeArg $m.IP)
    $pw = [DeskCred]::Read($CredTarget)
    if ($pw) { $a += ' --password ' + (ConvertTo-NativeArg $pw) }
    try { Sync-RustDeskTabs } catch {}
    $before = Get-RustDeskWindows -Sessions
    Start-Process $RustDeskExe -ArgumentList $a
    Watch-NewWindow $before (Get-ScreenFor $m)
}

# RustDesk opens a connection as a tab of its open remote window -- which cannot go to another
# display -- unless its local option enable-open-new-connections-in-tabs is 'N'
# (multi_window_manager.dart, RustDesk 1.5.0). It reads RustDesk_local.toml once at start and writes
# all of it back on every change (hbb_common LocalConfig), so the file is changed only while this
# user has no RustDesk window running: one without sessions is closed first (never the service,
# server, tray or connection manager); with sessions open it waits for the next connect after them.
$RustDeskLocal = Join-Path $env:APPDATA 'RustDesk\config\RustDesk_local.toml'
$TabsKey = 'enable-open-new-connections-in-tabs'
function Test-SessionWindows { "$(Get-RegValue $UiKey 'SessionWindows')" -ne '0' }   # default: a window per PC
function Set-SessionWindows([bool]$on) {   # the toolbar checkbox and the tray menu item
    if (-not (Test-Path $UiKey)) { New-Item $UiKey | Out-Null }
    Set-ItemProperty $UiKey -Name SessionWindows -Value $(if ($on) { '1' } else { '0' })
    $winBox.Checked = $on; $winItem.Checked = $on
    $msg = $(if ($on) { 'Each PC opens in its own RustDesk window' } else { 'Every PC opens as a tab of one RustDesk window' })
    if (@(Get-RustDeskWindows -Sessions).Count) { $msg += ' -- from the next View + control after the open sessions are closed.' }
    else { $msg += ', from the next View + control.' }
    Set-Status $msg $Ink
}
function Sync-RustDeskTabs {
    $want = $(if (Test-SessionWindows) { 'N' } else { 'Y' })
    $line = "$TabsKey = '$want'"
    $lines = New-Object Collections.Generic.List[string]
    if (Test-Path $RustDeskLocal) { $old = @(Get-Content $RustDeskLocal -Encoding UTF8); if ($old.Count) { $lines.AddRange([string[]]$old) } }
    $at = -1; for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match "^\s*$([regex]::Escape($TabsKey))\s*=") { $at = $i; break } }
    if ($at -ge 0 -and $lines[$at].Trim() -eq $line) { return }
    if ($at -lt 0 -and $want -eq 'Y') { return }   # not set = tabs, RustDesk's default
    if (@(Get-RustDeskWindows -Sessions).Count) { return }
    $sid = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $ui = @(Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.SessionId -eq $sid -and "$($_.CommandLine)" -and "$($_.CommandLine)" -notmatch '--(service|server|tray|cm)' })
    foreach ($p in $ui) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    if ($ui.Count) { Wait-Process -Id @($ui | ForEach-Object { $_.ProcessId }) -Timeout 5 -ErrorAction SilentlyContinue }
    if ($at -ge 0) { $lines[$at] = $line }
    else {
        $sec = -1; for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -eq '[options]') { $sec = $i; break } }
        if ($sec -ge 0) { $lines.Insert($sec + 1, $line) }
        else { if ($lines.Count -and $lines[$lines.Count - 1] -ne '') { $lines.Add('') }; $lines.Add('[options]'); $lines.Add($line) }
    }
    New-Item -ItemType Directory -Force (Split-Path $RustDeskLocal) | Out-Null
    [IO.File]::WriteAllLines($RustDeskLocal, $lines)   # UTF-8 without BOM
}

# Each PC opens on the display that matches its place in the desk layout relative to this PC (which
# stays on the primary display): left of me -> the display to the left, and so on. When there is no
# such display (or the PC is not in my row) nothing is moved: it opens as a normal window.
function Get-ScreenFor($m) {
    $scr = @([Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X }, { $_.Bounds.Y })
    if ($scr.Count -lt 2) { return $null }
    $rows = Get-LayoutRows $script:Kvm
    if ($null -eq $rows) { $rows = @(, @(Get-LayoutNames $script:Kvm)) }
    foreach ($row in $rows) {
        $r = @($row); $me = Find-Index $r $Me; $it = Find-Index $r $m.Name
        if ($me -lt 0 -or $it -lt 0) { continue }
        $prim = Find-Index ($scr | ForEach-Object { $_.Primary }) $true
        $i = $prim + ($it - $me)
        if ($i -ge 0 -and $i -lt $scr.Count) { return $scr[$i] }
    }
    $null
}
# RustDesk's own main window is titled just "RustDesk"; session windows are the others.
function Get-RustDeskWindows([switch]$Sessions) {
    $p = @(Get-Process -Name rustdesk -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    if (-not $p.Count) { return @() }
    $w = @([DeskWin]::ForPids([int[]]$p))
    if ($Sessions) { $w = @($w | Where-Object { ($t = [DeskWin]::Title($_)) -and $t -ne 'RustDesk' }) }
    $w
}
function Test-HideSessions { "$(Get-RegValue $UiKey 'HideSessionsFromTaskbar')" -eq '1' }
$script:Placers = New-Object Collections.ArrayList
$script:Claimed = @{}
function Watch-NewWindow($before, $screen) {   # RustDesk opens its window a moment later: poll up to 20 s
    $t = New-Object Windows.Forms.Timer; $t.Interval = 500
    $st = @{ Before = @($before); Screen = $screen; Tries = 0; Timer = $t }
    $t.Tag = $st
    $t.Add_Tick({
        param($sender)
        $x = $sender.Tag; $x.Tries++
        # Open all starts several watchers at once: each claims only a window no other watcher took.
        $new = @(Get-RustDeskWindows -Sessions | Where-Object { $x.Before -notcontains $_ -and -not $script:Claimed.ContainsKey($_) })
        if ($new.Count -gt 1 -and $script:Placers.Count -gt 1) { $new = @($new[0]) }
        if ($new.Count -or $x.Tries -ge 40) {
            $sender.Stop()
            foreach ($h in $new) { $script:Claimed[$h] = $true }
            foreach ($h in $new) {
                if ($x.Screen) { $b = $x.Screen.Bounds; [DeskWin]::Place($h, $b.X, $b.Y, $b.Width, $b.Height) }
                if (Test-HideSessions) { [DeskWin]::HideFromTaskbar($h) }
            }
            $script:Placers.Remove($sender)
            $sender.Dispose()
        }
    })
    [void]$script:Placers.Add($t); $t.Start()
}

# Wake-on-LAN has to leave through the adapter on the target's network. A limited broadcast
# (255.255.255.255) goes out of ONE interface, picked by metric, so with Wi-Fi on another router
# it can silently go to the wrong network (R16). Bind to the local IPv4 whose subnet holds the
# target and send to that subnet's broadcast on ports 9 and 7 (and the limited one from there).
function Get-WakeRoute($ip) {
    $t = [Net.IPAddress]::Parse($ip).GetAddressBytes()
    foreach ($n in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ("$($n.OperationalStatus)" -ne 'Up') { continue }
        foreach ($u in $n.GetIPProperties().UnicastAddresses) {
            if ("$($u.Address.AddressFamily)" -ne 'InterNetwork' -or -not $u.IPv4Mask) { continue }
            $a = $u.Address.GetAddressBytes(); $k = $u.IPv4Mask.GetAddressBytes(); $same = $true
            for ($i = 0; $i -lt 4; $i++) { if (($a[$i] -band $k[$i]) -ne ($t[$i] -band $k[$i])) { $same = $false } }
            if ($same -and $k[0] -ne 0) {
                $b = [byte[]]@(0..3 | ForEach-Object { $a[$_] -bor (255 - $k[$_]) })
                return [pscustomobject]@{ Local = $u.Address; Broadcast = [Net.IPAddress]::new($b) }
            }
        }
    }
    $null
}
function Send-Wake($m) {
    if (-not $m.MAC) { throw "No MAC address for $($m.Name) in machines.csv." }
    $mac = [byte[]]@($m.MAC -split '[:-]' | ForEach-Object { [Convert]::ToByte($_, 16) })
    if ($mac.Length -ne 6) { throw "The MAC address of $($m.Name) in machines.csv ($($m.MAC)) is not valid." }
    $pkt = [byte[]](@(0xFF) * 6 + $mac * 16)
    $r = if ($m.HasIP) { Get-WakeRoute $m.IP } else { $null }
    $u = if ($r) { New-Object Net.Sockets.UdpClient (New-Object Net.IPEndPoint $r.Local, 0) } else { New-Object Net.Sockets.UdpClient }
    try {
        $u.EnableBroadcast = $true
        $to = if ($r) { @("$($r.Broadcast)", '255.255.255.255') } else { @('255.255.255.255') }
        foreach ($d in $to) { foreach ($port in 9, 7) { [void]$u.Send($pkt, $pkt.Length, $d, $port) } }
    } finally { $u.Close() }
    $r   # $null: no adapter here is on that PC's network
}

# Commands for another PC's agent (C-3), which runs whitelisted actions oldest first and reports
# the result in its status file. Written as <id>.tmp, then renamed: the agent reads *.json only
# and deletes a file it cannot parse, so it must never see a half-written one.
function Send-DeskCommand($name, $action) {
    $dir = Join-Path $CommandDir $name
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $id = [guid]::NewGuid().ToString(); $now = Get-Date
    $json = [pscustomobject]@{ id = $id; action = $action; from = $Me; created = $now.ToString('o'); expires = $now.AddMinutes(10).ToString('o') } | ConvertTo-Json
    $tmp = Join-Path $dir "$id.tmp"
    [IO.File]::WriteAllText($tmp, $json, [Text.Encoding]::ASCII)
    [IO.File]::Move($tmp, (Join-Path $dir "$id.json"))
    $script:Sent[$name] = @{ Id = $id; Action = $action; At = $now }
}

# Desk order lives in kvm.json "row"; the server's 2-minute task rebuilds the Deskflow layout from
# it (U14). Re-read just before writing, so a PC that setup added a moment ago is kept.
function Move-InRow($name, [int]$dir) {
    if ($script:FromCache) { throw 'The shared folder is not reachable, so kvm.json cannot be changed now.' }
    $k = [IO.File]::ReadAllText($KvmPath) | ConvertFrom-Json
    if ($k.grid) { throw 'kvm.json has a "grid", which sets the desk order. Edit it there; these buttons change "row" only.' }
    $row = @($k.row | Where-Object { $_ } | ForEach-Object { "$_" })
    $i = Find-Index $row $name; $j = $i + $dir
    if ($i -lt 0 -or $j -lt 0 -or $j -ge $row.Count) { throw "$name cannot move that way (kvm.json row: $($row -join ' | '))." }
    $t = $row[$i]; $row[$i] = $row[$j]; $row[$j] = $t
    $k | Add-Member -NotePropertyName row -NotePropertyValue ([object[]]$row) -Force
    # One write, not temp + rename: a reader must never find kvm.json missing, because setup then
    # falls back to "this PC is the server" (R6).
    [IO.File]::WriteAllText($KvmPath, ($k | ConvertTo-Json -Depth 6), [Text.Encoding]::ASCII)
    $script:Kvm = $k
}

# ---------------------------------------------------------------- -Check
if ($Check) {
    Update-ShareData (Test-ShareHost)
    $script:Info = Get-KvmInfo; $script:Local = Get-LocalStatus
    $ms = @(Get-OrderedMachines)
    if (-not $ms.Count) { "No machines in $Csv yet." }
    else {
        $probes = @(Start-Probes $ms); $tasks = Get-ProbeTasks $probes
        if ($tasks.Count) { try { [void][Threading.Tasks.Task]::WaitAll($tasks, $ProbeMs) } catch {} }
        $res = Read-Probes $probes; $ctx = Get-KvmContext
        $ms | ForEach-Object {
            $s = Get-CardState $_ $res[$_.Name] $ctx
            [pscustomobject]@{
                Name = $_.Name; IP = $(if ($_.HasIP) { $_.IP } else { '(none)' })
                Online = $s.Online.T -replace '^Online: '; 'Keyboard + mouse' = $s.Kvm.T; RustDesk = $s.Rd.T -replace '^RustDesk: '
                Report = $s.Status.T; Notes = (@($s.Flags) | ForEach-Object { $_.Short }) -join '; '
            }
        } | Format-Table -AutoSize -Wrap | Out-String -Width 250
    }
    "Shared folder: $Root -- $(if (-not $script:FromCache) { 'online' } elseif (-not $script:ShareUp) { 'NOT reachable, using the cached copy' } else { 'no machines.csv there, using the cached copy' })"
    $si = $script:Info
    foreach ($kv in (Get-PanelText $si $script:Local).GetEnumerator()) {
        "$($kv.Value.T)$(if ($kv.Value.W) { "  ($($kv.Value.W))" })"
        if ($kv.Key -eq 'Layout') { $si.Links | ForEach-Object { "   $_" } }
    }
    return
}

# ---------------------------------------------------------------- window
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
# Our own taskbar identity, before the first window: as powershell.exe the button was grouped
# with PowerShell under its icon, and notifications said "Windows PowerShell". The shortcuts carry
# the same ID (DeskConsole.iss, Install-DeskConsole.ps1), which gives notifications our name and icon.
try {
    Add-Type -Name DeskAppId -Namespace Win32 -MemberDefinition '[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string id);'
    [void][Win32.DeskAppId]::SetCurrentProcessExplicitAppUserModelID('JamesVanDusen.DeskConsole')
} catch {}
# An error in a click handler lands here instead of .NET's "Unhandled exception -- Continue /
# Quit" dialog (U12). It has to be set before the first window exists.
try { [Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::CatchException) } catch {}
function Get-ErrorText($x) {   # the reason only: no "Exception calling ..." wrapper, no ErrorActionPreference preamble
    while ($x -is [Management.Automation.MethodInvocationException] -and $x.InnerException) { $x = $x.InnerException }
    $x.Message -replace '^The running command stopped because the preference variable "ErrorActionPreference" or common parameter is set to Stop: ', ''
}
[Windows.Forms.Application]::add_ThreadException({ param($s, $e) try { Show-Error (Get-ErrorText $e.Exception) } catch {} })
[Windows.Forms.Application]::EnableVisualStyles()
$Font  = New-Object Drawing.Font('Segoe UI', 9.5)
$Bold  = New-Object Drawing.Font('Segoe UI Semibold', 11)
# 4.5:1 or better on the window background (U15); amber = attention, not failure
$Green = [Drawing.Color]::FromArgb(0, 120, 60); $Red = [Drawing.Color]::FromArgb(190, 40, 40)
$Amber = [Drawing.Color]::FromArgb(160, 95, 0); $Grey = [Drawing.SystemColors]::GrayText; $Ink = [Drawing.SystemColors]::ControlText
$tips  = New-Object Windows.Forms.ToolTip

function New-Button($text, $tag, $onClick) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.Tag = $tag; $b.AutoSize = $true; $b.AutoSizeMode = 'GrowAndShrink'; $b.Font = $Font
    $b.Margin = '3,3,3,3'; $b.Padding = '6,1,6,1'; $b.Add_Click($onClick); $b
}
function New-Label($text, $font = $Font) {
    $l = New-Object Windows.Forms.Label; $l.Text = $text; $l.AutoSize = $true; $l.Font = $font; $l.Margin = '3,2,3,2'; $l
}
function New-CardLabel($text, $font = $Font) {   # fixed width: long text ends in "..." and the tooltip has all of it
    $l = New-Object Windows.Forms.Label; $l.Text = $text; $l.Font = $font; $l.AutoSize = $false; $l.AutoEllipsis = $true
    $l.Size = New-Object Drawing.Size 232, ($font.Height + 2); $l.Margin = '3,2,3,2'; $l
}
function New-Dialog($title, $size) {
    $d = New-Object Windows.Forms.Form
    $d.Text = $title; $d.ClientSize = $size; $d.FormBorderStyle = 'FixedDialog'; $d.StartPosition = 'CenterParent'
    $d.MaximizeBox = $false; $d.MinimizeBox = $false; $d.ShowInTaskbar = $false; $d.Font = $Font
    if ($form.Icon) { $d.Icon = $form.Icon }
    $d
}
function Show-Info($text, $icon = 'Information') {
    if ($form.Visible) { [void][Windows.Forms.MessageBox]::Show($form, "$text", 'Desk Console', 'OK', $icon) }
    else { [void][Windows.Forms.MessageBox]::Show("$text", 'Desk Console', 'OK', $icon) }
}
function Show-Error($text) { Show-Info $text 'Error' }
function Get-Color($s) { switch ($s) { 'ok' { $Green } 'bad' { $Red } 'warn' { $Amber } 'unknown' { $Grey } default { $Ink } } }
function Set-Dot($label, $item) { $label.Text = $item.T; $label.ForeColor = Get-Color $item.S; $tips.SetToolTip($label, $item.T) }
# Action messages stay for $Hold seconds before the next "Updated hh:mm:ss" replaces them.
$script:HoldUntil = Get-Date
function Set-Status($text, $color, [int]$Hold = 30) {
    $status.Text = $text; $status.ForeColor = $color
    $script:HoldUntil = (Get-Date).AddSeconds($Hold)
}
function Show-Balloon($text, $icon = 'Info') {
    if ($script:TrayIcon -and $text) { $script:TrayIcon.ShowBalloonTip(8000, 'Desk Console', $(if ($text.Length -gt 250) { $text.Substring(0, 247) + '...' } else { $text }), $icon) }
}

$form = New-Object Windows.Forms.Form
$form.Text = "Desk Console $AppVersion -- keyboard + mouse + RustDesk"
$ico = Join-Path $PSScriptRoot 'desk-console.ico'
if (Test-Path $ico) { $form.Icon = New-Object Drawing.Icon $ico }
$form.Size = '820,600'; $form.MinimumSize = '600,460'; $form.Font = $Font; $form.StartPosition = 'CenterScreen'; $form.KeyPreview = $true

# toolbar
$bar = New-Object Windows.Forms.FlowLayoutPanel; $bar.Dock = 'Top'; $bar.Height = 38; $bar.Padding = '6,4,6,0'; $bar.WrapContents = $false
$bar.Controls.Add((New-Button '&Refresh' $null { Invoke-FullRefresh }))
$bar.Controls.Add((New-Button '&Connect all' $null { Connect-All }))
$bar.Controls.Add((New-Button 'RustDesk &password...' $null { Show-RustDeskPasswordDialog }))
$bar.Controls.Add((New-Button 'P&hone / tablet...' $null { Show-MobileDialog }))
$bar.Controls.Add((New-Button '&Open share' $null { Start-Process explorer.exe $Root }))
# the same choice as the tray menu's "Open each PC in its own window"; either one updates the other
$winBox = New-Object Windows.Forms.CheckBox; $winBox.Text = 'Each PC in its own &window'; $winBox.AutoSize = $true; $winBox.Margin = '10,7,3,3'
$winBox.Checked = Test-SessionWindows
$tips.SetToolTip($winBox, "On: View + control opens each PC in a RustDesk window of its own, on the display that matches its place in the desk layout.`nOff: every PC is a tab of one RustDesk window.`nApplies from the next View + control once no RustDesk session is open.")
$winBox.Add_Click({ Set-SessionWindows $winBox.Checked })
$bar.Controls.Add($winBox)

# shared folder offline (U7): say so where it is seen, with the two things to do about it
$banner = New-Object Windows.Forms.Panel; $banner.Dock = 'Top'; $banner.Height = 36; $banner.Padding = '10,2,6,2'
$banner.BackColor = [Drawing.Color]::FromArgb(255, 243, 205); $banner.Visible = $false
$bannerLbl = New-Object Windows.Forms.Label; $bannerLbl.Dock = 'Fill'; $bannerLbl.AutoEllipsis = $true; $bannerLbl.TextAlign = 'MiddleLeft'
$bannerLbl.ForeColor = [Drawing.Color]::FromArgb(110, 70, 0)
$bannerBtns = New-Object Windows.Forms.FlowLayoutPanel; $bannerBtns.Dock = 'Right'; $bannerBtns.AutoSize = $true; $bannerBtns.WrapContents = $false
$bannerBtns.Controls.AddRange(@((New-Button 'Retry' $null { Invoke-FullRefresh }), (New-Button 'Open folder' $null { Start-Process explorer.exe $Root })))
$banner.Controls.AddRange(@($bannerLbl, $bannerBtns))

$cards = New-Object Windows.Forms.FlowLayoutPanel; $cards.Dock = 'Top'; $cards.Height = 222; $cards.Padding = '6,4,6,0'; $cards.AutoScroll = $true

# This PC: the lines are made once and only their text changes, so a refresh no longer takes the
# keyboard focus away (U15); the buttons are docked at the bottom and never scroll away (U3).
$synBox = New-Object Windows.Forms.GroupBox; $synBox.Dock = 'Fill'; $synBox.Padding = '10,4,10,6'
$synFlow = New-Object Windows.Forms.FlowLayoutPanel; $synFlow.Dock = 'Fill'; $synFlow.FlowDirection = 'TopDown'; $synFlow.WrapContents = $false; $synFlow.AutoScroll = $true
function New-PanelLine($font = $Font) {
    $l = New-Object Windows.Forms.Label; $l.AutoSize = $false; $l.AutoEllipsis = $true; $l.Font = $font
    $l.Size = New-Object Drawing.Size 760, ($font.Height + 3); $l.Margin = '3,1,3,1'; $synFlow.Controls.Add($l); $l
}
$script:Lines = [ordered]@{}
foreach ($n in 'Kvm', 'Layout', 'Hotkeys', 'Auto', 'Updates', 'RustDesk', 'DevBox') { $script:Lines[$n] = New-PanelLine $(if ($n -eq 'Kvm') { $Bold } else { $Font }) }
function Set-LineWidth { foreach ($l in $script:Lines.Values) { $l.Width = [Math]::Max(200, $synFlow.Width - [Windows.Forms.SystemInformation]::VerticalScrollBarWidth - 10) } }
$synFlow.Add_Resize({ Set-LineWidth })
$panelBtns = New-Object Windows.Forms.FlowLayoutPanel; $panelBtns.Dock = 'Bottom'; $panelBtns.AutoSize = $true; $panelBtns.AutoSizeMode = 'GrowAndShrink'
$btnOpen    = New-Button 'Open Deskflow' $null { Open-KvmApp }
$btnRestart = New-Button 'Restart Deskflow' $null { Restart-Kvm }
$btnAuto    = New-Button 'Automatic sign-in...' $null { Show-AutoLogonDialog }
$btnUpd     = New-Button 'Windows Update...' $null { Show-UpdatesDialog }
$btnDev     = New-Button 'Dev box...' $null { Show-DevBoxDialog }
$btnRepair  = New-Button 'Repair / update this PC...' $null { Start-Repair }
$panelBtns.Controls.AddRange(@($btnOpen, $btnRestart, $btnAuto, $btnUpd, $btnDev, $btnRepair))
foreach ($b in $panelBtns.Controls) { $b.Padding = '1,1,1,1'; $b.Margin = '2,3,2,3' }   # one row at the default width
$synBox.Controls.AddRange(@($synFlow, $panelBtns))

# status bar (U2): the old status label wrapped below the toolbar at the default width, so none
# of its messages were ever seen
$strip = New-Object Windows.Forms.StatusStrip
$status = New-Object Windows.Forms.ToolStripStatusLabel; $status.Spring = $true; $status.TextAlign = 'MiddleLeft'; $status.ForeColor = $Grey
$shareLbl = New-Object Windows.Forms.ToolStripStatusLabel; $shareLbl.BorderSides = 'Left'
$pwLbl = New-Object Windows.Forms.ToolStripStatusLabel; $pwLbl.BorderSides = 'Left'
$newLbl = New-Object Windows.Forms.ToolStripStatusLabel; $newLbl.BorderSides = 'Left'; $newLbl.IsLink = $true
$newLbl.Text = "What's new"; $newLbl.AccessibleName = "What's new in Desk Console $AppVersion"; $newLbl.Visible = Test-Path -LiteralPath $WhatsNewFile
$newLbl.Add_Click({ Show-WhatsNew })
foreach ($i in $status, $shareLbl, $pwLbl, $newLbl) { [void]$strip.Items.Add($i) }

# docking runs from the last control added: toolbar, banner, cards on top; status bar; panel fills
$form.Controls.AddRange(@($synBox, $strip, $cards, $banner, $bar))
$bar.TabIndex = 0; $banner.TabIndex = 1; $cards.TabIndex = 2; $synBox.TabIndex = 3; $strip.TabIndex = 4   # tab order = screen order
$form.Add_KeyDown({ param($s, $e) if ("$($e.KeyCode)" -eq 'F5') { Invoke-FullRefresh; $e.Handled = $true } })

# per-card actions for another PC (F6, C-3)
$actMenu = New-Object Windows.Forms.ContextMenuStrip
foreach ($a in @(@('restart', 'Restart...'), @('sleep', 'Sleep...'), @('lock', 'Lock...'), @('signout', 'Sign out...'))) {
    $it = New-Object Windows.Forms.ToolStripMenuItem $a[1]; $it.Tag = $a[0]
    $it.Add_Click({ Request-Command $actMenu.Tag $this.Tag }); [void]$actMenu.Items.Add($it)
}
[void]$actMenu.Items.Add('-')
# On by default; kvm.json "showRustDeskWindow" lists the PCs where it is off (Setup-Synergy.ps1
# Sync-CmWatcher): that PC's 2-minute task starts or stops a watcher that hides RustDesk's "someone
# is connected" window there
$cmItem = New-Object Windows.Forms.ToolStripMenuItem "Hide RustDesk's connection window there"
$cmItem.Add_Click({ Set-HideCm $actMenu.Tag (-not $cmItem.Checked) }); [void]$actMenu.Items.Add($cmItem)
function Get-ShowCmList { @($script:Kvm.showRustDeskWindow | Where-Object { $_ } | ForEach-Object { "$_" }) }
function Show-ActionMenu($btn) {
    $actMenu.Tag = $btn.Tag; $cmItem.Checked = (Get-ShowCmList) -notcontains $btn.Tag
    $actMenu.Show($btn, (New-Object Drawing.Point 0, $btn.Height))
}
function Set-HideCm($name, [bool]$on) {
    if ($script:FromCache) { throw 'The shared folder is not reachable, so kvm.json cannot be changed now.' }
    $k = [IO.File]::ReadAllText($KvmPath) | ConvertFrom-Json
    $list = @($k.showRustDeskWindow | Where-Object { $_ -and "$_" -ne $name } | ForEach-Object { "$_" })
    if (-not $on) { $list += $name }
    if ($list.Count) { $k | Add-Member -NotePropertyName showRustDeskWindow -NotePropertyValue ([object[]]$list) -Force }
    elseif ($k.PSObject.Properties['showRustDeskWindow']) { $k.PSObject.Properties.Remove('showRustDeskWindow') }
    if ($k.PSObject.Properties['hideRustDeskWindow']) { $k.PSObject.Properties.Remove('hideRustDeskWindow') }   # 1.8.4's opt-in list
    [IO.File]::WriteAllText($KvmPath, ($k | ConvertTo-Json -Depth 6), [Text.Encoding]::ASCII)   # one write, as Move-InRow (R6)
    $script:Kvm = $k
    Set-Status "$($name) $(if ($on) { 'hides' } else { 'shows' }) RustDesk's connection window from its next 2-minute run." $Ink
}
function Request-Command($name, $action) {
    $st = $script:Reports[$name]; $age = Get-StatusAge $st
    $verb = @{ restart = 'Restart'; sleep = 'Put to sleep'; lock = 'Lock'; signout = 'Sign out of' }[$action]
    $what = @{ restart = 'It restarts after a 60-second warning on its screen; unsaved work there is lost.'
               sleep   = 'Wake it again with the Wake button (needs Wake-on-LAN in its BIOS / network card).'
               lock    = 'Whoever is at that desk has to sign in again.'
               signout = 'Unsaved work there is lost. With automatic sign-in on, Windows signs straight back in.' }[$action]
    $text = "$verb $($name)?`r`n`r`n$what`r`n`r`nIts Desk Console agent picks this up within 2 minutes; the request expires after 10."
    if ($action -eq 'restart' -and $st -and $st.legalNotice) { $text += "`r`n`r`nAfter the restart it waits at the sign-in notice: click OK there (RustDesk works there)." }
    if ($null -eq $age) { $text += "`r`n`r`n$name has not reported yet (its agent is not running?), so nothing may happen." }
    elseif ($age -gt $StaleMin) { $text += "`r`n`r`n$name last reported $(Format-Minutes $age) ago, so nothing may happen." }
    if ("$([Windows.Forms.MessageBox]::Show($form, $text, 'Desk Console', 'YesNo', 'Warning', 'Button2'))" -ne 'Yes') { return }
    Send-DeskCommand $name $action
    Set-Status "$verb $($name): requested; its agent runs it within 2 minutes." $Ink
    Update-Cards $script:LastProbe (Get-KvmContext) | Out-Null
}

# ---------------------------------------------------------------- cards
$script:CardMap = @{}; $script:LastProbe = @{}
function New-EmptyState {   # first run (U16): what to do, with the two buttons that do it
    $p = New-Object Windows.Forms.FlowLayoutPanel; $p.FlowDirection = 'TopDown'; $p.AutoSize = $true; $p.WrapContents = $false; $p.Margin = '10,10,10,10'
    $p.Controls.Add((New-Label 'No PCs registered yet. Run setup (DeskConsoleSetup) on each PC: it adds the PC to machines.csv in the shared folder.'))
    $p.Controls.Add((New-Label "Shared folder: $Root")); $p.Controls[1].ForeColor = $Grey
    $r = New-Object Windows.Forms.FlowLayoutPanel; $r.AutoSize = $true; $r.Margin = '0,8,0,0'
    $r.Controls.AddRange(@((New-Button 'Run setup on this PC' $null { Start-Repair }), (New-Button 'Open shared folder' $null { Start-Process explorer.exe $Root })))
    $p.Controls.Add($r); $p
}
function New-Card($m, [bool]$grid, $row) {
    $isMe = $m.Name -eq $Me
    $g = New-Object Windows.Forms.GroupBox; $g.Size = '246,206'; $g.Margin = '4,4,4,4'   # 3 x 254 fits beside a scroll bar
    $g.Text = if ($isMe) { "$($m.Name)  (this PC)" } else { $m.Name }
    $f = New-Object Windows.Forms.FlowLayoutPanel; $f.Dock = 'Fill'; $f.FlowDirection = 'TopDown'; $f.WrapContents = $false
    $ip = New-CardLabel $(if ($m.HasIP) { "$($m.IP)   $($m.MAC)" } else { "no address in machines.csv   $($m.MAC)" }); $ip.ForeColor = $Grey
    $c = @{ On = (New-CardLabel 'Online: ...' $Bold); Kv = (New-CardLabel 'Keyboard + mouse: ...'); Rd = (New-CardLabel 'RustDesk: ...')
            St = (New-CardLabel ''); Fl = (New-CardLabel '') }
    $c.Fl.ForeColor = $Amber
    $f.Controls.AddRange(@($ip, $c.On, $c.Kv, $c.Rd, $c.St, $c.Fl))
    if (-not $isMe) {   # this PC's own card needs no remote buttons (U11)
        $b = New-Object Windows.Forms.FlowLayoutPanel; $b.AutoSize = $true; $b.WrapContents = $false; $b.Margin = '0,3,0,0'
        $c.View = New-Button 'View + control' $m.Name { Connect-Machine (Get-Machine $this.Tag) }
        $c.Wake = New-Button 'Wake' $m.Name { Invoke-Wake $this.Tag }; $c.Wake.Visible = $false
        $c.Act  = New-Button 'Actions' $m.Name { Show-ActionMenu $this }
        $c.View.AccessibleName = "View and control $($m.Name)"; $c.Wake.AccessibleName = "Wake $($m.Name)"; $c.Act.AccessibleName = "Actions for $($m.Name)"
        $b.Controls.AddRange(@($c.View, $c.Wake, $c.Act)); $f.Controls.Add($b)
    }
    $g.Controls.Add($f)
    # desk order: < and > swap this PC with its neighbour in kvm.json row (C-6, U14)
    $i = Find-Index $row $m.Name
    $why = if ($grid) { 'kvm.json has a "grid", which sets the desk order: edit it there (these buttons change "row" only).' }
           elseif ($i -lt 0) { "$($m.Name) is not in the desk layout (kvm.json row) yet." } else { $null }
    foreach ($d in -1, 1) {
        $mv = New-Object Windows.Forms.Button; $mv.Text = $(if ($d -lt 0) { '<' } else { '>' }); $mv.Tag = @{ Name = $m.Name; Dir = $d }
        $mv.Size = '22,20'; $mv.FlatStyle = 'Flat'; $mv.Padding = '0,0,0,0'; $mv.Font = $Font; $mv.BackColor = [Drawing.SystemColors]::Control
        $mv.Location = New-Object Drawing.Point $(if ($d -lt 0) { 194 } else { 218 }), 0
        $mv.Enabled = (-not $why) -and $(if ($d -lt 0) { $i -gt 0 } else { $i -ge 0 -and $i -lt @($row).Count - 1 })
        $mv.AccessibleName = "Move $($m.Name) $(if ($d -lt 0) { 'left' } else { 'right' }) in the desk layout"
        $tips.SetToolTip($mv, $(if ($why) { $why } else { "$($mv.AccessibleName) (kvm.json row; the server applies it within 2 minutes)" }))
        $mv.Add_Click({ Move-Card $this.Tag.Name $this.Tag.Dir })
        $g.Controls.Add($mv); $mv.BringToFront()
    }
    $script:CardMap[$m.Name] = $c
    $g
}
function Build-Cards {
    $cards.SuspendLayout()
    foreach ($c in @($cards.Controls)) { $c.Dispose() }
    $cards.Controls.Clear(); $script:CardMap = @{}
    $ms = @(Get-OrderedMachines)
    if (-not $ms.Count) { $cards.Controls.Add((New-EmptyState)) }
    else {
        $grid = [bool]($script:Kvm -and $script:Kvm.grid); $row = @(Get-LayoutNames $script:Kvm)
        foreach ($m in $ms) { $cards.Controls.Add((New-Card $m $grid $row)) }
    }
    $cards.ResumeLayout()
}
function Get-CardKey {   # a change here rebuilds the cards: a new PC, a new address, a new desk order
    ((@(Get-OrderedMachines) | ForEach-Object { "$($_.Name)|$($_.IP)|$($_.MAC)" }) -join ';') +
        "|grid:$([bool]($script:Kvm -and $script:Kvm.grid))|row:$((Get-LayoutNames $script:Kvm) -join ',')"
}
function Update-Cards($res, $ctx) {   # returns each card's state, for the change alerts
    foreach ($m in $script:Machines) {
        $c = $script:CardMap[$m.Name]; if (-not $c) { continue }
        $s = Get-CardState $m $res[$m.Name] $ctx
        Set-Dot $c.On $s.Online; Set-Dot $c.Kv $s.Kvm; Set-Dot $c.Rd $s.Rd; Set-Dot $c.St $s.Status
        $c.Fl.Text = (@($s.Flags) | ForEach-Object { $_.Short }) -join '; '
        $c.Fl.ForeColor = if ($s.Stale) { $Grey } else { $Amber }
        $tips.SetToolTip($c.Fl, ((@($s.Flags) | ForEach-Object { $_.Long }) -join "`r`n"))
        if ($c.View) {
            $c.Wake.Visible = $s.ShowWake; $c.View.Visible = -not $s.ShowWake
            $c.View.Enabled = $s.CanView; $c.Act.Enabled = $s.CanAct
        }
        [pscustomobject]@{ Name = $m.Name; State = $s }
    }
}
function Move-Card($name, [int]$dir) {
    Move-InRow $name $dir
    Build-Cards; Update-Cards $script:LastProbe (Get-KvmContext) | Out-Null
    Set-Status 'Layout saved -- the server applies it within 2 minutes.' $Ink
}
function Connect-All {   # skip what the last probe could not reach, and say so (U11)
    $script:ConnectQueue.Clear(); $skip = @()
    foreach ($m in Get-OrderedMachines) {
        if ($m.Name -eq $Me) { continue }
        $r = $script:LastProbe[$m.Name]
        if (-not $m.HasIP -or ($r -and -not $r.RustDesk)) { $skip += $m.Name; continue }
        $script:ConnectQueue.Enqueue($m)
    }
    $n = $script:ConnectQueue.Count
    Set-Status "Opening $n in RustDesk, one after another$(if ($skip.Count) { "; skipped $($skip -join ', ') (RustDesk not reachable)" })." $Ink
    $script:ConnectWait = $null; if ($n) { $connectTimer.Start() }
}
# One at a time: a second "rustdesk --connect" hands its connection to the running RustDesk's
# window (core_main.rs, WM_USER+2, RustDesk 1.5.0), and one sent while that RustDesk is still
# starting is lost -- Connect all opened only the first PC. The next PC goes once the last one's
# window is up; as tabs (no new window) 2 s after a RustDesk window exists; at most 15 s each.
$script:ConnectQueue = New-Object Collections.Queue
$script:ConnectWait = $null
$connectTimer = New-Object Windows.Forms.Timer; $connectTimer.Interval = 500
$connectTimer.Add_Tick({
    if ($script:ConnectWait) {
        $w = $script:ConnectWait; $now = @(Get-RustDeskWindows -Sessions); $age = ((Get-Date) - $w.At).TotalSeconds
        $ready = @($now | Where-Object { $w.Before -notcontains $_ }).Count -or
                 (-not (Test-SessionWindows) -and $now.Count -and $age -ge 2) -or $age -ge 15
        if (-not $ready) { return }
        $script:ConnectWait = $null
    }
    if (-not $script:ConnectQueue.Count) { $connectTimer.Stop(); return }
    $m = $script:ConnectQueue.Dequeue()
    $script:ConnectWait = @{ Before = @(Get-RustDeskWindows -Sessions); At = Get-Date }
    try { Connect-Machine $m } catch { Set-Status "$($m.Name): $(Get-ErrorText $_.Exception)" $Red }
})

# ---------------------------------------------------------------- wake, with a follow-up (F10)
$wakeTimer = New-Object Windows.Forms.Timer; $wakeTimer.Interval = 5000
function Invoke-Wake($name) {
    $m = Get-Machine $name
    $route = Send-Wake $m
    $where = if ($route) { "on $($route.Broadcast)" } elseif ($m.HasIP) { "-- but no network adapter here is on its network, so it may not arrive" } else { '(no address to watch for an answer)' }
    if ($m.HasIP) { $script:Waking[$name] = @{ Start = Get-Date; Probe = $null }; $wakeTimer.Start(); $where += '; watching for 2 minutes' }
    Set-Status "Wake sent to $name $where." $Ink 120
}
$wakeTimer.Add_Tick({
    try {
        foreach ($name in @($script:Waking.Keys)) {
            $w = $script:Waking[$name]; $m = Get-Machine $name
            if ($w.Probe) {
                $r = (Read-Probes @($w.Probe))[$name]; $w.Probe = $null
                if ($r -and $r.Online) {
                    $script:Waking.Remove($name); $msg = "$name is awake after $([int]((Get-Date) - $w.Start).TotalSeconds) s."
                    Set-Status $msg $Green; Show-Balloon $msg; continue
                }
            }
            if (-not $m -or ((Get-Date) - $w.Start).TotalSeconds -ge 120) {
                $script:Waking.Remove($name)
                Set-Status "$name did not answer within 2 minutes of Wake (is Wake-on-LAN on in its BIOS and network card?)." $Red 60; continue
            }
            $w.Probe = @(Start-Probes @($m))[0]
            $c = $script:CardMap[$name]
            if ($c) { Set-Dot $c.St @{ T = "Waking: no answer yet ($([int]((Get-Date) - $w.Start).TotalSeconds) s)"; S = 'warn' } }
        }
        if (-not $script:Waking.Count) { $wakeTimer.Stop() }
    } catch { Set-Status "Wake: $($_.Exception.Message)" $Red }
})

# ---------------------------------------------------------------- admin steps (C-1)
# Automatic sign-in and Windows Update run setup elevated with -NoPause -ResultFile: no hidden
# "Press Enter" console that froze this window until found (U12), and a result to show here.
$script:AdminJob = $null
function Remove-Secrets($f) { if ($f) { Remove-Item $f -Force -ErrorAction SilentlyContinue } }
function Start-AdminSetup([string]$phase, [string[]]$phaseArgs, [string]$what, [string]$secrets) {
    if ($script:AdminJob) { Remove-Secrets $secrets; throw 'An admin step is still running -- finish that window first.' }
    $setup = Join-Path $PSScriptRoot 'Setup-Synergy.ps1'
    if (-not (Test-Path $setup)) { $setup = Join-Path $Root 'Setup-Synergy.ps1' }
    $setup = ConvertTo-Unc $setup   # the elevated window cannot see mapped drives
    $res = Join-Path $env:TEMP ('ds-result-' + [guid]::NewGuid().ToString('N') + '.txt')
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$setup`"", '-Phase', $phase) + $phaseArgs + @('-NoPause', '-ResultFile', "`"$res`"")
    if ($secrets) { $a += @('-SecretsFile', "`"$secrets`"") }
    try { $p = Start-Process powershell.exe -Verb RunAs -PassThru -ArgumentList $a }
    catch { Remove-Secrets $secrets; Set-Status "$($what): cancelled (the Windows prompt was declined)." $Grey; return }
    $script:AdminJob = @{ P = $p; Result = $res; What = $what; Secrets = $secrets; Phase = $phase }
    $btnAuto.Enabled = $false; $btnUpd.Enabled = $false
    Set-Status "$($what): waiting for the admin window..." $Grey 3600
}
# Done = the process ended; without a usable process handle, the result file's last word says so:
# "<Phase>|OK|", or the trap's "<Phase>|FAIL|... (log: ...)" (other FAIL lines come mid-run).
function Test-AdminDone($j) {
    if ($j.P) { try { return $j.P.HasExited } catch {} }
    [bool](Select-String -LiteralPath $j.Result -Pattern '\|OK\|\s*$', '\|FAIL\|.*\(log: ' -Quiet -ErrorAction SilentlyContinue)
}
function Update-AdminJob {
    $j = $script:AdminJob
    if (-not $j -or -not (Test-AdminDone $j)) { return }
    $script:AdminJob = $null; $btnAuto.Enabled = $true; $btnUpd.Enabled = $true
    Remove-Secrets $j.Secrets
    $out = @(Get-Content $j.Result -ErrorAction SilentlyContinue | Where-Object { $_ })
    Remove-Item $j.Result -Force -ErrorAction SilentlyContinue
    Show-SetupResult $j.What $j.Phase $out
    Update-Panel
}
# setup appends "<Phase>|WARN|text", "<Phase>|FAIL|text" and, when the phase finished, "<Phase>|OK|"
function Show-SetupResult($what, $phase, [string[]]$out) {
    $fail = @($out | Where-Object { $_ -match '^[^|]*\|FAIL\|' } | ForEach-Object { ($_ -split '\|', 3)[2] })
    $warn = @($out | Where-Object { $_ -match '^[^|]*\|WARN\|' } | ForEach-Object { ($_ -split '\|', 3)[2] })
    $ok   = [bool]@($out | Where-Object { $_ -match "^$([regex]::Escape($phase))\|OK\|" }).Count
    if ($fail.Count) {
        Set-Status "$($what): FAILED -- $($fail[0])" $Red 120
        Show-Error ("$what failed:`r`n`r`n" + (($fail + $warn) -join "`r`n"))
    } elseif (-not $ok) {
        Set-Status "$($what): did not finish -- see logs\$Me-$phase.log in the shared folder." $Red 120
    } elseif ($warn.Count) {
        Set-Status "$($what): done, with $($warn.Count) note(s)." $Amber 120
        Show-Info ("$what is done. Please note:`r`n`r`n" + ($warn -join "`r`n")) 'Warning'
    } else { Set-Status "$($what): done." $Green }
}

# ---------------------------------------------------------------- this PC: buttons
function Open-KvmApp {
    $exe = $script:Info.Exe
    if (-not $exe -or -not (Test-Path $exe)) { throw "$($script:Info.Provider) is not installed on this PC. Use Repair / update this PC." }
    Start-Process $exe
}
# Deskflow: restarting its window as this user makes the daemon start a fresh core with the
# current settings, no admin (Setup-Synergy.ps1 does the same). Touching the daemon once left
# keyboard sharing down, so the service is restarted (with UAC) only when it is not running.
$restartTimer = New-Object Windows.Forms.Timer; $restartTimer.Interval = 2000
$restartTimer.Add_Tick({
    $restartTimer.Stop()
    try { Start-Process $script:RestartExe; Set-Status 'Deskflow restarted.' $Green } catch { Set-Status "Deskflow did not start: $($_.Exception.Message)" $Red }
})
function Restart-Kvm {
    $k = $script:Info
    if ($k.Provider -eq 'Deskflow' -and $k.Running -and $k.Exe) {
        Get-Process -Name deskflow -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        $script:RestartExe = $k.Exe; $restartTimer.Start()   # start it again in 2 s without freezing the window
        Set-Status 'Restarting the Deskflow window...' $Grey; return
    }
    $p = $k.Provider
    try {
        Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command',
            "Get-Service | Where-Object { `$_.DisplayName -match '$p' -and `$_.StartType -ne 'Disabled' } | Restart-Service"
        Set-Status "$p service restart requested (admin)." $Ink
    } catch { Set-Status "$p restart: cancelled." $Grey }
}
# Repair / update (C-13): the newest DeskConsoleSetup-*.exe in the shared folder (the wizard), else
# the installed setup script in a console.
function Start-Repair {
    $exe = $null
    if ($script:ShareUp) {
        $exe = Get-ChildItem $Root -Filter 'DeskConsoleSetup-*.exe' -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -match '^DeskConsoleSetup-\d+(\.\d+){1,3}\.exe$' } |
               Sort-Object { [version]($_.Name -replace '^DeskConsoleSetup-|\.exe$', '') } -Descending | Select-Object -First 1
    }
    if ($exe) { Start-Process $exe.FullName; Set-Status "Started $($exe.Name)." $Ink; return }
    $setup = @((Join-Path $InstallDir 'Setup-Synergy.ps1'), (Join-Path $PSScriptRoot 'Setup-Synergy.ps1')) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $setup) { throw "No DeskConsoleSetup-*.exe in $Root and no setup script here. Download DeskConsoleSetup from the project's releases." }
    Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$setup`"", '-Phase', 'All'
    Set-Status 'Started setup in a console window (no DeskConsoleSetup-*.exe in the shared folder).' $Ink
}

# ---------------------------------------------------------------- dialogs
function Show-RustDeskPasswordDialog {
    $d = New-Dialog 'RustDesk password' '420,216'
    $l = New-Label 'The RustDesk password of your PCs (the same on every PC):'; $l.Location = '14,12'
    $l1 = New-Label 'Password:'; $l1.Location = '14,44'
    $t1 = New-Object Windows.Forms.TextBox; $t1.UseSystemPasswordChar = $true; $t1.Location = '130,41'; $t1.Width = 270
    $l2 = New-Label 'Again:'; $l2.Location = '14,76'
    $t2 = New-Object Windows.Forms.TextBox; $t2.UseSystemPasswordChar = $true; $t2.Location = '130,73'; $t2.Width = 270
    $n = New-Label "Kept in this PC's Windows Credential Manager (DeskConsole:RustDesk),`r`nnever on the shared folder."; $n.Location = '14,106'; $n.ForeColor = $Grey
    $ok = New-Button 'Save on this PC' $null {}; $ok.Location = '14,170'; $ok.DialogResult = 'OK'
    $rm = New-Button 'Remove' $null {}; $rm.Location = '150,170'; $rm.DialogResult = 'Abort'; $rm.Enabled = [bool][DeskCred]::Read($CredTarget)
    $no = New-Button 'Cancel' $null {}; $no.Location = '330,170'; $no.DialogResult = 'Cancel'
    $d.Controls.AddRange(@($l, $l1, $t1, $l2, $t2, $n, $ok, $rm, $no)); $d.AcceptButton = $ok; $d.CancelButton = $no
    $r = "$($d.ShowDialog($form))"
    if ($r -eq 'OK') {
        if (-not $t1.Text -or $t1.Text -cne $t2.Text) { Show-Error 'The passwords are empty or different -- nothing saved.'; return }
        [DeskCred]::Write($CredTarget, 'rustdesk', $t1.Text); Set-Status 'RustDesk password saved on this PC.' $Green
    } elseif ($r -eq 'Abort') { [void][DeskCred]::Delete($CredTarget); Set-Status 'RustDesk password removed from this PC.' $Ink }
    $t1.Text = ''; $t2.Text = ''
    Update-Strip; Update-Panel
}

# The password goes to the elevated script through a %TEMP% file (deleted on read), never a
# command line; the script checks it with Windows before storing it.
function Show-AutoLogonDialog {
    $d = New-Dialog 'Automatic sign-in at boot' '470,370'
    # local account: just the name (DOMAIN\name was garbled in this box on one PC); domain account: DOMAIN\name
    $myName = if ($env:USERDOMAIN -eq $env:COMPUTERNAME) { $env:USERNAME } else { "$env:USERDOMAIN\$env:USERNAME" }
    $now  = New-Label "Now: $((Get-PanelText $script:Info (Get-LocalStatus)).Auto.T -replace '^Automatic sign-in at boot: ')"; $now.Location = '14,10'; $now.ForeColor = $Grey
    $on   = New-Object Windows.Forms.RadioButton; $on.Text = 'Turn on with an existing account (e.g. your own)'; $on.Location = '14,38'; $on.AutoSize = $true; $on.Checked = $true
    $new  = New-Object Windows.Forms.RadioButton; $new.Text = 'Turn on with a dedicated local account (desktops; created if missing)'; $new.Location = '14,62'; $new.AutoSize = $true
    $lu   = New-Label 'Account:'; $lu.Location = '34,90'
    $user = New-Object Windows.Forms.TextBox; $user.Location = '34,110'; $user.Width = 400; $user.Text = $myName
    $l1   = New-Label 'Password:'; $l1.Location = '34,140'
    $p1   = New-Object Windows.Forms.TextBox; $p1.Location = '34,160'; $p1.Width = 400; $p1.UseSystemPasswordChar = $true
    $l2   = New-Label 'Password again:'; $l2.Location = '34,188'
    $p2   = New-Object Windows.Forms.TextBox; $p2.Location = '34,208'; $p2.Width = 400; $p2.UseSystemPasswordChar = $true
    $lock = New-Object Windows.Forms.CheckBox; $lock.Text = 'Lock the screen right after (recommended)'; $lock.Location = '34,240'; $lock.AutoSize = $true; $lock.Checked = $true
    $off  = New-Object Windows.Forms.RadioButton; $off.Text = 'Turn off'; $off.Location = '14,272'; $off.AutoSize = $true
    $ok   = New-Button 'Apply (asks for admin)' $null {}; $ok.Location = '14,322'; $ok.DialogResult = 'OK'
    $no   = New-Button 'Cancel' $null {}; $no.Location = '380,322'; $no.DialogResult = 'Cancel'
    $sync = { $en = -not $off.Checked; foreach ($c in $user, $p1, $p2, $lock) { $c.Enabled = $en }
              if ($new.Checked -and $user.Text -eq $myName) { $user.Text = 'BuildRunner' }
              elseif ($on.Checked -and $user.Text -eq 'BuildRunner') { $user.Text = $myName } }
    $on.Add_CheckedChanged($sync); $new.Add_CheckedChanged($sync); $off.Add_CheckedChanged($sync)
    $d.Controls.AddRange(@($now, $on, $new, $lu, $user, $l1, $p1, $l2, $p2, $lock, $off, $ok, $no)); $d.AcceptButton = $ok; $d.CancelButton = $no
    if ("$($d.ShowDialog($form))" -ne 'OK') { return }
    $enable = -not $off.Checked
    if ($enable -and (-not $p1.Text -or $p1.Text -cne $p2.Text)) { Show-Error 'The passwords are empty or different -- nothing changed.'; return }
    $a = @('-AutoLogon', $(if ($enable) { 'Enable' } else { 'Disable' })); $f = $null
    if ($enable) {
        $f = Join-Path $env:TEMP ('ds-al-' + [guid]::NewGuid().ToString('N') + '.txt')
        # UTF-8 WITH a BOM: Windows PowerShell 5.1 reads a file without one in the ANSI code page,
        # which changed any accented character in the password (R8)
        [IO.File]::WriteAllLines($f, [string[]]@("al_user=$($user.Text)", "al_pass=$($p1.Text)", "al_new=$(if ($new.Checked) { 1 } else { 0 })"), (New-Object Text.UTF8Encoding $true))
        if ($lock.Checked) { $a += '-AutoLogonLock' }
    }
    $p1.Text = ''; $p2.Text = ''
    Start-AdminSetup 'AutoLogon' $a 'Automatic sign-in' $f
}

function Show-UpdatesDialog {
    $st = Get-LocalStatus
    $d = New-Dialog 'Windows Update restarts' '500,236'
    $now = New-Label "Now: $(switch ($st.updates) { 'complete' { 'no automatic restart while someone is signed in' } 'incomplete' { 'set, but incomplete (AUOptions is not 4)' } default { 'Windows default' } })$(if ($st.rebootPending) { '; a restart is pending' })"
    $now.Location = '14,12'; $now.ForeColor = $Grey
    $on = New-Object Windows.Forms.RadioButton; $on.Text = 'No automatic restart while someone is signed in'; $on.Location = '14,42'; $on.AutoSize = $true; $on.Checked = $true   # also when on: re-applying is the fix for "incomplete"
    $off = New-Object Windows.Forms.RadioButton; $off.Text = 'Windows default (may restart by itself to finish updates)'; $off.Location = '14,68'; $off.AutoSize = $true
    $n = New-Label "Updates still download and install; the restart waits until someone restarts the PC.`r`nPro / Enterprise / Education honour it; Home ignores it."
    $n.Location = '14,102'; $n.ForeColor = $Grey
    $ok = New-Button 'Apply (asks for admin)' $null {}; $ok.Location = '14,190'; $ok.DialogResult = 'OK'
    $no = New-Button 'Cancel' $null {}; $no.Location = '410,190'; $no.DialogResult = 'Cancel'
    $d.Controls.AddRange(@($now, $on, $off, $n, $ok, $no)); $d.AcceptButton = $ok; $d.CancelButton = $no
    if ("$($d.ShowDialog($form))" -ne 'OK') { return }
    Start-AdminSetup 'Updates' @('-NoAutoRestart', $(if ($on.Checked) { 'Enable' } else { 'Disable' })) 'Windows Update' $null
}

# Dev box (F11): several folders, each with VS Code and/or `claude --continue` (its last chat).
# Start-DevBox.ps1 -Configure -Items takes the whole list, checks it, writes devbox.json and
# registers the sign-in task; its "Note:" lines (VS Code / claude not found) are shown (U12).
function Show-DevBoxDialog {
    if (-not $DevScript) { throw 'Start-DevBox.ps1 is missing. Use Repair / update this PC.' }
    $items = @(Get-DevBoxItems (Get-DevBoxConf))
    $d = New-Dialog 'Dev box: resume at sign-in' '640,362'
    $l = New-Label "When $env:USERNAME signs in to this PC (also after an automatic sign-in), open:"; $l.Location = '14,12'
    $g = New-Object Windows.Forms.DataGridView; $g.Location = '14,40'; $g.Size = '612,170'; $g.RowHeadersVisible = $false
    $g.AllowUserToAddRows = $false; $g.AllowUserToResizeRows = $false; $g.SelectionMode = 'FullRowSelect'; $g.BackgroundColor = [Drawing.SystemColors]::Window
    $c1 = New-Object Windows.Forms.DataGridViewTextBoxColumn; $c1.HeaderText = 'Folder'; $c1.AutoSizeMode = 'Fill'
    $c2 = New-Object Windows.Forms.DataGridViewCheckBoxColumn; $c2.HeaderText = 'VS Code'; $c2.Width = 70
    $c3 = New-Object Windows.Forms.DataGridViewCheckBoxColumn; $c3.HeaderText = 'claude --continue'; $c3.Width = 120
    [void]$g.Columns.AddRange([Windows.Forms.DataGridViewColumn[]]@($c1, $c2, $c3))
    $g.Add_CurrentCellDirtyStateChanged({ if ($g.IsCurrentCellDirty) { [void]$g.CommitEdit('CurrentCellChange') } })   # a tick counts at once, not on leaving the cell
    foreach ($it in $items) { [void]$g.Rows.Add($it.Path, $it.Code, $it.Claude) }
    if (-not $items.Count) { [void]$g.Rows.Add('', $true, $true) }
    $add = New-Button 'Add folder...' $null {
        $fb = New-Object Windows.Forms.FolderBrowserDialog
        if ("$($fb.ShowDialog())" -eq 'OK') {
            $empty = @($g.Rows | Where-Object { -not "$($_.Cells[0].Value)".Trim() }) | Select-Object -First 1
            if ($empty) { $empty.Cells[0].Value = $fb.SelectedPath } else { [void]$g.Rows.Add($fb.SelectedPath, $true, $true) }
        } }
    $add.Location = '14,216'
    $rm = New-Button 'Remove' $null { foreach ($r in @($g.SelectedRows)) { $g.Rows.Remove($r) } }; $rm.Location = '124,216'
    $n = New-Label "claude --continue opens a terminal tab in that folder and resumes its last Claude Code chat.`r`nVS Code brings back its other windows by itself."
    $n.Location = '14,252'; $n.ForeColor = $Grey
    $ok  = New-Button 'Apply' $null {}; $ok.Location = '14,316'; $ok.DialogResult = 'OK'
    $now = New-Button 'Apply and run now' $null {}; $now.Location = '84,316'; $now.DialogResult = 'Retry'
    $off = New-Button 'Turn off' $null {}; $off.Location = '226,316'; $off.DialogResult = 'Abort'
    $no  = New-Button 'Cancel' $null {}; $no.Location = '556,316'; $no.DialogResult = 'Cancel'
    $d.Controls.AddRange(@($l, $g, $add, $rm, $n, $ok, $now, $off, $no)); $d.CancelButton = $no
    $r = "$($d.ShowDialog($form))"
    if ($r -eq 'Cancel') { return }
    $g.EndEdit() | Out-Null
    if ($r -eq 'Abort') { [void](& $DevScript -Disable 6>&1 | Out-String); Set-Status 'Dev box resume turned off.' $Ink; Update-Panel; return }
    $list = @(foreach ($row in $g.Rows) {
        $p = "$($row.Cells[0].Value)".Trim()
        if ($p) { @{ path = $p; code = [bool]$row.Cells[1].Value; claude = [bool]$row.Cells[2].Value } }
    })
    if (-not $list.Count) { throw 'Add a folder, or use Turn off.' }
    $out = Save-DevBox $list
    $notes = @($out -split "\r?\n" | Where-Object { $_ -match 'Note:' })
    if ($r -eq 'Retry') {
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$DevScript`"", '-Now'
    }
    Set-Status "Dev box resume saved ($($list.Count) folder$(if ($list.Count -ne 1) { 's' }))$(if ($r -eq 'Retry') { ' and started' })." $Green
    if ($notes.Count) { Show-Info ($notes -join "`r`n") 'Warning' }
    Update-Panel
}
function Save-DevBox($list) {
    if ((Get-Command $DevScript).Parameters.ContainsKey('Items')) { return (& $DevScript -Configure -Items $list 6>&1 | Out-String) }
    # an older installed Start-DevBox.ps1 (Desk Console started from the share before its own update)
    if ($list.Count -gt 1) { throw "This PC's Start-DevBox.ps1 takes one folder. Start Desk Console from the Start Menu once (it updates itself), then add the others." }
    $f = $list[0]
    & $DevScript -Configure -Folder $f.path -Claude:($f.claude) -NoCode:(-not $f.code) 6>&1 | Out-String
}

# RustDesk on a phone or tablet. NOT on Google Play (removed in 2023): Android installs come
# from RustDesk's GitHub release (APK) or F-Droid. QR images: tools\Make-MobileQr.py.
$MobileLinks = [ordered]@{
    'Android: RustDesk APK (GitHub)' = 'https://github.com/rustdesk/rustdesk/releases/download/1.5.0/rustdesk-1.5.0-aarch64-signed.apk'
    'Android: F-Droid'               = 'https://f-droid.org/packages/com.carriez.flutter_hbb/'
    'Android: all builds'            = 'https://github.com/rustdesk/rustdesk/releases/latest'
    'iPhone / iPad: App Store'       = 'https://apps.apple.com/app/rustdesk-remote-desktop/id1581225015'
}
function Show-MobileDialog { [void](New-MobileDialog).ShowDialog($form) }
function New-MobileDialog {
    $d = New-Dialog 'Control your PCs from a phone or tablet' '660,610'
    $col = 0
    foreach ($side in @(@{ Title = 'Android  (phone, foldable, tablet)'; Png = 'rustdesk-android.png'; Keys = @('Android: RustDesk APK (GitHub)', 'Android: F-Droid', 'Android: all builds') },
                        @{ Title = 'iPhone / iPad'; Png = 'rustdesk-ios.png'; Keys = @('iPhone / iPad: App Store') })) {
        $x = 20 + 330 * $col; $col++
        $t = New-Label $side.Title $Bold; $t.Location = "$x,14"; $d.Controls.Add($t)
        $png = Join-Path $PSScriptRoot "mobile\$($side.Png)"
        if (Test-Path $png) {
            # native size: scaling a QR code by a non-integer factor blurs its modules and hurts scanning.
            # Loaded from memory: Image.FromFile kept the PNG locked, and a self-update copying it failed (R3).
            $p = New-Object Windows.Forms.PictureBox; $p.Image = [Drawing.Image]::FromStream((New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($png))))
            $p.SizeMode = 'AutoSize'; $p.Location = "$x,44"; $d.Controls.Add($p)
        }
        $y = 290
        foreach ($k in $side.Keys) {
            $l = New-Object Windows.Forms.LinkLabel; $l.Text = $k; $l.Tag = $MobileLinks[$k]; $l.AutoSize = $true; $l.Location = "$x,$y"
            $l.Add_LinkClicked({ Start-Process $this.Tag }); $d.Controls.Add($l); $y += 24
        }
    }
    $d.Add_FormClosed({ foreach ($c in $this.Controls) { if ($c -is [Windows.Forms.PictureBox] -and $c.Image) { $c.Image.Dispose() } } })
    $myIp = (Get-Machine $Me).IP
    $net = if ($myIp -match '^(\d+\.\d+\.\d+)\.\d+$') { "$($Matches[1]).x" } else { 'the PCs'' network' }
    $steps = New-Object Windows.Forms.Label; $steps.Location = '20,370'; $steps.Size = '620,96'
    $steps.Text = "1. Scan a code with the phone's camera and install RustDesk (Android: allow your browser to install the app, or use F-Droid).`r`n" +
                  "2. Put the phone on the same Wi-Fi network as the PCs -- its address should start like $net`r`n" +
                  "3. In RustDesk, type a PC's address below, connect with your RustDesk password, and add it to Favourites.`r`n" +
                  "   Unfolded and sideways works best; Display > Scale adaptive."
    $d.Controls.Add($steps)
    $list = New-Object Windows.Forms.TextBox; $list.Multiline = $true; $list.ReadOnly = $true; $list.ScrollBars = 'Vertical'
    $list.Location = '20,474'; $list.Size = '620,90'; $list.Font = New-Object Drawing.Font('Consolas', 10)
    $list.Text = (Get-OrderedMachines | ForEach-Object { '{0,-20} {1}' -f $_.Name, $(if ($_.HasIP) { $_.IP } else { '(no address)' }) }) -join "`r`n"
    $d.Controls.Add($list)
    $ok = New-Button 'Close' $null {}; $ok.Location = '570,574'; $ok.DialogResult = 'OK'
    $d.Controls.Add($ok); $d.AcceptButton = $ok; $d.CancelButton = $ok
    $d
}

# What's new: whats-new.txt beside this script (installed with it), shown once per version -- the
# first time the window opens after an update; started in the notification area, a notification
# to click first -- and any time from the status bar. HKCU\Software\DeskConsole\WhatsNewSeen
# holds the version last shown.
function Test-WhatsNewPending {
    if (-not (Test-Path -LiteralPath $WhatsNewFile)) { return $false }
    $seen = ''
    try { $seen = "$((Get-ItemProperty $UiKey -Name WhatsNewSeen -ErrorAction Stop).WhatsNewSeen)" } catch {}
    $seen -ne "$AppVersion"
}
function Set-WhatsNewSeen {
    try {
        if (-not (Test-Path $UiKey)) { New-Item $UiKey | Out-Null }   # never New-Item -Force on a key: it empties it (R1)
        Set-ItemProperty $UiKey -Name WhatsNewSeen -Value "$AppVersion"
    } catch {}
}
function New-WhatsNewDialog {
    $d = New-Dialog "What's new in Desk Console $AppVersion" '700,560'
    $text = "whats-new.txt is missing from $PSScriptRoot."
    try { $text = (Get-Content -LiteralPath $WhatsNewFile -Raw -Encoding UTF8) -replace "`r?`n", "`r`n" } catch {}   # a TextBox breaks lines on CR LF only
    $box = New-Object Windows.Forms.TextBox; $box.Multiline = $true; $box.ReadOnly = $true; $box.WordWrap = $true; $box.ScrollBars = 'Vertical'
    $box.BackColor = [Drawing.SystemColors]::Window; $box.Location = '12,12'; $box.Size = '676,494'; $box.Text = $text.TrimEnd()
    $box.AccessibleName = "What's new"
    $d.Controls.Add($box)
    $link = New-Object Windows.Forms.LinkLabel; $link.Text = 'Release notes and the manual on GitHub'; $link.AutoSize = $true; $link.Location = '12,526'
    $link.Add_LinkClicked({ Start-Process "$ProjectUrl/releases/tag/v$AppVersion" }); $d.Controls.Add($link)
    $ok = New-Button 'Close' $null {}; $ok.Location = '612,518'; $ok.DialogResult = 'OK'
    $d.Controls.Add($ok); $d.AcceptButton = $ok; $d.CancelButton = $ok; $d.ActiveControl = $ok   # not the text: it would open all selected
    $d
}
function Show-WhatsNew {
    Set-WhatsNewSeen   # first: a second trigger while it is open (a notification click) must not open another
    $d = New-WhatsNewDialog
    if ($form.Visible) { [void]$d.ShowDialog($form) } else { $d.StartPosition = 'CenterScreen'; [void]$d.ShowDialog() }
    $d.Dispose()
}

# ---------------------------------------------------------------- refresh
# Every 15 s: start the share probe and the PC probes, update this PC's lines (local reads only);
# 250 ms ticks then wait up to 2 s for the probes and apply everything at once.
function Update-Panel {
    $script:Info = Get-KvmInfo; $script:Local = Get-LocalStatus
    $synBox.Text = "This PC ($Me)"
    $t = Get-PanelText $script:Info $script:Local
    foreach ($n in @($script:Lines.Keys)) {
        $l = $script:Lines[$n]; $v = $t[$n]
        $l.Text = $(if ($v.W) { "$($v.T)  --  $($v.W)" } else { $v.T })
        $l.ForeColor = if ($v.W) { $Amber } else { $Ink }
        $tips.SetToolTip($l, $l.Text)
    }
    $p = $script:Info.Provider
    $btnOpen.Visible = $p -ne 'None'; $btnRestart.Visible = $p -ne 'None'
    $btnOpen.Text = "Open $p"; $btnRestart.Text = "Restart $p"
}
function Update-Strip {
    $off = $script:FromCache
    $shareLbl.Text = if (-not $off) { 'Shared folder: online' } elseif (-not $script:ShareUp) { 'Shared folder: OFFLINE' } else { 'Shared folder: no machines.csv' }
    $shareLbl.ForeColor = if ($off) { $Red } else { $Green }
    $pwLbl.Text = "RustDesk password: $(if ([DeskCred]::Read($CredTarget)) { 'saved' } else { 'not saved' })"
    $when = if ($script:LastRead) { $script:LastRead.ToString('ddd HH:mm') } else { 'an earlier run' }
    $tips.SetToolTip($bannerLbl, "Shared folder: $Root")
    $bannerLbl.Text = if (-not $script:ShareUp) { "Shared folder not reachable -- showing the copy from $when." }
                      else { "No machines.csv in $Root -- showing the copy from $when." }
    $banner.Visible = $off
}
$script:Pending = $null; $script:ForceRebuild = $false
function Start-Refresh {
    if ($script:Pending) { return }
    $script:Pending = @{ Share = Start-ShareProbe; Probes = @(Start-Probes $script:Machines); At = Get-Date }
    try { Update-Panel } catch { Set-Status "Refresh failed: $($_.Exception.Message)" $Red 10 }
}
function Invoke-FullRefresh { $script:DeskflowExe = $null; $script:ForceRebuild = $true; Set-Status 'Checking...' $Grey 0; Start-Refresh }
# A change alerts only once two refreshes in a row agree, so one lost ping is not news (F9).
$script:Seen = @{}
function Test-Change($key, $value) {
    if ($null -eq $value) { return $false }
    $s = $script:Seen[$key]
    if (-not $s) { $script:Seen[$key] = @{ Now = $value; Next = $value; N = 0 }; return $false }
    if ($value -eq $s.Now) { $s.Next = $value; $s.N = 0; return $false }
    if ($value -eq $s.Next) { $s.N++ } else { $s.Next = $value; $s.N = 1 }
    if ($s.N -lt 2) { return $false }
    $s.Now = $value; $s.N = 0; $true
}
function Complete-Refresh {
    $pd = $script:Pending; if (-not $pd) { return }
    $tasks = @(Get-ProbeTasks $pd.Probes); if ($pd.Share -and $pd.Share.T) { $tasks += $pd.Share.T }
    $done = -not ($tasks | Where-Object { -not $_.IsCompleted })
    if (-not $done -and ((Get-Date) - $pd.At).TotalMilliseconds -lt $ProbeMs) { return }
    $script:Pending = $null
    $key = Get-CardKey
    Update-ShareData (Test-ShareProbe $pd.Share)
    if ($script:ForceRebuild -or (Get-CardKey) -ne $key) { $script:ForceRebuild = $false; Build-Cards }
    $res = Read-Probes $pd.Probes
    foreach ($k in $res.Keys) { $script:LastProbe[$k] = $res[$k] }
    $states = @(Update-Cards $res (Get-KvmContext))
    Update-Strip
    if ((Get-Date) -ge $script:HoldUntil) { $status.Text = "Updated $(Get-Date -f 'HH:mm:ss')"; $status.ForeColor = $Grey }
    $news = @(); $bad = $false
    if (Test-Change 'share' (-not $script:FromCache)) { $news += $(if ($script:FromCache) { $bad = $true; 'Shared folder not reachable: showing the cached list.' } else { 'Shared folder reachable again.' }) }
    foreach ($x in $states) {
        if ($x.Name -eq $Me) { continue }
        if (Test-Change "on:$($x.Name)" $x.State.OnlineRaw) { $news += "$($x.Name) is $(if ($x.State.OnlineRaw) { 'back online' } else { $bad = $true; 'offline' })." }
        if (Test-Change "kvm:$($x.Name)" $x.State.KvmUp) { $news += "$($x.Name): keyboard + mouse $(if ($x.State.KvmUp) { 'connected' } else { $bad = $true; 'disconnected' })." }
    }
    if ($news.Count) { Show-Balloon ($news -join "`r`n") $(if ($bad) { 'Warning' } else { 'Info' }) }
}
function Initialize-View {   # first load; the share probe is capped, so an asleep share host costs 2 s, not 40
    if ($script:Initialized) { return }; $script:Initialized = $true
    Update-ShareData (Test-ShareHost); Update-Panel; Build-Cards; Update-Strip; Start-Refresh
}

# While it runs (in the tray, for days): compare with the share's version.txt at most hourly and
# only when the share host answered the last refresh -- never during an admin step.
function Invoke-UpdateCheck([string]$why, [int]$minMinutes) {
    if ($script:AdminJob -or -not $script:ShareUp) { return }
    if (((Get-Date) - $script:UpdateAt).TotalMinutes -lt $minMinutes) { return }
    if (Invoke-SelfUpdate $why (-not $form.Visible)) { Exit-App }   # the new copy is starting; this one leaves
}
$timer = New-Object Windows.Forms.Timer; $timer.Interval = 15000
$timer.Add_Tick({ Start-Refresh; try { Invoke-UpdateCheck 'hourly' 60 } catch { Write-UpdateLog "hourly check failed: $($_.Exception.Message)" } })
$poll  = New-Object Windows.Forms.Timer; $poll.Interval = 250
$poll.Add_Tick({
    try { Complete-Refresh } catch { Set-Status "Refresh failed: $($_.Exception.Message)" $Red 10 }
    try { Update-AdminJob } catch { Set-Status "Admin step: $($_.Exception.Message)" $Red }
    if ($script:ShowEvent -and $script:ShowEvent.WaitOne(0)) {   # opened again from the Start Menu: also a moment to update
        try { Invoke-UpdateCheck 'opened' 5 } catch {}
        if (-not $script:Exiting) { Show-Main }
    }
})
$poll.Start()

if ($SnapshotMobile) {
    Update-ShareData (Test-ShareHost)
    $md = New-MobileDialog; $md.StartPosition = 'Manual'; $md.Location = '-3000,-3000'; $md.ShowInTaskbar = $false
    $md.Add_Shown({
        [Windows.Forms.Application]::DoEvents()
        $bmp = New-Object Drawing.Bitmap $md.Width, $md.Height
        $md.DrawToBitmap($bmp, (New-Object Drawing.Rectangle 0, 0, $md.Width, $md.Height))
        $bmp.Save($SnapshotMobile, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); $md.Close() })
    [void]$md.ShowDialog(); return
}
if ($SnapshotWhatsNew) {
    $wd = New-WhatsNewDialog; $wd.StartPosition = 'Manual'; $wd.Location = '-3000,-3000'; $wd.ShowInTaskbar = $false
    $wd.Add_Shown({
        [Windows.Forms.Application]::DoEvents()
        $bmp = New-Object Drawing.Bitmap $wd.Width, $wd.Height
        $wd.DrawToBitmap($bmp, (New-Object Drawing.Rectangle 0, 0, $wd.Width, $wd.Height))
        $bmp.Save($SnapshotWhatsNew, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); $wd.Close() })
    [void]$wd.ShowDialog(); return
}
if ($Snapshot) {
    $form.StartPosition = 'Manual'; $form.Location = '-3000,-3000'; $form.ShowInTaskbar = $false
    $form.Add_Shown({
        Initialize-View
        while ($script:Pending) { Start-Sleep -Milliseconds 100; Complete-Refresh }
        [Windows.Forms.Application]::DoEvents()
        $bmp = New-Object Drawing.Bitmap $form.Width, $form.Height
        $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle 0, 0, $form.Width, $form.Height))
        $bmp.Save($Snapshot, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); $form.Close() })
    [void]$form.ShowDialog(); return
}

# ---------------------------------------------------------------- tray, window position, run
# Closing the window keeps Desk Console in the notification area, watching (F9, U13): a PC that
# goes offline or loses the keyboard/mouse is a balloon, not something to happen to look at.
function Show-Main {
    if (-not $form.Visible) { $form.Show() }
    if ("$($form.WindowState)" -eq 'Minimized') { $form.WindowState = 'Normal' }
    $form.TopMost = $true; $form.TopMost = $false; $form.Activate()
}
function Save-Bounds {
    try {
        $b = if ("$($form.WindowState)" -eq 'Normal') { $form.Bounds } else { $form.RestoreBounds }
        if (-not (Test-Path $UiKey)) { New-Item $UiKey | Out-Null }   # never New-Item -Force on a key: it empties it (R1)
        Set-ItemProperty $UiKey -Name WindowBounds -Value "$($b.X),$($b.Y),$($b.Width),$($b.Height)"
    } catch {}
}
function Restore-Bounds {   # only where a screen still shows the title bar (a monitor may be gone)
    try {
        $v = @("$((Get-ItemProperty $UiKey -Name WindowBounds -ErrorAction Stop).WindowBounds)" -split ',' | ForEach-Object { [int]$_ })
        if ($v.Count -ne 4) { return }
        $grip = New-Object Drawing.Point ($v[0] + 60), ($v[1] + 12)
        if (@([Windows.Forms.Screen]::AllScreens | Where-Object { $_.WorkingArea.Contains($grip) }).Count) {
            $form.StartPosition = 'Manual'; $form.Bounds = New-Object Drawing.Rectangle $v[0], $v[1], $v[2], $v[3]
        }
    } catch {}
}
function Stop-App {   # once: timers, tray icon, then the message loop (the window is closed or closing)
    if ($script:Stopped) { return }; $script:Stopped = $true; $script:Exiting = $true
    $timer.Stop(); $poll.Stop(); $wakeTimer.Stop()
    if ($script:AdminJob) { Remove-Secrets $script:AdminJob.Secrets }
    if ($script:TrayIcon) { $script:TrayIcon.Visible = $false }
    $app.ExitThread()
}
function Exit-App { $script:Exiting = $true; if ($form.Visible) { Save-Bounds }; $form.Close(); Stop-App }
$script:TrayIcon = New-Object Windows.Forms.NotifyIcon
$script:TrayIcon.Icon = if ($form.Icon) { $form.Icon } else { [Drawing.SystemIcons]::Application }
$script:TrayIcon.Text = 'Desk Console'
$trayMenu = New-Object Windows.Forms.ContextMenuStrip
[void]$trayMenu.Items.Add('Open Desk Console', $null, { Show-Main })
[void]$trayMenu.Items.Add('Refresh', $null, { Invoke-FullRefresh })
[void]$trayMenu.Items.Add('-')
$hideItem = New-Object Windows.Forms.ToolStripMenuItem 'Hide RustDesk sessions from the taskbar'; $hideItem.CheckOnClick = $true
$hideItem.Checked = Test-HideSessions
$hideItem.Add_Click({
    if (-not (Test-Path $UiKey)) { New-Item $UiKey | Out-Null }
    Set-ItemProperty $UiKey -Name HideSessionsFromTaskbar -Value $(if ($hideItem.Checked) { '1' } else { '0' })
})
[void]$trayMenu.Items.Add($hideItem)
# Off: RustDesk's own way, every PC a tab of one window (which then stays on one display).
$winItem = New-Object Windows.Forms.ToolStripMenuItem 'Open each PC in its own window (on its display)'; $winItem.CheckOnClick = $true
$winItem.Checked = Test-SessionWindows
$winItem.Add_Click({ Set-SessionWindows $winItem.Checked })
[void]$trayMenu.Items.Add($winItem)
[void]$trayMenu.Items.Add('-')
[void]$trayMenu.Items.Add('Exit', $null, { Exit-App })
# Sessions hidden from the taskbar are listed here to bring one back to the front.
$trayMenu.Add_Opening({
    foreach ($i in @($trayMenu.Items | Where-Object { $_.Tag -eq 'session' })) { $trayMenu.Items.Remove($i); $i.Dispose() }
    $pos = 2
    foreach ($h in @(Get-RustDeskWindows -Sessions)) {
        $it = New-Object Windows.Forms.ToolStripMenuItem ([DeskWin]::Title($h)); $it.Tag = 'session'
        $hh = $h; $it.Add_Click({ [DeskWin]::Activate($hh) }.GetNewClosure())
        $trayMenu.Items.Insert($pos++, $it)
    }
})
$script:TrayIcon.ContextMenuStrip = $trayMenu
$script:TrayIcon.Add_MouseClick({ param($s, $e) if ("$($e.Button)" -eq 'Left') { Show-Main } })
$script:TrayIcon.Add_BalloonTipClicked({ Show-Main; if (Test-WhatsNewPending) { Show-WhatsNew } })
$script:TrayIcon.Visible = $true

$form.Add_FormClosing({ param($s, $e)
    if ($script:Exiting -or "$($e.CloseReason)" -ne 'UserClosing') { return }
    $e.Cancel = $true; Save-Bounds; $form.Hide()
    if (-not $script:TrayHint) {
        $script:TrayHint = $true
        Show-Balloon 'Still watching your PCs from here. Right-click this icon > Exit to quit.'
    }
})
$form.Add_FormClosed({ Stop-App })   # Windows signing out, or Exit
$form.Add_Shown({ $form.Refresh(); Initialize-View; $timer.Start(); if (Test-WhatsNewPending) { Show-WhatsNew } })
Restore-Bounds
$app = New-Object Windows.Forms.ApplicationContext
if ($Tray) {
    # outside the message loop: an error here (Deskflow rewriting its settings at sign-in) would end
    # the tray copy silently; keep the icon and let the next 15-s refresh try again
    try { Initialize-View } catch { $script:Initialized = $false; Write-UpdateLog "tray start: first load failed ($($_.Exception.Message)) -- retrying on the next refresh" }
    $timer.Start()
    if (Test-WhatsNewPending) { Show-Balloon "Desk Console $AppVersion is installed. Click here to see what's new." }
} else { $form.Show() }
[Windows.Forms.Application]::Run($app)
try { $script:TrayIcon.Dispose() } catch {}
try { if ($script:Mutex) { $script:Mutex.ReleaseMutex(); $script:Mutex.Dispose() } } catch {}
