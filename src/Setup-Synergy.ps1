<#
  Setup-Synergy.ps1 -- one script for every PC (the keyboard/mouse server and its clients).
  Run it with DeskConsoleSetup.exe or Setup-Synergy.cmd. Safe to re-run.
  (The name is historical: it started as Synergy-only; installed copies and the trust-sync
  task refer to it by this name, so it stays.)

  Site settings come from site.json next to this script (see site.example.json): the shared
  folder, the hosts to save the share login for, and an optional drive letter to map.

  Phase 1, as you (not elevated):
    - saves the share login in Windows Credential Manager for every site.json credentialHosts
      entry (default: the share's server name)
    - maps site.json mapDrive -> mapPath (optional; persistent, reconnects at sign-in)
    - installs Desk Console for this user
  Phase 2, elevated (one UAC prompt):
    - keyboard + mouse sharing, by kvm.json "provider" on the share:
        Synergy  -- Synergy 3.8.3 (paid licence); Deskflow is switched off
        Deskflow -- Deskflow 1.27.0 (free, open source, the project Synergy is built
                    on); Synergy is switched off, NOT uninstalled
        None     -- both switched off
      Switching off = service stopped + Disabled, sign-in entry parked in
      HKLM\SOFTWARE\DeskConsole\DisabledRun; switching back restores both.
    - RustDesk 1.5.0 (see + control each screen) as a service; direct IP on the
      LAN only (21118); unattended password asked once per machine, never saved here
    - firewall: TCP 24800 (Synergy/Deskflow), TCP/UDP 21118 (RustDesk), ping; LAN only
    - registers this PC in machines.csv (wired adapter first)
  Phase 3, as you again (Deskflow only): writes %APPDATA%\Deskflow\Deskflow.conf
    (server or client, server IP) and, on the server, deskflow-server.conf from
    kvm.json "row" with the Ctrl+Alt+Left/Right hotkeys; starts Deskflow at sign-in.

  Choose the provider for every PC:  Setup-Synergy.cmd -Kvm Deskflow   (or Synergy / None)
  then run Setup-Synergy.cmd on each PC.

  Drive mappings are per logon token, so a Z: mapped from an elevated window
  is invisible in Explorer. That is why phase 1 runs un-elevated.
#>
param(
    [ValidateSet('All','User','Admin','Finish','AutoLogon','TrustSync')] [string]$Phase = 'All',
    [ValidateSet('','Enable','Disable')] [string]$AutoLogon = '',   # Windows automatic sign-in at boot
    [switch]$AutoLogonLock,                                         # ...then lock the screen right away
    [ValidateSet('','Synergy','Deskflow','None')] [string]$Kvm = '',
    [ValidateSet('','Server','Client')] [string]$Role = '',   # Server = make THIS PC kvm.json "server"
    [switch]$ResetCredential,
    [switch]$ResetRemotePassword,
    [string]$NasUser = '',          # share login user; default site.json credentialUser
    # used by DeskConsoleSetup.exe (Inno Setup): no prompts, bundled MSIs, no final pause
    [string]$SecretsFile = '',      # nas_user= nas_pass= rd_pass= al_user= al_pass= lines, in {tmp} / %TEMP%
    [string]$InstallerDir = '',     # bundled MSIs; anything missing falls back to the share
    [switch]$FromInstaller
)
$ErrorActionPreference = 'Stop'

# Always 64-bit. A 32-bit launcher (Inno Setup's ShellExecute of "powershell.exe") starts
# SysWOW64 PowerShell, which sees the WOW6432Node registry (HKLM Run, Winlogon) and cannot
# read 64-bit process paths -- that once left Synergy's sign-in entry and tray app running
# after "Synergy switched off". Re-launch in the 64-bit host with the same arguments.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $ps64 = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    $fwd = foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch]) { if ($kv.Value) { "-$($kv.Key)" } }
        else { "-$($kv.Key)"; "`"$($kv.Value)`"" }
    }
    & $ps64 -NoProfile -ExecutionPolicy Bypass -File "$PSCommandPath" @fwd
    exit $LASTEXITCODE
}

# ---------------------------------------------------------------- site settings
# site.json sits next to this script: on the shared folder, and in the install folder (the
# installer writes it). Fields: shareRoot, credentialHosts, credentialUser, mapDrive, mapPath.
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
$Site       = Get-DeskSite
$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\DeskConsole'
# the shared folder: site.json, else the folder this script runs from (unless that is the install folder)
$Root = if ($Site.shareRoot) { ConvertTo-Unc "$($Site.shareRoot)" }
        elseif ((ConvertTo-Unc $PSScriptRoot) -ne $InstallDir) { ConvertTo-Unc $PSScriptRoot }
        else { $null }
if (-not $Root) { $Root = $PSScriptRoot }   # last resort: everything local
$ShareHost  = if ($Root -match '^\\\\([^\\]+)\\') { $Matches[1] } else { $null }
$NasHosts   = @($Site.credentialHosts | Where-Object { $_ })
if (-not $NasHosts.Count -and $ShareHost) { $NasHosts = @($ShareHost) }
if (-not $NasUser) { $NasUser = "$($Site.credentialUser)" }
$MapDrive   = "$($Site.mapDrive)".TrimEnd('\')          # e.g. "Z:" -- optional
$MapPath    = "$($Site.mapPath)"                        # e.g. "\\nas\share"
$Installers = @{
    Synergy  = @{ Msi = 'synergy-3.8.3-x64.msi';       Sha = '40AE79CEF0EB3A54D43EA95A016EB90483CFF9D92E5F1929D9CA3AC6D56004C7' }
    RustDesk = @{ Msi = 'rustdesk-1.5.0-x86_64.msi';   Sha = '624FE792AB1D76B35134DAB84BFF97A6BCD14043FFD090A2C6A2800F77580495' }
    # unsigned upstream build; hash = the digest GitHub publishes for v1.27.0
    Deskflow = @{ Msi = 'deskflow-1.27.0-win-x64.msi'; Sha = '0CA5668C4731F5477D0B189BDB11196A2CA51281985D9D8C0757BF7F3B782D64' }
}
$KvmJson     = Join-Path $Root 'kvm.json'
$SynergyConf = 'C:\ProgramData\Synergy\config\synergy.conf'
$SynergyCore = 'C:\ProgramData\Synergy\config\synergy-core.conf'
$DeskflowDir = Join-Path $env:APPDATA 'Deskflow'
$RustDeskExe = 'C:\Program Files\RustDesk\rustdesk.exe'
$RustDeskToml = 'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk2.toml'
$ParkedRun   = 'HKLM:\SOFTWARE\DeskConsole\DisabledRun'
$Me        = $env:COMPUTERNAME

function Say($m, $c = 'Cyan') { Write-Host "[$Me] $m" -ForegroundColor $c }

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# kvm.json: { provider, server, row (left -> right) } shared by every PC
function Get-Kvm {
    if (Test-Path $KvmJson) { return Get-Content $KvmJson -Raw | ConvertFrom-Json }
    [pscustomobject]@{ provider = 'Deskflow'; server = $Me; row = @($Me) }   # first PC set up = server until -Role says otherwise
}
function Save-Kvm($k) { $k | ConvertTo-Json | Set-Content $KvmJson -Encoding ascii }
function Find-Exe($dir, $name) { (Get-ChildItem $dir -Filter $name -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1).FullName }

# Secrets handed over by the installer wizard (never on a command line).
$Secrets = @{}
if ($SecretsFile -and (Test-Path $SecretsFile)) {
    foreach ($l in Get-Content $SecretsFile) { if ($l -match '^(\w+)=(.*)$') { $Secrets[$Matches[1]] = $Matches[2] } }
    if ($Phase -eq 'AutoLogon') { Remove-Item $SecretsFile -Force -ErrorAction SilentlyContinue }   # Desk Console's file
}

# ---------------------------------------------------------------- phase 1
function Invoke-UserPhase {
    if ($NasHosts.Count) {
        $saved = (cmdkey /list) -match "target=$([regex]::Escape($NasHosts[0]))$"
        if ($Secrets['nas_pass'] -or $ResetCredential -or (-not $saved -and -not $FromInstaller)) {
            if ($Secrets['nas_pass']) {
                $user = if ($Secrets['nas_user']) { $Secrets['nas_user'] } else { $NasUser }; $pw = $Secrets['nas_pass']
            } else {
                $cred = Get-Credential -UserName $NasUser -Message "Login for \\$($NasHosts[0]) (saved to Windows Credential Manager)"
                if (-not $cred) { throw 'No credential entered.' }
                $user = $cred.UserName; $pw = $cred.GetNetworkCredential().Password
            }
            foreach ($h in $NasHosts) {
                cmdkey /delete:$h 2>$null | Out-Null
                cmdkey /add:$h /user:$user /pass:$pw | Out-Null
            }
            $pw = $null
            Say "Saved the share login for: $($NasHosts -join ', ')" Green
        } else {
            Say 'Share login already saved (use -ResetCredential to replace it).'
        }
    }

    if ($MapDrive -and $MapPath) {
        $z = Get-SmbMapping -LocalPath $MapDrive -ErrorAction SilentlyContinue
        if ($z -and $z.RemotePath -ne $MapPath) {
            Say "$MapDrive is mapped to $($z.RemotePath), not $MapPath -- leaving it alone." Yellow
        } elseif ($z -and $z.Status -eq 'OK') {
            Say "$MapDrive already mapped to $MapPath."
        } else {
            if ($z) { net use $MapDrive /delete /y 2>$null | Out-Null }
            net use $MapDrive $MapPath /persistent:yes | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "net use $MapDrive $MapPath failed ($LASTEXITCODE)" }
            Say "Mapped $MapDrive -> $MapPath (persistent)." Green
        }
    }

    # keep the share path in site.json as UNC: the elevated step cannot see drive letters
    $here = Join-Path $PSScriptRoot 'site.json'
    if ($Site -and (Test-Path $here) -and "$($Site.shareRoot)" -match '^[A-Za-z]:') {
        $Site.shareRoot = ConvertTo-Unc "$($Site.shareRoot)"; $Site | ConvertTo-Json | Set-Content $here -Encoding ascii
    }

    # Desk Console for this user (Start Menu + Desktop, Settings > Apps entry; no admin)
    # -- DeskConsoleSetup.exe installs it itself
    if (-not $FromInstaller) { & (Join-Path $Root 'Install-DeskConsole.ps1') }

    if ($Kvm) {   # after the NAS login is saved, so the share is writable on a fresh PC
        $k = Get-Kvm; $k.provider = $Kvm; Save-Kvm $k
        Say "kvm.json provider set to $Kvm for every PC -- run setup on each PC to apply." Green
    }
    if ($Role) {
        $k = Get-Kvm
        if ($Role -eq 'Server') { $k.server = $Me; Save-Kvm $k; Say "kvm.json server set to $Me." Green }
        elseif ($k.server -eq $Me) { Say "kvm.json still names $Me as the server -- pick another server on that PC." Yellow }
    }
}

# ---------------------------------------------------------------- phase 2
function Install-FromShare($name, $installedTest) {
    if (& $installedTest) { Say "$name already installed."; return $false }
    $i = $Installers[$name]
    $src = Join-Path $Root "installer\$($i.Msi)"
    if ($InstallerDir -and (Test-Path (Join-Path $InstallerDir $i.Msi))) { $src = Join-Path $InstallerDir $i.Msi }
    $h = (Get-FileHash $src -Algorithm SHA256).Hash
    if ($h -ne $i.Sha) { throw "$($i.Msi) hash mismatch on share ($h). Not installing." }
    $local = Join-Path $env:TEMP $i.Msi
    Copy-Item $src $local -Force
    Say "Installing $($i.Msi)..."
    $log = Join-Path $env:TEMP "$name-install.log"
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$local`" /qn /norestart /l*v `"$log`"" -Wait -PassThru
    Remove-Item $local -ErrorAction SilentlyContinue
    if ($p.ExitCode -notin 0, 3010) { throw "$name msiexec exit $($p.ExitCode); log: $log" }
    Say "$name installed." Green
    return $true
}

function Set-FirewallRule($name, [hashtable]$spec) {
    Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName $name -Direction Inbound -RemoteAddress LocalSubnet -Profile Any -Action Allow @spec | Out-Null
}

# Switch a KVM product off without uninstalling it: stop + disable its services,
# park its sign-in (Run) entries, end its processes. Enable-Kvm undoes exactly that.
function Disable-Kvm($product) {
    $any = $false
    Get-Service | Where-Object { $_.DisplayName -match $product -or $_.Name -match $product } | ForEach-Object {
        if ($_.Status -ne 'Stopped') { Stop-Service $_.Name -Force -ErrorAction SilentlyContinue }
        Set-Service $_.Name -StartupType Disabled; $any = $true
    }
    foreach ($scope in 'HKLM', 'HKCU') {
        $run = "${scope}:\Software\Microsoft\Windows\CurrentVersion\Run"
        (Get-ItemProperty $run -ErrorAction SilentlyContinue).PSObject.Properties |
            Where-Object { $_.Name -notlike 'PS*' -and "$($_.Value)" -match "\\$product\\" } | ForEach-Object {
                New-Item $ParkedRun -Force -ErrorAction SilentlyContinue | Out-Null
                New-ItemProperty $ParkedRun -Name "$scope|$($_.Name)" -Value $_.Value -Force | Out-Null
                Remove-ItemProperty $run -Name $_.Name; $any = $true
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
    Install-FromShare 'Synergy' { Test-Path 'C:\Program Files\Synergy\synergy-core.exe' } | Out-Null
    Enable-Kvm 'Synergy'
    Get-ChildItem 'C:\Program Files\Synergy' -Filter 'synergy*.exe' -ErrorAction SilentlyContinue | ForEach-Object {
        Set-FirewallRule "Synergy 3 ($($_.Name), LAN)" @{ Program = $_.FullName }
    }
    Say 'Synergy on; firewall allows it from the local subnet.' Green
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
    $p = Start-Process $local -ArgumentList '/install', '/quiet', '/norestart', '/log', "`"$env:TEMP\VCRedist-install.log`"" -Wait -PassThru
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
    Say 'Deskflow on; firewall allows it from the local subnet.' Green
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

function Install-RustDesk {
    $fresh = Install-FromShare 'RustDesk' { Test-Path $RustDeskExe }
    $svc = Get-Service RustDesk -ErrorAction SilentlyContinue
    if (-not $svc) { & $RustDeskExe --install-service | Out-Null; Start-Sleep 5; $svc = Get-Service RustDesk -ErrorAction SilentlyContinue }
    if ($svc) { Set-Service RustDesk -StartupType Automatic; if ($svc.Status -ne 'Running') { Start-Service RustDesk } }
    else { Say 'RustDesk service did not appear -- open RustDesk once and accept its service install prompt.' Yellow }

    # direct IP access on the LAN (no relay needed inside the house)
    & $RustDeskExe --option direct-server Y 2>$null | Out-Null
    Start-Sleep 2
    # Never restart RustDesk while someone is connected through it: setup is often run over a
    # RustDesk session, and a restart would drop it mid-install.
    $inSession = [bool](Get-NetTCPConnection -LocalPort 21118 -State Established -ErrorAction SilentlyContinue)
    if ((Test-Path $RustDeskToml) -and -not ((Get-Content $RustDeskToml -Raw) -match "direct-server = 'Y'") -and $inSession) {
        Say 'RustDesk direct IP is not on yet, but you are connected through RustDesk -- not restarting it now. Re-run setup at the PC, or tick Settings > Security > Enable direct IP access.' Yellow
    } elseif ((Test-Path $RustDeskToml) -and -not ((Get-Content $RustDeskToml -Raw) -match "direct-server = 'Y'")) {
        Stop-Service RustDesk
        $t = Get-Content $RustDeskToml -Raw
        if ($t -match '\[options\]') { $t = $t -replace '\[options\]', "[options]`ndirect-server = 'Y'" }
        else { $t += "`n[options]`ndirect-server = 'Y'`n" }
        Set-Content $RustDeskToml $t -Encoding utf8 -NoNewline
        Start-Service RustDesk
    }
    $direct = (Test-Path $RustDeskToml) -and ((Get-Content $RustDeskToml -Raw) -match "direct-server = 'Y'")
    Say "RustDesk direct IP access: $(if ($direct) {'ON'} else {'NOT CONFIRMED -- tick Settings > Security > Enable direct IP access'})" $(if ($direct) {'Green'} else {'Yellow'})

    Set-FirewallRule 'RustDesk direct IP (TCP 21118, LAN)' @{ Protocol = 'TCP'; LocalPort = 21118 }
    Set-FirewallRule 'RustDesk direct IP (UDP 21118, LAN)' @{ Protocol = 'UDP'; LocalPort = 21118 }
    Set-FirewallRule 'RustDesk (program, LAN)' @{ Program = $RustDeskExe }
    # lets Desk-Console see this PC as online (Windows drops ping by default)
    Set-FirewallRule 'Desk Console ping (ICMPv4, LAN)' @{ Protocol = 'ICMPv4'; IcmpType = 8 }

    if ($Secrets['rd_pass']) {
        & $RustDeskExe --password $Secrets['rd_pass'] | Out-Null; Say 'RustDesk password set (from the installer).' Green
    } elseif (($fresh -or $ResetRemotePassword) -and -not $FromInstaller) {
        Write-Host ''
        Say 'Set the RustDesk unattended password for this PC (use the same one on all three).' White
        $a = Read-Host 'RustDesk password' -AsSecureString
        $b = Read-Host 'Again' -AsSecureString
        $pa = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($a))
        $pb = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($b))
        if ($pa -and $pa -ceq $pb) { & $RustDeskExe --password $pa | Out-Null; Say 'RustDesk password set.' Green }
        else { Say 'Passwords empty or different -- re-run with -ResetRemotePassword.' Yellow }
        $pa = $pb = $null
    }
}

