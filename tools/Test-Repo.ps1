<#
  Test-Repo.ps1 -- the static checks to run before every build; CI runs them on every push
  (.github\workflows\ci.yml). Read-only: it parses and reads files and runs nothing from src\.

    powershell -ExecutionPolicy Bypass -File tools\Test-Repo.ps1 [-SkipAnalyzer]

  Each check is here because of something that went wrong, or nearly did:
    parse     every *.ps1 parses with 0 errors in THIS PowerShell (CI runs it in 5.1 and in 7), and
              no PowerShell 7-only parameter is used: the PCs run Windows PowerShell 5.1.
    ascii     *.ps1, *.cmd and *.iss are ASCII only. 5.1 reads a .ps1 that has no BOM in the ANSI
              code page, so one smart quote or arrow corrupts a string or breaks the parse.
    version   src\version.txt is the only version. A hard-coded $AppVersion that misses a bump makes
              every installed Desk Console reinstall and relaunch itself, hidden, forever.
              The installer's AppVersion comes from it, CHANGELOG.md has its section, and the first
              line of src\whats-new.txt (shown once after each update) names it.
    files     the three installed-file lists agree: DeskConsole.iss [Files], its AppFile list (files
              set aside before copying -- the 'file locked mid-install' fix) and Install-DeskConsole.ps1
              $Files (self-update), with version.txt copied last so a half-done update is retried.
              Every src\*.ps1 is in them (a script no list installs is missing on every PC).
    params    every parameter (and ValidateSet value) the installer, the .cmd launchers and Desk
              Console pass to Setup-Synergy.ps1 is one it declares: the installer runs the steps
              hidden, so an unknown one would fail a whole step with nothing on screen.
    agent     Setup-Synergy.ps1 still has the functions and variables Agent.ps1 uses (contract
              C-10); the agent skips a missing one quietly, which would switch self-healing off.
    pins      tools\Test-Pins.ps1: bundled versions, hashes, phone APK links and QR codes agree.
    analyzer  PSScriptAnalyzer when it is installed (or bundled with VS Code's PowerShell extension):
              PSUseCompatibleSyntax for 5.1 and every Error-severity rule (tools\PSScriptAnalyzerSettings.psd1).
  Every check runs even when an earlier one fails. Exit 1 when anything failed.
#>
param([switch]$SkipAnalyzer)
$ErrorActionPreference = 'Stop'
$Repo = Split-Path $PSScriptRoot -Parent
$script:Fails = 0
function Pass($m) { Write-Host "  ok    $m" -ForegroundColor Green }
function Fail($m) { Write-Host "  FAIL  $m" -ForegroundColor Red; $script:Fails++ }
function Note($m) { Write-Host "  note  $m" -ForegroundColor Yellow }
function Rel($f) { $f.FullName.Substring($Repo.Length + 1) }
function Get-RepoFiles([string[]]$patterns) {
    Get-ChildItem $Repo -Recurse -File -Include $patterns |
        Where-Object { $_.FullName.Substring($Repo.Length) -notmatch '^\\(\.git|\.vscode|dist|installer\\redist|node_modules)\\' }
}
function Invoke-Check([string]$title, [scriptblock]$body) {
    Write-Host $title
    try { & $body } catch { Fail "the check itself failed: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- parse
# 7-only parameters do not fail a 5.1 parse (they are only names), so they are listed here.
$Ps7Only = @{
    'ForEach-Object' = 'Parallel'; 'ConvertFrom-Json' = 'AsHashtable', 'Depth', 'NoEnumerate'
    'ConvertTo-Json' = 'AsArray', 'EnumsAsStrings', 'EscapeHandling'
    'Get-Content' = 'AsByteStream'; 'Set-Content' = 'AsByteStream'; 'Add-Content' = 'AsByteStream'
    'Join-Path' = 'AdditionalChildPath'; 'Split-Path' = 'LeafBase', 'Extension'
    'Invoke-WebRequest' = 'SkipCertificateCheck', 'SkipHttpErrorCheck'; 'Invoke-RestMethod' = 'SkipCertificateCheck', 'SkipHttpErrorCheck', 'StatusCodeVariable'
    'Get-Date' = 'AsUTC', 'UnixTimeSeconds'; 'Test-Connection' = 'TargetName', 'TcpPort'
    'Select-String' = 'Raw', 'NoEmphasis'; 'Start-Process' = 'Environment'
}
$Aliases = @{ '%' = 'ForEach-Object'; 'foreach' = 'ForEach-Object'; 'gc' = 'Get-Content'; 'cat' = 'Get-Content'; 'type' = 'Get-Content'
              'sc' = 'Set-Content'; 'ac' = 'Add-Content'; 'iwr' = 'Invoke-WebRequest'; 'irm' = 'Invoke-RestMethod'; 'sls' = 'Select-String' }
Invoke-Check "parse  (PowerShell $($PSVersionTable.PSVersion))" {
    $n = 0
    foreach ($f in Get-RepoFiles '*.ps1', '*.psm1', '*.psd1') {
        $tok = $null; $err = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tok, [ref]$err)
        foreach ($e in @($err | Where-Object { $_ })) { Fail "$(Rel $f):$($e.Extent.StartLineNumber): $($e.Message)" }
        foreach ($c in $ast.FindAll({ param($x) $x -is [Management.Automation.Language.CommandAst] }, $true)) {
            $name = $c.GetCommandName(); if (-not $name) { continue }
            if ($Aliases.ContainsKey($name)) { $name = $Aliases[$name] }
            if (-not $Ps7Only.ContainsKey($name)) { continue }
            foreach ($p in @($c.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] })) {
                # exact names only: a prefix would also match 5.1 parameters (-Leaf is a prefix of -LeafBase)
                if (@($Ps7Only[$name]) -contains $p.ParameterName) {
                    Fail "$(Rel $f):$($p.Extent.StartLineNumber): $name -$($p.ParameterName) exists only in PowerShell 6/7"
                }
            }
        }
        if (-not $err) { $n++ }
    }
    Pass "$n script(s) parse with 0 errors"
}

