<#
  Desk-Console.ps1 -- one window for every PC: the keyboard/mouse server and its clients.
  Launch with Desk-Console.cmd or the Start Menu shortcut. -Check prints the same status
  without a window; -Snapshot <png> renders the window off-screen and exits.

  Machines come from machines.csv in the shared folder (written by Setup-Synergy.ps1 on each PC).
  Per machine: online (ping / RustDesk / SMB), keyboard + mouse role (kvm.json) and, for this
  PC, its live Deskflow state; RustDesk direct IP reachable (TCP 21118). "View + control"
  opens it in RustDesk by IP; "Wake" sends a Wake-on-LAN packet (needs WoL in that PC's BIOS/NIC).
  The RustDesk password is kept in THIS PC's Windows Credential Manager
  (DeskConsole:RustDesk), never on the share.
#>
param([switch]$Check, [string]$Snapshot)   # -Snapshot <png>: render the window off-screen and exit
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
$Root        = if ($Site.shareRoot) { ConvertTo-Unc "$($Site.shareRoot)" }
               elseif ((ConvertTo-Unc $PSScriptRoot) -ne (Join-Path $env:LOCALAPPDATA 'Programs\DeskConsole')) { ConvertTo-Unc $PSScriptRoot }
               else { $PSScriptRoot }
$Csv         = Join-Path $Root 'machines.csv'
$RustDeskExe = 'C:\Program Files\RustDesk\rustdesk.exe'
$SynergyExe  = 'C:\Program Files\Synergy\Synergy.exe'
$SynergyConf = 'C:\ProgramData\Synergy\config\synergy.conf'
$SynergyCore = 'C:\ProgramData\Synergy\config\synergy-core.conf'
$CredTarget  = 'DeskConsole:RustDesk'
$AppVersion  = [version]'1.5.0'          # keep equal to version.txt on the share
$InstallDir  = Join-Path $env:LOCALAPPDATA 'Programs\DeskConsole'
$Cache       = Join-Path $InstallDir 'machines.csv'   # last good copy, used when the share is offline
$Installed   = $PSScriptRoot -eq $InstallDir

# Installed copy: update from the share when version.txt there is newer, then relaunch.
if ($Installed -and -not $Check -and -not $Snapshot) {
    try {
        $remote = [version](Get-Content (Join-Path $Root 'version.txt') -TotalCount 1 -ErrorAction Stop).Trim()
        if ($remote -gt $AppVersion) {
            & (Join-Path $Root 'Install-DeskConsole.ps1') -Quiet
            Start-Process (Join-Path $env:WINDIR 'System32\conhost.exe') -ArgumentList '--headless', 'powershell.exe', '-NoProfile',
                '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$InstallDir\Desk-Console.ps1`""
            return
        }
    } catch {}
}

Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Text;
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
}
'@

# ---------------------------------------------------------------- model
$script:FromCache = $false
function Get-Machines {
    $src = $null; $script:FromCache = $false
    if (Test-Path $Csv) {
        $src = $Csv
        if (Test-Path $InstallDir) { try { Copy-Item $Csv $Cache -Force -ErrorAction Stop } catch {} }
    } elseif (Test-Path $Cache) { $src = $Cache; $script:FromCache = $true }
    if ($src) { @(Import-Csv $src | Where-Object { $_.Name }) } else { @() }
}

# All probes start at once and are read later, so the window never blocks. A PC on
# Wi-Fi power save or just woken can take >0.5 s for its first reply (a desktop
# showed offline at 0.6 s), so results are read at 2 s.
$ProbeMs = 2000
function Start-Probes($machines) {
    foreach ($m in $machines) {
        # No probe of 24800: Deskflow logs every plain connect there as "failed to accept secure
        # socket" (a burst every few seconds with four Desk Consoles open). The
        # keyboard/mouse line comes from kvm.json + this PC's own connection table instead.
        $r = New-Object Net.Sockets.TcpClient; $f = New-Object Net.Sockets.TcpClient
        [pscustomobject]@{ M = $m; Rc = $r; Fc = $f
            P = (New-Object Net.NetworkInformation.Ping).SendPingAsync($m.IP, $ProbeMs)
            R = $r.ConnectAsync($m.IP, 21118)
            F = $f.ConnectAsync($m.IP, 445) }   # Windows firewall drops ping by default; SMB answers
    }
}
function Get-ProbeTasks($probes) { [Threading.Tasks.Task[]]@($probes | ForEach-Object { $_.P; $_.R; $_.F }) }

