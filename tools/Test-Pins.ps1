<#
  Test-Pins.ps1 -- the bundled RustDesk, Deskflow and Visual C++ runtime versions and SHA-256 pins
  must agree everywhere they are written. tools\Get-Redist.ps1 ($items) is the source; this reads
  (never runs) the other places:
    src\Setup-Synergy.ps1      $Installers RustDesk/Deskflow (Msi, Sha, Ver when present), $VcRedist (Exe, Sha)
    installer\DeskConsole.iss  the redist\ files it bundles, and its phone page's APK link
    THIRD-PARTY-NOTICES.md     version, tag and SHA-256 of each bundled program
    src\Desk-Console.ps1, tools\Make-MobileQr.py   the RustDesk APK link (same version as the MSI)
    src\mobile\*.png, installer\mobile\*.bmp       the QR codes decode to those same links
  Why: setup re-checks each hash on every PC and stops halfway on a mismatch ("hash mismatch ...
  Not installing"), and a QR code not regenerated after a bump sends phones to the old APK.
  Runs at the end of Get-Redist.ps1 and from tools\Test-Repo.ps1. Exit 1 when anything disagrees.

    powershell -ExecutionPolicy Bypass -File tools\Test-Pins.ps1
#>
param()
$ErrorActionPreference = 'Stop'
$Repo = Split-Path $PSScriptRoot -Parent
$script:Fails = 0
function Pass($m) { Write-Host "  ok    $m" -ForegroundColor Green }
function Fail($m) { Write-Host "  FAIL  $m" -ForegroundColor Red; $script:Fails++ }
function Note($m) { Write-Host "  note  $m" -ForegroundColor Yellow }
Write-Host 'Test-Pins: bundled versions and hashes'

# ---------------------------------------------------------------- reading scripts without running them
function Get-ScriptAst([string]$rel) {
    $p = Join-Path $Repo $rel
    if (-not (Test-Path $p)) { return $null }
    $tok = $null; $err = $null
    [Management.Automation.Language.Parser]::ParseFile($p, [ref]$tok, [ref]$err)
}
# right-hand side of the first "$<name> = ..." in a script
function Get-AssignedAst($ast, [string]$name) {
    if (-not $ast) { return $null }
    $a = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and
            $n.Left.VariablePath.UserPath -eq $name }, $true)
    if ($a) { $a.Right } else { $null }
}
# literal values only (strings, numbers, $null, arrays, hashtables); anything computed comes back as its source text
function ConvertFrom-ConstAst($e) {
    $L = 'System.Management.Automation.Language'
    if ($e -is "$L.PipelineAst" -and $e.PipelineElements.Count -eq 1) { $e = $e.PipelineElements[0] }
    if ($e -is "$L.CommandExpressionAst") { $e = $e.Expression }
    if ($e -is "$L.ConvertExpressionAst") { $e = $e.Child }          # [ordered]@{...}, [version]'1.0'
    if ($e -is "$L.HashtableAst") {
        $o = @{}
        foreach ($kv in $e.KeyValuePairs) { $o["$($kv.Item1.Value)"] = ConvertFrom-ConstAst $kv.Item2 }
        return $o
    }
    if ($e -is "$L.ArrayExpressionAst") { return , @($e.SubExpression.Statements | ForEach-Object { ConvertFrom-ConstAst $_ }) }
    if ($e -is "$L.ArrayLiteralAst") { return , @($e.Elements | ForEach-Object { ConvertFrom-ConstAst $_ }) }
    if ($e -is "$L.ConstantExpressionAst") { return $e.Value }     # includes string constants
    if ($e -is "$L.VariableExpressionAst" -and $e.VariablePath.UserPath -eq 'null') { return $null }
    "$($e.Extent.Text)"
}
function Read-Text([string]$rel) {
    $p = Join-Path $Repo $rel
    if (Test-Path $p) { [IO.File]::ReadAllText($p) } else { $null }
}