# ---------------------------------------------------------------- automatic sign-in
# Same method as Sysinternals Autologon: the password goes into the LSA secret
# "DefaultPassword" (encrypted), never the plain-text Winlogon DefaultPassword value.
# The password is checked with LogonUser first, so a typo cannot strand a PC at the
# sign-in screen. Optional: lock the screen right after an automatic sign-in (a logon
# task that locks only when Windows started < 3 min ago, so manual sign-ins are left alone).
$Winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$PwLess   = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device'
$DcKey    = 'HKLM:\SOFTWARE\DeskConsole'
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
    public static bool Check(string user, string domain, string password) {
        IntPtr t; if (!LogonUser(user, domain, password, 2, 0, out t)) return false;
        CloseHandle(t); return true;
    }
}
'@
}

function Set-AutoLogon {
    Add-AutoLogonType
    if ($AutoLogon -eq 'Disable') {
        Set-ItemProperty $Winlogon -Name AutoAdminLogon -Value '0' -Type String
        Remove-ItemProperty $Winlogon -Name DefaultPassword -ErrorAction SilentlyContinue
        [DeskAutoLogon]::StoreSecret('DefaultPassword', $null)
        $was = (Get-ItemProperty $DcKey -ErrorAction SilentlyContinue).PasswordLessWas
        if ($null -ne $was) {
            Set-ItemProperty $PwLess -Name DevicePasswordLessBuildVersion -Value $was -Type DWord
            Remove-ItemProperty $DcKey -Name PasswordLessWas
        }
        Unregister-ScheduledTask -TaskName $LockTask -Confirm:$false -ErrorAction SilentlyContinue
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
        if ($FromInstaller) { throw 'Automatic sign-in needs the Windows password -- nothing changed.' }
        $s = Read-Host "Windows password for $dom\$name" -AsSecureString
        $pw = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
    }

    # al_new=1: a local account just for automatic sign-in (the desktops); the Surface
    # uses an existing account. Created in Users (not Administrators); password never
    # expires so the PC does not stop at a "change your password" screen one day.
    if ($Secrets['al_new'] -eq '1') {
        if ($user -match '\\') { $name = ($user -split '\\', 2)[1] }
        $dom = $env:COMPUTERNAME
        $sec = ConvertTo-SecureString $pw -AsPlainText -Force
        if (Get-LocalUser -Name $name -ErrorAction SilentlyContinue) {
            Set-LocalUser -Name $name -Password $sec -PasswordNeverExpires $true
            Say "Local account $name exists -- password updated."
        } else {
            New-LocalUser -Name $name -Password $sec -FullName 'Desk (automatic sign-in)' `
                -Description 'Created by Desk Console setup for automatic sign-in' -PasswordNeverExpires -AccountNeverExpires | Out-Null
            Say "Created local account $name." Green
        }
        $users = (New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-545').Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
        Add-LocalGroupMember -Group $users -Member $name -ErrorAction SilentlyContinue
        # a brand-new account's first sign-in stops on the privacy-settings screen
        New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE' -Force | Out-Null
        Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE' -Name DisablePrivacyExperience -Value 1 -Type DWord
    }
    if (-not [DeskAutoLogon]::Check($name, $dom, $pw)) {
        $pw = $null; throw "Windows rejected that password for $dom\$name -- automatic sign-in NOT changed."
    }
    [DeskAutoLogon]::StoreSecret('DefaultPassword', $pw); $pw = $null
    Set-ItemProperty $Winlogon -Name AutoAdminLogon    -Value '1'   -Type String
    Set-ItemProperty $Winlogon -Name DefaultUserName   -Value $name -Type String
    Set-ItemProperty $Winlogon -Name DefaultDomainName -Value $dom  -Type String
    Remove-ItemProperty $Winlogon -Name DefaultPassword, AutoLogonCount -ErrorAction SilentlyContinue

    # "Only allow Windows Hello sign-in" hides automatic sign-in: remember it, turn it off
    $cur = (Get-ItemProperty $PwLess -ErrorAction SilentlyContinue).DevicePasswordLessBuildVersion
    if ($cur) {
        New-Item $DcKey -Force -ErrorAction SilentlyContinue | Out-Null
        if ($null -eq (Get-ItemProperty $DcKey -ErrorAction SilentlyContinue).PasswordLessWas) {
            New-ItemProperty $DcKey -Name PasswordLessWas -Value $cur -PropertyType DWord -Force | Out-Null
        }
        Set-ItemProperty $PwLess -Name DevicePasswordLessBuildVersion -Value 0 -Type DWord
        Say 'Turned off "only allow Windows Hello sign-in" (restored when auto sign-in is turned off).'
    }

    if ($AutoLogonLock) {
        $cmd = 'if (((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalMinutes -lt 3) { rundll32.exe user32.dll,LockWorkStation }'
        $act = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\conhost.exe" -Argument "--headless powershell.exe -NoProfile -WindowStyle Hidden -Command `"$cmd`""
        $trg = New-ScheduledTaskTrigger -AtLogOn -User "$dom\$name"; $trg.Delay = 'PT20S'   # let services + tray apps start first
        $pr  = New-ScheduledTaskPrincipal -UserId "$dom\$name" -LogonType Interactive -RunLevel Limited
        $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $LockTask -Action $act -Trigger $trg -Principal $pr -Settings $set -Force | Out-Null
    } else {
        Unregister-ScheduledTask -TaskName $LockTask -Confirm:$false -ErrorAction SilentlyContinue
    }
    Say "Automatic sign-in is ON for $dom\$name$(if ($AutoLogonLock) { ', then the screen locks' })." Green
    $pol = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue
    if ($pol.LegalNoticeCaption -or $pol.LegalNoticeText) { Say 'A sign-in notice (policy) is set on this PC -- it stops automatic sign-in until it is cleared.' Yellow }
}

function Register-Machine {
    # wired before Wi-Fi, then the adapter with the default gateway, then lowest metric
    # (a desktop once registered its Wi-Fi address, which sleeps; its wired one answers).
    # Private IPv4 only: no loopback, no APIPA 169.254.x, no adapter without a default gateway first.
    $ipObj = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | ForEach-Object {
        $ad = Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue
        if (-not $ad -or $ad.Status -ne 'Up') { return }
        [pscustomobject]@{ IPAddress = $_.IPAddress; InterfaceIndex = $_.InterfaceIndex
            Wifi    = $ad.PhysicalMediaType -match '802\.11|Wireless' -or $ad.InterfaceDescription -match 'Wi-?Fi|Wireless'
            NoGw    = -not (Get-NetRoute -InterfaceIndex $_.InterfaceIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
            Metric  = (Get-NetIPInterface -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4).InterfaceMetric }
    } | Sort-Object Wifi, NoGw, Metric | Select-Object -First 1
    $mac = if ($ipObj) { (Get-NetAdapter -InterfaceIndex $ipObj.InterfaceIndex).MacAddress }
    $id = try { (& $RustDeskExe --get-id | Out-String).Trim() } catch { '' }
    $row = [pscustomobject]@{ Name = $Me; IP = $ipObj.IPAddress; MAC = $mac; RustDeskId = $id; Updated = (Get-Date -f 'yyyy-MM-dd HH:mm') }
    $reg = Join-Path $Root 'machines.csv'
    $rows = @(Import-Csv $reg -ErrorAction SilentlyContinue | Where-Object { $_.Name -and $_.Name -ne $Me }) + $row
    $rows | Sort-Object Name | Export-Csv $reg -NoTypeInformation -Encoding ascii
    Write-Host ''
    Say "Registered in machines.csv:  $Me  $($row.IP)  $mac  RustDesk id $id" White
    if (-not $ipObj) { Say 'No usable network address -- connect this PC to the LAN (Ethernet) and re-run.' Yellow }
}

function Invoke-AdminPhase {
    $k = Get-Kvm
    Say "Keyboard + mouse provider (kvm.json): $($k.provider)" White
    Set-FirewallRule 'Synergy 3 (TCP 24800, LAN)' @{ Protocol = 'TCP'; LocalPort = 24800 }   # same port for both
    try {   # a keyboard/mouse failure must not cost this PC its RustDesk, sign-in and registration
        switch ($k.provider) {
            'Synergy'  { Disable-Kvm 'Deskflow'; Install-Synergy; Add-SynergyHotkeys }
            'Deskflow' { Disable-Kvm 'Synergy';  Install-Deskflow; Set-DeskflowSystem }
            default    { Disable-Kvm 'Synergy';  Disable-Kvm 'Deskflow'; Say 'Keyboard + mouse sharing is off on this PC.' }
        }
    } catch { Say "Keyboard + mouse setup FAILED: $($_.Exception.Message) -- continuing with the rest; re-run setup after fixing it." Red }
    Install-RustDesk
    if ($AutoLogon) {
        try { Set-AutoLogon } catch { Say "Automatic sign-in NOT changed: $($_.Exception.Message)" Red }   # don't lose the rest of setup
    }
    Register-Machine
    Write-Host '   Control everything from Desk Console (Start Menu).'
}

# ---------------------------------------------------------------- phase 3 (as you)
# QSettings INI writer: replaces or adds section/key values, keeps everything else.
function Set-Ini($path, [Collections.Specialized.OrderedDictionary]$vals) {
    $lines = New-Object Collections.Generic.List[string]
    if (Test-Path $path) { $lines.AddRange([string[]](Get-Content $path)) }
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

# Deskflow reads %APPDATA%\Deskflow\Deskflow.conf if it exists, else the machine-wide
# C:\ProgramData\Deskflow\Deskflow.conf (Settings.cpp, v1.27.0). The admin step writes the
# machine-wide one + the server layout and starts Deskflow for EVERY user (HKLM Run), so an
# automatic-sign-in account such as BuildRunner gets it too; the finish step writes the same
# values into the signed-in user's file so an older per-user copy cannot disagree.
$DeskflowSysDir = 'C:\ProgramData\Deskflow'
$UserServerConf = Join-Path $DeskflowDir 'deskflow-server.conf'   # the server's signed-in user; writable by the 2-minute task
function Get-DeskflowValues {
    $k = Get-Kvm
    $row = @($k.row | Where-Object { $_ })
    if ($row -notcontains $Me) { $row += $Me; $k.row = $row; Save-Kvm $k; Say "Added $Me to the right end of kvm.json row." Green }
    $isServer = $k.server -eq $Me
    $serverIp = (Import-Csv (Join-Path $Root 'machines.csv') | Where-Object { $_.Name -eq $k.server }).IP
    if (-not $isServer -and -not $serverIp) { Say "Server $($k.server) is not in machines.csv yet -- run setup there first, then here." Yellow }
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
    foreach ($c in $row) { $ini["computer_$c/name"] = $c }
    [pscustomobject]@{ Kvm = $k; Row = $row; IsServer = $isServer; ServerIp = $serverIp; ServerConf = $serverConf; Ini = $ini }
}

function Get-DeskflowServerConfText($row) {
    $sb = [Text.StringBuilder]::new()
    [void]$sb.AppendLine('# Generated by Setup-Synergy.ps1 from kvm.json "row" -- the server''s 2-minute task rebuilds it when the row changes.')
    [void]$sb.AppendLine('# Deskflow 1.27: the computers are listed in Deskflow.conf [computer_<name>]; links + options only here.')
    [void]$sb.AppendLine('section: links')
    for ($i = 0; $i -lt $row.Count; $i++) {
        [void]$sb.AppendLine("`t$($row[$i]):")
        if ($i -gt 0)              { [void]$sb.AppendLine("`t`tleft = $($row[$i-1])") }
        if ($i -lt $row.Count - 1) { [void]$sb.AppendLine("`t`tright = $($row[$i+1])") }
    }
    [void]$sb.AppendLine('end')
    [void]$sb.AppendLine('section: options')
    [void]$sb.AppendLine("`tkeystroke(Control+Alt+Left) = switchInDirection(left)")
    [void]$sb.AppendLine("`tkeystroke(Control+Alt+Right) = switchInDirection(right)")
    [void]$sb.AppendLine('end')
    $sb.ToString()
}

# Server only, from the 2-minute task: a PC that joined later is in
# kvm.json "row" but not in the server's Deskflow config, so the server would refuse it as an
# unknown computer. Rebuild the layout + computer list when they differ. Deskflow's core restarts
# itself when its settings file changes ("settings file changed" in the daemon log), so the
# signed-in user's Deskflow.conf gets a stamp whenever the layout file changes.
function Update-DeskflowServerLayout {
    $v = Get-DeskflowValues
    if (-not $v.IsServer) { return }
    $text = Get-DeskflowServerConfText $v.Row
    $userConf = Join-Path $DeskflowDir 'Deskflow.conf'
    $layoutChanged = $false; $computersChanged = $false
    # the signed-in user's own layout file (always writable), and that user's Deskflow pointed at it
    New-Item -ItemType Directory -Force $DeskflowDir | Out-Null
    if ("$(Get-Content $UserServerConf -Raw -ErrorAction SilentlyContinue)" -ne $text) {
        [IO.File]::WriteAllText($UserServerConf, $text); $layoutChanged = $true
    }
    $ext = '"' + $UserServerConf.Replace('\', '\\') + '"'
    if ((Test-Path $userConf) -and -not (Select-String -Path $userConf -SimpleMatch "externalConfigFile=$ext" -Quiet) -and
        -not (Select-String -Path $userConf -SimpleMatch "externalConfigFile=$($UserServerConf.Replace('\', '\\'))" -Quiet)) {
        Set-Ini $userConf ([ordered]@{ 'server/externalConfig' = 'true'; 'server/externalConfigFile' = $ext }); $layoutChanged = $true
    }
    # machine-wide copy for other accounts: only if this user may write it (admin-created = read-only)
    if ("$(Get-Content $v.ServerConf -Raw -ErrorAction SilentlyContinue)" -ne $text) {
        try { [IO.File]::WriteAllText($v.ServerConf, $text) } catch {}
    }
    $computers = [ordered]@{}; foreach ($c in $v.Row) { $computers["computer_$c/name"] = $c }
    foreach ($conf in $userConf, (Join-Path $DeskflowSysDir 'Deskflow.conf')) {
        if (-not (Test-Path $conf)) { continue }
        $missing = @($v.Row | Where-Object { -not (Select-String -Path $conf -Pattern "^\[computer_$([regex]::Escape($_))\]" -Quiet) })
        if ($missing.Count) { try { Set-Ini $conf $computers; if ($conf -eq $userConf) { $computersChanged = $true } } catch {} }
    }
    # The core reads its settings only when it starts; restarting the Deskflow window (as this
    # user, no admin) makes the daemon start a fresh core. Only when something changed.
    if ($layoutChanged -or $computersChanged) {
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
    $row = $v.Row; $serverConf = $v.ServerConf; $isServer = $v.IsServer; $k = $v.Kvm; $serverIp = $v.ServerIp

    if ($isServer) {
        [IO.File]::WriteAllText($serverConf, (Get-DeskflowServerConfText $row))
        Say "Deskflow SERVER. Layout left -> right: $($row -join ' | ')" Green
    } else {
        Say "Deskflow client of $($k.server) ($serverIp)." Green
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
$TrustTask   = 'DeskConsole Deskflow trust sync'
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

# As the signed-in user, no admin: at sign-in and every 2 minutes, so a client installed later
# is trusted by the server within 2 minutes.
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
    if ($v.IsServer) { [IO.File]::WriteAllText($UserServerConf, (Get-DeskflowServerConfText $v.Row)) }
    Set-Ini (Join-Path $DeskflowDir 'Deskflow.conf') $ini
    Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Deskflow' -ErrorAction SilentlyContinue  # HKLM has it now
    Start-Process $exe
    Sync-DeskflowTrust
    try { Register-TrustSyncTask; Say 'Deskflow trust sync runs every 2 minutes (no dialogs for new PCs).' }
    catch { Say "Could not create the trust-sync task: $($_.Exception.Message)" Yellow }
}

# ---------------------------------------------------------------- main
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

# the 2-minute trust sync: quiet, no transcript, never prompts
if ($Phase -eq 'TrustSync') {
    try { Sync-DeskflowTrust -Quiet } catch {}
    try { Update-DeskflowServerLayout } catch {}   # server only: a PC that joined later
    exit 0
}

# every run leaves logs\<PC>-<phase>.log on the share, with the failing line
$LogDir = Join-Path $Root 'logs'
try { New-Item -ItemType Directory -Force $LogDir | Out-Null; Start-Transcript (Join-Path $LogDir "$Me-$Phase.log") -Force | Out-Null } catch {}
trap {
    Write-Host ''
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    Write-Host "PowerShell $($PSVersionTable.PSVersion)  user $env:USERNAME  admin $(Test-Admin)" -ForegroundColor DarkGray
    try { Stop-Transcript | Out-Null } catch {}
    if ($Phase -in 'Admin', 'AutoLogon') { Read-Host 'Press Enter to close' | Out-Null }
    exit 1
}
switch ($Phase) {
    'User'  { Invoke-UserPhase; if (-not $FromInstaller) { Set-DeskflowUser } }
    'Admin' { Invoke-AdminPhase; if (-not $FromInstaller) { Write-Host ''; Read-Host 'Done. Press Enter to close this window' | Out-Null } }
    'Finish' { Set-DeskflowUser }
    'AutoLogon' {   # elevated, from Desk Console's "Automatic sign-in..." button
        if (-not $AutoLogon) { throw 'Pass -AutoLogon Enable or -AutoLogon Disable.' }
        Set-AutoLogon
        if (-not $FromInstaller) { Write-Host ''; Read-Host 'Done. Press Enter to close this window' | Out-Null }
    }
    'All'   {
        Invoke-UserPhase
        if (Test-Admin) { Invoke-AdminPhase }
        else {
            Say 'Elevating for install + firewall (UAC prompt)...'
            # the elevated token cannot see Z:, so hand it the UNC path
            $self = ConvertTo-Unc $PSCommandPath
            $fwd = @(); if ($ResetRemotePassword) { $fwd += '-ResetRemotePassword' }
            Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList (@(
                '-NoProfile', '-ExecutionPolicy', 'Bypass',
                '-File', "`"$self`"", '-Phase', 'Admin') + $fwd)
        }
        Set-DeskflowUser
    }
}
try { Stop-Transcript | Out-Null } catch {}