# Keyboard/mouse line for one card. Role from kvm.json; live state only for THIS PC, read from
# its own TCP table (no connection to anyone's port 24800).
function Get-KvmCardState($name) {
    $kvm = try { Get-Content (Join-Path $Root 'kvm.json') -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null }
    $prov = if ($kvm) { "$($kvm.provider)" } else { Get-KvmProvider }   # never a blind 'Synergy'
    if ($prov -eq 'None') { return @{ Text = 'Keyboard + mouse: off'; Ok = $false } }
    $role = if ($kvm -and $name -eq $kvm.server) { 'server' } else { 'client' }
    if ($name -ne $env:COMPUTERNAME) { return @{ Text = "$prov $role"; Ok = $true } }
    if ($role -eq 'server') {
        $listen = [bool](Get-NetTCPConnection -LocalPort 24800 -State Listen -ErrorAction SilentlyContinue)
        $n = @(Get-NetTCPConnection -LocalPort 24800 -State Established -ErrorAction SilentlyContinue |
               Select-Object -ExpandProperty RemoteAddress -Unique).Count   # PCs, not sockets (a stray probe is a socket too)
        return @{ Text = $(if ($listen) { "$prov server: $n connected" } else { "$prov server: NOT running" }); Ok = $listen }
    }
    $up = [bool](Get-NetTCPConnection -RemotePort 24800 -State Established -ErrorAction SilentlyContinue)
    @{ Text = "$prov client: $(if ($up) { 'connected' } else { 'not connected' })"; Ok = $up }
}

function Read-Probes($probes) {
    foreach ($p in $probes) {
        $kv = Get-KvmCardState $p.M.Name
        [pscustomobject]@{
            Name     = $p.M.Name; IP = $p.M.IP
            Online   = ($p.P.Status -eq 'RanToCompletion' -and $p.P.Result.Status -eq 'Success') -or
                       ('RanToCompletion' -in $p.R.Status, $p.F.Status)
            Kvm      = $kv.Text
            RustDesk = $p.R.Status -eq 'RanToCompletion'
            KvmOk    = $kv.Ok
        }
        $p.Rc.Dispose(); $p.Fc.Dispose()
    }
}
function Get-Status($machines) {   # blocking version, for -Check
    $probes = @(Start-Probes $machines); $tasks = Get-ProbeTasks $probes
    if ($tasks.Count) { try { [void][Threading.Tasks.Task]::WaitAll($tasks, $ProbeMs) } catch {} }
    Read-Probes $probes
}

