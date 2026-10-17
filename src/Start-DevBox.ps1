<#
  Start-DevBox.ps1 -- on a dev box, reopen VS Code and resume Claude Code at sign-in, for one or
  more folders.

  Configure (as the user who signs in; no admin):
    Start-DevBox.ps1 -Configure -Folder D:\repos\app [-Claude] [-NoCode] [-DelaySec 20]
        the first folder (what the installer and older Desk Console set; other folders stay)
    Start-DevBox.ps1 -Configure -AddFolder D:\repos\tools [-Claude] [-NoCode]
        one more folder, or new choices for one already in the list
    Start-DevBox.ps1 -Configure -RemoveFolder D:\repos\tools      (removing the last one = -Disable)
    Start-DevBox.ps1 -Configure -Items <list>                     the whole list, in order:
        @(@{ path = 'D:\repos\app'; code = $true; claude = $true }, @{ path = 'E:\site'; code = $true; claude = $false })
        or the same as JSON: '[{"path":"D:\\repos\\app","code":true,"claude":true}]'   (an empty list = -Disable)
    Start-DevBox.ps1 -Disable
  Run now (what the sign-in task does, minus the delay):
    Start-DevBox.ps1 -Now

  devbox.json next to this script:
    { "items": [ { "path": "D:\\repos\\app", "code": true, "claude": true }, ... ], "delaySec": 20,
      "folder": ..., "openCode": ..., "resumeClaude": ... }   <- item 1 again, for 1.6.0 readers
  A 1.6.0 file, { folder, openCode, resumeClaude, delaySec }, still works: it is item 1.
  A folder must exist when it is added; one already in the list is kept while it is missing
  (an unplugged drive): the sign-in run logs it and carries on.

  -Configure registers the per-user scheduled task "DeskConsole dev box resume" (at log on). At
  sign-in the task waits delaySec, then for every folder in the list:
    - code: opens VS Code on it (VS Code's "window.restoreWindows" -- default "all" -- brings back
      the other windows; -Configure sets it back to "all" if it was changed)
    - claude: runs `claude --continue` there, which picks up the last Claude Code conversation in
      that folder: one tab per folder in a Windows Terminal window named "devbox" (without
      Windows Terminal, one PowerShell window each). The VS Code extension does not start a
      chat by itself, so the CLI is what resumes.
  devbox.log next to this script records each run.
