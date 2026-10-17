<#
  Setup-Synergy.ps1 -- one script for every PC (the keyboard/mouse server and its clients).
  Run it with DeskConsoleSetup.exe or Setup-Synergy.cmd. Safe to re-run.
  (The name is historical: it started as Synergy-only; installed copies and the 2-minute
  task refer to it by this name, so it stays.)

  Site settings come from site.json next to this script (see site.example.json): the shared
  folder, the hosts to save the share login for, an optional drive letter to map, and how far
  RustDesk reaches: "rustdeskReach" "lan" (default: the home network only) or "anywhere";
  "lanCidr" names the home network(s), else it is this PC's own network.

  -Phase (default All = User, then Admin elevated, then Finish):
    User      as you: the share login -> Windows Credential Manager; kvm.json provider/server;
              site.json mapDrive -> mapPath (optional, persistent); the wizard's RustDesk password
              for Desk Console's View + control; Desk Console itself
    Admin     elevated (one UAC prompt):
              - keyboard + mouse sharing, by kvm.json "provider" on the share:
                  Synergy  -- Synergy 3.8.3 (paid licence); Deskflow is switched off
                  Deskflow -- Deskflow 1.27.0 (free, open source, the project Synergy is built
                              on) and the Visual C++ runtime it needs; Synergy is switched off,
                              NOT uninstalled (Remove-Synergy.cmd does that)
                  None     -- both switched off
                Switching off = service stopped + Disabled, sign-in entry parked in
                HKLM\SOFTWARE\DeskConsole\DisabledRun; switching back restores both.
              - RustDesk 1.5.0 as a service, direct IP (21118), answering the home network only
                (its IP whitelist) unless site.json says "anywhere"; unattended password once
              - firewall: TCP 24800, TCP/UDP 21118, ping, and the vendors' own allow rules, all
                limited to the home network, on every network profile
              - automatic sign-in (-AutoLogon) and Windows Update restarts (-NoAutoRestart) when
                asked; an older lock-after-sign-in task is brought up to date without a password
              - registers this PC in machines.csv
    Finish    as you: Deskflow settings, and on the server the layout from kvm.json "row" or
              "grid" with the Ctrl+Alt+arrow and Ctrl+Alt+Shift+1..9 hotkeys; the 2-minute
              background task (every provider); dev box resume (-DevBoxFolder)
    AutoLogon elevated, from Desk Console: -AutoLogon Enable|Disable [-AutoLogonLock]
    Updates   from Set-NoAutoRestart.cmd (asks for admin): -NoAutoRestart Enable|Disable
    RemoveSynergy  from Remove-Synergy.cmd (asks for admin): uninstall Synergy once no PC uses it
    TrustSync the 2-minute task: Deskflow trust + server layout, then Agent.ps1 (status file,
              address self-healing, Desk Console's command queue)

  -ResultFile <file> appends "<Phase>|WARN|<text>" / "<Phase>|FAIL|<text>" for every yellow or
  red line and "<Phase>|OK|" when the phase finishes, for the installer and Desk Console.
  -NoPause (and -FromInstaller) never wait for Enter.

  Choose the provider for every PC:  Setup-Synergy.cmd -Kvm Deskflow   (or Synergy / None)
  then run Setup-Synergy.cmd on each PC.

  Drive mappings are per logon token, so a Z: mapped from an elevated window
  is invisible in Explorer. That is why the User phase runs un-elevated.
#>
[CmdletBinding()]
param(
    [ValidateSet('All','User','Admin','Finish','AutoLogon','TrustSync','Updates','RemoveSynergy')] [string]$Phase = 'All',
    [ValidateSet('','Enable','Disable')] [string]$NoAutoRestart = '',   # Windows Update: no restart while someone is signed in
    [string]$DevBoxFolder = '',     # dev box: reopen VS Code on this folder at sign-in (Finish step, as the user)
    [switch]$DevBoxClaude,          # ...and open a terminal running `claude --continue` there
    [switch]$DevBoxNoCode,          # ...Claude only, no VS Code
    [ValidateSet('','Enable','Disable')] [string]$AutoLogon = '',   # Windows automatic sign-in at boot
    [switch]$AutoLogonLock,                                         # ...then lock the screen right away
    [ValidateSet('','Synergy','Deskflow','None')] [string]$Kvm = '',
    [switch]$KvmIfUnset,            # ...only when kvm.json names no provider yet (the wizard could not read it)
    # Server = make THIS PC kvm.json "server"; ServerIfUnset = only when kvm.json names no server yet
    [ValidateSet('','Server','Client','ServerIfUnset')] [string]$Role = '',
    [switch]$ResetCredential,
    [switch]$ResetRemotePassword,
    [string]$NasUser = '',          # share login user; default site.json credentialUser
    # used by DeskConsoleSetup.exe (Inno Setup) and Desk Console: no prompts, bundled MSIs, a result file
    [string]$SecretsFile = '',      # nas_user= nas_pass= rd_pass= al_user= al_pass= al_new= lines, in {tmp} / %TEMP%
    [string]$InstallerDir = '',     # bundled MSIs; anything missing falls back to the share
    [string]$ResultFile = '',       # appends <Phase>|WARN|..., <Phase>|FAIL|..., <Phase>|OK|
    [switch]$NoPause,               # never wait for Enter (implied by -FromInstaller)
    [switch]$FromInstaller,
    # An argument this copy does not know (an older or newer caller) is reported, not fatal: it
    # used to stop the phase before it started.
    [Parameter(ValueFromRemainingArguments = $true)] [string[]]$Unknown
)
$ErrorActionPreference = 'Stop'
$ScriptArgs = $PSBoundParameters   # this run's options, handed on to the elevated / 64-bit copy

# ---------------------------------------------------------------- command lines
# One argument for a native command line by the MSVC / CommandLineToArgvW rules: backslashes
# before a quote doubled, the quote escaped, the whole value in quotes. Windows PowerShell 5.1
# hands an embedded quote over unescaped, so a password containing " silently changed (R8), and
# a value ending in \ escaped its own closing quote.
function Quote-NativeArg([string]$s) {
    '"' + ([regex]::Replace($s, '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

# An elevated window cannot see mapped drives: turn "Z:\x" into "\\server\share\x".
function ConvertTo-Unc([string]$path) {
    if ($path -match '^([A-Za-z]):(.*)$') {
        $d = Get-PSDrive -Name $Matches[1] -PSProvider FileSystem -ErrorAction SilentlyContinue
        if ($d.DisplayRoot) { return $d.DisplayRoot.TrimEnd('\') + $Matches[2] }
    }
    $path
}

# This run's parameters as arguments for another copy of the script. E5/R9: the elevation for
# the Admin phase used to pass only -ResetRemotePassword, so -AutoLogon, -NoAutoRestart,
# -SecretsFile and -InstallerDir were silently dropped on the way.
function Get-ForwardArgs([Collections.IDictionary]$Bound, [string[]]$Except = @()) {
    foreach ($k in @($Bound.Keys)) {
        if ($k -eq 'Unknown' -or $Except -contains $k) { continue }
        $v = $Bound[$k]
        if ($v -is [Management.Automation.SwitchParameter]) { if ($v.IsPresent) { "-$k" }; continue }
        if ($k -in 'SecretsFile', 'InstallerDir', 'ResultFile') {
            # absolute first: the elevated copy starts in System32, so a relative path would land there
            $v = ConvertTo-Unc ($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath("$v"))
        }
        "-$k"; Quote-NativeArg "$v"
    }
}

# Always 64-bit. A 32-bit launcher (Inno Setup's ShellExecute of "powershell.exe") starts
# SysWOW64 PowerShell, which sees the WOW6432Node registry (HKLM Run, Winlogon) and cannot
# read 64-bit process paths -- that once left Synergy's sign-in entry and tray app running
# after "Synergy switched off". Re-launch in the 64-bit host with the same arguments.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $ps64 = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    $fwd = @(Get-ForwardArgs $ScriptArgs) + @($Unknown | Where-Object { $_ } | ForEach-Object { Quote-NativeArg $_ })
    & $ps64 -NoProfile -ExecutionPolicy Bypass -File "$PSCommandPath" @fwd
    exit $LASTEXITCODE
}

# ---------------------------------------------------------------- site settings
# site.json sits next to this script: on the shared folder, and in the install folder (the
# installer writes it). Fields: shareRoot, credentialHosts, credentialUser, mapDrive, mapPath,
# rustdeskReach, lanCidr.
function Get-DeskSite {
    foreach ($p in (Join-Path $PSScriptRoot 'site.json'), (Join-Path (Split-Path $PSScriptRoot -Parent) 'site.json')) {
        if (Test-Path $p) { try { return (Get-Content $p -Raw | ConvertFrom-Json) } catch {} }
    }
    $null
}
$Site       = Get-DeskSite
$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\DeskConsole'
# the shared folder: site.json, else the folder this script runs from (unless that is the install folder)
$Root = if ($Site.shareRoot) { ConvertTo-Unc "$($Site.shareRoot)" }
        elseif ((ConvertTo-Unc $PSScriptRoot) -ne $InstallDir) { ConvertTo-Unc $PSScriptRoot }
        else { $null }
if (-not $Root) { $Root = $PSScriptRoot }   # last resort: everything local
$ShareHost  = if ($Root -match '^\\\\([^\\]+)\\') { $Matches[1] } else { $null }
# "lanCidr" and "rustdeskReach" hold for every PC, so the shared folder's site.json wins over this
# copy's (an installed copy is refreshed only when Desk Console updates itself). Read on first use,
# from the Admin phase -- never from the 2-minute task.
$script:ShareSite = $null
function Get-SiteSetting([string]$name) {
    if ($null -eq $script:ShareSite) {
        $script:ShareSite = $false
        $p = Join-Path $Root 'site.json'
        if (Test-Path $p) { try { $script:ShareSite = Get-Content $p -Raw | ConvertFrom-Json } catch {} }
    }
    foreach ($s in @($script:ShareSite, $Site)) { if ($s -and $s.PSObject.Properties[$name]) { return $s.$name } }
    $null
}
$NasHosts   = @($Site.credentialHosts | Where-Object { $_ })
if (-not $NasHosts.Count -and $ShareHost) { $NasHosts = @($ShareHost) }
if (-not $NasUser) { $NasUser = "$($Site.credentialUser)" }
$MapDrive   = "$($Site.mapDrive)".TrimEnd('\')          # e.g. "Z:" -- optional
$MapPath    = "$($Site.mapPath)"                        # e.g. "\\nas\share"
# Ver: an older installed copy is upgraded (Install-FromShare)
$Installers = @{
    Synergy  = @{ Msi = 'synergy-3.8.3-x64.msi';       Ver = '3.8.3';  Sha = '40AE79CEF0EB3A54D43EA95A016EB90483CFF9D92E5F1929D9CA3AC6D56004C7' }
    RustDesk = @{ Msi = 'rustdesk-1.5.0-x86_64.msi';   Ver = '1.5.0';  Sha = '624FE792AB1D76B35134DAB84BFF97A6BCD14043FFD090A2C6A2800F77580495' }
    # unsigned upstream build; hash = the digest GitHub publishes for v1.27.0
    Deskflow = @{ Msi = 'deskflow-1.27.0-win-x64.msi'; Ver = '1.27.0'; Sha = '0CA5668C4731F5477D0B189BDB11196A2CA51281985D9D8C0757BF7F3B782D64' }
}
$KvmJson     = Join-Path $Root 'kvm.json'
$SynergyConf = 'C:\ProgramData\Synergy\config\synergy.conf'
$SynergyCore = 'C:\ProgramData\Synergy\config\synergy-core.conf'
$DeskflowDir = Join-Path $env:APPDATA 'Deskflow'
$RustDeskExe = 'C:\Program Files\RustDesk\rustdesk.exe'
$RustDeskToml = 'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk2.toml'
$DcKey       = 'HKLM:\SOFTWARE\DeskConsole'
$ParkedRun   = 'HKLM:\SOFTWARE\DeskConsole\DisabledRun'
$KvmPortRule = 'Desk Console keyboard/mouse (TCP 24800, LAN)'
$Me          = $env:COMPUTERNAME
$Unattended  = [bool]($FromInstaller -or $NoPause)       # no Read-Host pauses or prompts
$PausePhases = 'Admin', 'AutoLogon', 'Updates', 'RemoveSynergy'   # elevated windows that stay open at the end
$script:LanCidrs = @(); $script:FwScope = 'LocalSubnet'; $script:FwSafe = $true; $script:LogPath = $null; $script:RustDeskFresh = $false

# ---------------------------------------------------------------- output, results
# -ResultFile: a line per warning or failure, and "<Phase>|OK|" when the phase finishes, so the
# installer's last page and Desk Console can say what went wrong (U1/R4: the wizard reported
# success while the hidden steps' errors vanished). ASCII, one line each: readers split on '|'.
function Format-ResultLine([string]$kind, [string]$text) {
    $t = [regex]::Replace(($text -replace '\s*[\r\n]+\s*', ' '), '[^\x20-\x7E]', '?')
    "$Phase|$kind|$t"
}
function Add-Result([string]$kind, [string]$text = '') {
    if (-not $ResultFile) { return }
    try { Add-Content -LiteralPath $ResultFile -Value (Format-ResultLine $kind $text) -Encoding Ascii } catch {}
}
function Say($m, $c = 'Cyan') {
    Write-Host "[$Me] $m" -ForegroundColor $c
    if ($c -eq 'Yellow') { Add-Result 'WARN' $m } elseif ($c -eq 'Red') { Add-Result 'FAIL' $m }
}

# R5: one failing step (msiexec 1618, a service or firewall error) used to end the Admin phase
# before automatic sign-in, Windows Update and machines.csv. Each step now fails on its own.
function Invoke-Step([string]$what, [scriptblock]$do) {
    try { & $do } catch { Say "${what}: $($_.Exception.Message) -- continuing with the rest; re-run setup after fixing it." Red }
}

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# A native program with an exact command line (Start-Process passes the string as it is, in
# Windows PowerShell and PowerShell 7 alike), hidden, waited for. Exit code; $null on timeout,
# and then it is ended rather than left running hidden.
function Invoke-Native([string]$exe, [string]$argLine, [int]$TimeoutSec = 60) {
    $p = Start-Process -FilePath $exe -ArgumentList $argLine -WindowStyle Hidden -PassThru
    $null = $p.Handle   # keeps the exit code readable once the process has ended
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill() } catch {}; return $null }
    $p.ExitCode
}

# The 2-minute task's first share access: a share host that is asleep or gone makes it hang
# 20-40 s (R11, seen in Desk Console) -- most of the task's 1-minute limit. A TCP connect to SMB
# (445) or NetBIOS (139, an old NAS) with a 3 s limit answers first, as the agent does.
function Test-ShareUp {
    if (-not $ShareHost) { return $true }
    $cs = @(); $ts = @()
    foreach ($port in 445, 139) { $c = New-Object Net.Sockets.TcpClient; $cs += $c; try { $ts += $c.ConnectAsync($ShareHost, $port) } catch {} }
    $sw = [Diagnostics.Stopwatch]::StartNew(); $ok = $false
    while ($ts.Count -and -not $ok -and $sw.ElapsedMilliseconds -lt 3000) {
        $ok = [bool]@($ts | Where-Object { $_.Status -eq 'RanToCompletion' }).Count
        if (-not $ok -and -not @($ts | Where-Object { -not $_.IsCompleted }).Count) { break }   # refused, or no such host
        if (-not $ok) { Start-Sleep -Milliseconds 50 }
    }
    foreach ($c in $cs) { try { $c.Close() } catch {} }
    $ok
}

# This script again, elevated, for one phase, with this run's options. Its exit code.
function Invoke-Elevated([string]$ElevPhase, [string[]]$Except = @(), [string[]]$Extra = @()) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Quote-NativeArg (ConvertTo-Unc $PSCommandPath)), '-Phase', $ElevPhase) +
         @(Get-ForwardArgs $ScriptArgs -Except (@('Phase') + $Except)) + $Extra
    $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList $a
    $p.ExitCode
}

# ---------------------------------------------------------------- registry
# New-Item -Force on a registry key that EXISTS deletes the key and everything under it, then
# creates it empty (RegistryProvider.NewItem calls RemoveItem first). That erased the parked
# sign-in entries, HKLM\SOFTWARE\DeskConsole and the Windows Update policy (R1). Create only
# what is missing, parent first, never with -Force.
function Confirm-RegKey([string]$k) {
    if (Test-Path -LiteralPath $k) { return }
    $parent = Split-Path $k -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { Confirm-RegKey $parent }
    New-Item -Path $k | Out-Null
}
# HKLM\SOFTWARE\DeskConsole values (C-4): AutoLogonUser, RustDeskReach, RustDeskWhitelist,
# HiberbootWas, PasswordLessWas, AUOptionsWas ... -- what setup changed, for Desk Console and the agent
function Get-DcValue([string]$n) { (Get-ItemProperty -LiteralPath $DcKey -Name $n -ErrorAction SilentlyContinue).$n }
function Set-DcValue([string]$n, $v, [string]$type = 'String') {
    Confirm-RegKey $DcKey
    New-ItemProperty -LiteralPath $DcKey -Name $n -Value $v -PropertyType $type -Force | Out-Null
}
function Remove-DcValue([string]$n) { Remove-ItemProperty -LiteralPath $DcKey -Name $n -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------- kvm.json
# { provider, server, row (left -> right), optional grid, options, hotkeys } shared by every PC
function Get-Kvm {
    if (Test-Path $KvmJson) { return Get-Content $KvmJson -Raw | ConvertFrom-Json }
    [pscustomobject]@{ provider = 'Deskflow'; server = $Me; row = @($Me) }   # first PC set up = server until -Role says otherwise
}
# -Depth 6: "grid" (rows of names) and "options" would be cut to type names at the default depth (F12)
function Save-Kvm($k) { $k | ConvertTo-Json -Depth 6 | Set-Content $KvmJson -Encoding ascii }
function Set-KvmField($k, [string]$name, $value) {   # a hand-written kvm.json may lack the field
    if ($k.PSObject.Properties[$name]) { $k.$name = $value } else { $k | Add-Member -NotePropertyName $name -NotePropertyValue $value }
}
function Find-Exe($dir, $name) { (Get-ChildItem $dir -Filter $name -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1).FullName }

# The layout as rows (top -> bottom), each left -> right: kvm.json "grid" when present (a list
# of names alone counts as one row), else "row". A name appears once (Deskflow names ignore
# case): a name twice would give overlapping links, and Deskflow then refuses the whole layout.
function Get-KvmGrid($k) {
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if ($k.PSObject.Properties['grid'] -and $k.grid) { $src = @($k.grid) } else { $src = ,@($k.row) }
    if (-not @($src | Where-Object { $_ -is [array] }).Count) { $src = ,@($src) }
    $rows = New-Object Collections.Generic.List[object]
    foreach ($r in $src) {
        $names = [string[]]@(@($r) | ForEach-Object { "$_".Trim() } | Where-Object { $_ -and $seen.Add($_) })
        if ($names.Count) { $rows.Add($names) }
    }
    ,$rows.ToArray()   # one array of rows, also for a single row: assign it, do not wrap it in @()
}
function Get-KvmScreens($grid) { foreach ($r in $grid) { foreach ($n in $r) { $n } } }   # card order
function Format-KvmLayout($grid) { (@($grid | ForEach-Object { $_ -join ' | ' })) -join '  /  ' }

# ---------------------------------------------------------------- network
# C-10/R7: the address the other PCs use for this one. First the source address Windows picks to
# reach the shared folder's host -- a UDP "connect" chooses route and address without sending a
# packet; measured cold 0.4-0.55 s, against 2.4-2.7 s (once 10 s) for Find-NetRoute, and this
# runs in the 2-minute task. That also skips a full-tunnel VPN that only wins on metric.
# Fallback: Up adapters, virtual ones (Hyper-V/WSL switch, VPN) last, then: has a default
# gateway, wired, lowest metric (F13: the old sort put a gateway-less vEthernet ahead of Wi-Fi).
$VirtualNic = 'Hyper-V Virtual|Virtual Ethernet|WSL|Tailscale|WireGuard|VPN|TAP-Windows|Host-Only|Loopback'
function Get-PreferredIPv4 {
    if ($ShareHost) {
        try {
            $dst = [Net.Dns]::GetHostAddresses($ShareHost) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
            if ($dst) {
                $u = New-Object Net.Sockets.UdpClient
                try { $u.Connect($dst, 445); $local = $u.Client.LocalEndPoint.Address } finally { $u.Close() }
                $r = Get-IPv4Info $local
                if ($r) { return $r }
            }
        } catch {}
    }
    $c = foreach ($a in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
        if ($a.IPAddress -like '127.*' -or $a.IPAddress -like '169.254.*') { continue }
        $ad = Get-NetAdapter -InterfaceIndex $a.InterfaceIndex -ErrorAction SilentlyContinue
        if (-not $ad -or $ad.Status -ne 'Up') { continue }
        [pscustomobject]@{ IPAddress = $a.IPAddress; PrefixLength = [int]$a.PrefixLength; MAC = $ad.MacAddress; InterfaceIndex = $a.InterfaceIndex
            Virtual = [bool]$ad.Virtual -or $ad.InterfaceDescription -match $VirtualNic
            NoGw    = -not (Get-NetRoute -InterfaceIndex $a.InterfaceIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
            Wifi    = $ad.PhysicalMediaType -match '802\.11|Wireless' -or $ad.InterfaceDescription -match 'Wi-?Fi|Wireless'
            Metric  = (Get-NetIPInterface -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric }
    }
    $best = $c | Sort-Object Virtual, NoGw, Wifi, Metric | Select-Object -First 1
    if ($best) { $best | Select-Object IPAddress, PrefixLength, MAC, InterfaceIndex }
}
function Get-IPv4Info($addr) {   # prefix length, MAC and interface index of one local address, from .NET (no CIM)
    if (-not $addr -or "$addr" -like '127.*' -or "$addr" -like '169.254.*' -or "$addr" -eq '0.0.0.0') { return $null }
    foreach ($nic in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        $p = $nic.GetIPProperties()
        $ua = $p.UnicastAddresses | Where-Object { $_.Address.Equals($addr) } | Select-Object -First 1
        if (-not $ua) { continue }
        $mac = ($nic.GetPhysicalAddress().GetAddressBytes() | ForEach-Object { $_.ToString('X2') }) -join '-'
        return [pscustomobject]@{ IPAddress = "$addr"; PrefixLength = [int]$ua.PrefixLength
            MAC = $(if ($mac) { $mac } else { $null }); InterfaceIndex = $p.GetIPv4Properties().Index }
    }
    $null
}

function ConvertTo-IPv4Number([string]$ip) {
    $a = $null
    if (-not [Net.IPAddress]::TryParse($ip, [ref]$a) -or "$($a.AddressFamily)" -ne 'InterNetwork') { return $null }
    $b = $a.GetAddressBytes(); [Array]::Reverse($b); [long][BitConverter]::ToUInt32($b, 0)
}
function Get-IPv4Mask([int]$len) { [long]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $len)) }
# "192.168.1.25/24" -> "192.168.1.0/24", a bare address -> /32. The firewall and RustDesk get
# the network address; shorter than /8 is not a home network (0.0.0.0/0 would open everything).
function ConvertTo-NetworkCidr([string]$s) {
    if ($s -notmatch '^\s*((?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d))(?:/(\d{1,2}))?\s*$') { return $null }
    $len = if ($Matches[2]) { [int]$Matches[2] } else { 32 }
    if ($len -lt 8 -or $len -gt 32) { return $null }
    $b = [BitConverter]::GetBytes([uint32]((ConvertTo-IPv4Number $Matches[1]) -band (Get-IPv4Mask $len))); [Array]::Reverse($b)
    "$([Net.IPAddress]::new($b).IPAddressToString)/$len"
}
function Test-IPv4InCidrs([string]$ip, [string[]]$cidrs) {
    $v = ConvertTo-IPv4Number ($ip -replace '^::ffff:', '')
    if ($null -eq $v) { return $false }
    foreach ($c in $cidrs) {
        $net, $len = $c -split '/', 2
        $m = Get-IPv4Mask ([int]$len)
        if (($v -band $m) -eq ((ConvertTo-IPv4Number $net) -band $m)) { return $true }
    }
    $false
}
# C-7: site.json "lanCidr" (one CIDR or a list); without it, the network of this PC's preferred
# address. The RustDesk whitelist and the firewall scope both come from here.
function Get-LanCidrs {
    $out = New-Object Collections.Generic.List[string]
    foreach ($c in @(Get-SiteSetting 'lanCidr')) {
        if (-not "$c".Trim()) { continue }
        $n = ConvertTo-NetworkCidr "$c"
        if (-not $n) { Say "site.json lanCidr '$c' is not an IPv4 network such as 192.168.1.0/24 -- ignored." Yellow }
        elseif (-not $out.Contains($n)) { $out.Add($n) }
    }
    if (-not $out.Count) {
        # Derived only when this PC's network really is the one the shared folder's server is on,
        # and /8../30: run on a VPN, a hotel network or the second router, the "home network"
        # would otherwise be fixed to that network (or a VPN's /32) and lock the LAN out later.
        $ip = Get-PreferredIPv4
        if ($ip -and $ip.PrefixLength -ge 8 -and $ip.PrefixLength -le 30) {
            $n = ConvertTo-NetworkCidr "$($ip.IPAddress)/$($ip.PrefixLength)"
            $shareIp = $null
            if ($ShareHost) { try { $shareIp = [Net.Dns]::GetHostAddresses($ShareHost) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1 } catch {} }
            if ($n -and $shareIp -and (Test-IPv4InCidrs "$shareIp" @($n))) { $out.Add($n) }
            elseif ($n) { Say "This PC's network $n does not contain the shared folder's server, so it is not taken as the home network -- set ""lanCidr"" in site.json." Yellow }
        }
    }
    $out   # one string per network: call it as @(Get-LanCidrs)
}

# C-10/R7: this PC's row in machines.csv, written whole to a temp file then moved over the old
# one (a reader never sees half a file; a sharing violation is retried). Rows with this name, or
# this MAC under another name (a renamed PC, R15), are replaced. Always these five columns (F13:
# Export-Csv takes its columns from the first row). An empty IP never writes a row (R12: one
# blank row blanked every card); an empty MAC or RustDeskId keeps what the row had.
function Update-MachineRow([string]$IP, [string]$MAC, [string]$RustDeskId) {
    if (-not $IP) { return $false }
    $reg = Join-Path $Root 'machines.csv'; $tmp = "$reg.$Me.tmp"
    $norm = { param($x) ("$x" -replace '[^0-9A-Fa-f]', '').ToUpper() }
    for ($try = 1; ; $try++) {
        try {
            $old = @(if (Test-Path $reg) { Import-Csv $reg })
            $mine = $old | Where-Object { $_.Name -eq $Me } | Select-Object -First 1
            if (-not $MAC -and $mine) { $MAC = "$($mine.MAC)" }
            if (-not $RustDeskId -and $mine) { $RustDeskId = "$($mine.RustDeskId)" }
            $m = & $norm $MAC
            $rows = @($old | Where-Object { $_.Name -and $_.Name -ne $Me -and -not ($m -and (& $norm $_.MAC) -eq $m) }) +
                    [pscustomobject]@{ Name = $Me; IP = $IP; MAC = $MAC; RustDeskId = $RustDeskId; Updated = (Get-Date -f 'yyyy-MM-dd HH:mm') }
            $rows | Select-Object Name, IP, MAC, RustDeskId, Updated | Sort-Object Name | Export-Csv $tmp -NoTypeInformation -Encoding ascii
            Move-Item $tmp $reg -Force
            return $true
        } catch {
            if ($try -ge 5) { Remove-Item $tmp -ErrorAction SilentlyContinue; throw }
            Start-Sleep -Milliseconds 400
        }
    }
}

# Secrets handed over by the installer wizard or Desk Console (never on a command line). UTF-8:
# Windows PowerShell reads a file without a BOM as ANSI, which changed an e-acute or a pound
# sign in a password before LogonUser saw it (R8).
$Secrets = @{}
if ($SecretsFile -and (Test-Path $SecretsFile)) {
    foreach ($l in Get-Content $SecretsFile -Encoding UTF8) { if ($l -match '^(\w+)=(.*)$') { $Secrets[$Matches[1]] = $Matches[2] } }
    if ($Phase -eq 'AutoLogon') { Remove-Item $SecretsFile -Force -ErrorAction SilentlyContinue }   # Desk Console's file
}

# ---------------------------------------------------------------- phase 1 (as you)
function Add-SetupCredType {   # not "DeskCred": Desk Console defines that one
    if ('DeskSetupCred' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class DeskSetupCred {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct CREDENTIAL {
        public int Flags; public int Type; public string TargetName; public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize; public IntPtr CredentialBlob; public int Persist;
        public int AttributeCount; public IntPtr Attributes; public string TargetAlias; public string UserName;
    }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredWrite(ref CREDENTIAL cred, int flags);
    // generic credential (Type 1), Persist 2 (local machine): the entry Desk Console's DeskCred reads
    public static void Write(string target, string user, string secret) {
        var b = Encoding.Unicode.GetBytes(secret);
        var c = new CREDENTIAL { Type = 1, TargetName = target, UserName = user, CredentialBlobSize = b.Length, Persist = 2 };
        c.CredentialBlob = Marshal.AllocCoTaskMem(b.Length);
        try { Marshal.Copy(b, 0, c.CredentialBlob, b.Length); if (!CredWrite(ref c, 0)) throw new System.ComponentModel.Win32Exception(); }
        finally { Marshal.FreeCoTaskMem(c.CredentialBlob); }
    }
}
'@
}

# C-12/U9d: the RustDesk password typed in the wizard also goes to this user's Credential Manager
# as DeskConsole:RustDesk, so View + control does not ask for it again.
function Save-RustDeskCredential([string]$pw) {
    Add-SetupCredType
    [DeskSetupCred]::Write('DeskConsole:RustDesk', 'rustdesk', $pw)
    Say 'RustDesk password saved for Desk Console (Credential Manager: DeskConsole:RustDesk).' Green
}

function Save-ShareLogin {
    $saved = (cmdkey /list) -match "target=$([regex]::Escape($NasHosts[0]))$"
    if ($Secrets['nas_pass'] -or $ResetCredential -or (-not $saved -and -not $Unattended)) {
        if ($Secrets['nas_pass']) {
            $user = if ($Secrets['nas_user']) { $Secrets['nas_user'] } else { $NasUser }; $pw = $Secrets['nas_pass']
        } else {
            if ($Unattended) { throw 'A new share login needs nas_pass in the secrets file (unattended run) -- nothing changed.' }   # never a prompt in a hidden window
            $cred = Get-Credential -UserName $NasUser -Message "Login for \\$($NasHosts[0]) (saved to Windows Credential Manager)"
            if (-not $cred) { throw 'No credential entered.' }
            $user = $cred.UserName; $pw = $cred.GetNetworkCredential().Password
        }
        foreach ($h in $NasHosts) {
            cmdkey /delete:$h 2>$null | Out-Null
            # quoted (R8): '/pass:$pw' dropped an embedded quote, so the saved password differed
            $rc = Invoke-Native 'cmdkey.exe' "/add:$(Quote-NativeArg $h) /user:$(Quote-NativeArg $user) /pass:$(Quote-NativeArg $pw)"
            if ($rc -ne 0) { $pw = $null; throw "cmdkey could not save the login for $h (exit $rc)." }
        }
        $pw = $null
        Say "Saved the share login for: $($NasHosts -join ', ')" Green
    } elseif ($saved) {
        Say 'Share login already saved (use -ResetCredential to replace it).'
    } else {   # U9c: this used to say "already saved" when nothing was
        Say 'No share login saved and none entered -- this PC reaches the shared folder only if Windows already has access to it.' Yellow
    }
}

# R6: the wizard passes -Kvm and -Role even when it could not read kvm.json (no share login yet),
# which silently made a new client the server, or flipped the provider, for every PC.
# -KvmIfUnset / -Role ServerIfUnset change kvm.json only where it names nothing yet.
function Update-KvmFromArgs {
    if (-not $Kvm -and -not $Role) { return }
    $exists = Test-Path $KvmJson
    if ($exists) { $k = Get-Kvm } else { $k = [pscustomobject]@{ provider = 'Deskflow'; server = ''; row = @($Me) } }
    $before = $k | ConvertTo-Json -Depth 6 -Compress
    $was = "$($k.server)"
    if ($Kvm) {
        if ($KvmIfUnset -and $exists -and "$($k.provider)") {
            if ("$($k.provider)" -ne $Kvm) { Say "kvm.json already says $($k.provider) for every PC -- left as it is." Yellow }
        } else {
            Set-KvmField $k 'provider' $Kvm
            Say "kvm.json provider set to $Kvm for every PC -- run setup on each PC to apply." Green
        }
    }
    switch ($Role) {
        'Server'        { Set-KvmField $k 'server' $Me }
        'ServerIfUnset' {
            if (-not $was -or $was -eq $Me) { Set-KvmField $k 'server' $Me }
            else { Say "kvm.json already names $was as the keyboard/mouse server -- this PC joins as its client. To move the keyboard and mouse here, run setup again and choose Server." Yellow }
        }
        'Client'        {
            if ($was -eq $Me) { Say "kvm.json still names $Me as the server -- pick another server on that PC." Yellow }
            elseif (-not $was) { Say 'No keyboard/mouse server is set yet -- run setup on the PC the keyboard and mouse are plugged into, and choose Server.' Yellow }
        }
        default         { if (-not $exists) { Set-KvmField $k 'server' $Me } }   # no -Role: the first PC set up is the server
    }
    if ("$($k.server)" -eq $Me -and $was -ne $Me) { Say "kvm.json server set to $Me." Green }
    if (-not $exists -or ($k | ConvertTo-Json -Depth 6 -Compress) -ne $before) { Save-Kvm $k }
}

function Set-DriveMapping {
    $z = Get-SmbMapping -LocalPath $MapDrive -ErrorAction SilentlyContinue
    if ($z -and $z.RemotePath -ne $MapPath) { Say "$MapDrive is mapped to $($z.RemotePath), not $MapPath -- leaving it alone." Yellow; return }
    if ($z -and $z.Status -eq 'OK') { Say "$MapDrive already mapped to $MapPath."; return }
    # stdin closed (<nul): in the installer's hidden window "net use" must fail, never wait at
    # "Enter the user name" (R4); a failed mapping is a warning -- the \\server path still works
    if ($z) { cmd.exe /c "net use $MapDrive /delete /y <nul >nul 2>&1" }
    cmd.exe /c "net use $MapDrive $(Quote-NativeArg $MapPath) /persistent:yes <nul >nul 2>&1"
    if ($LASTEXITCODE -ne 0) { Say "$MapDrive NOT mapped to $MapPath (net use exit $LASTEXITCODE) -- the shared folder still works by its \\server path." Yellow; return }
    Say "Mapped $MapDrive -> $MapPath (persistent)." Green
}

# R4 order: the share login first, then kvm.json (needs that login on a fresh PC), then the
# optional drive mapping -- a failed "net use" used to throw away the wizard's provider and role.
function Invoke-UserPhase {
    if ($NasHosts.Count) { Invoke-Step 'Share login NOT saved' { Save-ShareLogin } }
    if ($Secrets['rd_pass']) { Invoke-Step 'RustDesk password NOT saved for Desk Console' { Save-RustDeskCredential $Secrets['rd_pass'] } }
    Invoke-Step 'kvm.json NOT updated' { Update-KvmFromArgs }
    if ($MapDrive -and $MapPath) { Invoke-Step "Drive $MapDrive NOT mapped" { Set-DriveMapping } }

    # keep the share path in site.json as UNC: the elevated step cannot see drive letters
    $here = Join-Path $PSScriptRoot 'site.json'
    if ($Site -and (Test-Path $here) -and "$($Site.shareRoot)" -match '^[A-Za-z]:') {
        $Site.shareRoot = ConvertTo-Unc "$($Site.shareRoot)"
        $Site | ConvertTo-Json -Depth 6 | Set-Content $here -Encoding UTF8   # UTF-8 (R8): ascii turned a non-ASCII path into '?'
    }

    # Desk Console for this user (Start Menu + Desktop, Settings > Apps entry; no admin)
    # -- DeskConsoleSetup.exe installs it itself
    if (-not $FromInstaller) { & (Join-Path $Root 'Install-DeskConsole.ps1') }
}

# ---------------------------------------------------------------- phase 2 (elevated)
function Get-ExeVersion($path) {   # "1.5.0+68", "1.27.0.0", "3.8.3" -> [version] a.b.c; $null when unknown
    if (-not $path -or -not (Test-Path $path)) { return $null }
    $vi = (Get-Item $path).VersionInfo
    foreach ($s in $vi.ProductVersion, $vi.FileVersion) {
        if ("$s" -match '^\s*(\d+)\.(\d+)(?:\.(\d+))?') { return [version]('{0}.{1}.{2}' -f $Matches[1], $Matches[2], $(if ($Matches[3]) { $Matches[3] } else { '0' })) }
    }
    $null
}

# msiexec, waiting out 1618 ("another installation is in progress" -- Windows Update, often)
# for up to 10 x 30 s instead of failing the step (R5).
function Invoke-Msi([string]$msiArgs, [string]$logName) {
    $log = Join-Path $env:TEMP "$logName.log"
    for ($try = 1; ; $try++) {
        $p = Start-Process msiexec.exe -ArgumentList "$msiArgs /l*v $(Quote-NativeArg $log)" -Wait -PassThru
        if ($p.ExitCode -ne 1618 -or $try -ge 10) { return $p.ExitCode }
        Say "Another installation is running (often Windows Update) -- trying again in 30 s ($try of 10)."
        Start-Sleep 30
    }
}

# R14: "installed" used to mean "the exe exists", so a newer bundled RustDesk or Deskflow never
# reached the PCs set up earlier. An older copy is upgraded -- except RustDesk while you are
# connected through it, because its service restarts during the upgrade.
function Install-FromShare($name, [scriptblock]$findExe) {
    $i = $Installers[$name]
    $exe = & $findExe
    $have = Get-ExeVersion $exe
    if ($exe -and (-not $have -or $have -ge [version]$i.Ver)) { Say "$name$(if ($have) { " $have" }) already installed."; return $false }
    if ($exe -and $name -eq 'RustDesk' -and (Get-RustDeskSessions).Any) {
        Say "RustDesk $have -> $($i.Ver) upgrade postponed: you are connected through RustDesk. Re-run setup at the PC, or after you disconnect." Yellow
        return $false
    }
    $src = Join-Path $Root "installer\$($i.Msi)"
    if ($InstallerDir -and (Test-Path (Join-Path $InstallerDir $i.Msi))) { $src = Join-Path $InstallerDir $i.Msi }
    if ($exe -and -not (Test-Path $src)) { Say "$name $have is older than $($i.Ver), but $($i.Msi) is not here to upgrade it -- keeping $have." Yellow; return $false }
    $h = (Get-FileHash $src -Algorithm SHA256).Hash
    if ($h -ne $i.Sha) { throw "$($i.Msi) hash mismatch on share ($h). Not installing." }
    $local = Join-Path $env:TEMP $i.Msi
    Copy-Item $src $local -Force
    Say $(if ($exe) { "Upgrading $name $have -> $($i.Ver)..." } else { "Installing $($i.Msi)..." })
    $rc = Invoke-Msi "/i $(Quote-NativeArg $local) /qn /norestart" "$name-install"
    Remove-Item $local -ErrorAction SilentlyContinue
    if ($rc -notin 0, 3010) { throw "$name msiexec exit $rc; log: $env:TEMP\$name-install.log" }
    Say "$name $($i.Ver) installed." Green
    return $true
}

# Desk Console's own inbound rules: limited to the home network (lanCidr, else LocalSubnet),
# every profile -- the Surface's home network is categorised Public (S3: Private,Domain would
# cut it off at home).
function Set-FirewallRule($name, [hashtable]$spec) {
    Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName $name -Direction Inbound -RemoteAddress $script:FwScope -Profile Any -Action Allow @spec | Out-Null
}
# E16/F15: the shared port rule was "Synergy 3 (TCP 24800, LAN)" on Deskflow PCs too, and a
# clean-up of "Synergy*" rules would have cut Deskflow's port.
function Set-KvmPortRule {
    Set-FirewallRule $KvmPortRule @{ Protocol = 'TCP'; LocalPort = 24800 }   # same port for both products
    Get-NetFirewallRule -DisplayName 'Synergy 3 (TCP 24800, LAN)' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
}
# C-15/F4/S3: the RustDesk, Deskflow and Synergy MSIs add their own inbound allow rules for ANY
# address on every profile (seen live: "RustDesk Service", "Deskflow Server"/"Deskflow Client",
# "Synergy Core", "Synergy 3 Service"); allow rules add up, so the LAN-only rules restricted
# nothing. Every inbound allow rule for those programs gets the home-network scope. Re-done on
# every run: an MSI upgrade recreates them. COM, not Get-NetFirewallApplicationFilter: 0.4 s
# against 30 s for the same rules (measured on 698 rules).
function Set-VendorFirewallScope {
    if (-not $script:FwSafe) { Say 'Vendor firewall rules left as they are this time (see the note about your RustDesk session above).' Yellow; return }
    $scope = $script:FwScope -join ','
    $under = '^' + [regex]::Escape("$env:ProgramFiles\") + '(RustDesk|Deskflow|Synergy)\\'
    $names = 'RustDesk Service', 'Deskflow Server', 'Deskflow Client', 'Synergy Core', 'Synergy 3 Service'
    $n = 0
    foreach ($r in (New-Object -ComObject HNetCfg.FwPolicy2).Rules) {
        if ($r.Direction -ne 1 -or $r.Action -ne 1) { continue }   # inbound, allow
        $app = [Environment]::ExpandEnvironmentVariables("$($r.ApplicationName)")
        if (-not ($app -match $under -or $names -contains $r.Name)) { continue }
        try { $r.RemoteAddresses = $scope; $n++ } catch { Say "Firewall rule '$($r.Name)' NOT limited to the home network: $($_.Exception.Message)" Yellow }
    }
    Say "Firewall: $n RustDesk/Deskflow/Synergy program rule(s) answer only $scope (all network profiles)."
}

# Switch a KVM product off without uninstalling it: stop + disable its services,
# park its sign-in (Run) entries, end its processes. Enable-Kvm undoes exactly that.
function Disable-Kvm($product) {
    $any = $false
    foreach ($s in @(Get-Service | Where-Object { $_.DisplayName -match $product -or $_.Name -match $product })) {
        if ($s.Status -ne 'Stopped') { Stop-Service $s.Name -Force -ErrorAction SilentlyContinue }
        Set-Service $s.Name -StartupType Disabled; $any = $true
    }
    foreach ($scope in 'HKLM', 'HKCU') {
        $run = "${scope}:\Software\Microsoft\Windows\CurrentVersion\Run"
        $hits = @((Get-ItemProperty $run -ErrorAction SilentlyContinue).PSObject.Properties |
            Where-Object { $_.Name -notlike 'PS*' -and "$($_.Value)" -match "\\$product\\" })
        if ($hits.Count) { Confirm-RegKey $ParkedRun }   # R1: never re-created -- that erased the other product's entries
        foreach ($h in $hits) {
            New-ItemProperty $ParkedRun -Name "$scope|$($h.Name)" -Value $h.Value -Force | Out-Null
            Remove-ItemProperty $run -Name $h.Name; $any = $true
        }
    }
    Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -match "\\$product\\" } | Stop-Process -Force -ErrorAction SilentlyContinue
    if ($any) { Say "$product switched off (not uninstalled)." }
}

function Enable-Kvm($product) {
    Get-Service | Where-Object { $_.DisplayName -match $product -or $_.Name -match $product } | ForEach-Object {
        Set-Service $_.Name -StartupType Automatic
        if ($_.Status -ne 'Running') { Start-Service $_.Name -ErrorAction SilentlyContinue }
    }
    if (Test-Path $ParkedRun) {
        (Get-ItemProperty $ParkedRun).PSObject.Properties |
            Where-Object { $_.Name -like '*|*' -and "$($_.Value)" -match "\\$product\\" } | ForEach-Object {
                $scope, $name = $_.Name -split '\|', 2
                New-ItemProperty "${scope}:\Software\Microsoft\Windows\CurrentVersion\Run" -Name $name -Value $_.Value -Force | Out-Null
                Remove-ItemProperty $ParkedRun -Name $_.Name
            }
    }
}

function Install-Synergy {
    Install-FromShare 'Synergy' { $p = 'C:\Program Files\Synergy\synergy-core.exe'; if (Test-Path $p) { $p } } | Out-Null
    Enable-Kvm 'Synergy'
    Get-ChildItem 'C:\Program Files\Synergy' -Filter 'synergy*.exe' -ErrorAction SilentlyContinue | ForEach-Object {
        Set-FirewallRule "Synergy 3 ($($_.Name), LAN)" @{ Program = $_.FullName }
    }
    Say 'Synergy on; the firewall allows it from the home network.' Green
}

# Deskflow's MSI refuses to install without the Microsoft Visual C++ runtime 14.44+ (exit 1603,
# "ShowVCRedistError" -- seen on a fresh desktop). Install Microsoft's signed vc_redist.x64.exe
# when the runtime is missing or older; 1638 = a newer one is already there.
$VcRedist = @{ Exe = 'vc_redist.x64.exe'; Sha = 'CC0FF0EB1DC3F5188AE6300FAEF32BF5BEEBA4BDD6E8E445A9184072096B713B' }   # 14.44.35211.0
function Install-VCRedist {
    foreach ($key in 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64') {
        $p = Get-ItemProperty $key -ErrorAction SilentlyContinue
        if ($p.Installed -eq 1 -and ($p.Major -gt 14 -or ($p.Major -eq 14 -and $p.Minor -ge 44))) { Say "Visual C++ runtime $($p.Version) present."; return }
    }
    $src = Join-Path $Root "installer\$($VcRedist.Exe)"
    if ($InstallerDir -and (Test-Path (Join-Path $InstallerDir $VcRedist.Exe))) { $src = Join-Path $InstallerDir $VcRedist.Exe }
    $h = (Get-FileHash $src -Algorithm SHA256).Hash
    if ($h -ne $VcRedist.Sha) { throw "$($VcRedist.Exe) hash mismatch ($h). Not installing." }
    $local = Join-Path $env:TEMP $VcRedist.Exe
    Copy-Item $src $local -Force
    Say 'Installing the Microsoft Visual C++ runtime (Deskflow needs 14.44 or newer)...'
    for ($try = 1; ; $try++) {   # 1618 = another installation is running (Windows Update), as for the MSIs
        $p = Start-Process $local -ArgumentList '/install', '/quiet', '/norestart', '/log', "`"$env:TEMP\VCRedist-install.log`"" -Wait -PassThru
        if ($p.ExitCode -ne 1618 -or $try -ge 10) { break }
        Say "Another installation is running (often Windows Update) -- trying again in 30 s ($try of 10)."
        Start-Sleep 30
    }
    Remove-Item $local -ErrorAction SilentlyContinue
    if ($p.ExitCode -notin 0, 3010, 1638) { throw "Visual C++ runtime install exit $($p.ExitCode); log: $env:TEMP\VCRedist-install.log" }
    Say 'Visual C++ runtime installed.' Green
}

function Install-Deskflow {
    Install-VCRedist
    Install-FromShare 'Deskflow' { Find-Exe 'C:\Program Files\Deskflow' 'deskflow*.exe' } | Out-Null
    Enable-Kvm 'Deskflow'
    Get-ChildItem 'C:\Program Files\Deskflow' -Filter 'deskflow*.exe' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        Set-FirewallRule "Deskflow ($($_.Name), LAN)" @{ Program = $_.FullName }
    }
    Say 'Deskflow on; the firewall allows it from the home network.' Green
}

# Server only: Synergy 3 keeps its live server layout in synergy.conf. Add
# direction hotkeys to its options section (idempotent). The Synergy app may
# rewrite this file when you change the layout -- re-run the script after.
function Add-SynergyHotkeys {
    if (-not (Test-Path $SynergyCore) -or -not ((Get-Content $SynergyCore) -match '^coreMode=2')) {
        Say 'Not the Synergy server (or not configured yet) -- no hotkeys to add here.'
        return
    }
    if (-not (Test-Path $SynergyConf)) { Say 'Server has no layout yet; add the computers in the Synergy app, then re-run.' Yellow; return }
    $text = Get-Content $SynergyConf -Raw
    if ($text -match 'switchInDirection') { Say 'Synergy hotkeys already present.'; return }
    $keys = "`tkeystroke(Control+Alt+Left) = switchInDirection(left)`r`n" +
            "`tkeystroke(Control+Alt+Right) = switchInDirection(right)`r`n"
    if ($text -match '(?s)section: options') {
        $text = [regex]::Replace($text, '(?s)(section: options\r?\n.*?)(\r?\nend)', { param($m) $m.Groups[1].Value + "`r`n" + $keys.TrimEnd() + $m.Groups[2].Value }, 1)
    } else {
        $text += "`r`nsection: options`r`n$keys" + "end`r`n"
    }
    Copy-Item $SynergyConf "$SynergyConf.bak" -Force
    Set-Content $SynergyConf $text -Encoding ascii -NoNewline
    Get-Service | Where-Object { $_.DisplayName -match 'synergy' -and $_.Status -eq 'Running' } | Restart-Service
    Say 'Synergy hotkeys added: Ctrl+Alt+Left / Ctrl+Alt+Right (backup: synergy.conf.bak).' Green
}

# ---------------------------------------------------------------- RustDesk
function Install-RustDesk {
    $script:RustDeskFresh = Install-FromShare 'RustDesk' { if (Test-Path $RustDeskExe) { $RustDeskExe } }
    $svc = Get-Service RustDesk -ErrorAction SilentlyContinue
    if (-not $svc) { & $RustDeskExe --install-service | Out-Null; Start-Sleep 5; $svc = Get-Service RustDesk -ErrorAction SilentlyContinue }
    if ($svc) { Set-Service RustDesk -StartupType Automatic; if ($svc.Status -ne 'Running') { Start-Service RustDesk } }
    else { Say 'RustDesk service did not appear -- open RustDesk once and accept its service install prompt.' Yellow }
}

# Open RustDesk sessions to this PC. Setup is often run over one, and RustDesk must never be
# restarted (or whitelisted) out from under it: direct-IP peers are Established on local port
# 21118; a session through RustDesk's relay shows only as rustdesk.exe -> remote port 21117,
# and then this PC cannot see the controller's address at all.
function Get-RustDeskSessions {
    $direct = @(Get-NetTCPConnection -LocalPort 21118 -State Established -ErrorAction SilentlyContinue |
        ForEach-Object { "$($_.RemoteAddress)" -replace '^::ffff:', '' } | Select-Object -Unique)
    $ids = @(Get-Process -Name rustdesk -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    $relay = $ids.Count -and [bool](Get-NetTCPConnection -RemotePort 21117 -State Established -ErrorAction SilentlyContinue |
        Where-Object { $ids -contains $_.OwningProcess })
    # A connection by ID inside the LAN or a hole-punched one uses other ports and shows up in
    # neither test above; RustDesk's connection manager (rustdesk.exe --cm / --cm-no-ui) runs for
    # every incoming session, so it counts as a session whose origin this PC cannot see.
    $cm = $ids.Count -and [bool](Get-CimInstance Win32_Process -Filter "Name='rustdesk.exe'" -ErrorAction SilentlyContinue |
        Where-Object { "$($_.CommandLine)" -match '--cm' })
    $unknown = [bool]$cm -and -not $direct.Count -and -not [bool]$relay
    [pscustomobject]@{ Direct = $direct; Relayed = [bool]$relay; Unknown = $unknown
        Any = ($direct.Count -gt 0) -or [bool]$relay -or [bool]$cm }
}

# RustDesk2.toml [options] holds  name = 'value'  (that is how direct-server reads back).
function Get-TomlOption([string]$text, [string]$name) {
    $in = $false
    foreach ($l in ($text -split '\r?\n')) {
        if ($l -match '^\s*\[(.+?)\]\s*$') { $in = $Matches[1] -eq 'options'; continue }
        if ($in -and $l -match "^\s*$([regex]::Escape($name))\s*=\s*(?:'([^']*)'|""([^""]*)"")") { return "$($Matches[1])$($Matches[2])" }
    }
    $null
}
function Set-TomlOption([string]$text, [string]$name, [string]$value) {   # value '' removes the line
    $lines = New-Object Collections.Generic.List[string]
    if ($text) { $lines.AddRange([string[]]($text -split '\r?\n')) }
    $line = "$name = '$value'"
    $si = -1; for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -eq '[options]') { $si = $i; break } }
    if ($si -lt 0) {
        if ($value) { if ($lines.Count -and $lines[$lines.Count - 1] -ne '') { $lines.Add('') }; $lines.Add('[options]'); $lines.Add($line); $lines.Add('') }
        return ($lines -join "`n")
    }
    $end = $lines.Count; for ($i = $si + 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*\[') { $end = $i; break } }
    for ($i = $si + 1; $i -lt $end; $i++) {
        if ($lines[$i] -match "^\s*$([regex]::Escape($name))\s*=") {
            if ($value) { $lines[$i] = $line } else { $lines.RemoveAt($i) }
            return ($lines -join "`n")
        }
    }
    if ($value) { $lines.Insert($si + 1, $line) }
    $lines -join "`n"
}

# Direct IP (no relay needed in the house) and how far RustDesk reaches (C-16, S2/F2). Checked
# in RustDesk 1.5.0 (gh api, tag 1.5.0): src/server/connection.rs check_whitelist reads option
# "whitelist", splits it on "," WITHOUT trimming (so no spaces), parses each entry with
# cidr-utils 0.5 IpCidr (a CIDR or one address), and an entry "0.0.0.0" switches it off. It runs
# in on_open for every connection -- relayed ones too: src/server.rs create_relay_connection
# passes the controller's address as the ID server saw it, through try_into_v4 -- so a LAN-only
# list refuses connections by ID from the internet although the PC stays registered with the
# public ID server. src/core_main.rs: "--option <name> <value>" needs admin and an installed
# RustDesk and sets it through the running service; two arguments only prints the value.
function Set-RustDeskOptions {
    $reach = if ("$(Get-SiteSetting 'rustdeskReach')" -eq 'anywhere') { 'anywhere' } else { 'lan' }
    $want = $null   # $null: leave the whitelist as it is
    if ($reach -eq 'anywhere') { $want = '' }
    elseif (-not $script:LanCidrs.Count) { Say 'RustDesk is NOT limited to the home network: no home network found -- set "lanCidr" in site.json.' Yellow }
    else {
        # SAFETY: James runs the desktops through RustDesk; never set a list that would refuse
        # the session this setup may be running in
        $s = Get-RustDeskSessions
        $outside = @($s.Direct | Where-Object { -not (Test-IPv4InCidrs $_ $script:LanCidrs) })
        if ($s.Relayed -or $s.Unknown) { Say 'RustDesk is NOT limited to the home network yet: a RustDesk session is open whose origin this PC cannot see (relay, ID or peer-to-peer). Re-run setup at the PC or over a direct-IP connection (Desk Console).' Yellow }
        elseif ($outside.Count) { Say "RustDesk is NOT limited to the home network yet: you are connected from $($outside -join ', '), outside $($script:LanCidrs -join ', '), and would be locked out." Yellow }
        else { $want = $script:LanCidrs -join ',' }
    }
    [void](Invoke-Native $RustDeskExe '--option direct-server Y')
    if ($null -ne $want) { [void](Invoke-Native $RustDeskExe "--option whitelist $(Quote-NativeArg $want)") }   # "" clears it
    Start-Sleep 2

    # the service did not take it (not running yet): write its config file and restart it --
    # unless someone is connected through RustDesk right now (setup over a RustDesk session)
    $toml = if (Test-Path $RustDeskToml) { Get-Content $RustDeskToml -Raw -Encoding UTF8 } else { $null }
    if ($null -ne $toml) {
        $needDirect = (Get-TomlOption $toml 'direct-server') -ne 'Y'
        $needList   = ($null -ne $want) -and ("$(Get-TomlOption $toml 'whitelist')" -ne $want)
        if (($needDirect -or $needList) -and (Get-RustDeskSessions).Any) {
            Say 'RustDesk settings are not in place yet, but you are connected through RustDesk -- not restarting it now. Re-run setup at the PC, or tick Settings > Security > Enable direct IP access.' Yellow
        } elseif ($needDirect -or $needList) {
            Stop-Service RustDesk
            $toml = Get-Content $RustDeskToml -Raw -Encoding UTF8
            if ($needDirect) { $toml = Set-TomlOption $toml 'direct-server' 'Y' }
            if ($needList)   { $toml = Set-TomlOption $toml 'whitelist' $want }
            [IO.File]::WriteAllText($RustDeskToml, $toml, (New-Object Text.UTF8Encoding $false))   # no BOM in a TOML file
            Start-Service RustDesk
        }
    }
    $direct = ($null -ne $toml) -and (Get-TomlOption $toml 'direct-server') -eq 'Y'
    Say "RustDesk direct IP access: $(if ($direct) {'ON'} else {'NOT CONFIRMED -- tick Settings > Security > Enable direct IP access'})" $(if ($direct) {'Green'} else {'Yellow'})

    # what is in force, for Desk Console and the agent (C-4); unknown when it cannot be read
    if ($null -eq $toml) { Remove-DcValue 'RustDeskReach'; Remove-DcValue 'RustDeskWhitelist'; Say 'RustDesk reach NOT confirmed (no service settings file yet).' Yellow; return }
    $list = "$(Get-TomlOption $toml 'whitelist')"
    Set-DcValue 'RustDeskReach' $(if ($list) { 'lan' } else { 'anywhere' }); Set-DcValue 'RustDeskWhitelist' $list
    if ($list) { Say "RustDesk answers only $list (home network)." Green }
    elseif ($reach -eq 'anywhere') { Say 'RustDesk can be reached from anywhere by ID + password (site.json "rustdeskReach": "anywhere").' }
    else { Say 'RustDesk can be reached from the internet by ID + password until the home-network list is set.' Yellow }
}

function Set-RustDeskFirewall {
    Set-FirewallRule 'RustDesk direct IP (TCP 21118, LAN)' @{ Protocol = 'TCP'; LocalPort = 21118 }
    Set-FirewallRule 'RustDesk direct IP (UDP 21118, LAN)' @{ Protocol = 'UDP'; LocalPort = 21118 }
    Set-FirewallRule 'RustDesk (program, LAN)' @{ Program = $RustDeskExe }
    # lets Desk-Console see this PC as online (Windows drops ping by default)
    Set-FirewallRule 'Desk Console ping (ICMPv4, LAN)' @{ Protocol = 'ICMPv4'; IcmpType = 8 }
}

function Set-RustDeskPassword {
    if ($Secrets['rd_pass']) {
        if ($null -eq (Invoke-Native $RustDeskExe "--password $(Quote-NativeArg $Secrets['rd_pass'])")) { throw 'rustdesk --password did not finish.' }
        Say 'RustDesk password set (from the installer).' Green
    } elseif (($script:RustDeskFresh -or $ResetRemotePassword) -and -not $Unattended) {
        Write-Host ''
        Say 'Set the RustDesk unattended password for this PC (use the same one on all three).' White
        $a = Read-Host 'RustDesk password' -AsSecureString
        $b = Read-Host 'Again' -AsSecureString
        $pa = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($a))
        $pb = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($b))
        if ($pa -and $pa -ceq $pb) { [void](Invoke-Native $RustDeskExe "--password $(Quote-NativeArg $pa)"); Say 'RustDesk password set.' Green }
        else { Say 'Passwords empty or different -- re-run with -ResetRemotePassword.' Yellow }
        $pa = $pb = $null
    }
}

# ---------------------------------------------------------------- automatic sign-in
# Same method as Sysinternals Autologon: the password goes into the LSA secret
# "DefaultPassword" (encrypted), never the plain-text Winlogon DefaultPassword value.
# The password is checked with LogonUser first, so a typo cannot strand a PC at the
# sign-in screen. Optional: lock the screen right after an automatic sign-in (a logon task
# that locks only after a boot or a sign-out, so manual sign-ins are left alone).
$Winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$PwLess   = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device'
$PowerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
$LockTask = 'DeskConsole lock after auto sign-in'

function Add-AutoLogonType {
    if ('DeskAutoLogon' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class DeskAutoLogon {
    [StructLayout(LayoutKind.Sequential)] struct LSA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)] struct LSA_OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }
    [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr system, ref LSA_OBJECT_ATTRIBUTES attr, uint access, out IntPtr handle);
    [DllImport("advapi32.dll")] static extern uint LsaStorePrivateData(IntPtr handle, ref LSA_UNICODE_STRING key, IntPtr data);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr handle);
    [DllImport("advapi32.dll")] static extern int LsaNtStatusToWinError(uint status);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool LogonUser(string user, string domain, string password, int logonType, int provider, out IntPtr token);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    static LSA_UNICODE_STRING Str(string s) {
        var u = new LSA_UNICODE_STRING(); u.Buffer = Marshal.StringToHGlobalUni(s);
        u.Length = (ushort)(s.Length * 2); u.MaximumLength = (ushort)(u.Length + 2); return u;
    }
    // value == null deletes the secret
    public static void StoreSecret(string key, string value) {
        var attr = new LSA_OBJECT_ATTRIBUTES(); attr.Length = Marshal.SizeOf(attr);
        IntPtr h; uint st = LsaOpenPolicy(IntPtr.Zero, ref attr, 0x000F0FFF, out h);
        if (st != 0) throw new System.ComponentModel.Win32Exception(LsaNtStatusToWinError(st));
        var k = Str(key); var d = new LSA_UNICODE_STRING(); IntPtr pd = IntPtr.Zero;
        try {
            if (value != null) { d = Str(value); pd = Marshal.AllocHGlobal(Marshal.SizeOf(d)); Marshal.StructureToPtr(d, pd, false); }
            st = LsaStorePrivateData(h, ref k, pd);
            if (st != 0 && !(value == null && st == 0xC0000034)) throw new System.ComponentModel.Win32Exception(LsaNtStatusToWinError(st));
        } finally {
            Marshal.FreeHGlobal(k.Buffer);
            if (d.Buffer != IntPtr.Zero) { Marshal.FreeHGlobal(d.Buffer); }
            if (pd != IntPtr.Zero) { Marshal.FreeHGlobal(pd); }
            LsaClose(h);
        }
    }
    // 0 = Windows accepts this sign-in; else the Win32 error (1326 wrong name or password,
    // 1330 password expired, 1907 must change it, 1331 disabled, 1909 locked out)
    public static int LogonError(string user, string domain, string password) {
        IntPtr t; if (!LogonUser(user, domain, password, 2, 0, out t)) return Marshal.GetLastWin32Error();
        CloseHandle(t); return 0;
    }
    public static bool Check(string user, string domain, string password) { return LogonError(user, domain, password) == 0; }
}
'@
}