# kvm.json on the share says which keyboard/mouse product every PC uses.
function Get-KvmProvider {
    try { return "$((Get-Content (Join-Path $Root 'kvm.json') -Raw -ErrorAction Stop | ConvertFrom-Json).provider)" } catch {}
    # kvm.json unreachable (share offline or moved): say what THIS PC actually runs, never guess.
    # (1.4.8 guessed "Synergy" after the share folder was renamed, on PCs running Deskflow.)
    $on = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.StartType -ne 'Disabled' -and $_.DisplayName -match 'deskflow|synergy' }
    if ($on | Where-Object { $_.DisplayName -match 'deskflow' }) { 'Deskflow' }
    elseif ($on | Where-Object { $_.DisplayName -match 'synergy' }) { 'Synergy' }
    else { 'None' }
}
function Get-KvmInfo {
    $prov = Get-KvmProvider
    switch ($prov) {
        'Deskflow' { $core = Join-Path $env:APPDATA 'Deskflow\Deskflow.conf'
                     if (-not (Test-Path $core)) { $core = 'C:\ProgramData\Deskflow\Deskflow.conf' }   # what Deskflow itself falls back to
                     # the layout this user's Deskflow reads (setup moved it into the profile in 1.4.10)
                     $conf = Join-Path $env:APPDATA 'Deskflow\deskflow-server.conf'
                     if (-not (Test-Path $conf)) { $conf = 'C:\ProgramData\Deskflow\deskflow-server.conf' }
                     $exe = (Get-ChildItem 'C:\Program Files\Deskflow' -Filter 'deskflow.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1).FullName }
        'Synergy'  { $core = $SynergyCore; $conf = $SynergyConf; $exe = $SynergyExe }
        default    { return [pscustomobject]@{ Provider = 'None'; Exe = $null; Service = '-'; Links = @()
                         Role = 'keyboard + mouse sharing is off (kvm.json provider None)'; Hotkeys = '-' } }
    }
    $svc  = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $prov -or $_.Name -match $prov } | Select-Object -First 1
    $mode = if (Test-Path $core) { (Select-String -Path $core -Pattern '^coreMode=(\d+)' | Select-Object -First 1).Matches.Groups[1].Value }
    $role = switch ($mode) { '2' { 'SERVER (keyboard + mouse here)' } '1' { 'client' } $null { 'not installed / not configured' } default { "mode $mode" } }
    $links = @(); $hot = $false
    if (Test-Path $conf) {
        $cur = $null; $inLinks = $false
        foreach ($l in Get-Content $conf) {
            if ($l -match '^section: links') { $inLinks = $true; continue }
            if ($l -match '^end') { $inLinks = $false; continue }
            if ($inLinks -and $l -match '^\t(\S+):\s*$') { $cur = $Matches[1]; continue }
            if ($inLinks -and $l -match '^\t\t(\w+)(\([^)]*\))?\s*=\s*([^(\s]+)') { $links += "$cur  $($Matches[1]) ->  $($Matches[3])" }
        }
        $hot = (Get-Content $conf -Raw) -match 'switchInDirection'
    }
    [pscustomobject]@{
        Provider = $prov; Exe = $exe
        Service = if ($svc) { "$($svc.Status) / $($svc.StartType)" } else { 'missing' }
        Role = $role; Links = $links
        Hotkeys = if ($hot) { 'Ctrl+Alt+Left / Ctrl+Alt+Right switch screens; Scroll Lock locks the cursor' }
                  elseif ($mode -eq '2') { 'none yet -- re-run Setup-Synergy.cmd on this PC' } else { 'set on the server' }
    }
}

# Windows automatic sign-in on THIS PC (set by Setup-Synergy.ps1 -Phase AutoLogon)
$LockTask = 'DeskConsole lock after auto sign-in'
function Get-AutoLogonInfo {
    $w = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
    $lock = [bool](Get-ScheduledTask -TaskName $LockTask -ErrorAction SilentlyContinue)
    if ("$($w.AutoAdminLogon)" -eq '1') { "ON for $($w.DefaultDomainName)\$($w.DefaultUserName)$(if ($lock) { ', then the screen locks' })" } else { 'off' }
}

# ---------------------------------------------------------------- actions
function Connect-Machine($m) {
    if (-not (Test-Path $RustDeskExe)) { [Windows.Forms.MessageBox]::Show('RustDesk is not installed here. Run Setup-Synergy.cmd.') | Out-Null; return }
    $a = @('--connect', $m.IP)
    $pw = [DeskCred]::Read($CredTarget)
    if ($pw) { $a += '--password', $pw }
    Start-Process $RustDeskExe -ArgumentList $a
}

function Send-Wake($m) {
    if (-not $m.MAC) { [Windows.Forms.MessageBox]::Show("No MAC address for $($m.Name) in machines.csv.") | Out-Null; return }
    $mac = [byte[]]($m.MAC -split '[:-]' | ForEach-Object { [Convert]::ToByte($_, 16) })
    $pkt = [byte[]](@(0xFF) * 6 + $mac * 16)
    $u = New-Object Net.Sockets.UdpClient; $u.EnableBroadcast = $true
    [void]$u.Send($pkt, $pkt.Length, '255.255.255.255', 9); $u.Close()
}

# ---------------------------------------------------------------- -Check
if ($Check) {
    $ms = Get-Machines
    if (-not $ms) { "No machines in $Csv yet." } else { Get-Status $ms | Format-Table -AutoSize | Out-String }
    $si = Get-KvmInfo
    "Keyboard + mouse ($($si.Provider)) on $($env:COMPUTERNAME): $($si.Role); service $($si.Service)"
    $si.Links | ForEach-Object { "   $_" }
    "Hotkeys: $($si.Hotkeys)"
    "RustDesk password saved on this PC: $([bool][DeskCred]::Read($CredTarget))"
    "Automatic sign-in: $(Get-AutoLogonInfo)"
    return
}

# ---------------------------------------------------------------- window
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$Font  = New-Object Drawing.Font('Segoe UI', 9.5)
$Bold  = New-Object Drawing.Font('Segoe UI Semibold', 11)
$Green = [Drawing.Color]::FromArgb(30, 140, 70); $Grey = [Drawing.Color]::FromArgb(130, 130, 130); $Red = [Drawing.Color]::FromArgb(190, 50, 50)

function New-Button($text, $tag, $onClick) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.Tag = $tag; $b.AutoSize = $true; $b.Font = $Font; $b.Margin = '4,4,4,4'
    $b.Add_Click($onClick); $b
}
function New-Label($text, $font = $Font) {
    $l = New-Object Windows.Forms.Label; $l.Text = $text; $l.AutoSize = $true; $l.Font = $font; $l.Margin = '3,2,3,2'; $l
}