#>
param(
    [switch]$Configure,
    [string]$Folder = '',
    [string]$AddFolder = '',
    [string]$RemoveFolder = '',
    [object[]]$Items,
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

# UTF-8, not ascii: a folder under an accented user name was stored and logged with '?' (R8)
function Write-Log($m) { "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')  $m" | Add-Content -LiteralPath $Log -Encoding UTF8; Write-Host $m }

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

# One argument for a Windows command line (CommandLineToArgvW rules, which Code.exe, wt.exe and
# powershell.exe follow): in quotes, backslashes doubled before a quote and at the end -- "D:\"
# would otherwise escape its own closing quote and swallow the next argument (R8).
function ConvertTo-NativeArg([string]$s) {
    $s = [regex]::Replace($s, '(\\*)"', { param($m) ($m.Groups[1].Value * 2) + '\"' })
    '"' + ($s -replace '(\\+)$', '$1$1') + '"'
}

# "C:\x\" -> "C:\x", but "D:\" stays: "D:" alone is the current folder on D:, not its root (R8)
function Get-DevBoxPath([string]$p) {
    $p = "$p".Trim().Trim('"').Trim()
    if ($p.Length -gt 3) { $p = $p.TrimEnd([char[]]'\/') }
    if ($p -match '^[A-Za-z]:$') { $p += '\' }
    $p
}

function ConvertTo-DevBoxBool($v, [bool]$default) {
    if ($null -eq $v) { return $default }
    if ($v -is [string]) { return $v.Trim() -match '^(1|true|yes|on)$' }   # [bool]'false' is $true
    [bool]$v
}

function New-DevBoxItem([string]$path) { [pscustomobject]@{ path = Get-DevBoxPath $path; code = -not $NoCode; claude = [bool]$Claude } }

# -Items, JSON text or devbox.json -> {path, code, claude}. The 1.6.0 names (folder, openCode,
# resumeClaude) are read too; a bare folder path takes -NoCode / -Claude.
function ConvertTo-DevBoxItem($raw) {
    foreach ($r in @($raw)) {
        if ($null -eq $r) { continue }
        if ($r -is [string]) {
            $t = $r.Trim()
            if ($t.StartsWith('[') -or $t.StartsWith('{')) {
                $j = ConvertFrom-Json $t
                if ($j -isnot [array] -and $null -ne $j.items) { $j = $j.items }   # a whole devbox.json
                ConvertTo-DevBoxItem $j
            } else { New-DevBoxItem $t }
            continue
        }
        $p = $r.path;   if ($null -eq $p) { $p = $r.folder }
        $c = $r.code;   if ($null -eq $c) { $c = $r.openCode }
        $l = $r.claude; if ($null -eq $l) { $l = $r.resumeClaude }
        [pscustomobject]@{ path = Get-DevBoxPath "$p"; code = ConvertTo-DevBoxBool $c $true; claude = ConvertTo-DevBoxBool $l $false }
    }
}

# One entry per folder (paths compare case-insensitively); a repeat adds its choices to the first.
function Merge-DevBoxItem($list) {
    $out = New-Object Collections.Generic.List[object]
    foreach ($i in @($list)) {
        $dup = $null
        foreach ($o in $out) { if ($o.path -eq $i.path) { $dup = $o; break } }
        if ($dup) { $dup.code = $dup.code -or $i.code; $dup.claude = $dup.claude -or $i.claude }
        else { $out.Add([pscustomobject]@{ path = $i.path; code = [bool]$i.code; claude = [bool]$i.claude }) }
    }
    $out
}

function Read-DevBoxConf {
    if (-not (Test-Path -LiteralPath $Conf)) { return $null }
    $c = Get-Content -LiteralPath $Conf -Raw -Encoding UTF8 | ConvertFrom-Json
    $list = @()
    if ($null -ne $c.items) { $list = @(ConvertTo-DevBoxItem @($c.items)) }
    elseif ($c.folder) { $list = @(ConvertTo-DevBoxItem $c) }   # 1.6.0: { folder, openCode, resumeClaude, delaySec }
    # a hand-edited entry without a folder is skipped, not fatal; a repeated folder is merged, so
    # it never gets two tabs running claude --continue on the same conversation
    $list = @(Merge-DevBoxItem @($list | Where-Object { "$($_.path)".Trim() }))
    $d = 20; if ($null -ne $c.delaySec) { $d = [int]$c.delaySec }
    # at most 5 minutes: the sign-in task is stopped after 10, and the folders still need to open
    [pscustomobject]@{ Items = $list; DelaySec = [math]::Max(0, [math]::Min(300, $d)) }
}

function Save-DevBoxConf($list, [int]$delay) {
    $first = $list[0]
    $o = [ordered]@{
        items        = @($list | ForEach-Object { [ordered]@{ path = $_.path; code = [bool]$_.code; claude = [bool]$_.claude } })
        delaySec     = $delay
        folder       = $first.path        # item 1 again: the installer's dev box page and 1.6.0 read these
        openCode     = [bool]$first.code
        resumeClaude = [bool]$first.claude
    }
    $tmp = "$Conf.tmp"   # written whole, then moved over: a half-written file would skip a sign-in
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $o -Depth 5), (New-Object Text.UTF8Encoding $true))
    Move-Item -LiteralPath $tmp -Destination $Conf -Force
}

