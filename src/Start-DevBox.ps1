<#
  Start-DevBox.ps1 -- on a dev box, reopen VS Code on a folder and resume Claude Code at sign-in.

  Configure (as the user who signs in; no admin):
    Start-DevBox.ps1 -Configure -Folder D:\repos\myproject [-Claude] [-NoCode] [-DelaySec 20]
    Start-DevBox.ps1 -Disable
  Run now (what the sign-in task does, minus the delay):
    Start-DevBox.ps1 -Now

  -Configure writes devbox.json next to this script and registers the per-user scheduled task
  "DeskConsole dev box resume" (at log on). At sign-in the task waits DelaySec, then:
    - opens VS Code on the folder (VS Code's "window.restoreWindows" -- default "all" -- brings
      back the other windows; -Configure sets it back to "all" if it was changed)
    - with -Claude, opens a terminal in the folder running `claude --continue`, which picks up
      the last Claude Code conversation in that folder. (The VS Code extension does not start a
      chat by itself, so the CLI is what resumes.)
  devbox.log next to this script records the last run.
#>
param(
    [switch]$Configure,
    [string]$Folder = '',
    [switch]$Claude,
    [switch]$NoCode,
    [int]$DelaySec = 20,
    [switch]$Disable,
    [switch]$Now
)
$ErrorActionPreference = 'Stop'
$Conf = Join-Path $PSScriptRoot 'devbox.json'
$Log  = Join-Path $PSScriptRoot 'devbox.log'
$Task = 'DeskConsole dev box resume'

function Write-Log($m) { "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')  $m" | Add-Content $Log -Encoding ascii; Write-Host $m }

function Find-Code {
    foreach ($p in (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\Code.exe'),
                   (Join-Path $env:ProgramFiles 'Microsoft VS Code\Code.exe')) { if (Test-Path $p) { return $p } }
    $cmd = (Get-Command code -ErrorAction SilentlyContinue).Source      # ...\Microsoft VS Code\bin\code.cmd
    if ($cmd) { $exe = Join-Path (Split-Path (Split-Path $cmd -Parent) -Parent) 'Code.exe'; if (Test-Path $exe) { return $exe } }
    $null
}
function Find-Claude {
    $c = (Get-Command claude -ErrorAction SilentlyContinue).Source
    if ($c) { return $c }
    foreach ($p in (Join-Path $env:USERPROFILE '.local\bin\claude.exe'), (Join-Path $env:APPDATA 'npm\claude.cmd')) { if (Test-Path $p) { return $p } }
    $null
}

# ------------------------------------------------------------ off
if ($Disable) {
    Unregister-ScheduledTask -TaskName $Task -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path $Conf) { Remove-Item $Conf -Force }
    Write-Host 'Dev box resume is off.'
    return
}

# ------------------------------------------------------------ configure
if ($Configure) {
    $Folder = $Folder.Trim().TrimEnd('\')
    if (-not $Folder -or -not (Test-Path $Folder -PathType Container)) { throw "Folder not found: '$Folder'" }
    if ($NoCode -and -not $Claude) { throw 'Nothing to do: choose VS Code, Claude, or both.' }
    [pscustomobject]@{ folder = $Folder; openCode = -not $NoCode; resumeClaude = [bool]$Claude; delaySec = $DelaySec } |
        ConvertTo-Json | Set-Content $Conf -Encoding ascii

    $act = New-ScheduledTaskAction -Execute (Join-Path $env:WINDIR 'System32\conhost.exe') `
        -Argument "--headless $env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    $trg = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $Task -Action $act -Trigger $trg -Settings $set -Force | Out-Null

    # VS Code restores every window by default ("all"); put it back if someone changed it.
    # Text edit only -- settings.json may hold comments, which a JSON parser would reject.
    $vs = Join-Path $env:APPDATA 'Code\User\settings.json'
    if (Test-Path $vs) {
        $t = Get-Content $vs -Raw
        if ($t -match '"window\.restoreWindows"\s*:\s*"(?!all")[^"]*"') {
            Copy-Item $vs "$vs.deskconsole.bak" -Force
            [IO.File]::WriteAllText($vs, ($t -replace '"window\.restoreWindows"\s*:\s*"[^"]*"', '"window.restoreWindows": "all"'))
            Write-Host 'VS Code: window.restoreWindows set back to "all" (backup: settings.json.deskconsole.bak).'
        }
    }
    $what = @(); if (-not $NoCode) { $what += 'VS Code' }; if ($Claude) { $what += 'claude --continue' }
    Write-Host "Dev box resume ON for $env:USERNAME`: $($what -join ' + ') in $Folder, $DelaySec s after sign-in."
    if (-not $NoCode -and -not (Find-Code)) { Write-Host 'Note: VS Code was not found on this PC yet.' -ForegroundColor Yellow }
    if ($Claude -and -not (Find-Claude)) { Write-Host 'Note: the claude command was not found on this PC yet.' -ForegroundColor Yellow }
    return
}

# ------------------------------------------------------------ run (sign-in task, or -Now)
if (-not (Test-Path $Conf)) { return }
$c = Get-Content $Conf -Raw | ConvertFrom-Json
if (-not $Now) { Start-Sleep -Seconds ([int]$c.delaySec) }
if (-not (Test-Path $c.folder)) { Write-Log "folder missing: $($c.folder)"; return }

if ($c.openCode) {
    $code = Find-Code
    if ($code) { Start-Process $code -ArgumentList "`"$($c.folder)`""; Write-Log "VS Code: $($c.folder)" }
    else { Write-Log 'VS Code not found' }
}
if ($c.resumeClaude) {
    $cl = Find-Claude
    if (-not $cl) { Write-Log 'claude not found (install Claude Code, or add it to PATH)' }
    else {
        $ps  = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $run = "& '$($cl.Replace("'", "''"))' --continue"
        $wt  = (Get-Command wt.exe -ErrorAction SilentlyContinue).Source
        if ($wt) {   # Windows Terminal: one tab in the folder ("wt" splits commands on ';', so none here)
            Start-Process $wt -ArgumentList "-d `"$($c.folder)`" --title `"Claude (resumed)`" `"$ps`" -NoExit -Command `"$run`""
        } else {
            Start-Process $ps -WorkingDirectory $c.folder -ArgumentList '-NoExit', '-Command', $run
        }
        Write-Log "claude --continue: $($c.folder)"
    }
}