$form = New-Object Windows.Forms.Form
$form.Text = "Desk Console $AppVersion -- keyboard + mouse + RustDesk"
$ico = Join-Path $PSScriptRoot 'desk-console.ico'
if (Test-Path $ico) { $form.Icon = New-Object Drawing.Icon $ico }
$form.Size = '820,560'; $form.MinimumSize = '560,420'; $form.Font = $Font; $form.StartPosition = 'CenterScreen'

$synBox = New-Object Windows.Forms.GroupBox; $synBox.Dock = 'Fill'; $synBox.Padding = '10,8,10,8'
$synFlow = New-Object Windows.Forms.FlowLayoutPanel; $synFlow.Dock = 'Fill'; $synFlow.FlowDirection = 'TopDown'; $synFlow.WrapContents = $false; $synFlow.AutoScroll = $true
$synBox.Controls.Add($synFlow)

$cards = New-Object Windows.Forms.FlowLayoutPanel; $cards.Dock = 'Top'; $cards.Height = 215; $cards.Padding = '6,6,6,0'; $cards.AutoScroll = $true

$bar = New-Object Windows.Forms.FlowLayoutPanel; $bar.Dock = 'Top'; $bar.Height = 40; $bar.Padding = '6,4,6,0'
$status = New-Label ''; $status.ForeColor = $Grey; $status.Margin = '12,9,3,0'

$form.Controls.Add($synBox); $form.Controls.Add($cards); $form.Controls.Add($bar)