function Register-DevBoxTask {
    $act = New-ScheduledTaskAction -Execute (Join-Path $env:WINDIR 'System32\conhost.exe') `
        -Argument "--headless $env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    $trg = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $Task -Action $act -Trigger $trg -Settings $set -Force | Out-Null
}

function Disable-DevBox {
    Unregister-ScheduledTask -TaskName $Task -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Conf) { Remove-Item -LiteralPath $Conf -Force }
    Write-Host 'Dev box resume is off.'
}

# VS Code restores every window by default ("all"); put it back if someone changed it.
# Text edit only -- settings.json may hold comments, which a JSON parser would reject. It is
# UTF-8 without a BOM: read as ANSI, any non-ASCII text in it would be written back garbled.
function Reset-VsCodeRestoreWindows {
    $vs = Join-Path $env:APPDATA 'Code\User\settings.json'
    if (-not (Test-Path -LiteralPath $vs)) { return }
    $t = Get-Content -LiteralPath $vs -Raw -Encoding UTF8
    if ($t -match '"window\.restoreWindows"\s*:\s*"(?!all")[^"]*"') {
        Copy-Item -LiteralPath $vs -Destination "$vs.deskconsole.bak" -Force
        [IO.File]::WriteAllText($vs, ($t -replace '"window\.restoreWindows"\s*:\s*"[^"]*"', '"window.restoreWindows": "all"'))
        Write-Host 'VS Code: window.restoreWindows set back to "all" (backup: settings.json.deskconsole.bak).'
    }
}

function Format-DevBoxItem($i) {
    $w = @(); if ($i.code) { $w += 'VS Code' }; if ($i.claude) { $w += 'claude --continue' }
    "$($w -join ' + ') in $($i.path)"
}

# One Windows Terminal tab per folder, all in one window named "devbox". wt splits its command
# line on every ';', so a folder (or claude path) with one gets its own PowerShell window.
function Start-DevBoxClaude([string]$path, [string]$claudeExe, [int]$tabs) {
    $ps   = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $run  = "& '$($claudeExe.Replace("'", "''"))' --continue"
    $leaf = [IO.Path]::GetFileName($path.TrimEnd('\')); if (-not $leaf) { $leaf = $path }
    $wt   = (Get-Command wt.exe -ErrorAction SilentlyContinue).Source
    $a = "-w devbox new-tab -d $(ConvertTo-NativeArg $path) --title $(ConvertTo-NativeArg "Claude: $leaf") " +
         "$(ConvertTo-NativeArg $ps) -NoExit -Command $(ConvertTo-NativeArg $run)"
    if ($wt -and $a -notmatch ';') {
        # the first call creates the window (a cold start after sign-in takes seconds); a second
        # call before it exists would open another window instead of a tab
        if ($tabs -eq 1) { Start-Sleep -Seconds 3 } elseif ($tabs -gt 1) { Start-Sleep -Seconds 1 }
        Start-Process -FilePath $wt -ArgumentList $a
        Write-Log "claude --continue: $path (Windows Terminal tab)"
        return ($tabs + 1)
    }
    Start-Process -FilePath $ps -WorkingDirectory $path -ArgumentList "-NoExit -Command $(ConvertTo-NativeArg $run)"
    Write-Log "claude --continue: $path"
    $tabs
}

# ------------------------------------------------------------ off
if ($Disable) { Disable-DevBox; return }

# ------------------------------------------------------------ configure
if ($Configure) {
    $cur = $null
    try { $cur = Read-DevBoxConf } catch { Write-Host "devbox.json could not be read and is replaced: $($_.Exception.Message)" -ForegroundColor Yellow }
    $before = @(); if ($cur) { $before = @($cur.Items) }
    $list = New-Object Collections.Generic.List[object]
    foreach ($i in $before) { $list.Add($i) }
    $delay = $DelaySec; if ($cur -and -not $PSBoundParameters.ContainsKey('DelaySec')) { $delay = $cur.DelaySec }
    foreach ($k in 'Folder', 'AddFolder') {   # 1.6.0 said this for an empty folder box too
        if ($PSBoundParameters.ContainsKey($k) -and -not "$($PSBoundParameters[$k])".Trim()) { throw "Folder not found: ''" }
    }
    $added = @()   # what this call adds or changes: those folders must exist now
    if ($PSBoundParameters.ContainsKey('Items')) {
        $list.Clear()
        foreach ($i in @(ConvertTo-DevBoxItem $Items)) { $list.Add($i); $added += $i }
    }
    if ($Folder) {   # folder 1 is replaced; the others stay (the installer only knows one folder)
        $n = New-DevBoxItem $Folder; $added += $n
        if ($list.Count) { $list.RemoveAt(0) }
        for ($x = $list.Count - 1; $x -ge 0; $x--) { if ($list[$x].path -eq $n.path) { $list.RemoveAt($x) } }
        $list.Insert(0, $n)
    }
    if ($AddFolder) {
        $n = New-DevBoxItem $AddFolder; $added += $n
        $hit = $false
        foreach ($i in $list) { if ($i.path -eq $n.path) { $i.code = $n.code; $i.claude = $n.claude; $hit = $true } }
        if (-not $hit) { $list.Add($n) }
    }
    if ($RemoveFolder) {
        $r = Get-DevBoxPath $RemoveFolder; $was = $list.Count
        for ($x = $list.Count - 1; $x -ge 0; $x--) { if ($list[$x].path -eq $r) { $list.RemoveAt($x) } }
        if ($list.Count -eq $was) { throw "Not in the dev box list: '$r'" }
    }
    if (-not ($PSBoundParameters.ContainsKey('Items') -or $Folder -or $AddFolder -or $RemoveFolder -or $list.Count)) {
        throw 'Nothing to configure: give -Folder, -AddFolder or -Items.'
    }
    foreach ($n in $added) {
        if (-not $n.path) { throw 'A dev box entry has no folder.' }
        if (-not $n.code -and -not $n.claude) { throw "Nothing to do for '$($n.path)': choose VS Code, Claude, or both." }
        $known = @($before | Where-Object { $_.path -eq $n.path }).Count
        if (-not $known -and -not (Test-Path -LiteralPath $n.path -PathType Container)) { throw "Folder not found: '$($n.path)'" }
    }
    $final = @(Merge-DevBoxItem @($list | Where-Object { $_.path -and ($_.code -or $_.claude) }))
    if (-not $final.Count) { Disable-DevBox; return }   # the last folder removed, or an empty list

    Save-DevBoxConf $final $delay
    Register-DevBoxTask
    $anyCode = @($final | Where-Object { $_.code }).Count -gt 0
    $anyClaude = @($final | Where-Object { $_.claude }).Count -gt 0
    if ($anyCode) { Reset-VsCodeRestoreWindows }
    Write-Host "Dev box resume ON for $env:USERNAME, $delay s after sign-in:"
    foreach ($i in $final) { Write-Host "  $(Format-DevBoxItem $i)" }
    if ($anyCode -and -not (Find-Code)) { Write-Host 'Note: VS Code was not found on this PC yet.' -ForegroundColor Yellow }
    if ($anyClaude -and -not (Find-Claude)) { Write-Host 'Note: the claude command was not found on this PC yet.' -ForegroundColor Yellow }
    return
}

# ------------------------------------------------------------ run (sign-in task, or -Now)
$c = $null
try { $c = Read-DevBoxConf } catch { Write-Log "devbox.json unreadable: $($_.Exception.Message)"; return }
if (-not $c -or -not @($c.Items).Count) { return }
if (-not $Now) { Start-Sleep -Seconds $c.DelaySec }
$here = @(foreach ($i in $c.Items) {
    if (Test-Path -LiteralPath $i.path -PathType Container) { $i } else { Write-Log "folder missing: $($i.path)" }
})

$code = $null; $first = $true
foreach ($i in @($here | Where-Object { $_.code })) {
    if (-not $code) { $code = Find-Code; if (-not $code) { Write-Log 'VS Code not found'; break } }
    if (-not $first) { Start-Sleep -Seconds 1 }   # later folders go to the instance the first one started
    $first = $false
    try { Start-Process -FilePath $code -ArgumentList (ConvertTo-NativeArg $i.path); Write-Log "VS Code: $($i.path)" }
    catch { Write-Log "VS Code failed for $($i.path): $($_.Exception.Message)" }
}

$cl = $null; $tabs = 0
foreach ($i in @($here | Where-Object { $_.claude })) {
    if (-not $cl) { $cl = Find-Claude; if (-not $cl) { Write-Log 'claude not found (install Claude Code, or add it to PATH)'; break } }
    try { $tabs = Start-DevBoxClaude $i.path $cl $tabs } catch { Write-Log "claude failed for $($i.path): $($_.Exception.Message)" }
}
