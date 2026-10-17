<#
  Install-DeskConsole.ps1 -- per-user install of Desk Console (no admin).
    Install:    Install-DeskConsole.cmd            [-AutoStart] [-NoDesktop]
    Uninstall:  Settings > Apps > Desk Console, or Install-DeskConsole.cmd -Uninstall

  Installs to %LOCALAPPDATA%\Programs\DeskConsole: the app, its icon and this
  installer (the uninstaller). Start Menu + Desktop shortcuts, optional
  sign-in start, and an entry in Settings > Apps. Shortcuts launch through
  `conhost --headless` so no console window flashes.
  The installed app updates itself: on launch it compares version.txt on the
  share with its own version and reinstalls from the share when it is newer.
  site.json (from the shared folder, or written here) tells the installed copy where the share is.
#>
param([switch]$AutoStart, [switch]$NoDesktop, [switch]$Uninstall, [switch]$Quiet)
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
$Files    = 'Desk-Console.ps1', 'desk-console.ico', 'version.txt', 'Install-DeskConsole.ps1', 'Setup-Synergy.ps1',
            'Set-NoAutoRestart.cmd', 'Start-DevBox.ps1', 'mobile\rustdesk-android.png', 'mobile\rustdesk-ios.png'

function Say($m, $c = 'Cyan') { if (-not $Quiet) { Write-Host "[Desk Console] $m" -ForegroundColor $c } }

if ($Uninstall) {
    Set-Location $env:TEMP
    Get-Process powershell -ErrorAction SilentlyContinue |
        Where-Object { $_.Id -ne $PID -and (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine -match 'DeskConsole\\Desk-Console\.ps1' } |
        Stop-Process -Force
    $Lnks.Values | ForEach-Object { Remove-Item $_ -ErrorAction SilentlyContinue }
    Remove-Item $Key -Recurse -ErrorAction SilentlyContinue
    Remove-Item $Dir -Recurse -Force -ErrorAction SilentlyContinue
    Say 'Uninstalled. (The saved RustDesk password stays in Credential Manager as DeskConsole:RustDesk.)' Green
    return
}

$src = if (Test-Path (Join-Path $Share 'Desk-Console.ps1')) { $Share } else { $PSScriptRoot }
New-Item -ItemType Directory -Force $Dir | Out-Null
foreach ($f in $Files) {
    $from = Join-Path $src $f; $to = Join-Path $Dir $f
    if (-not (Test-Path $from)) { continue }   # optional files (e.g. phone QR images) a share may not have yet
    New-Item -ItemType Directory -Force (Split-Path $to -Parent) | Out-Null
    Copy-Item $from $to -Force
}
# site.json tells the installed copy where the shared folder is: the share's own, else one
# that points at the folder we installed from
if (Test-Path (Join-Path $src 'site.json')) { Copy-Item (Join-Path $src 'site.json') (Join-Path $Dir 'site.json') -Force }
elseif (-not (Test-Path (Join-Path $Dir 'site.json')) -and $src -ne $Dir) {
    [pscustomobject]@{ shareRoot = $src } | ConvertTo-Json | Set-Content (Join-Path $Dir 'site.json') -Encoding ascii
}
$ver = (Get-Content (Join-Path $Dir 'version.txt') -TotalCount 1).Trim()

# Installed by DeskConsoleSetup.exe (Inno Setup)? It owns the shortcuts and the
# Settings > Apps entry, so a self-update only refreshes the files.
$InnoKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DeskConsole_is1'
if (Test-Path $InnoKey) {
    Copy-Item (Join-Path $src 'Setup-Synergy.ps1') (Join-Path $Dir 'Setup-Synergy.ps1') -Force -ErrorAction SilentlyContinue
    Set-ItemProperty $InnoKey -Name DisplayVersion -Value $ver
    Say "Updated Desk Console files to $ver (setup-installed copy)." Green
    return
}

$app  = Join-Path $Dir 'Desk-Console.ps1'
$icon = Join-Path $Dir 'desk-console.ico'
$wsh  = New-Object -ComObject WScript.Shell
function New-Lnk($path) {
    $l = $wsh.CreateShortcut($path)
    $l.TargetPath = Join-Path $env:WINDIR 'System32\conhost.exe'
    $l.Arguments = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$app`""
    $l.WorkingDirectory = $Dir; $l.IconLocation = "$icon,0"
    $l.Description = 'Keyboard + mouse sharing and RustDesk for every PC'
    $l.Save()
}
New-Lnk $Lnks.StartMenu
if ($NoDesktop) { Remove-Item $Lnks.Desktop -ErrorAction SilentlyContinue } else { New-Lnk $Lnks.Desktop }
if ($AutoStart) { New-Lnk $Lnks.Startup } elseif (-not $Quiet) { Remove-Item $Lnks.Startup -ErrorAction SilentlyContinue }

New-Item $Key -Force | Out-Null
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
Say "Start Menu$(if (-not $NoDesktop) {' + Desktop'})$(if ($AutoStart) {' + start at sign-in'}). Uninstall from Settings > Apps."
