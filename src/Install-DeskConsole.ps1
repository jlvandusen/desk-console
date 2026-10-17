<#
  Install-DeskConsole.ps1 -- per-user install of Desk Console (no admin).
    Install:    Install-DeskConsole.cmd            [-AutoStart | -NoAutoStart] [-NoDesktop] [-Force]
    Uninstall:  Settings > Apps > Desk Console, or Install-DeskConsole.cmd -Uninstall

  Installs to %LOCALAPPDATA%\Programs\DeskConsole: the app, its icon and this
  installer (the uninstaller). Start Menu + Desktop shortcuts, optional
  sign-in start (-AutoStart: in the notification area), and an entry in Settings > Apps.
  Shortcuts launch through `conhost --headless` so no console window flashes.
  The installed app updates itself: on launch it compares version.txt on the
  share with its own version and runs this script from the share (-Quiet) when it is newer.
  It never puts an older version over a newer one unless -Force: re-running setup from an
  older shared folder used to downgrade the PC without a word.
  site.json (from the shared folder, or written here) tells the installed copy where the share is.
#>
param([switch]$AutoStart, [switch]$NoDesktop, [switch]$Uninstall, [switch]$Quiet, [switch]$Force, [switch]$NoAutoStart)
$ErrorActionPreference = 'Stop'
$Dir      = Join-Path $env:LOCALAPPDATA 'Programs\DeskConsole'
# An elevated window cannot see mapped drives: turn "Z:\x" into "\\server\share\x".
function ConvertTo-Unc([string]$path) {
    if ($path -match '^([A-Za-z]):(.*)$') {
        $d = Get-PSDrive -Name $Matches[1] -PSProvider FileSystem -ErrorAction SilentlyContinue
        if ($d.DisplayRoot) { return $d.DisplayRoot.TrimEnd('\') + $Matches[2] }
    }
    $path
}
# The shared folder: site.json next to this script wins (a moved folder can leave a stub with
# just version.txt + this script + a site.json pointing at the new place); else this folder.
$Site = $null
$sj = Join-Path $PSScriptRoot 'site.json'
if (Test-Path $sj) { try { $Site = Get-Content $sj -Raw | ConvertFrom-Json } catch {} }
$Share = if ($Site.shareRoot -and (Test-Path (Join-Path (ConvertTo-Unc "$($Site.shareRoot)") 'Desk-Console.ps1'))) { ConvertTo-Unc "$($Site.shareRoot)" }
         else { ConvertTo-Unc $PSScriptRoot }
$Programs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$Lnks     = @{
    StartMenu = Join-Path $Programs 'Desk Console.lnk'
    Desktop   = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Desk Console.lnk'
    Startup   = Join-Path $Programs 'Startup\Desk Console.lnk'
}
$Key      = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DeskConsole'
$InnoKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DeskConsole_is1'   # DeskConsoleSetup.exe's entry
# The installed files, version.txt LAST: a copy that stops half-way (the share drops, another
# Desk Console holds a file) leaves the old version.txt, so the next launch still sees the share
# as newer and tries again. installer\DeskConsole.iss has the same list twice -- [Files] and
# AppFile()/AppFileCount -- in the same order (contract C-8): change all three together.
$Files    = 'Desk-Console.ps1', 'Setup-Synergy.ps1', 'Agent.ps1', 'Install-DeskConsole.ps1', 'Start-DevBox.ps1',
            'Set-NoAutoRestart.cmd', 'Remove-Synergy.cmd', 'desk-console.ico',
            'mobile\rustdesk-android.png', 'mobile\rustdesk-ios.png', 'whats-new.txt', 'version.txt'
# per-user tasks setup creates; both start PowerShell on a script in $Dir
$Tasks    = 'DeskConsole Deskflow trust sync', 'DeskConsole dev box resume'

function Say($m, $c = 'Cyan') { if (-not $Quiet) { Write-Host "[Desk Console] $m" -ForegroundColor $c } }

# [version] of version.txt in a folder, or $null
function Get-DcVersion($folder) {
    try { [version]"$(Get-Content (Join-Path $folder 'version.txt') -TotalCount 1 -ErrorAction Stop)".Trim() } catch { $null }
}

if ($Uninstall) {
    Set-Location $env:TEMP
    # Installed by DeskConsoleSetup.exe: its own uninstaller also removes its Settings > Apps entry
    $inno = Get-ItemProperty $InnoKey -ErrorAction SilentlyContinue
    if ($inno -and $inno.UninstallString) {
        Start-Process "$($inno.UninstallString)".Trim('"')
        Say 'Started the Desk Console uninstaller.' Green
        return
    }
    Get-Process powershell -ErrorAction SilentlyContinue |
        Where-Object { $_.Id -ne $PID -and (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine -match 'DeskConsole\\Desk-Console\.ps1' } |
        Stop-Process -Force -ErrorAction SilentlyContinue   # one that just exited must not stop the uninstall
    # Left behind, these start a PowerShell against a deleted script: the trust-sync task every
    # 2 minutes, the dev box task at every sign-in. The "lock after auto sign-in" task stays: it
    # needs no file here, and removing it would leave a PC that still signs in by itself unlocked.
    foreach ($t in $Tasks) {
        try { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    }
    $Lnks.Values | ForEach-Object { Remove-Item $_ -ErrorAction SilentlyContinue }
    Remove-Item $Key -Recurse -ErrorAction SilentlyContinue
    # the app's own per-user settings (window position); HKLM\SOFTWARE\DeskConsole is setup's record
    # of what it changed on the PC and stays
    Remove-Item 'HKCU:\Software\DeskConsole' -Recurse -ErrorAction SilentlyContinue
    Remove-Item $Dir -Recurse -Force -ErrorAction SilentlyContinue
    Say 'Uninstalled. Still on this PC: the saved RustDesk password (Credential Manager, DeskConsole:RustDesk), the share login, and automatic sign-in with its screen lock if it is on.' Green
    return
}

$src = if (Test-Path (Join-Path $Share 'Desk-Console.ps1')) { $Share } else { $PSScriptRoot }
# run from the install folder itself (the share offline): nothing to copy, just refresh the rest
$fromSelf = (ConvertTo-Unc $src).TrimEnd('\') -eq $Dir.TrimEnd('\')

# E2: no downgrade. Setup-Synergy.ps1 runs this from the shared folder, which can be older than
# what is installed (a newer DeskConsoleSetup run on this PC).
$have = Get-DcVersion $Dir
$new  = Get-DcVersion $src
if (-not $Force -and -not $fromSelf -and $have -and $new -and $new -lt $have) {
    Say "Desk Console $have is installed; $src has the older $new, so nothing was changed (-Force installs it anyway)." Yellow
    return
}

New-Item -ItemType Directory -Force $Dir | Out-Null
if (-not $fromSelf) {
    foreach ($f in $Files) {
        $from = Join-Path $src $f; $to = Join-Path $Dir $f
        if (-not (Test-Path $from)) { continue }   # optional files (e.g. phone QR images) a share may not have yet
        New-Item -ItemType Directory -Force (Split-Path $to -Parent) | Out-Null
        Copy-Item $from $to -Force
    }
    # site.json tells the installed copy where the shared folder is: the share's own, else one
    # that points at the folder we installed from
    if (Test-Path (Join-Path $src 'site.json')) { Copy-Item (Join-Path $src 'site.json') (Join-Path $Dir 'site.json') -Force }
    elseif (-not (Test-Path (Join-Path $Dir 'site.json'))) {
        # UTF-8, not ascii: an ascii write stored a folder such as C:\Users\Jose with an accent as '?' (R8)
        [pscustomobject]@{ shareRoot = $src } | ConvertTo-Json | Set-Content (Join-Path $Dir 'site.json') -Encoding UTF8
    }
}
$ver = (Get-Content (Join-Path $Dir 'version.txt') -TotalCount 1).Trim()

$app  = Join-Path $Dir 'Desk-Console.ps1'
$icon = Join-Path $Dir 'desk-console.ico'
$wsh  = $null
function New-Lnk($path, [string]$extra = '') {
    if (-not $script:wsh) { $script:wsh = New-Object -ComObject WScript.Shell }
    $l = $script:wsh.CreateShortcut($path)
    $l.TargetPath = Join-Path $env:WINDIR 'System32\conhost.exe'
    $l.Arguments = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$app`"$extra"
    $l.WorkingDirectory = $Dir; $l.IconLocation = "$icon,0"
    $l.Description = 'Keyboard + mouse sharing and RustDesk for every PC'
    $l.Save()
}

# Installed by DeskConsoleSetup.exe (Inno Setup)? It owns the shortcuts and the
# Settings > Apps entry, so a self-update only refreshes the files -- and turns an older
# sign-in shortcut into one that starts in the notification area (contract C-9: -Tray).
if (Test-Path $InnoKey) {
    Set-ItemProperty $InnoKey -Name DisplayVersion -Value $ver
    try { if (Test-Path $Lnks.Startup) { New-Lnk $Lnks.Startup ' -Tray' } } catch {}   # the files are in: never fail on this
    Say "Updated Desk Console files to $ver (setup-installed copy)." Green
    return
}

# A self-update (-Quiet) refreshes the shortcuts that exist and brings back none the user removed.
New-Lnk $Lnks.StartMenu
if ($NoDesktop) { Remove-Item $Lnks.Desktop -ErrorAction SilentlyContinue }
elseif (-not $Quiet -or (Test-Path $Lnks.Desktop)) { New-Lnk $Lnks.Desktop }
if ($AutoStart -or ($Quiet -and (Test-Path $Lnks.Startup))) { New-Lnk $Lnks.Startup ' -Tray' }
elseif ($NoAutoStart) { Remove-Item $Lnks.Startup -ErrorAction SilentlyContinue }   # only when asked: setup's repair calls this without arguments
elseif (Test-Path $Lnks.Startup) { New-Lnk $Lnks.Startup ' -Tray' }

# Never New-Item -Force on an existing registry key: it deletes the key first, values and all (R1).
if (-not (Test-Path $Key)) { New-Item $Key -Force | Out-Null }
$props = @{
    DisplayName = 'Desk Console'; DisplayVersion = $ver; Publisher = 'James VanDusen'
    DisplayIcon = $icon; InstallLocation = $Dir; NoModify = 1; NoRepair = 1
    EstimatedSize = [int]((Get-ChildItem $Dir | Measure-Object Length -Sum).Sum / 1KB)
    UninstallString = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$Dir\Install-DeskConsole.ps1`" -Uninstall"
}
foreach ($k in $props.Keys) {
    $type = if ($props[$k] -is [int]) { 'DWord' } else { 'String' }
    New-ItemProperty $Key -Name $k -Value $props[$k] -PropertyType $type -Force | Out-Null
}
Say "Installed Desk Console $ver -> $Dir" Green
Say "Start Menu$(if (Test-Path $Lnks.Desktop) {' + Desktop'})$(if (Test-Path $Lnks.Startup) {' + start at sign-in (notification area)'}). Uninstall from Settings > Apps."