# Direct member of the local Administrators group (S-1-5-32-544, any language): $true, $false, or
# $null when Windows cannot tell (Get-LocalGroupMember fails on a group holding an orphaned SID).
# The password reset (R10) treats "cannot tell" as yes: a wrong "no" would reset an admin's password.
function Test-LocalAdmin($sid) {
    try { [bool](Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | Where-Object { "$($_.SID)" -eq "$sid" }) }
    catch { $null }
}
function Test-SignedInUser([string]$name) {   # the elevated user, and the console user (over-the-shoulder UAC differs)
    if ($name -eq $env:USERNAME) { return $true }
    "$((Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName)" -eq "$env:COMPUTERNAME\$name"
}

# R10: an existing account is checked with the typed password FIRST and only a failed check
# resets it -- never for the signed-in user or an administrator. A reset (unlike a password
# change) cannot re-protect DPAPI: the account's saved passwords, Credential Manager entries
# and EFS keys are lost. Every installer re-run on a desktop used to reset BuildRunner.
function Set-DedicatedAccount([string]$name, [string]$pw) {
    $sec = ConvertTo-SecureString $pw -AsPlainText -Force
    $acct = Get-LocalUser -Name $name -ErrorAction SilentlyContinue
    if (-not $acct) {
        New-LocalUser -Name $name -Password $sec -FullName 'Desk (automatic sign-in)' `
            -Description 'Created by Desk Console setup for automatic sign-in' -PasswordNeverExpires -AccountNeverExpires | Out-Null
        Say "Created local account $name." Green
    } else {
        $err = [DeskAutoLogon]::LogonError($name, $env:COMPUTERNAME, $pw)
        if ($err -eq 0) {
            Set-LocalUser -Name $name -PasswordNeverExpires $true
            Say "Local account $name exists -- password checked, not changed."
        } elseif ($err -notin 1326, 1330, 1907) {
            throw "Windows refuses sign-in for $name for another reason than the password ($((New-Object ComponentModel.Win32Exception $err).Message)) -- nothing changed."
        } elseif (Test-SignedInUser $name) {
            throw "That is not the current password of $name, the account signed in now, and setup does not reset it -- type its current password."
        } elseif ((Test-LocalAdmin $acct.SID) -ne $false) {
            throw "That is not the current password of $name, an administrator (or setup cannot tell), and setup does not reset it -- type its current password or choose another name."
        } else {
            Set-LocalUser -Name $name -Password $sec -PasswordNeverExpires $true
            Say "Local account ${name}: password reset -- its saved passwords and encrypted files are lost." Yellow
        }
    }
    $users = (New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-545').Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
    Add-LocalGroupMember -Group $users -Member $name -ErrorAction SilentlyContinue
    # a brand-new account's first sign-in stops on the privacy-settings screen
    Confirm-RegKey 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE'
    Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE' -Name DisablePrivacyExperience -Value 1 -Type DWord
}

# S5: the LSA secret can be read back in clear by any administrator (or SYSTEM process) on this
# PC, the way Sysinternals Autologon's can. Worth saying when the password opens more than this PC.
function Get-PasswordExposure([string]$dom, [string]$name) {
    if ($dom -ne $env:COMPUTERNAME) { return 'a domain account' }
    $u = Get-LocalUser -Name $name -ErrorAction SilentlyContinue
    if (-not $u) { return $null }
    if ("$($u.PrincipalSource)" -eq 'MicrosoftAccount') { return 'a Microsoft account' }
    $admin = Test-LocalAdmin $u.SID
    if ($admin) { return 'an administrator' }
    if ($null -eq $admin) { return 'perhaps an administrator (Windows could not list the group)' }
    $null
}

# C-11/R13: lock only right after an AUTOMATIC sign-in -- Windows started less than 3 minutes
# ago, or someone signed out less than 3 minutes ago (Winlogon event 7002): Windows signs the
# account straight back in after a sign-out (KB 324737), which the boot-time check missed. Fast
# Startup is turned off together with the lock, so a shut down + power on is a real boot. The
# task runs as the signed-in user, who may read the System log. Passed as -EncodedCommand, so
# no quoting can break it.
function Get-LockCheckScript {
    @'
$since = (Get-Date).AddMinutes(-3)
$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$logoff = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Winlogon'; Id = 7002; StartTime = $since } -MaxEvents 1 -ErrorAction SilentlyContinue
if ($boot -gt $since -or $logoff) { rundll32.exe user32.dll,LockWorkStation }
'@
}
function Get-EncodedCommand([string]$text) { [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($text)) }
function Get-LockTaskArgs {
    "--headless $env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -WindowStyle Hidden -EncodedCommand $(Get-EncodedCommand (Get-LockCheckScript))"
}
function Register-LockTask([string]$dom, [string]$name) {
    $act = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\conhost.exe" -Argument (Get-LockTaskArgs)
    $trg = New-ScheduledTaskTrigger -AtLogOn -User "$dom\$name"; $trg.Delay = 'PT20S'   # let services + tray apps start first
    $pr  = New-ScheduledTaskPrincipal -UserId "$dom\$name" -LogonType Interactive -RunLevel Limited
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $LockTask -Action $act -Trigger $trg -Principal $pr -Settings $set -Force | Out-Null
}

# S6/C-11: with Fast Startup a shut down + power on is a resume, LastBootUpTime stays days old and
# the lock never ran (HiberbootEnabled=1 on the Surface). Off while lock-after-sign-in is on; the
# old value is kept as HiberbootWas (-1 = was not set) and put back when that ends.
function Disable-FastStartup {
    $cur = (Get-ItemProperty $PowerKey -ErrorAction SilentlyContinue).HiberbootEnabled
    if ($cur -eq 0) { return }
    if ($null -eq (Get-DcValue 'HiberbootWas')) { Set-DcValue 'HiberbootWas' $(if ($null -eq $cur) { -1 } else { $cur }) 'DWord' }
    Set-ItemProperty $PowerKey -Name HiberbootEnabled -Value 0 -Type DWord
    Say 'Fast Startup turned off, so a shut down + power on also locks the screen (put back when the lock is turned off).'
}
function Restore-FastStartup {
    $was = Get-DcValue 'HiberbootWas'
    if ($null -eq $was) { return }
    if ($was -eq -1) { Remove-ItemProperty $PowerKey -Name HiberbootEnabled -ErrorAction SilentlyContinue }
    else { Set-ItemProperty $PowerKey -Name HiberbootEnabled -Value $was -Type DWord }
    Remove-DcValue 'HiberbootWas'
    Say 'Fast Startup setting put back.'
}

function Set-AutoLogon {
    Add-AutoLogonType
    if ($AutoLogon -eq 'Disable') {
        Set-ItemProperty $Winlogon -Name AutoAdminLogon -Value '0' -Type String
        Remove-ItemProperty $Winlogon -Name DefaultPassword -ErrorAction SilentlyContinue
        [DeskAutoLogon]::StoreSecret('DefaultPassword', $null)
        $was = Get-DcValue 'PasswordLessWas'
        if ($null -ne $was) {
            Set-ItemProperty $PwLess -Name DevicePasswordLessBuildVersion -Value $was -Type DWord
            Remove-DcValue 'PasswordLessWas'
        }
        Unregister-ScheduledTask -TaskName $LockTask -Confirm:$false -ErrorAction SilentlyContinue
        Remove-DcValue 'AutoLogonUser'
        Restore-FastStartup
        Say 'Automatic sign-in is OFF (password removed from the LSA store).' Green
        return
    }

    $user = if ($Secrets['al_user']) { "$($Secrets['al_user'])".Trim() } else { "$env:USERDOMAIN\$env:USERNAME" }
    # "Bob", ".\Bob" and "THISPC\Bob" all mean the local account on this PC
    if ($user -match '^\.\\') { $user = $user.Substring(2) }
    $dom, $name = if ($user -match '\\') { $user -split '\\', 2 } else { $env:COMPUTERNAME, $user }
    if ($dom -eq '.') { $dom = $env:COMPUTERNAME }
    $pw = $Secrets['al_pass']
    if (-not $pw) {
        if ($Unattended) { throw 'Automatic sign-in needs the Windows password -- nothing changed.' }
        $s = Read-Host "Windows password for $dom\$name" -AsSecureString
        $pw = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
    }

    # al_new=1: a local account just for automatic sign-in (the desktops); the Surface
    # uses an existing account. Created in Users (not Administrators); password never
    # expires so the PC does not stop at a "change your password" screen one day.
    if ($Secrets['al_new'] -eq '1') {
        if ($user -match '\\') { $name = ($user -split '\\', 2)[1] }
        $dom = $env:COMPUTERNAME
        Set-DedicatedAccount $name $pw
    }
    if (-not [DeskAutoLogon]::Check($name, $dom, $pw)) {
        $pw = $null; throw "Windows rejected that password for $dom\$name -- automatic sign-in NOT changed."
    }
    [DeskAutoLogon]::StoreSecret('DefaultPassword', $pw); $pw = $null
    Set-ItemProperty $Winlogon -Name AutoAdminLogon    -Value '1'   -Type String
    Set-ItemProperty $Winlogon -Name DefaultUserName   -Value $name -Type String
    Set-ItemProperty $Winlogon -Name DefaultDomainName -Value $dom  -Type String
    Remove-ItemProperty $Winlogon -Name DefaultPassword, AutoLogonCount -ErrorAction SilentlyContinue
    # R13: another account's console sign-in rewrites DefaultUserName; Desk Console compares
    # it with the account set here (C-4)
    Set-DcValue 'AutoLogonUser' "$dom\$name"

    # "Only allow Windows Hello sign-in" hides automatic sign-in: remember it, turn it off
    $cur = (Get-ItemProperty $PwLess -ErrorAction SilentlyContinue).DevicePasswordLessBuildVersion
    if ($cur) {
        if ($null -eq (Get-DcValue 'PasswordLessWas')) { Set-DcValue 'PasswordLessWas' $cur 'DWord' }
        Set-ItemProperty $PwLess -Name DevicePasswordLessBuildVersion -Value 0 -Type DWord
        Say 'Turned off "only allow Windows Hello sign-in" (restored when auto sign-in is turned off).'
    }

    if ($AutoLogonLock) {
        Register-LockTask $dom $name
        Disable-FastStartup
    } else {
        Unregister-ScheduledTask -TaskName $LockTask -Confirm:$false -ErrorAction SilentlyContinue
        Restore-FastStartup
    }
    Say "Automatic sign-in is ON for $dom\$name$(if ($AutoLogonLock) { ', then the screen locks' })." Green
    $exp = Get-PasswordExposure $dom $name
    if ($exp) { Say "$dom\$name is ${exp}: its password can be read back by any administrator on this PC -- do not use a password you use elsewhere." Yellow }
    # James keeps the sign-in notice on the desktops: information, not an error
    $pol = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue
    if ($pol.LegalNoticeCaption -or $pol.LegalNoticeText) { Say 'Sign-in notice (policy) is on: after a restart, click OK on it -- RustDesk works at that screen -- then the automatic sign-in goes ahead.' Yellow }
}

# C-11 repair on every Admin run, no password needed: a lock task made by an older setup gets
# the new check, Fast Startup goes off, and the sign-in account is recorded if it is missing.
function Repair-AutoLogon {
    if ("$((Get-ItemProperty $Winlogon -ErrorAction SilentlyContinue).AutoAdminLogon)" -ne '1') { return }
    $task = Get-ScheduledTask -TaskName $LockTask -ErrorAction SilentlyContinue
    if (-not $task) { return }
    # the trigger keeps DOM\name; the principal reports the bare name (seen on the trust task)
    $who = "$(@($task.Triggers)[0].UserId)"; if (-not $who) { $who = "$($task.Principal.UserId)" }
    if ($who -and $who -notmatch '\\') { $who = "$env:COMPUTERNAME\$who" }
    if (-not $who) { return }
    if (-not (Get-DcValue 'AutoLogonUser')) { Set-DcValue 'AutoLogonUser' $who; Say "Recorded the automatic sign-in account: $who." }
    if ("$(@($task.Actions)[0].Arguments)" -ne (Get-LockTaskArgs)) {
        $dom, $name = $who -split '\\', 2
        Register-LockTask $dom $name
        Say 'Lock after automatic sign-in updated: it now also locks after a sign-out.' Green
    }
    Disable-FastStartup
}

# ---------------------------------------------------------------- Windows Update restarts
# The value behind the Group Policy "Computer Configuration > Administrative Templates > Windows
# Components > Windows Update > No auto-restart with logged on users for scheduled automatic
# updates installations" (Pro/Enterprise/Education honour it; Home ignores it). Updates still
# download and install; the restart waits until you do it. With automatic sign-in someone is
# always signed in, so a PC you reach only remotely is never restarted from under you.
# R2/C-5: Microsoft says it applies only when Configure Automatic Updates is option 4
# (learn.microsoft.com/windows/deployment/update/waas-restart), so Enable also sets AUOptions=4,
# install every day at 03:00. The values that were there are kept as <name>Was under
# HKLM\SOFTWARE\DeskConsole (-1 = was not set) and put back by Disable. NoAutoUpdate is never
# touched. Written straight to the policy key, so gpedit.msc shows "Not configured".
$WuAuKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$AuSchedule = [ordered]@{ AUOptions = 4; ScheduledInstallDay = 0; ScheduledInstallTime = 3 }
function Get-UpdatePolicyState {   # C-5: the same test Desk Console and the agent make
    $p = Get-ItemProperty $WuAuKey -ErrorAction SilentlyContinue
    if ($p.NoAutoRebootWithLoggedOnUsers -eq 1 -and $p.AUOptions -eq 4) { 'complete' }
    elseif ($p.NoAutoRebootWithLoggedOnUsers -eq 1) { 'incomplete' }
    else { 'off' }
}
function Set-NoAutoRestart {
    if ($NoAutoRestart -eq 'Disable') {
        Remove-ItemProperty $WuAuKey -Name NoAutoRebootWithLoggedOnUsers -ErrorAction SilentlyContinue
        foreach ($n in $AuSchedule.Keys) {
            $was = Get-DcValue "${n}Was"
            if ($null -eq $was) { continue }   # not set by Desk Console: not ours to change
            if ($was -eq -1) { Remove-ItemProperty $WuAuKey -Name $n -ErrorAction SilentlyContinue }
            else { Set-ItemProperty $WuAuKey -Name $n -Value $was -Type DWord }
            Remove-DcValue "${n}Was"
        }
        Say "Windows Update may restart this PC again (Windows default). Policy read back: $(Get-UpdatePolicyState)." Green
        return
    }
    Confirm-RegKey $WuAuKey   # R1: New-Item -Force here deleted every other AU policy value on each run
    $cur = Get-ItemProperty $WuAuKey -ErrorAction SilentlyContinue
    foreach ($n in $AuSchedule.Keys) {
        if ($null -eq (Get-DcValue "${n}Was")) { Set-DcValue "${n}Was" $(if ($null -eq $cur.$n) { -1 } else { $cur.$n }) 'DWord' }
        New-ItemProperty $WuAuKey -Name $n -Value $AuSchedule[$n] -PropertyType DWord -Force | Out-Null
    }
    New-ItemProperty $WuAuKey -Name NoAutoRebootWithLoggedOnUsers -Value 1 -PropertyType DWord -Force | Out-Null
    $p = Get-ItemProperty $WuAuKey
    $ed = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).EditionID
    # read back (F1/R9: the old log could not prove the policy was ever applied)
    Say "Windows Update installs updates every day at 03:00 and will not restart this PC while someone is signed in ($ed). Read back: AUOptions=$($p.AUOptions), NoAutoRebootWithLoggedOnUsers=$($p.NoAutoRebootWithLoggedOnUsers) -> $(Get-UpdatePolicyState)." Green
    if ($ed -match 'Core|Home') { Say 'This is Windows Home, which ignores this policy.' Yellow }
    if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) { Say 'Domain-joined: a domain Group Policy can override this setting.' Yellow }
}

function Register-Machine {
    $ip = Get-PreferredIPv4
    $id = try { (& $RustDeskExe --get-id | Out-String).Trim() } catch { '' }
    Write-Host ''
    if (-not $ip) { Say 'No usable network address -- connect this PC to the LAN (Ethernet) and re-run. machines.csv not changed.' Yellow; return }
    [void](Update-MachineRow -IP $ip.IPAddress -MAC $ip.MAC -RustDeskId $id)
    Say "Registered in machines.csv:  $Me  $($ip.IPAddress)  $($ip.MAC)  RustDesk id $id" White
}

# F10: Desk Console's Wake button needs the network card to listen for magic packets. Enabled on
# the wired card this PC uses for the LAN (Wi-Fi cards rarely wake). Changing a card's power
# settings can reset the card for a moment, so it is left alone while someone is connected
# through RustDesk. A PC that is switched OFF also needs Wake on LAN in its BIOS/UEFI.
function Enable-WakeOnLan {
    $ip = Get-PreferredIPv4
    if (-not $ip) { return }
    $ad = Get-NetAdapter -InterfaceIndex $ip.InterfaceIndex -ErrorAction SilentlyContinue
    if (-not $ad) { return }
    if ($ad.PhysicalMediaType -match '802\.11|Wireless') { Say 'Wake-on-LAN: this PC reaches the LAN over Wi-Fi, which usually cannot wake it -- skipped.'; return }
    $pm = Get-NetAdapterPowerManagement -Name $ad.Name -ErrorAction SilentlyContinue
    if (-not $pm) { Say "Wake-on-LAN: $($ad.Name) does not report power management -- skipped."; return }
    # "Allow this device to wake the computer" is a power setting: it never touches the link
    $armed = $false
    try { $armed = @(& powercfg.exe /devicequery wake_armed | ForEach-Object { "$_".Trim() }) -contains $ad.InterfaceDescription } catch {}
    if (-not $armed) { [void](Invoke-Native 'powercfg.exe' "/deviceenablewake $(Quote-NativeArg $ad.InterfaceDescription)") }
    if ("$($pm.WakeOnMagicPacket)" -eq 'Enabled') { Say "Wake-on-LAN on for $($ad.Name)$(if (-not $armed) { ' (now allowed to wake the PC)' })."; return }
    if ((Get-RustDeskSessions).Any) {
        # Changing Wake on Magic Packet resets the network card on many drivers, which would drop
        # the session -- and the desktops are set up through one. The next start does it instead.
        Register-WakeOnLanAtBoot $ad
        Say "Wake-on-LAN for $($ad.Name) is turned on at the next restart (task '$WolTask'): changing it now can reset the network card under your RustDesk session."
        return
    }
    Set-NetAdapterPowerManagement -Name $ad.Name -WakeOnMagicPacket Enabled -ErrorAction Stop
    Unregister-ScheduledTask -TaskName $WolTask -Confirm:$false -ErrorAction SilentlyContinue   # one an earlier run left
    Say "Wake-on-LAN on for $($ad.Name) (a PC that is switched off also needs Wake on LAN in its BIOS/UEFI)." Green
}

# One-shot, as SYSTEM, at the next start (before anyone can connect); it deletes itself.
$WolTask = 'DeskConsole Wake-on-LAN'
function Register-WakeOnLanAtBoot($ad) {
    $n = "$($ad.Name)" -replace "'", "''"
    $d = "$($ad.InterfaceDescription)" -replace "'", "''"
    $cmd = "try { Set-NetAdapterPowerManagement -Name '$n' -WakeOnMagicPacket Enabled -ErrorAction Stop; " +
           "& powercfg.exe /deviceenablewake '$d' } catch {}; " +
           "Unregister-ScheduledTask -TaskName '$WolTask' -Confirm:`$false"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    $act = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
             -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $enc"
    $trg = New-ScheduledTaskTrigger -AtStartup
    $pr  = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $WolTask -Action $act -Trigger $trg -Principal $pr -Settings $set -Force | Out-Null
}

function Invoke-AdminPhase {
    try { $k = Get-Kvm; Say "Keyboard + mouse provider (kvm.json): $($k.provider)" White }
    catch { $k = $null; Say "kvm.json NOT read: $($_.Exception.Message) -- keyboard/mouse left as it is; the rest goes ahead." Red }
    Invoke-Step 'Home network NOT found' { $script:LanCidrs = @(Get-LanCidrs) }
    if ($script:LanCidrs.Count) {
        Say "Home network: $($script:LanCidrs -join ', ') ($(if (Get-SiteSetting 'lanCidr') { 'site.json lanCidr' } else { 'this PC''s network' }))."
        # SAFETY, the same rule as the RustDesk whitelist: never narrow the firewall under a RustDesk
        # session that comes from outside the home network or whose origin is unknown -- the
        # vendor rules allowed it in, and narrowing them would cut it off (James runs the
        # desktops through RustDesk). Those runs keep 1.6.0's "local subnet" and leave the
        # vendor rules alone.
        $sess = Get-RustDeskSessions
        $outside = @($sess.Direct | Where-Object { -not (Test-IPv4InCidrs $_ $script:LanCidrs) })
        if ($sess.Relayed -or $sess.Unknown -or $outside.Count) {
            $script:FwSafe = $false
            Say 'Firewall NOT narrowed to the home network this time: you are connected through RustDesk from outside it (or its origin cannot be seen), and narrowing could cut that session off. Re-run setup at the PC or from inside the home network.' Yellow
        } else { $script:FwScope = $script:LanCidrs }
    } else { Say 'Home network not found (no lanCidr in site.json, no LAN address): the firewall rules use "local subnet".' Yellow }
    Invoke-Step 'Keyboard/mouse firewall rule FAILED' { Set-KvmPortRule }
    if ($k) { Invoke-Step 'Keyboard + mouse setup FAILED' {   # a keyboard/mouse failure must not cost this PC its RustDesk, sign-in and registration
        switch ($k.provider) {
            'Synergy'  { Disable-Kvm 'Deskflow'; Install-Synergy; Add-SynergyHotkeys }
            'Deskflow' { Disable-Kvm 'Synergy';  Install-Deskflow; Set-DeskflowSystem }
            default    { Disable-Kvm 'Synergy';  Disable-Kvm 'Deskflow'; Say 'Keyboard + mouse sharing is off on this PC.' }
        }
    } }
    Invoke-Step 'RustDesk install FAILED' { Install-RustDesk }
    Invoke-Step 'RustDesk direct IP / home network setting FAILED' { Set-RustDeskOptions }
    Invoke-Step 'RustDesk firewall rules FAILED' { Set-RustDeskFirewall }
    Invoke-Step 'RustDesk password NOT set' { Set-RustDeskPassword }
    Invoke-Step 'Vendor firewall rules NOT limited' { Set-VendorFirewallScope }   # after the installs: an MSI recreates them
    if ($AutoLogon) { Invoke-Step 'Automatic sign-in NOT changed' { Set-AutoLogon } }
    else { Invoke-Step 'Automatic sign-in check FAILED' { Repair-AutoLogon } }
    if ($NoAutoRestart) { Invoke-Step 'Windows Update restart setting NOT changed' { Set-NoAutoRestart } }
    Invoke-Step 'Wake-on-LAN setting FAILED' { Enable-WakeOnLan }
    Invoke-Step 'Registration in machines.csv FAILED' { Register-Machine }   # last, and even after failures above
    Write-Host '   Control everything from Desk Console (Start Menu).'
}

# ---------------------------------------------------------------- Remove Synergy (elevated)
# F15/C-14: once no PC uses Synergy (subscription cancelled): uninstall it, delete its firewall
# rules -- the vendor's and Desk Console's per-program ones -- and its parked sign-in entries.
# The shared keyboard/mouse port rule stays: it is re-made first under its own name.
function Invoke-RemoveSynergyPhase {
    if (-not (Test-Path $KvmJson)) { throw "kvm.json is not reachable ($KvmJson), so setup cannot tell whether a PC still uses Synergy. Nothing changed." }
    if ("$((Get-Kvm).provider)" -eq 'Synergy') { throw 'kvm.json says the PCs use Synergy -- switch them to Deskflow first (DeskConsoleSetup, or Setup-Synergy.cmd -Kvm Deskflow). Nothing changed.' }
    # kvm.json may already say Deskflow while THIS PC has not run setup since: Synergy is then
    # still its live keyboard/mouse, and removing it would leave none until setup runs
    $live = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'Synergy' -and ($_.Status -eq 'Running' -or "$($_.StartType)" -ne 'Disabled') })
    if ($live.Count) { throw "Synergy is still switched on here ($($live[0].DisplayName): $($live[0].Status), $($live[0].StartType)) -- run setup on this PC first so it switches to Deskflow. Nothing changed." }
    $script:LanCidrs = @(Get-LanCidrs)
    $sess = Get-RustDeskSessions
    $outside = @($sess.Direct | Where-Object { -not (Test-IPv4InCidrs $_ $script:LanCidrs) })
    if ($script:LanCidrs.Count -and -not ($sess.Relayed -or $sess.Unknown -or $outside.Count)) { $script:FwScope = $script:LanCidrs }
    Set-KvmPortRule
    $apps = @(foreach ($u in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') {
        Get-ChildItem $u -ErrorAction SilentlyContinue | ForEach-Object { Get-ItemProperty $_.PSPath } |
            Where-Object { "$($_.DisplayName)" -match '^Synergy' -and $_.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$' }
    })
    if (-not $apps.Count) { Say 'Synergy is not installed (no Windows Installer entry).' }
    foreach ($a in $apps) {
        Say "Uninstalling $($a.DisplayName) $($a.DisplayVersion)..."
        $logName = "Synergy-uninstall-$($a.PSChildName.Trim('{}'))"   # one log per product
        $rc = Invoke-Msi "/x $($a.PSChildName) /qn /norestart" $logName
        if ($rc -in 0, 3010, 1605) { Say "$($a.DisplayName) removed$(if ($rc -eq 3010) { ' (restart to finish)' })." Green }
        else { Say "$($a.DisplayName) uninstall FAILED (msiexec exit $rc; log: $env:TEMP\$logName.log)." Red }
    }
    $rules = @(Get-NetFirewallRule -DisplayName 'Synergy*' -ErrorAction SilentlyContinue)
    $rules | Remove-NetFirewallRule
    Say "Removed $($rules.Count) Synergy firewall rule(s); the keyboard/mouse port rule stays ($KvmPortRule)."
    if (Test-Path $ParkedRun) {
        $parked = @((Get-ItemProperty $ParkedRun).PSObject.Properties | Where-Object { $_.Name -like '*|*' -and "$($_.Value)" -match '\\Synergy\\' })
        foreach ($e in $parked) { Remove-ItemProperty $ParkedRun -Name $e.Name }
        if ($parked.Count) { Say "Removed $($parked.Count) parked Synergy sign-in entry(ies)." }
    }
    Say 'Synergy is removed from this PC. Its installers in the shared folder are left for the other PCs.' Green
}