# ---------------------------------------------------------------- ascii
Invoke-Check 'ascii  (*.ps1, *.cmd, *.iss)' {
    $n = 0; $latin1 = [Text.Encoding]::GetEncoding(28591)
    foreach ($f in Get-RepoFiles '*.ps1', '*.psm1', '*.psd1', '*.cmd', '*.bat', '*.iss') {
        $t = $latin1.GetString([IO.File]::ReadAllBytes($f.FullName))   # one char per byte
        $bad = [regex]::Matches($t, '[^\x00-\x7F]')
        if (-not $bad.Count) { $n++; continue }
        $where = @($bad | Select-Object -First 5 | ForEach-Object {
            $line = ([regex]::Matches($t.Substring(0, $_.Index), "`n")).Count + 1
            'line {0} byte 0x{1:X2}' -f $line, [int][char]$_.Value })
        Fail "$(Rel $f): $($bad.Count) non-ASCII byte(s): $($where -join ', ')$(if ($bad.Count -gt 5) { ', ...' })"
    }
    Pass "$n file(s) are ASCII only"
}

# ---------------------------------------------------------------- version
Invoke-Check 'version  (src\version.txt is the only source)' {
    $vf = Join-Path $Repo 'src\version.txt'
    $vt = if (Test-Path $vf) { "$(Get-Content $vf -TotalCount 1)".Trim() } else { '' }
    $v = $null
    if (-not [version]::TryParse($vt, [ref]$v) -or $v.Build -lt 0 -or $v.Revision -ge 0) { Fail "src\version.txt is '$vt'; it must be one x.y.z line"; return }
    Pass "src\version.txt = $v"

    # $AppVersion must be read from version.txt; a fallback of 0.0 for a missing file is fine
    foreach ($f in Get-RepoFiles '*.ps1') {
        foreach ($m in [regex]::Matches([IO.File]::ReadAllText($f.FullName), '(?m)^[ \t]*\$AppVersion\s*=\s*(\[version\]\s*)?[''"](?<v>\d+(\.\d+)+)[''"]')) {
            if ($m.Groups['v'].Value -notmatch '^0(\.0)+$') { Fail "$(Rel $f): hard-coded `$AppVersion = '$($m.Groups['v'].Value)' -- read src\version.txt instead" }
        }
    }
    $iss = [IO.File]::ReadAllText((Join-Path $Repo 'installer\DeskConsole.iss'))
    if ($iss -notmatch '(?m)^#define\s+VerFile\s+FileOpen\(.*version\.txt') { Fail 'DeskConsole.iss does not read AppVer from src\version.txt' }
    foreach ($key in 'AppVersion', 'VersionInfoVersion', 'VersionInfoProductVersion') {
        $m = [regex]::Match($iss, "(?m)^\s*$key\s*=\s*(.+?)\s*$")
        if ($m.Success -and $m.Groups[1].Value -notmatch '\{#AppVer\}') { Fail "DeskConsole.iss $key=$($m.Groups[1].Value) is hard-coded -- use {#AppVer}" }
        elseif ($m.Success) { Pass "DeskConsole.iss $key={#AppVer}" }
        elseif ($key -eq 'AppVersion') { Fail 'DeskConsole.iss has no AppVersion={#AppVer}' }
        elseif ($key -eq 'VersionInfoVersion') { Note 'DeskConsole.iss sets no VersionInfoVersion: the setup exe''s file version reads 0.0.0.0' }
    }
    $cl = Join-Path $Repo 'CHANGELOG.md'
    if (-not (Test-Path $cl)) { Fail 'CHANGELOG.md is missing (the release notes come from it)' }
    elseif ([IO.File]::ReadAllText($cl) -notmatch "(?m)^##\s*\[?$([regex]::Escape("$v"))\]?(\s|$)") { Fail "CHANGELOG.md has no '## [$v]' section" }
    else { Pass "CHANGELOG.md has a $v section" }
    # Desk Console shows whats-new.txt once after every update: one left at the last version would
    # greet every PC with the previous release's news. Plain ASCII, like the scripts.
    $wn = Join-Path $Repo 'src\whats-new.txt'
    if (-not (Test-Path $wn)) { Fail 'src\whats-new.txt is missing (Desk Console shows it after an update)' }
    else {
        $first = "$(Get-Content $wn -TotalCount 1)"
        if ($first -notmatch "(^|\s)$([regex]::Escape("$v"))(\s|$)") { Fail "src\whats-new.txt starts '$first' -- its first line must name $v" }
        elseif ([regex]::IsMatch([Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($wn)), '[^\x00-\x7F]')) { Fail 'src\whats-new.txt has non-ASCII characters' }
        else { Pass "src\whats-new.txt is for $v" }
    }
}

