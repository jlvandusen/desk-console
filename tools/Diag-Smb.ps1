<#
  Diag-Smb.ps1 -- why can't another PC open \\<this PC>\C$ ?  Read-only unless -Fix.
  Run on the PC being connected TO, in an admin PowerShell:
    powershell -ExecutionPolicy Bypass -File \\<server>\<share>\DeskConsole\tools\Diag-Smb.ps1
  Writes ..\logs\<PC>-smb-diag.txt beside this tools folder (or %TEMP% if that is not writable); no passwords, account names only.

  -Fix sets LocalAccountTokenFilterPolicy = 1: local admin accounts then keep admin rights
  over the network, which C$ needs. Windows strips them by default ("remote UAC"), so a
  correct password for a local admin still fails on C$. Weaker against network attacks --
  only on a home LAN you trust. -Undo puts it back.
#>
param([switch]$Fix, [switch]$Undo)
$ErrorActionPreference = 'Continue'
$logDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'logs'
try { New-Item -ItemType Directory -Force $logDir -ErrorAction Stop | Out-Null } catch { $logDir = $env:TEMP }
$out = Join-Path $logDir "$env:COMPUTERNAME-smb-diag.txt"
$sys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'

$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (($Fix -or $Undo) -and -not $elevated) {
    Write-Host 'NOT elevated -- nothing changed. Re-opening as Administrator (approve the prompt)...' -ForegroundColor Yellow
    Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"", $(if ($Fix) { '-Fix' } else { '-Undo' })
    return
}
try {
    if ($Fix)  { Set-ItemProperty $sys -Name LocalAccountTokenFilterPolicy -Value 1 -Type DWord -ErrorAction Stop; Write-Host 'LocalAccountTokenFilterPolicy = 1 (remote UAC off for local admins)' -ForegroundColor Green }
    if ($Undo) { Remove-ItemProperty $sys -Name LocalAccountTokenFilterPolicy -ErrorAction Stop; Write-Host 'LocalAccountTokenFilterPolicy removed (Windows default)' -ForegroundColor Green }
} catch { Write-Host "Change FAILED: $($_.Exception.Message)" -ForegroundColor Red }

$r = New-Object Text.StringBuilder
function Add($t) { [void]$r.AppendLine($t) }
Add "SMB diagnostics for $env:COMPUTERNAME  $(Get-Date -f 'yyyy-MM-dd HH:mm:ss')  elevated=$elevated"
Add "Windows $([Environment]::OSVersion.Version)   domain-joined: $((Get-CimInstance Win32_ComputerSystem).PartOfDomain)"
Add ''
Add "LocalAccountTokenFilterPolicy: $((Get-ItemProperty $sys -ErrorAction SilentlyContinue).LocalAccountTokenFilterPolicy)   (empty/0 = remote UAC ON: local admins cannot use C$ over the network)"
$lsa = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -ErrorAction SilentlyContinue
Add "LimitBlankPasswordUse: $($lsa.LimitBlankPasswordUse)   forceguest: $($lsa.forceguest)   (forceguest=1 = everyone signs in as Guest)"
Add "RestrictReceivingNTLMTraffic: $((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0' -ErrorAction SilentlyContinue).RestrictReceivingNTLMTraffic)   (2 = NTLM sign-ins refused)"
Add ''
Add '--- SMB server'
Get-SmbServerConfiguration | Select-Object EnableSMB2Protocol, RequireSecuritySignature, AutoShareServer, AnnounceServer | Format-List | Out-String | ForEach-Object { Add $_.Trim() }
Add "Shares: $((Get-SmbShare | ForEach-Object Name) -join ', ')"
Add "Server service: $((Get-Service LanmanServer).Status)"
Add ''
Add '--- network profile + firewall'
Get-NetConnectionProfile | ForEach-Object { Add "$($_.InterfaceAlias): $($_.NetworkCategory)" }
Get-NetFirewallRule -Group '@FirewallAPI.dll,-28502' -Direction Inbound -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match 'SMB-In' } | ForEach-Object { Add "$($_.DisplayName) [$($_.Profile)] enabled=$($_.Enabled)" }
Add ''
Add '--- local accounts'
Get-LocalUser | ForEach-Object { Add ("{0,-16} enabled={1,-5} pwSet={2:yyyy-MM-dd} source={3}" -f $_.Name, $_.Enabled, $_.PasswordLastSet, $_.PrincipalSource) }
$admins = (New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544').Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
Add "Administrators: $((Get-LocalGroupMember $admins | ForEach-Object Name) -join ', ')"
Add ''
Add '--- last failed network sign-ins (Security 4625; logon type 3 = network)'
$codes = @{ '0xc000006a' = 'wrong password'; '0xc0000064' = 'no such user'; '0xc000006d' = 'bad user name or password';
            '0xc000015b' = 'logon type not granted (Access this computer from the network)'; '0xc0000234' = 'account locked';
            '0xc0000072' = 'account disabled'; '0xc000006e' = 'account restriction (blank password?)'; '0xc0000071' = 'password expired' }
try {
    Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4625; StartTime = (Get-Date).AddHours(-6) } -MaxEvents 10 -ErrorAction Stop | ForEach-Object {
        $x = [xml]$_.ToXml(); $d = @{}; foreach ($n in $x.Event.EventData.Data) { $d[$n.Name] = $n.'#text' }
        $sub = "$($d.SubStatus)".ToLower(); $st = "$($d.Status)".ToLower()
        Add ("{0:HH:mm:ss} user={1}\{2} from={3} type={4} pkg={5} status={6} sub={7} => {8}" -f $_.TimeCreated, $d.TargetDomainName, $d.TargetUserName,
            $d.IpAddress, $d.LogonType, $d.AuthenticationPackageName, $st, $sub, $(if ($codes[$sub]) { $codes[$sub] } elseif ($codes[$st]) { $codes[$st] } else { '?' }))
    }
} catch { Add "none in the last 6 hours (or the Security log needs admin): $($_.Exception.Message)" }
Add ''
Add '--- last successful network sign-ins (4624 type 3)'
try {
    Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4624; StartTime = (Get-Date).AddHours(-6) } -MaxEvents 200 -ErrorAction Stop |
        Where-Object { $_.Properties[8].Value -eq 3 } | Select-Object -First 5 | ForEach-Object {
            Add ("{0:HH:mm:ss} user={1}\{2} from={3} pkg={4}" -f $_.TimeCreated, $_.Properties[6].Value, $_.Properties[5].Value, $_.Properties[18].Value, $_.Properties[10].Value)
        }
} catch { Add "none: $($_.Exception.Message)" }

$r.ToString() | Set-Content $out -Encoding ascii
Write-Host $r.ToString()
Write-Host "Saved to $out" -ForegroundColor Cyan