# ---------------------------------------------------------------- phase 3 (as you)
# QSettings INI writer: replaces or adds section/key values, keeps everything else. UTF-8 both
# ways: Qt 6 writes UTF-8 without a BOM, which Windows PowerShell read as ANSI and wrote back
# double-encoded on every run (R8).
function Set-Ini($path, [Collections.Specialized.OrderedDictionary]$vals) {
    $lines = New-Object Collections.Generic.List[string]
    if (Test-Path $path) { $old = @(Get-Content $path -Encoding UTF8); if ($old.Count) { $lines.AddRange([string[]]$old) } }
    foreach ($kv in $vals.GetEnumerator()) {
        $sec, $key = $kv.Key -split '/', 2
        $line = "$key=$($kv.Value)"
        $si = -1; for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -eq "[$sec]") { $si = $i; break } }
        if ($si -lt 0) {
            if ($lines.Count -and $lines[$lines.Count - 1] -ne '') { $lines.Add('') }
            $lines.Add("[$sec]"); $lines.Add($line); continue
        }
        $end = $lines.Count; for ($i = $si + 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*\[') { $end = $i; break } }
        $done = $false
        for ($i = $si + 1; $i -lt $end; $i++) { if ($lines[$i] -match "^\s*$([regex]::Escape($key))\s*=") { $lines[$i] = $line; $done = $true; break } }
        if (-not $done) { $ins = $end; while ($ins -gt $si + 1 -and $lines[$ins - 1].Trim() -eq '') { $ins-- }; $lines.Insert($ins, $line) }
    }
    [IO.File]::WriteAllLines($path, $lines)   # UTF-8 without BOM -- a BOM would corrupt the first [section]
}
function Get-Ini($path) {   # "section/key" -> value
    $h = @{}; $sec = ''
    if (-not (Test-Path $path)) { return $h }
    foreach ($l in Get-Content $path -Encoding UTF8) {
        if ($l -match '^\s*\[(.+)\]\s*$') { $sec = $Matches[1]; continue }
        if ($l -match '^\s*([^=;#\s][^=]*?)\s*=(.*)$') { $h["$sec/$($Matches[1])"] = $Matches[2].Trim() }
    }
    $h
}