# ---------------------------------------------------------------- the source: Get-Redist.ps1
$items = ConvertFrom-ConstAst (Get-AssignedAst (Get-ScriptAst 'tools\Get-Redist.ps1') 'items')   # (not @(...): that would nest the array)
$pin = @{}
foreach ($i in @($items)) {
    if ($i -isnot [hashtable]) { continue }
    if ("$($i.Name)" -match '^rustdesk-')     { $pin['RustDesk'] = $i }
    elseif ("$($i.Name)" -match '^deskflow-') { $pin['Deskflow'] = $i }
    elseif ("$($i.Name)" -match '^vc_redist') { $pin['VC'] = $i }
}
foreach ($k in 'RustDesk', 'Deskflow', 'VC') {
    if (-not $pin[$k]) { Fail "tools\Get-Redist.ps1 `$items has no $k entry -- cannot check anything else"; }
}
if ($script:Fails) { exit 1 }
$rd = $pin['RustDesk']; $df = $pin['Deskflow']; $vc = $pin['VC']

foreach ($k in 'RustDesk', 'Deskflow', 'VC') {
    $i = $pin[$k]; $ok = $true
    if ("$($i.Sha)" -notmatch '^[0-9A-F]{64}$') { Fail "Get-Redist.ps1 $($i.Name): Sha is not 64 upper-case hex digits"; $ok = $false }
    if (-not "$($i.Url)".EndsWith("/$($i.Name)", [StringComparison]::OrdinalIgnoreCase)) { Fail "Get-Redist.ps1 $($i.Name): Url does not end in /$($i.Name)"; $ok = $false }
    if ($k -ne 'VC') {
        if ("$($i.Name)" -notlike "*-$($i.Version)-*") { Fail "Get-Redist.ps1 $($i.Name): name does not carry Version $($i.Version)"; $ok = $false }
        if ("$($i.Url)" -notlike "*/download/$($i.Tag)/*") { Fail "Get-Redist.ps1 $($i.Name): Url is not under tag $($i.Tag)"; $ok = $false }
    } elseif ("$($i.Url)" -notmatch [regex]::Escape("$($i.Sha)")) { Fail "Get-Redist.ps1 $($i.Name): Microsoft's Url carries a different SHA-256 than Sha"; $ok = $false }
    if ($ok) { Pass "Get-Redist.ps1  $($i.Name)  $($i.Version)" }
}

# ---------------------------------------------------------------- src\Setup-Synergy.ps1
$ss = Get-ScriptAst 'src\Setup-Synergy.ps1'
if (-not $ss) { Fail 'src\Setup-Synergy.ps1 is missing' } else {
    $inst = ConvertFrom-ConstAst (Get-AssignedAst $ss 'Installers')
    if ($inst -isnot [hashtable]) { Fail 'Setup-Synergy.ps1: no literal $Installers = @{ ... } found' } else {
        foreach ($k in 'RustDesk', 'Deskflow') {
            $e = $inst[$k]; $p = $pin[$k]
            if ($e -isnot [hashtable]) { Fail "Setup-Synergy.ps1 `$Installers has no $k entry"; continue }
            $bad = @()
            if ("$($e.Msi)" -ne $p.Name) { $bad += "Msi '$($e.Msi)' (want $($p.Name))" }
            if ("$($e.Sha)" -ne $p.Sha)  { $bad += "Sha $($e.Sha) (want $($p.Sha))" }
            foreach ($vk in 'Ver', 'Version') { if ($e.ContainsKey($vk) -and "$($e[$vk])" -ne $p.Version) { $bad += "$vk '$($e[$vk])' (want $($p.Version))" } }
            if ($bad) { Fail "Setup-Synergy.ps1 `$Installers.$k : $($bad -join '; ')" } else { Pass "Setup-Synergy.ps1  `$Installers.$k" }
        }
    }
    # the VC++ runtime pin: $VcRedist, or an entry of $Installers that names vc_redist.x64.exe
    $vce = ConvertFrom-ConstAst (Get-AssignedAst $ss 'VcRedist')
    if ($vce -isnot [hashtable] -and $inst -is [hashtable]) {
        $vce = @($inst.Values | Where-Object { $_ -is [hashtable] -and ("$($_.Exe)$($_.Msi)" -eq $vc.Name) }) | Select-Object -First 1
    }
    if ($vce -isnot [hashtable]) { Fail 'Setup-Synergy.ps1: no $VcRedist = @{ Exe; Sha } found' }
    else {
        $name = if ($vce.Exe) { "$($vce.Exe)" } else { "$($vce.Msi)" }
        if ($name -ne $vc.Name -or "$($vce.Sha)" -ne $vc.Sha) { Fail "Setup-Synergy.ps1 VC++ runtime: '$name' $($vce.Sha) (want $($vc.Name) $($vc.Sha))" }
        else { Pass 'Setup-Synergy.ps1  $VcRedist' }
    }
}