$script:CardMap = @{}
function Build-Cards {
    $cards.Controls.Clear(); $script:CardMap = @{}
    $ms = Get-Machines
    if (-not $ms) { $cards.Controls.Add((New-Label "No machines yet -- run Setup-Synergy.cmd on each PC ($Csv).")); return }
    foreach ($m in $ms) {
        $g = New-Object Windows.Forms.GroupBox; $g.Size = '250,195'; $g.Margin = '6,6,6,6'
        $g.Text = if ($m.Name -eq $env:COMPUTERNAME) { "$($m.Name)  (this PC)" } else { $m.Name }
        $f = New-Object Windows.Forms.FlowLayoutPanel; $f.Dock = 'Fill'; $f.FlowDirection = 'TopDown'; $f.WrapContents = $false
        $f.Controls.Add((New-Label "$($m.IP)   $($m.MAC)"))
        $on = New-Label 'Online: ...' $Bold; $sy = New-Label 'Keyboard + mouse: ...'; $rd = New-Label 'RustDesk: ...'
        $f.Controls.AddRange(@($on, $sy, $rd))
        $row = New-Object Windows.Forms.FlowLayoutPanel; $row.AutoSize = $true; $row.Margin = '0,6,0,0'
        $row.Controls.Add((New-Button 'View + control' $m { Connect-Machine $this.Tag }))
        $row.Controls.Add((New-Button 'Wake' $m { Send-Wake $this.Tag; $status.Text = "Wake packet sent to $($this.Tag.Name)." }))
        $f.Controls.Add($row)
        $g.Controls.Add($f); $cards.Controls.Add($g)
        $script:CardMap[$m.Name] = @{ On = $on; Sy = $sy; Rd = $rd }
    }
}

function Set-Dot($label, $text, $ok, $offColor) {
    $label.Text = $text; $label.ForeColor = if ($ok) { $Green } else { $offColor }
}

# The password goes to the elevated script through a %TEMP% file (deleted on read),
# never a command line; the script checks it with Windows before storing it.
function Show-AutoLogonDialog {
    $d = New-Object Windows.Forms.Form
    $d.Text = 'Automatic sign-in at boot'; $d.ClientSize = '420,340'; $d.FormBorderStyle = 'FixedDialog'
    $d.StartPosition = 'CenterParent'; $d.MaximizeBox = $false; $d.MinimizeBox = $false; $d.Font = $Font
    # local account: just the name (DOMAIN\name was garbled in this box on one PC);
    # domain account: DOMAIN\name
    $me   = if ($env:USERDOMAIN -eq $env:COMPUTERNAME) { $env:USERNAME } else { "$env:USERDOMAIN\$env:USERNAME" }
    $on   = New-Object Windows.Forms.RadioButton; $on.Text = 'Turn on with an existing account (e.g. your own)'; $on.Location = '14,12'; $on.AutoSize = $true; $on.Checked = $true
    $new  = New-Object Windows.Forms.RadioButton; $new.Text = 'Turn on with a dedicated local account (desktops; created if missing)'; $new.Location = '14,36'; $new.AutoSize = $true
    $lu   = New-Label 'Account:'; $lu.Location = '34,64'
    $user = New-Object Windows.Forms.TextBox; $user.Location = '34,84'; $user.Width = 360; $user.Text = $me
    $l1   = New-Label 'Password:'; $l1.Location = '34,114'
    $p1   = New-Object Windows.Forms.TextBox; $p1.Location = '34,134'; $p1.Width = 360; $p1.UseSystemPasswordChar = $true
    $l2   = New-Label 'Password again:'; $l2.Location = '34,162'
    $p2   = New-Object Windows.Forms.TextBox; $p2.Location = '34,182'; $p2.Width = 360; $p2.UseSystemPasswordChar = $true
    $lock = New-Object Windows.Forms.CheckBox; $lock.Text = 'Lock the screen right after (recommended)'; $lock.Location = '34,214'; $lock.AutoSize = $true; $lock.Checked = $true
    $off  = New-Object Windows.Forms.RadioButton; $off.Text = 'Turn off'; $off.Location = '14,246'; $off.AutoSize = $true
    $ok   = New-Object Windows.Forms.Button; $ok.Text = 'Apply (asks for admin)'; $ok.Location = '14,290'; $ok.AutoSize = $true; $ok.DialogResult = 'OK'
    $no   = New-Object Windows.Forms.Button; $no.Text = 'Cancel'; $no.Location = '210,290'; $no.AutoSize = $true; $no.DialogResult = 'Cancel'
    $sync = { $en = -not $off.Checked; foreach ($c in $user, $p1, $p2, $lock) { $c.Enabled = $en }
              if ($new.Checked -and $user.Text -eq $me) { $user.Text = 'BuildRunner' }
              elseif ($on.Checked -and $user.Text -eq 'BuildRunner') { $user.Text = $me } }
    $on.Add_CheckedChanged($sync); $new.Add_CheckedChanged($sync); $off.Add_CheckedChanged($sync)
    $d.Controls.AddRange(@($on, $new, $lu, $user, $l1, $p1, $l2, $p2, $lock, $off, $ok, $no)); $d.AcceptButton = $ok; $d.CancelButton = $no
    if ($d.ShowDialog($form) -ne 'OK') { return }
    $enable = -not $off.Checked
    if ($enable -and (-not $p1.Text -or $p1.Text -cne $p2.Text)) {
        [Windows.Forms.MessageBox]::Show('The passwords are empty or different -- nothing changed.') | Out-Null; return
    }
    $setup = Join-Path $PSScriptRoot 'Setup-Synergy.ps1'
    if (-not (Test-Path $setup)) { $setup = Join-Path $Root 'Setup-Synergy.ps1' }
    $setup = ConvertTo-Unc $setup   # the elevated window cannot see mapped drives
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$setup`"", '-Phase', 'AutoLogon', '-AutoLogon', $(if ($enable) { 'Enable' } else { 'Disable' }))
    $f = Join-Path $env:TEMP ('ds-al-' + [guid]::NewGuid().ToString('N') + '.txt')
    if ($enable) {
        [IO.File]::WriteAllLines($f, [string[]]@("al_user=$($user.Text)", "al_pass=$($p1.Text)", "al_new=$(if ($new.Checked) { 1 } else { 0 })"))
        $a += '-SecretsFile', "`"$f`""
        if ($lock.Checked) { $a += '-AutoLogonLock' }
    }
    $p1.Text = ''; $p2.Text = ''
    try { Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList $a } catch { $status.Text = 'Automatic sign-in: cancelled.' }
    finally { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    Update-All
}