# Deskflow reads %APPDATA%\Deskflow\Deskflow.conf if it exists, else the machine-wide
# C:\ProgramData\Deskflow\Deskflow.conf (Settings.cpp, v1.27.0), and its core reads the same
# file (the GUI hands its path to the daemon, CoreProcess.cpp). The admin step writes the
# machine-wide one + the server layout and starts Deskflow for EVERY user (HKLM Run), so an
# automatic-sign-in account such as BuildRunner gets it too; the finish step writes the same
# values into the signed-in user's file so an older per-user copy cannot disagree.
$DeskflowSysDir = 'C:\ProgramData\Deskflow'
$UserServerConf = Join-Path $DeskflowDir 'deskflow-server.conf'   # the server's signed-in user; writable by the 2-minute task

# kvm.json "options" (allow-list) -> Deskflow.conf [server]. Checked in Deskflow v1.27.0 (gh api):
# src/lib/server/Config.cpp readSectionOptions takes heartbeat, switch delay, double-tap and
# clipboard from Settings, not from the layout file -- its "section: options" keeps only
# keystroke/mousepress lines and skips the rest. src/lib/common/Settings.h/.cpp: server/heartbeat,
# server/switchDelay, server/switchDoubleTap are milliseconds and count only with their
# server/enable* flag; server/enableClipboard; server/clipboardSize is MiB (default 3; Config.cpp
# multiplies by 1024 for the KB value Server.cpp compares). kvm.json keeps Synergy's KB unit for
# clipboardSharingSize (3072 = Deskflow's default 3 MiB), rounded up to whole MiB.
$DeskflowTimers = [ordered]@{   # kvm.json name -> enable key, value key
    switchDelay     = 'server/enableSwitchDelay',     'server/switchDelay'
    switchDoubleTap = 'server/enableSwitchDoubleTap', 'server/switchDoubleTap'
    heartbeat       = 'server/enableHeartbeat',       'server/heartbeat'
}
function ConvertTo-NonNegativeInt($v) {
    if ($null -eq $v -or $v -is [bool]) { return $null }
    $n = 0L
    if ([long]::TryParse("$v", [ref]$n) -and $n -ge 0 -and $n -le [int]::MaxValue) { return [int]$n }
    $null
}
function Get-DeskflowServerOptions($opts) {
    $ini = [ordered]@{}
    if (-not $opts) { return $ini }
    foreach ($p in $opts.PSObject.Properties) {
        $v = $p.Value
        if ($p.Name -eq 'clipboardSharing') {
            if ($v -is [bool]) { $ini['server/enableClipboard'] = "$v".ToLower() }
            else { Say 'kvm.json options.clipboardSharing must be true or false -- ignored.' Yellow }
        } elseif ($p.Name -eq 'clipboardSharingSize') {
            $kb = ConvertTo-NonNegativeInt $v
            if ($null -eq $kb) { Say 'kvm.json options.clipboardSharingSize must be a size in KB (3072 = 3 MB) -- ignored.' Yellow }
            else { $ini['server/clipboardSize'] = [string][int][math]::Ceiling($kb / 1024) }   # 0 turns clipboard sharing off
        } elseif ($DeskflowTimers.Contains($p.Name)) {
            $ms = ConvertTo-NonNegativeInt $v
            $keys = $DeskflowTimers[$p.Name]
            if ($null -eq $ms) { Say "kvm.json options.$($p.Name) must be milliseconds (0 = off) -- ignored." Yellow; continue }
            $ini[$keys[0]] = $(if ($ms -gt 0) { 'true' } else { 'false' })
            if ($ms -gt 0) { $ini[$keys[1]] = "$ms" }
        } else {
            Say "kvm.json options.$($p.Name) is not one Desk Console sets (clipboardSharing, clipboardSharingSize, switchDelay, switchDoubleTap, heartbeat) -- ignored." Yellow
        }
    }
    $ini
}