# ---------------------------------------------------------------- files
function Get-IssFiles([string]$iss) {   # installed paths ({app}-relative) of [Files] entries copied from ..\src\
    $sec = [regex]::Match($iss, '(?ms)^\[Files\]\s*$(.*?)(?=^\[)').Groups[1].Value
    foreach ($line in $sec -split "`r?`n") {
        if ($line -match '^\s*;' -or $line -notmatch 'Source:\s*"(?<s>[^"]+)"') { continue }
        $src = $Matches['s']
        if ($src -notlike '..\src\*' -or $line -notmatch 'DestDir:\s*"\{app\}(?<d>[^"]*)"') { continue }
        $sub = $Matches['d'].Trim('\')
        foreach ($hit in @(Get-ChildItem (Join-Path (Join-Path $Repo 'installer') $src) -File -ErrorAction SilentlyContinue)) {
            if ($sub) { "$sub\$($hit.Name)" } else { $hit.Name }
        }
    }
}
function Get-AppFileList([string]$iss) {   # the AppFile(I) case list in [Code]
    $body = [regex]::Match($iss, '(?ms)^function\s+AppFile\b.*?^end;').Value
    if (-not $body) { return $null }
    @([regex]::Matches($body, "(\d+)\s*:\s*Result\s*:=\s*'([^']+)'") | Sort-Object { [int]$_.Groups[1].Value } | ForEach-Object { $_.Groups[2].Value })
}
Invoke-Check 'files  (DeskConsole.iss [Files] = AppFile list = Install-DeskConsole.ps1 $Files)' {
    $before = $script:Fails
    $iss = [IO.File]::ReadAllText((Join-Path $Repo 'installer\DeskConsole.iss'))
    $lists = [ordered]@{}
    $lists['DeskConsole.iss [Files]'] = @(Get-IssFiles $iss)
    $app = Get-AppFileList $iss
    if ($null -eq $app) { Fail 'DeskConsole.iss: no "function AppFile" list found' } else { $lists['DeskConsole.iss AppFile'] = $app }

    $ip = Join-Path $Repo 'src\Install-DeskConsole.ps1'
    $tok = $null; $err = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($ip, [ref]$tok, [ref]$err)
    $asg = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -eq 'Files' }, $true)
    if (-not $asg) { Fail 'Install-DeskConsole.ps1: no $Files = ... list found' }
    else {
        $ps = @($asg.Right.FindAll({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value })
        # version.txt last: a copy that stops halfway leaves the old version.txt, so the next launch retries
        $last = if ($ps.Count) { $ps[-1] } else { '' }
        if ($ps -contains 'version.txt' -and $last -ne 'version.txt') { Fail "Install-DeskConsole.ps1 copies version.txt before $last -- it must be the last file" }
        elseif ($ps -notcontains 'version.txt') {
            if ([IO.File]::ReadAllText($ip) -match '(?s)foreach\s*\(\s*\$\w+\s+in\s+\$Files\s*\).*?version\.txt') { $ps += 'version.txt'; Pass 'Install-DeskConsole.ps1 copies version.txt after $Files' }
            else { Fail 'Install-DeskConsole.ps1 never copies version.txt' }
        } else { Pass 'Install-DeskConsole.ps1 copies version.txt last' }
        $lists['Install-DeskConsole.ps1 $Files'] = $ps
    }

    # the AppFile loops must cover the whole list (they once hard-coded "0 to 6")
    if ($null -ne $app) {
        foreach ($m in [regex]::Matches($iss, '(?i)for\s+I\s*:=\s*0\s+to\s+(\d+)\s+do')) {
            if ([int]$m.Groups[1].Value -ne $app.Count - 1) { Fail "DeskConsole.iss loops 'for I := 0 to $($m.Groups[1].Value)' over $($app.Count) AppFile entries" }
        }
        $cm = [regex]::Match($iss, '(?i)\bAppFileCount\s*=\s*(\d+)\s*;')
        if ($cm.Success -and [int]$cm.Groups[1].Value -ne $app.Count) { Fail "DeskConsole.iss AppFileCount = $($cm.Groups[1].Value) but AppFile lists $($app.Count) files" }
    }

    $norm = { param($a) @($a | ForEach-Object { "$_".Replace('/', '\').ToLowerInvariant() } | Sort-Object -Unique) }
    $names = @($lists.Keys)
    for ($i = 0; $i -lt $names.Count; $i++) {
        for ($j = $i + 1; $j -lt $names.Count; $j++) {
            $a = & $norm $lists[$names[$i]]; $b = & $norm $lists[$names[$j]]
            $onlyA = @($a | Where-Object { $b -notcontains $_ }); $onlyB = @($b | Where-Object { $a -notcontains $_ })
            if ($onlyA -or $onlyB) {
                Fail ("{0} vs {1}:{2}{3}" -f $names[$i], $names[$j], $(if ($onlyA) { " only in the first: $($onlyA -join ', ')." }), $(if ($onlyB) { " only in the second: $($onlyB -join ', ')." }))
            }
        }
    }
    $all = & $norm ($lists.Values | ForEach-Object { $_ })
    foreach ($p in $all) { if (-not (Test-Path (Join-Path (Join-Path $Repo 'src') $p))) { Fail "listed for install but missing: src\$p" } }
    foreach ($s in Get-ChildItem (Join-Path $Repo 'src') -Filter '*.ps1' -File) {
        foreach ($k in $names) { if ((& $norm $lists[$k]) -notcontains $s.Name.ToLowerInvariant()) { Fail "src\$($s.Name) is not in $k (installed PCs would not get it)" } }
    }
    if ($script:Fails -eq $before) { Pass "$(@($all).Count) installed file(s) agree: $(@($all) -join ', ')" }
}

# ---------------------------------------------------------------- params
# Every caller of Setup-Synergy.ps1 may pass only the parameters -- and ValidateSet values -- it
# declares. The installer runs the steps hidden: an unknown parameter fails a whole step on the PC
# with nothing on screen.
$PsExeParams = 'NoProfile', 'ExecutionPolicy', 'File', 'Command', 'WindowStyle', 'NoExit', 'NonInteractive', 'NoLogo',
               'EncodedCommand', 'Sta', 'Mta', 'Version', 'InputFormat', 'OutputFormat', 'ConfigurationName'
function Get-ScriptParams([string]$path) {   # name -> ValidateSet values ($null: any value)
    $tok = $null; $err = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tok, [ref]$err)
    $p = @{}
    if ($ast.ParamBlock) {
        foreach ($x in $ast.ParamBlock.Parameters) {
            $set = $null
            foreach ($a in $x.Attributes) {
                if ($a -is [Management.Automation.Language.AttributeAst] -and $a.TypeName.Name -eq 'ValidateSet') {
                    $set = @($a.PositionalArguments | ForEach-Object { "$($_.Value)" })
                }
            }
            $p[$x.Name.VariablePath.UserPath] = $set
        }
    }
    $p
}
function Test-SetupArg([string]$where, [string]$name, [string]$value, $params) {
    $hit = @($params.Keys | Where-Object { $_ -eq $name })
    if (-not $hit) { $hit = @($params.Keys | Where-Object { $_.StartsWith($name, [StringComparison]::OrdinalIgnoreCase) }) }   # PowerShell takes a unique prefix
    if ($hit.Count -ne 1) { Fail "$where passes -$name, which Setup-Synergy.ps1 does not declare$(if ($hit.Count -gt 1) { ' (ambiguous)' })"; return }
    $set = $params[$hit[0]]
    if ($set -and $value -and $value -notmatch '^[%$({"]' -and @($set) -notcontains $value) {
        Fail "$where passes -$name $value; Setup-Synergy.ps1 accepts $(@($set | Where-Object { $_ }) -join ', ')"
    }
}
# "-Name Value -Switch" in a piece of command line -> name/value pairs
function Split-SetupArgs([string]$text) {
    $t = @($text -split '\s+' | Where-Object { $_ })
    for ($i = 0; $i -lt $t.Count; $i++) {
        if ($t[$i] -notmatch '^-([A-Za-z]\w*)$') { continue }
        $name = $Matches[1]   # before the next -match replaces $Matches
        $v = if ($i + 1 -lt $t.Count -and -not $t[$i + 1].StartsWith('-')) { $t[$i + 1] } else { '' }
        [pscustomobject]@{ Name = $name; Value = $v }
    }
}
Invoke-Check 'params  (callers of Setup-Synergy.ps1 vs its param block)' {
    $before = $script:Fails
    $sp = Get-ScriptParams (Join-Path $Repo 'src\Setup-Synergy.ps1')
    if (-not $sp.Count) { Fail 'src\Setup-Synergy.ps1 has no param block'; return }
    $n = 0
    # installer: the [Run] steps that run Setup-Synergy.ps1, and the [Code] functions they call
    $iss = [IO.File]::ReadAllText((Join-Path $Repo 'installer\DeskConsole.iss')) -replace '\\\r?\n\s*', ' '
    foreach ($line in $iss -split "`r?`n") {
        if ($line -notmatch 'Parameters:\s*"(?<p>(?:[^"]|"")*)"') { continue }
        $p = $Matches['p']   # (read before the next -match replaces $Matches)
        if ($p -notmatch 'Setup-Synergy\.ps1""') { continue }
        $tail = ($p -split 'Setup-Synergy\.ps1""', 2)[1] -replace '""[^"]*""', 'X'
        foreach ($a in Split-SetupArgs ($tail -replace '\{code:\w+\}', '')) { Test-SetupArg 'DeskConsole.iss [Run]' $a.Name $a.Value $sp; $n++ }
        foreach ($fn in [regex]::Matches($tail, '\{code:(\w+)\}') | ForEach-Object { $_.Groups[1].Value }) {
            $body = [regex]::Match($iss, "(?ms)^function\s+$fn\b.*?^end;").Value
            if (-not $body) { Fail "DeskConsole.iss: {code:$fn} has no function $fn"; continue }
            foreach ($lit in [regex]::Matches($body, "'([^']*)'") | ForEach-Object { $_.Groups[1].Value }) {
                foreach ($a in Split-SetupArgs $lit) { Test-SetupArg "DeskConsole.iss $fn" $a.Name $a.Value $sp; $n++ }
            }
        }
    }
    # launchers
    foreach ($f in Get-ChildItem (Join-Path $Repo 'src') -Filter '*.cmd' -File) {
        foreach ($line in Get-Content $f.FullName) {
            if ($line -notmatch 'Setup-Synergy\.ps1"?(?<rest>.*)$') { continue }
            foreach ($a in Split-SetupArgs $Matches['rest']) { Test-SetupArg "src\$($f.Name)" $a.Name $a.Value $sp; $n++ }
        }
    }
    # Desk Console: its admin steps (Start-AdminSetup and its callers) and every '-Phase', '<x>' list
    $tok = $null; $err = $null
    $dc = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo 'src\Desk-Console.ps1'), [ref]$tok, [ref]$err)
    $dashes = { param($node) @($node.FindAll({ param($x) $x -is [Management.Automation.Language.StringConstantExpressionAst] -and $x.Value -match '^-[A-Za-z]\w*$' }, $true) |
                ForEach-Object { $_.Value.Substring(1) } | Where-Object { $PsExeParams -notcontains $_ }) }
    $calls = @($dc.FindAll({ param($x) $x -is [Management.Automation.Language.CommandAst] -and $x.GetCommandName() -eq 'Start-AdminSetup' }, $true))
    $defs = @($dc.FindAll({ param($x) $x -is [Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq 'Start-AdminSetup' }, $true))
    foreach ($d in $defs) { foreach ($nm in & $dashes $d) { Test-SetupArg 'Desk-Console.ps1 Start-AdminSetup' $nm '' $sp; $n++ } }
    foreach ($c in $calls) {
        $ph = $c.CommandElements | Select-Object -Skip 1 -First 1
        if ($ph -is [Management.Automation.Language.StringConstantExpressionAst]) { Test-SetupArg 'Desk-Console.ps1 Start-AdminSetup' 'Phase' $ph.Value $sp; $n++ }
        $fn = $c.Parent; while ($fn -and $fn -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $fn = $fn.Parent }
        if ($fn) { foreach ($nm in & $dashes $fn) { Test-SetupArg "Desk-Console.ps1 $($fn.Name)" $nm '' $sp; $n++ } }
    }
    foreach ($arr in $dc.FindAll({ param($x) $x -is [Management.Automation.Language.ArrayLiteralAst] }, $true)) {
        $el = @($arr.Elements)
        for ($i = 0; $i -lt $el.Count - 1; $i++) {
            if ($el[$i] -is [Management.Automation.Language.StringConstantExpressionAst] -and $el[$i].Value -eq '-Phase' -and
                $el[$i + 1] -is [Management.Automation.Language.StringConstantExpressionAst]) { Test-SetupArg 'Desk-Console.ps1' 'Phase' $el[$i + 1].Value $sp; $n++ }
        }
    }
    if ($script:Fails -eq $before) { Pass "$n argument(s) from the installer, the launchers and Desk Console match Setup-Synergy.ps1" }
}

# ---------------------------------------------------------------- agent
# Agent.ps1 runs inside Setup-Synergy.ps1 -Phase TrustSync and uses its functions and variables
# (contract C-10). It skips a step quietly when one is missing, so a renamed function would turn
# self-healing off on every PC without a sound.
Invoke-Check 'agent  (Setup-Synergy.ps1 provides what Agent.ps1 uses)' {
    $before = $script:Fails
    $sf = Join-Path $Repo 'src\Setup-Synergy.ps1'; $af = Join-Path $Repo 'src\Agent.ps1'
    if (-not (Test-Path $af)) { Fail 'src\Agent.ps1 is missing'; return }
    $tok = $null; $err = $null
    $ss = [Management.Automation.Language.Parser]::ParseFile($sf, [ref]$tok, [ref]$err)
    $fns = @{}
    foreach ($d in $ss.FindAll({ param($x) $x -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        $ps = @()
        if ($d.Parameters) { $ps += @($d.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) }
        if ($d.Body.ParamBlock) { $ps += @($d.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) }
        $fns[$d.Name] = $ps
    }
    $need = [ordered]@{ 'Get-Kvm' = @(); 'Get-DeskflowValues' = @('NoAppend'); 'Set-Ini' = @(); 'Find-Exe' = @()
                        'Get-PreferredIPv4' = @(); 'Update-MachineRow' = @('IP', 'MAC', 'RustDeskId') }
    foreach ($k in $need.Keys) {
        if (-not $fns.ContainsKey($k)) { Fail "Setup-Synergy.ps1 has no function $k (Agent.ps1 uses it)"; continue }
        foreach ($p in $need[$k]) { if (@($fns[$k]) -notcontains $p) { Fail "Setup-Synergy.ps1 $k has no -$p (Agent.ps1 passes it)" } }
    }
    $assigned = @($ss.FindAll({ param($x) $x -is [Management.Automation.Language.AssignmentStatementAst] -and
                    $x.Left -is [Management.Automation.Language.VariableExpressionAst] }, $false) | ForEach-Object { $_.Left.VariablePath.UserPath })
    foreach ($v in 'Root', 'Me', 'DeskflowDir', 'InstallDir', 'RustDeskExe') {
        if ($assigned -notcontains $v) { Fail "Setup-Synergy.ps1 never sets `$$v (Agent.ps1 reads it)" }
    }
    $text = [IO.File]::ReadAllText($sf)
    if ($text -notmatch 'Agent\.ps1' -or $text -notmatch 'Invoke-DeskAgent') { Fail 'Setup-Synergy.ps1 -Phase TrustSync does not run Agent.ps1 (Invoke-DeskAgent)' }
    if ([IO.File]::ReadAllText($af) -notmatch '(?m)^function\s+Invoke-DeskAgent\b') { Fail 'Agent.ps1 defines no Invoke-DeskAgent' }
    if ($script:Fails -eq $before) { Pass 'Get-Kvm, Get-DeskflowValues -NoAppend, Set-Ini, Find-Exe, Get-PreferredIPv4, Update-MachineRow and the variables are there' }
}

# ---------------------------------------------------------------- pins
Invoke-Check 'pins  (tools\Test-Pins.ps1)' {
    & (Join-Path $PSScriptRoot 'Test-Pins.ps1')
    if ($LASTEXITCODE) { $script:Fails++ }
}

# ---------------------------------------------------------------- analyzer
if ($SkipAnalyzer) { Write-Host 'analyzer'; Note 'skipped (-SkipAnalyzer)' }
else {
    Invoke-Check 'analyzer  (PSScriptAnalyzer: PSUseCompatibleSyntax 5.1 + Error severity)' {
        $mod = Get-Module -ListAvailable PSScriptAnalyzer | Sort-Object Version -Descending | Select-Object -First 1
        $psd = if ($mod) { $mod.Path } else {   # VS Code's PowerShell extension bundles one; load it read-only from there
            Get-ChildItem (Join-Path "$env:USERPROFILE" '.vscode\extensions\ms-vscode.powershell-*\modules\PSScriptAnalyzer\*\PSScriptAnalyzer.psd1') -ErrorAction SilentlyContinue |
                Sort-Object { [version]$_.Directory.Name } -Descending | Select-Object -First 1 -ExpandProperty FullName }
        if (-not $psd) { Note 'PSScriptAnalyzer is not installed -- skipped (CI runs it)'; return }
        Import-Module $psd
        $settings = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'
        $n = 0
        foreach ($f in Get-RepoFiles '*.ps1') {
            $r = @(Invoke-ScriptAnalyzer -Path $f.FullName -Settings $settings)
            foreach ($d in $r) { Fail "$(Rel $f):$($d.Line) $($d.RuleName): $($d.Message)" }
            if (-not $r.Count) { $n++ }
        }
        Pass "$n script(s) clean (PSScriptAnalyzer $((Get-Module PSScriptAnalyzer).Version))"
    }
}

Write-Host ''
if ($script:Fails) { Write-Host "Test-Repo: $($script:Fails) problem(s)." -ForegroundColor Red; exit 1 }
Write-Host 'Test-Repo: every check passed.' -ForegroundColor Green
exit 0