$script:Pending = $null
function Apply-Probes {
    $pd = $script:Pending; if (-not $pd) { return }
    $tasks = Get-ProbeTasks $pd.Probes
    $done = -not ($tasks | Where-Object { -not $_.IsCompleted })
    if (-not $done -and ((Get-Date) - $pd.At).TotalMilliseconds -lt $ProbeMs) { return }
    $script:Pending = $null
    foreach ($s in Read-Probes $pd.Probes) {
        $c = $script:CardMap[$s.Name]; if (-not $c) { continue }
        Set-Dot $c.On ("Online: " + $(if ($s.Online) { 'yes' } else { 'no' })) $s.Online $Red
        Set-Dot $c.Sy $s.Kvm $s.KvmOk $Grey
        Set-Dot $c.Rd ("RustDesk: " + $(if ($s.RustDesk) { 'reachable' } else { 'not reachable' })) $s.RustDesk $Red
    }
    $status.Text = "Updated $(Get-Date -f 'HH:mm:ss')$(if ($script:FromCache) { '  -  SHARE OFFLINE, cached list' })  -  RustDesk password saved: $(if ([DeskCred]::Read($CredTarget)) { 'yes' } else { 'no' })"
}

function Update-All {
    try {
        if (-not $script:Pending) { $script:Pending = @{ Probes = @(Start-Probes (Get-Machines)); At = Get-Date } }
        $si = Get-KvmInfo; $script:Kvm = $si
        $synBox.Text = "Keyboard + mouse on this PC ($($env:COMPUTERNAME))"
        $synFlow.SuspendLayout(); $synFlow.Controls.Clear()
        $synFlow.Controls.Add((New-Label "Using: $($si.Provider)      Role: $($si.Role)      Service: $($si.Service)" $Bold))
        $synFlow.Controls.Add((New-Label "Hotkeys: $($si.Hotkeys)"))
        $synFlow.Controls.Add((New-Label "Automatic sign-in at boot: $(Get-AutoLogonInfo)"))
        if ($si.Links) { $synFlow.Controls.Add((New-Label 'Layout (screen  edge ->  neighbour):')); $si.Links | ForEach-Object { $synFlow.Controls.Add((New-Label "      $_")) } }
        $btns = New-Object Windows.Forms.FlowLayoutPanel; $btns.AutoSize = $true; $btns.Margin = '0,8,0,0'
        if ($si.Provider -ne 'None') {
            $btns.Controls.Add((New-Button "Open $($si.Provider) app" $null { if ($script:Kvm.Exe -and (Test-Path $script:Kvm.Exe)) { Start-Process $script:Kvm.Exe } }))
            $btns.Controls.Add((New-Button "Restart $($si.Provider) (admin)" $null {
                $p = $script:Kvm.Provider
                Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile', '-Command', "Get-Service | Where-Object { `$_.DisplayName -match '$p' -and `$_.StartType -ne 'Disabled' } | Restart-Service" }))
        }
        $btns.Controls.Add((New-Button 'Automatic sign-in...' $null { Show-AutoLogonDialog }))
        $btns.Controls.Add((New-Button 'Re-run setup on this PC' $null { Start-Process (Join-Path $Root 'Setup-Synergy.cmd') }))
        $synFlow.Controls.Add($btns)
        $synFlow.ResumeLayout()
        $status.Text = 'Checking...'
    } catch { $status.Text = "Refresh failed: $($_.Exception.Message)" }
}

$bar.Controls.Add((New-Button 'Refresh' $null { Build-Cards; Update-All }))
$bar.Controls.Add((New-Button 'Connect all' $null {
    foreach ($m in Get-Machines) { if ($m.Name -ne $env:COMPUTERNAME) { Connect-Machine $m } } }))
$bar.Controls.Add((New-Button 'RustDesk password...' $null {
    $d = New-Object Windows.Forms.Form; $d.Text = 'RustDesk password'; $d.Size = '340,150'; $d.FormBorderStyle = 'FixedDialog'; $d.StartPosition = 'CenterParent'; $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $t = New-Object Windows.Forms.TextBox; $t.UseSystemPasswordChar = $true; $t.Location = '12,14'; $t.Width = 300
    $ok = New-Object Windows.Forms.Button; $ok.Text = 'Save on this PC'; $ok.Location = '12,48'; $ok.AutoSize = $true; $ok.DialogResult = 'OK'
    $d.Controls.AddRange(@($t, $ok)); $d.AcceptButton = $ok
    if ($d.ShowDialog($form) -eq 'OK' -and $t.Text) { [DeskCred]::Write($CredTarget, 'rustdesk', $t.Text); Update-All }
}))
$bar.Controls.Add((New-Button 'Open share' $null { Start-Process explorer.exe $Root }))
$bar.Controls.Add($status)

$timer = New-Object Windows.Forms.Timer; $timer.Interval = 15000; $timer.Add_Tick({ Update-All })
$poll  = New-Object Windows.Forms.Timer; $poll.Interval = 250;     $poll.Add_Tick({ try { Apply-Probes } catch { $status.Text = "Refresh failed: $($_.Exception.Message)" } })
$poll.Start()
if ($Snapshot) {
    $form.StartPosition = 'Manual'; $form.Location = '-3000,-3000'; $form.ShowInTaskbar = $false
    $form.Add_Shown({
        Build-Cards; Update-All
        while ($script:Pending) { Start-Sleep -Milliseconds 100; Apply-Probes }
        [Windows.Forms.Application]::DoEvents()
        $bmp = New-Object Drawing.Bitmap $form.Width, $form.Height
        $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle 0, 0, $form.Width, $form.Height))
        $bmp.Save($Snapshot, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); $form.Close() })
    [void]$form.ShowDialog(); return
}
$form.Add_Shown({ Build-Cards; Update-All; $timer.Start() })
$form.Add_FormClosed({ $timer.Stop() })
[void]$form.ShowDialog()