function Get-DeskflowValues([switch]$NoAppend) {
    # -NoAppend: the 2-minute task and the agent read kvm.json and never write it (C-6), and
    # without one they must not act on Get-Kvm's "this PC is the server" fallback (R6)
    if ($NoAppend -and -not (Test-Path $KvmJson)) { throw "kvm.json not found ($KvmJson)." }
    $k = Get-Kvm
    $row = @($k.row | Where-Object { $_ } | ForEach-Object { "$_" })
    if (-not $NoAppend -and $row -notcontains $Me) {
        $row += $Me; Set-KvmField $k 'row' $row; Save-Kvm $k; Say "Added $Me to the right end of kvm.json row." Green
    }
    $grid = Get-KvmGrid $k
    $screens = @(Get-KvmScreens $grid)
    if (-not $NoAppend -and $k.PSObject.Properties['grid'] -and $k.grid -and $screens -notcontains $Me) {
        Say "kvm.json has a ""grid"" without $Me -- add $Me to it to place this PC in the layout." Yellow
    }
    # every name the layout or the row knows; Deskflow refuses links and hotkeys to any other name
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $computers = @(@($screens) + @($row) | Where-Object { $_ -and $seen.Add($_) })
    $isServer = "$($k.server)" -eq $Me
    $csv = Join-Path $Root 'machines.csv'
    $serverIp = if ("$($k.server)" -and (Test-Path $csv)) { (Import-Csv $csv | Where-Object { $_.Name -eq $k.server } | Select-Object -First 1).IP }
    if (-not $isServer -and -not "$($k.server)") { Say 'No keyboard/mouse server is set in kvm.json yet -- run setup on the PC the keyboard and mouse are plugged into, and choose Server.' Yellow }
    elseif (-not $isServer -and -not $serverIp) { Say "Server $($k.server) is not in machines.csv yet -- run setup there first, then here." Yellow }
    $serverConf = Join-Path $DeskflowSysDir 'deskflow-server.conf'
    $ini = [ordered]@{
        'core/coreMode'             = $(if ($isServer) { 2 } else { 1 })   # 1 client, 2 server (Settings.h CoreMode)
        'core/computerName'         = $Me
        'client/remoteHost'         = "$serverIp"
        'server/externalConfig'     = 'true'
        'server/externalConfigFile' = '"' + $serverConf.Replace('\', '\\') + '"'
        'gui/startCoreWithGui'      = 'true'
    }
    # Deskflow 1.27 takes the computer list from here ([computer_<name>] name=<name>,
    # Settings::knownComputers), NOT from the layout file's "section: screens", which it
    # ignores -- the links then fail with 'unknown computer name'.
    foreach ($c in $computers) { $ini["computer_$c/name"] = $c }
    if ($isServer) { foreach ($kv in (Get-DeskflowServerOptions $k.options).GetEnumerator()) { $ini[$kv.Key] = $kv.Value } }
    $hot = -not ($k.PSObject.Properties['hotkeys'] -and "$($k.hotkeys)" -eq 'False')   # default on
    [pscustomobject]@{ Kvm = $k; Row = $row; Grid = $grid; Screens = $screens; Computers = $computers; Hotkeys = $hot
        IsServer = $isServer; ServerIp = $serverIp; ServerConf = $serverConf; Ini = $ini }
}

# Links between two rows that may hold different numbers of screens. Each row spans the full
# width, split evenly; a screen links to every screen of the next row it overlaps, the overlap
# as a percent range of each edge ("down(0,50) = C(50,100)"). Integer percents rounded from the
# same shared boundaries, so neighbouring ranges touch but never overlap -- Deskflow rejects an
# overlapping range (Config::connect) and an empty one (parseInterval) and then loads nothing.
function Format-LinkRange($o0, $o1, $e0, $e1) {   # [o0,o1] as percent of edge [e0,e1]; '' = the whole edge
    $s = [math]::Round(100.0 * ($o0 - $e0) / ($e1 - $e0)); $e = [math]::Round(100.0 * ($o1 - $e0) / ($e1 - $e0))
    if ($s -ge $e) { return $null }
    if ($s -eq 0 -and $e -eq 100) { return '' }
    "($s,$e)"
}
function Get-VerticalLinks($row, [int]$c, $other, [string]$dir) {
    $a0 = [math]::Round(100.0 * $c / $row.Count); $a1 = [math]::Round(100.0 * ($c + 1) / $row.Count)
    for ($j = 0; $j -lt $other.Count; $j++) {
        $b0 = [math]::Round(100.0 * $j / $other.Count); $b1 = [math]::Round(100.0 * ($j + 1) / $other.Count)
        $o0 = [math]::Max($a0, $b0); $o1 = [math]::Min($a1, $b1)
        if ($o0 -ge $o1) { continue }
        $src = Format-LinkRange $o0 $o1 $a0 $a1; $dst = Format-LinkRange $o0 $o1 $b0 $b1
        if ($null -eq $src -or $null -eq $dst) { continue }
        "$dir$src = $($other[$j])$dst"
    }
}

# Deskflow 1.27 layout file (src/lib/server/Config.cpp v1.27.0): "section: links" takes
# left/right/up/down; "section: options" keeps only keystroke(...) lines. switchToScreen(<name>)
# throws "unknown computer name" for a name missing from Deskflow.conf [computer_<name>], so the
# Ctrl+Alt+Shift+<n> hotkeys (C-6/F8, 1..9 in card order) use only the layout's own names.
function Get-DeskflowServerConfText($grid, [bool]$Hotkeys = $true) {
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('# Generated by Setup-Synergy.ps1 from kvm.json "row" or "grid" -- the server''s 2-minute task rebuilds it when the layout changes.')
    [void]$sb.AppendLine('# Deskflow 1.27: the computers and options are in Deskflow.conf; links + hotkeys only here.')
    [void]$sb.AppendLine('section: links')
    for ($r = 0; $r -lt $grid.Count; $r++) {
        $row = $grid[$r]
        for ($c = 0; $c -lt $row.Count; $c++) {
            [void]$sb.AppendLine("`t$($row[$c]):")
            if ($c -gt 0)               { [void]$sb.AppendLine("`t`tleft = $($row[$c - 1])") }
            if ($c -lt $row.Count - 1)  { [void]$sb.AppendLine("`t`tright = $($row[$c + 1])") }
            if ($r -gt 0)               { foreach ($l in Get-VerticalLinks $row $c $grid[$r - 1] 'up')   { [void]$sb.AppendLine("`t`t$l") } }
            if ($r -lt $grid.Count - 1) { foreach ($l in Get-VerticalLinks $row $c $grid[$r + 1] 'down') { [void]$sb.AppendLine("`t`t$l") } }
        }
    }
    [void]$sb.AppendLine('end')
    [void]$sb.AppendLine('section: options')
    [void]$sb.AppendLine("`tkeystroke(Control+Alt+Left) = switchInDirection(left)")
    [void]$sb.AppendLine("`tkeystroke(Control+Alt+Right) = switchInDirection(right)")
    if ($grid.Count -gt 1) {
        [void]$sb.AppendLine("`tkeystroke(Control+Alt+Up) = switchInDirection(up)")
        [void]$sb.AppendLine("`tkeystroke(Control+Alt+Down) = switchInDirection(down)")
    }
    if ($Hotkeys) {
        $n = 0
        foreach ($s in @(Get-KvmScreens $grid)) {
            if (++$n -gt 9) { break }
            [void]$sb.AppendLine("`tkeystroke(Control+Alt+Shift+$n) = switchToScreen($s)")
        }
    }
    [void]$sb.AppendLine('end')
    $sb.ToString()
}

# Server only, from the 2-minute task: a PC that joined later is in kvm.json but not in the
# server's Deskflow config, so the server would refuse it as an unknown computer; a layout or
# option edit in kvm.json must reach Deskflow too. Rebuild what differs. Deskflow's core restarts
# itself when its settings file changes ("settings file changed" in the daemon log), so the
# signed-in user's Deskflow.conf gets a stamp whenever the layout file changes.
function Update-DeskflowServerLayout {
    if ("$((Get-Kvm).provider)" -ne 'Deskflow') { return }   # F12: never restart a Deskflow that was switched off
    $v = Get-DeskflowValues -NoAppend                         # C-6: the task never writes kvm.json
    if (-not $v.IsServer) { return }
    $text = Get-DeskflowServerConfText $v.Grid $v.Hotkeys
    $userConf = Join-Path $DeskflowDir 'Deskflow.conf'
    $changed = $false
    # the signed-in user's own layout file (always writable), and that user's Deskflow pointed at it
    New-Item -ItemType Directory -Force $DeskflowDir | Out-Null
    if ("$(Get-Content $UserServerConf -Raw -ErrorAction SilentlyContinue)" -ne $text) {
        [IO.File]::WriteAllText($UserServerConf, $text); $changed = $true
    }
    $ext = '"' + $UserServerConf.Replace('\', '\\') + '"'
    if ((Test-Path $userConf) -and -not (Select-String -Path $userConf -SimpleMatch "externalConfigFile=$ext" -Quiet) -and
        -not (Select-String -Path $userConf -SimpleMatch "externalConfigFile=$($UserServerConf.Replace('\', '\\'))" -Quiet)) {
        Set-Ini $userConf ([ordered]@{ 'server/externalConfig' = 'true'; 'server/externalConfigFile' = $ext }); $changed = $true
    }
    # machine-wide copy for other accounts: only if this user may write it (admin-created = read-only)
    if ("$(Get-Content $v.ServerConf -Raw -ErrorAction SilentlyContinue)" -ne $text) {
        try { [IO.File]::WriteAllText($v.ServerConf, $text) } catch {}
    }
    # the computer list and the kvm.json options, wherever they differ
    $want = [ordered]@{}
    foreach ($kv in $v.Ini.GetEnumerator()) {
        if ($kv.Key -like 'computer_*' -or ($kv.Key -like 'server/*' -and $kv.Key -notlike 'server/externalConfig*')) { $want[$kv.Key] = $kv.Value }
    }
    foreach ($conf in $userConf, (Join-Path $DeskflowSysDir 'Deskflow.conf')) {
        if (-not (Test-Path $conf)) { continue }
        $have = Get-Ini $conf
        $diff = [ordered]@{}
        foreach ($kv in $want.GetEnumerator()) { if ("$($have[$kv.Key])" -ne "$($kv.Value)") { $diff[$kv.Key] = $kv.Value } }
        if ($diff.Count) { try { Set-Ini $conf $diff; if ($conf -eq $userConf) { $changed = $true } } catch {} }
    }
    # The core reads its settings only when it starts; restarting the Deskflow window (as this
    # user, no admin) makes the daemon start a fresh core. Only when something changed.
    if ($changed) {
        $exe = Find-Exe 'C:\Program Files\Deskflow' 'deskflow.exe'
        Get-Process -Name deskflow -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep 2
        if ($exe) { Start-Process $exe }
    }
}

function Set-DeskflowSystem {   # admin step
    $exe = Find-Exe 'C:\Program Files\Deskflow' 'deskflow.exe'
    if (-not $exe) { Say 'deskflow.exe not found after install.' Yellow; return }
    $v = Get-DeskflowValues
    New-Item -ItemType Directory -Force $DeskflowSysDir | Out-Null
    # only the GUI (deskflow.exe) -- it rewrites its conf on exit. Never deskflow-daemon (the
    # service) or deskflow-core: killing the daemon left keyboard sharing down until a restart.
    Get-Process -Name deskflow -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Set-Ini (Join-Path $DeskflowSysDir 'Deskflow.conf') $v.Ini

    if ($v.IsServer) {
        [IO.File]::WriteAllText($v.ServerConf, (Get-DeskflowServerConfText $v.Grid $v.Hotkeys))
        Say "Deskflow SERVER. Layout (rows top to bottom, each left -> right): $(Format-KvmLayout $v.Grid)" Green
    } elseif ("$($v.Kvm.server)") {
        Say "Deskflow client of $($v.Kvm.server) ($($v.ServerIp))." Green
    }
    # every user, including an automatic-sign-in account (parked/restored by Disable-/Enable-Kvm)
    New-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Deskflow' -Value "`"$exe`"" -Force | Out-Null
    Say 'Deskflow starts at sign-in for every user. First connection: accept the server''s fingerprint on each client.' White
}

# Deskflow TLS trust without dialogs. Each PC's certificate is
# C:\ProgramData\Deskflow\tls\deskflow.pem (Settings::tlsDir on Windows); its fingerprint is
# "v2:sha256:<hex of SHA-256 over the DER cert>" (Fingerprint::toDbLine). Every PC publishes its
# own to fingerprints\<PC>.txt on the share; the server keeps trusted-clients = every other
# PC's, a client keeps trusted-servers = the server's. Deskflow re-reads those files on every
# connection (SecureSocket::verifyCertFingerprint), so a new client is accepted without a
# restart. (The server's own trust dialog can fail to appear until Deskflow is restarted.)
$DeskflowTls = 'C:\ProgramData\Deskflow\tls'
$TrustTask   = 'DeskConsole Deskflow trust sync'   # the name installed copies and the uninstaller know
function Get-DeskflowFingerprint([int]$WaitSec = 0) {
    $pem = Join-Path $DeskflowTls 'deskflow.pem'
    for ($i = 0; $i -lt $WaitSec -and -not (Test-Path $pem); $i++) { Start-Sleep 1 }   # Deskflow makes it on first start
    if (-not (Test-Path $pem)) { return $null }
    $m = [regex]::Match((Get-Content $pem -Raw), '-----BEGIN CERTIFICATE-----(.+?)-----END CERTIFICATE-----', 'Singleline')
    if (-not $m.Success) { return $null }
    $der = [Convert]::FromBase64String(($m.Groups[1].Value -replace '\s', ''))
    'v2:sha256:' + ((([Security.Cryptography.SHA256]::Create().ComputeHash($der)) | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Sync-DeskflowTrust([switch]$Quiet) {
    $k = Get-Kvm
    if ($k.provider -ne 'Deskflow') { return }
    $fpDir = Join-Path $Root 'fingerprints'
    New-Item -ItemType Directory -Force $fpDir | Out-Null
    $mine = Get-DeskflowFingerprint $(if ($Quiet) { 0 } else { 30 })
    if ($mine) {
        $f = Join-Path $fpDir "$Me.txt"
        if ("$(Get-Content $f -TotalCount 1 -ErrorAction SilentlyContinue)".Trim() -ne $mine) { Set-Content $f $mine -Encoding ascii }
    } elseif (-not $Quiet) { Say 'Deskflow has no certificate yet -- open Deskflow once, then re-run setup.' Yellow }

    $others = @(Get-ChildItem $fpDir -Filter '*.txt' -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -ne $Me })
    if ($k.server -eq $Me) { $db = 'trusted-clients' } else { $db = 'trusted-servers'; $others = @($others | Where-Object { $_.BaseName -eq $k.server }) }
    $want = @($others | ForEach-Object { "$(Get-Content $_.FullName -TotalCount 1)".Trim() } | Where-Object { $_ -match '^v2:sha256:[0-9a-f]{64}$' })
    $path = Join-Path $DeskflowTls $db
    $have = @(Get-Content $path -ErrorAction SilentlyContinue | Where-Object { $_ })
    $add  = @($want | Where-Object { $have -notcontains $_ })
    if ($add.Count) {
        New-Item -ItemType Directory -Force $DeskflowTls | Out-Null
        [IO.File]::WriteAllLines($path, [string[]]($have + $add))
        if (-not $Quiet) { Say "Deskflow now trusts $($add.Count) more PC(s) ($db)." Green }
    }
}

# As the signed-in user, no admin: at sign-in and every 2 minutes. Deskflow trust (a client
# installed later is trusted by the server within 2 minutes), the server layout, and Agent.ps1.
# C-10: registered for EVERY provider -- the agent's status file and address self-healing
# matter on Synergy and None PCs too (it used to exist on Deskflow PCs only).
function Register-TrustSyncTask {
    $script = Join-Path $env:LOCALAPPDATA 'Programs\DeskConsole\Setup-Synergy.ps1'
    if (-not (Test-Path $script)) { $script = Join-Path $Root 'Setup-Synergy.ps1' }
    $act = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\conhost.exe" `
        -Argument "--headless $env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Phase TrustSync"
    $t1 = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $t2 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 2)
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $TrustTask -Action $act -Trigger $t1, $t2 -Settings $set -Force | Out-Null
}

function Set-DeskflowUser {     # finish step, as the signed-in user
    if ((Get-Kvm).provider -ne 'Deskflow') { return }
    $exe = Find-Exe 'C:\Program Files\Deskflow' 'deskflow.exe'
    if (-not $exe) { Say 'Deskflow is not installed yet -- the admin step did not finish.' Yellow; return }
    $v = Get-DeskflowValues
    Get-Process -Name deskflow -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue   # GUI only
    New-Item -ItemType Directory -Force $DeskflowDir | Out-Null
    # This user's Deskflow reads a layout file in its OWN profile: the machine-wide one in
    # ProgramData is read-only to users, so the 2-minute task could not add a PC that joined later.
    $ini = [ordered]@{}; foreach ($kv in $v.Ini.GetEnumerator()) { $ini[$kv.Key] = $kv.Value }
    $ini['server/externalConfigFile'] = '"' + $UserServerConf.Replace('\', '\\') + '"'
    if ($v.IsServer) { [IO.File]::WriteAllText($UserServerConf, (Get-DeskflowServerConfText $v.Grid $v.Hotkeys)) }
    Set-Ini (Join-Path $DeskflowDir 'Deskflow.conf') $ini
    Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Deskflow' -ErrorAction SilentlyContinue  # HKLM has it now
    Start-Process $exe
    Sync-DeskflowTrust
}

# Start-DevBox's "Note: ... not found" lines go through Say, so they reach the result file too
function Set-DevBoxFromArgs {
    $out = & (Join-Path $PSScriptRoot 'Start-DevBox.ps1') -Configure -Folder $DevBoxFolder -Claude:$DevBoxClaude -NoCode:$DevBoxNoCode 6>&1
    foreach ($o in @($out)) { $t = "$o"; if ($t -match '^Note:') { Say $t Yellow } elseif ($t) { Say $t } }
}

function Invoke-FinishPhase {
    Invoke-Step 'Deskflow settings FAILED' { Set-DeskflowUser }
    Invoke-Step 'Background task NOT created' {
        Register-TrustSyncTask
        Say 'Desk Console background task runs every 2 minutes (Deskflow trust, this PC''s status and address).'
    }
    # per-user sign-in task, so this runs as the signed-in user (not elevated); E5: 'All' too
    if ($DevBoxFolder) { Invoke-Step 'Dev box resume NOT set' { Set-DevBoxFromArgs } }
}

# ---------------------------------------------------------------- main
# The 2-minute task first: quiet, no transcript, never prompts, always exit 0 -- and before the
# QuickEdit Add-Type below, which compiled C# with csc.exe on every run (R9).
if ($Phase -eq 'TrustSync') {
    try {
        # R6: no kvm.json, nothing to sync (and no share, no 40 s wait for it)
        if ((Test-ShareUp) -and (Test-Path $KvmJson) -and "$((Get-Kvm).provider)" -eq 'Deskflow') {
            try { Sync-DeskflowTrust -Quiet } catch {}
            try { Update-DeskflowServerLayout } catch {}   # server only: a PC that joined later, a layout edit
        }
    } catch {}
    # C-10: status file, address self-healing, client reconcile, command queue
    try { $ag = Join-Path $PSScriptRoot 'Agent.ps1'; if (Test-Path $ag) { . $ag; Invoke-DeskAgent } } catch {}
    exit 0
}

# A click in a console window starts QuickEdit selection ("Select ..." in the title), which
# freezes every write -- the script hangs until Esc (it happened in the installer's admin
# window). Turn QuickEdit off for this window.
try {
    Add-Type -Name DeskConsoleMode -Namespace Win32 -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int h);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);
'@
    $hIn = [Win32.DeskConsoleMode]::GetStdHandle(-10); $mode = 0
    if ([Win32.DeskConsoleMode]::GetConsoleMode($hIn, [ref]$mode)) {
        [void][Win32.DeskConsoleMode]::SetConsoleMode($hIn, ($mode -band (-bnot 0x40)) -bor 0x80)   # -QUICK_EDIT, +EXTENDED_FLAGS
    }
} catch {}

# every run leaves logs\<PC>-<phase>.log on the share, with the failing line. A launcher that
# only asks for admin logs to <PC>-<phase>-launcher.log: the elevated copy could not open the
# file its own launcher held, so the run that changed the policy left no log (R9). Share not
# reachable: %TEMP%\DeskConsole-<PC>-<phase>.log, named in the result file (R4).
$LogDir = Join-Path $Root 'logs'
$logName = if (($Phase -in 'Updates', 'RemoveSynergy') -and -not (Test-Admin)) { "$Me-$Phase-launcher.log" } else { "$Me-$Phase.log" }
try {
    New-Item -ItemType Directory -Force $LogDir | Out-Null
    $p = Join-Path $LogDir $logName; Start-Transcript $p -Force | Out-Null; $script:LogPath = $p
} catch {
    try { $p = Join-Path $env:TEMP "DeskConsole-$logName"; Start-Transcript $p -Force | Out-Null; $script:LogPath = $p } catch {}
}
trap {
    Write-Host ''
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    Write-Host "PowerShell $($PSVersionTable.PSVersion)  user $env:USERNAME  admin $(Test-Admin)" -ForegroundColor DarkGray
    Add-Result 'FAIL' "$($_.Exception.Message) (log: $(if ($script:LogPath) { $script:LogPath } else { 'none' }))"
    try { Stop-Transcript | Out-Null } catch {}
    if ($Phase -in $PausePhases -and -not $Unattended) { Read-Host 'Press Enter to close' | Out-Null }
    exit 1
}
if ($Unknown) { Say "Ignored unknown arguments: $($Unknown -join ' ')" Yellow }

switch ($Phase) {
    'User'   { Invoke-UserPhase; if (-not $FromInstaller) { Invoke-FinishPhase } }
    'Admin'  { Invoke-AdminPhase }
    'Finish' { Invoke-FinishPhase }
    'Updates' {     # from Set-NoAutoRestart.cmd or Desk Console
        if (-not $NoAutoRestart) { $NoAutoRestart = 'Enable' }
        if (-not (Test-Admin)) {   # ask for admin once; the elevated copy logs and writes the result
            $rc = Invoke-Elevated 'Updates' -Except 'NoAutoRestart' -Extra '-NoAutoRestart', $NoAutoRestart
            try { Stop-Transcript | Out-Null } catch {}
            exit $rc
        }
        Set-NoAutoRestart
    }
    'RemoveSynergy' {   # from Remove-Synergy.cmd
        if (-not (Test-Admin)) {
            $rc = Invoke-Elevated 'RemoveSynergy'
            try { Stop-Transcript | Out-Null } catch {}
            exit $rc
        }
        Invoke-RemoveSynergyPhase
    }
    'AutoLogon' {   # elevated, from Desk Console's "Automatic sign-in..." button
        if (-not $AutoLogon) { throw 'Pass -AutoLogon Enable or -AutoLogon Disable.' }
        Set-AutoLogon
    }
    'All'   {
        Invoke-UserPhase
        if (Test-Admin) { Invoke-AdminPhase }
        else {
            Say 'Elevating for install + firewall (UAC prompt)...'
            # the elevated token cannot see Z:, so it gets UNC paths; User/Finish-only options stay here
            try {
                $rc = Invoke-Elevated 'Admin' -Except 'Kvm', 'KvmIfUnset', 'Role', 'ResetCredential', 'NasUser', 'DevBoxFolder', 'DevBoxClaude', 'DevBoxNoCode'
                if ($rc -ne 0) { Say "The admin step did not finish (exit $rc) -- see logs\$Me-Admin.log in the shared folder." Red }
            } catch { Say "The admin step did not run: $($_.Exception.Message)" Red }
        }
        Invoke-FinishPhase
    }
}
Add-Result 'OK'
try { Stop-Transcript | Out-Null } catch {}
if ($Phase -in $PausePhases -and -not $Unattended) { Write-Host ''; Read-Host 'Done. Press Enter to close this window' | Out-Null }