# ---------------------------------------------------------------- installer\DeskConsole.iss
$issText = Read-Text 'installer\DeskConsole.iss'
$want = @($items | ForEach-Object { "$($_.Name)" })
if (-not $issText) { Fail 'installer\DeskConsole.iss is missing' } else {
    $bundled = @([regex]::Matches($issText, '(?m)^\s*Source:\s*"redist\\([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
    $missing = @($want | Where-Object { $bundled -notcontains $_ })
    $extra   = @($bundled | Where-Object { $want -notcontains $_ })
    if ($missing -or $extra) { Fail "DeskConsole.iss [Files] redist\: missing $($missing -join ', ') ; not pinned $($extra -join ', ')" }
    else { Pass "DeskConsole.iss  bundles $($bundled -join ', ')" }
}

# ---------------------------------------------------------------- RustDesk APK links (phones)
$ApkRx  = 'rustdesk/releases/download/(?<tag>[^/''"\s]+)/rustdesk-(?<ver>[^/''"\s]+?)-aarch64-signed\.apk'
$ApkUrl = "https://github.com/rustdesk/rustdesk/releases/download/$($rd.Tag)/rustdesk-$($rd.Version)-aarch64-signed.apk"
# "$Ver", "${Ver}" or "{VER}" in a link -> the literal it is assigned in the same file
function Resolve-Ref([string]$text, [string]$v) {
    if ($v -match '^\$\{?(\w+)\}?$' -or $v -match '^\{(\w+)\}$') {
        $n = $Matches[1]
        $m = [regex]::Match($text, "(?m)^\s*\`$?$n\s*=\s*(\[[^\]]+\])?\s*['""]([^'""]+)['""]")
        if ($m.Success) { return $m.Groups[2].Value }
    }
    $v
}
foreach ($rel in 'src\Desk-Console.ps1', 'installer\DeskConsole.iss', 'tools\Make-MobileQr.py') {
    $t = Read-Text $rel
    if (-not $t) { Fail "$rel is missing"; continue }
    $ms = [regex]::Matches($t, $ApkRx)
    if (-not $ms.Count) { Fail "$rel has no RustDesk APK link (expected $ApkUrl)"; continue }
    $bad = @($ms | Where-Object { (Resolve-Ref $t $_.Groups['tag'].Value) -ne $rd.Tag -or (Resolve-Ref $t $_.Groups['ver'].Value) -ne $rd.Version } |
             ForEach-Object { $_.Value })
    if ($bad) { Fail "$rel APK link is not RustDesk $($rd.Version): $($bad -join ' ')" } else { Pass "$rel  APK link $($rd.Version)" }
}

# ---------------------------------------------------------------- THIRD-PARTY-NOTICES.md
$tp = Read-Text 'THIRD-PARTY-NOTICES.md'
if (-not $tp) { Fail 'THIRD-PARTY-NOTICES.md is missing' } else {
    $rows = @($tp -split "`r?`n" | Where-Object { $_ -match '^\|' })
    foreach ($k in 'RustDesk', 'Deskflow', 'VC') {
        $p = $pin[$k]
        $rx = @{ RustDesk = '\*\*RustDesk\*\*'; Deskflow = '\*\*Deskflow\*\*'; VC = 'Visual C\+\+' }[$k]
        $row = $rows | Where-Object { $_ -match $rx } | Select-Object -First 1
        if (-not $row) { Fail "THIRD-PARTY-NOTICES.md has no table row for $($p.Product)"; continue }
        $cells = @($row.Split('|') | ForEach-Object { $_.Trim() })
        $bad = @()
        if ($cells.Count -lt 3 -or $cells[2] -ne $p.Version) { $bad += "version '$($cells[2])' (want $($p.Version))" }
        $sha = [regex]::Match($row, '\b[0-9A-Fa-f]{64}\b').Value
        if ($sha -ne $p.Sha) { $bad += "SHA-256 '$sha' (want $($p.Sha))" }
        if ($p.Tag) {
            $tags = @([regex]::Matches($row, 'tag `([^`]+)`') | ForEach-Object { $_.Groups[1].Value })
            if (-not $tags -or @($tags | Where-Object { $_ -ne $p.Tag })) { $bad += "tag '$($tags -join ',')' (want $($p.Tag))" }
        }
        if ($bad) { Fail "THIRD-PARTY-NOTICES.md $($p.Product): $($bad -join '; ')" } else { Pass "THIRD-PARTY-NOTICES.md  $($p.Product) $($p.Version)" }
    }
}

# ---------------------------------------------------------------- QR codes
# The images are clean, axis-aligned renders (tools\Make-MobileQr.py, segno, EC level M), so a
# small reader is enough: sample the module grid, try the 8 masks, read the byte-mode payload.
$EcM   = @{ 1 = @(1, 16); 2 = @(1, 28); 3 = @(1, 44); 4 = @(2, 32); 5 = @(2, 43); 6 = @(4, 27) }   # blocks, data codewords per block
$Align = @{ 2 = 18; 3 = 22; 4 = 26; 5 = 30; 6 = 34 }
function Test-QrMask([int]$k, [int]$r, [int]$c) {
    switch ($k) {
        0 { return (($r + $c) % 2) -eq 0 }
        1 { return ($r % 2) -eq 0 }
        2 { return ($c % 3) -eq 0 }
        3 { return (($r + $c) % 3) -eq 0 }
        4 { return (([Math]::Floor($r / 2) + [Math]::Floor($c / 3)) % 2) -eq 0 }
        5 { return ((($r * $c) % 2) + (($r * $c) % 3)) -eq 0 }
        6 { return (((($r * $c) % 2) + (($r * $c) % 3)) % 2) -eq 0 }
        7 { return (((($r + $c) % 2) + (($r * $c) % 3)) % 2) -eq 0 }
    }
}
function Read-QrText([string]$path) {
    $bmp = New-Object Drawing.Bitmap $path
    try {
        $w = $bmp.Width
        $dark = { param($x, $y) $p = $bmp.GetPixel($x, $y); (0.299 * $p.R + 0.587 * $p.G + 0.114 * $p.B) -lt 128 }
        $start = -1; for ($i = 0; $i -lt [Math]::Min($w, $bmp.Height); $i++) { if (& $dark $i $i) { $start = $i; break } }
        if ($start -lt 0) { return $null }
        $end = $start; while ($end -lt $w -and (& $dark $end $start)) { $end++ }   # the finder's top row: 7 modules
        $scale = [int][Math]::Floor(($end - $start) / 7)
        if ($scale -lt 1) { return $null }
        $n = [int][Math]::Floor(($w - 2 * $start) / $scale)
        if ((($n - 17) % 4) -ne 0) { return $null }
        $v = [int](($n - 17) / 4)
        if (-not $EcM.ContainsKey($v)) { return $null }   # versions 1-6 only (7+ carry version blocks)
        $half = [int][Math]::Floor($scale / 2)
        $grid = New-Object 'bool[,]' $n, $n
        for ($r = 0; $r -lt $n; $r++) { for ($c = 0; $c -lt $n; $c++) { $grid[$r, $c] = & $dark ($start + $c * $scale + $half) ($start + $r * $scale + $half) } }
        # data modules in reading order: two-column strips from the right, alternating up and down
        $cells = New-Object Collections.Generic.List[int[]]
        $c = $n - 1; $up = $true
        while ($c -gt 0) {
            if ($c -eq 6) { $c-- }
            $rows = if ($up) { ($n - 1)..0 } else { 0..($n - 1) }
            foreach ($r in $rows) {
                foreach ($cc in $c, ($c - 1)) {
                    $fn = ($r -lt 9 -and $cc -lt 9) -or ($r -lt 9 -and $cc -ge $n - 8) -or ($r -ge $n - 8 -and $cc -lt 9) -or $r -eq 6 -or $cc -eq 6
                    if (-not $fn -and $Align.ContainsKey($v)) { $a = $Align[$v]; $fn = [Math]::Abs($r - $a) -le 2 -and [Math]::Abs($cc - $a) -le 2 }
                    if (-not $fn) { $cells.Add([int[]]@($r, $cc)) }
                }
            }
            $up = -not $up; $c -= 2
        }
        $blocks = $EcM[$v][0]; $per = $EcM[$v][1]
        $codeword = { param($k, $b) $x = 0
            for ($j = 0; $j -lt 8; $j++) { $rc = $cells[$b + $j]; $x = ($x -shl 1) -bor [int]($grid[$rc[0], $rc[1]] -xor (Test-QrMask $k $rc[0] $rc[1])) }
            $x }
        for ($k = 0; $k -lt 8; $k++) {
            if (((& $codeword $k 0) -shr 4) -ne 4) { continue }   # the first codeword starts with the byte-mode indicator 0100
            $cw = New-Object Collections.Generic.List[int]
            for ($b = 0; $b + 7 -lt $cells.Count; $b += 8) { $cw.Add((& $codeword $k $b)) }
            if ($cw.Count -lt $blocks * $per) { continue }
            $data = New-Object Collections.Generic.List[int]   # data codewords are interleaved block by block
            for ($bl = 0; $bl -lt $blocks; $bl++) { for ($j = 0; $j -lt $per; $j++) { $data.Add($cw[$j * $blocks + $bl]) } }
            $bits = -join ($data | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') })
            if ($bits.Substring(0, 4) -ne '0100') { continue }   # byte mode
            $len = [Convert]::ToInt32($bits.Substring(4, 8), 2)
            if (12 + 8 * $len -gt $bits.Length) { continue }
            $bytes = [byte[]](0..($len - 1) | ForEach-Object { [Convert]::ToByte($bits.Substring(12 + 8 * $_, 8), 2) })
            $s = [Text.Encoding]::ASCII.GetString($bytes)
            if ($s -match '^https?://[\x21-\x7E]+$') { return $s }
        }
        $null
    } finally { $bmp.Dispose() }
}

$qrPy = Read-Text 'tools\Make-MobileQr.py'
$IosUrl = if ($qrPy -and $qrPy -match '"ios"\s*:\s*"([^"]+)"') { $Matches[1] } else { $null }
$drawing = $true
try { Add-Type -AssemblyName System.Drawing } catch { $drawing = $false }
if (-not $drawing) { Note 'QR images not checked: System.Drawing is not available in this PowerShell.' }
else {
    # what ships: Desk Console's PNGs and the installer page's BMPs (installer\mobile\*.png only feed Convert-QrBmp.ps1)
    foreach ($q in @(
            @{ File = 'src\mobile\rustdesk-android.png'; Want = $ApkUrl }
            @{ File = 'src\mobile\rustdesk-ios.png'; Want = $IosUrl }
            @{ File = 'installer\mobile\rustdesk-android.bmp'; Want = $ApkUrl }
            @{ File = 'installer\mobile\rustdesk-ios.bmp'; Want = $IosUrl })) {
        $p = Join-Path $Repo $q.File
        if (-not (Test-Path $p)) { Fail "$($q.File) is missing (tools\Make-MobileQr.py, then tools\Convert-QrBmp.ps1)"; continue }
        $got = $null
        try { $got = Read-QrText $p } catch { $got = $null }
        if (-not $got) { Note "$($q.File): could not read the QR code (not a plain segno render?) -- scan it with a phone" }
        elseif (-not $q.Want) { Note "$($q.File): reads $got (no iOS link found in Make-MobileQr.py to compare)" }
        elseif ($got -ne $q.Want) { Fail "$($q.File) opens $got, want $($q.Want) -- run tools\Make-MobileQr.py and tools\Convert-QrBmp.ps1" }
        else { Pass "$($q.File)  -> $(Split-Path $got -Leaf)" }
    }
}

if ($script:Fails) { Write-Host "Test-Pins: $($script:Fails) problem(s)." -ForegroundColor Red; exit 1 }
Write-Host 'Test-Pins: every pin agrees.' -ForegroundColor Green
exit 0
