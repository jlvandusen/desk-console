<#
  Get-Redist.ps1 -- download the third-party installers the setup bundles, into installer\redist\,
  and check each one's SHA-256 (and Authenticode signature where the vendor signs it).
  Run before building installer\DeskConsole.iss. Nothing here is committed to git.

    powershell -ExecutionPolicy Bypass -File tools\Get-Redist.ps1                 # download + verify, then Test-Pins
    powershell -ExecutionPolicy Bypass -File tools\Get-Redist.ps1 -CheckLatest    # is a newer upstream release out?
    powershell -ExecutionPolicy Bypass -File tools\Get-Redist.ps1 -ListPins       # the pins, as objects

  $items below is the ONE place the bundled versions and hashes are decided. The same values are
  repeated in src\Setup-Synergy.ps1 (re-checked on every PC before running an installer),
  installer\DeskConsole.iss, THIRD-PARTY-NOTICES.md and the phone APK links; tools\Test-Pins.ps1
  fails when any of them disagree, and runs at the end of every download so no build ships a
  pin that setup would refuse halfway through ("hash mismatch ... Not installing").

  -CheckLatest asks GitHub for the newest RustDesk and Deskflow releases and Microsoft's permalink
  for the newest Visual C++ runtime, prints them beside the pins and exits 1 when a pin is behind
  (2 when the check itself failed). -Report <file> also writes the result as JSON (used by
  .github\workflows\upstream-watch.yml to open one issue per component). Set GH_TOKEN or
  GITHUB_TOKEN to avoid GitHub's 60-requests-an-hour anonymous limit.

  Synergy is commercial and is never downloaded or bundled: put its MSI in the shared folder's
  installer\ folder yourself if you use it (Setup-Synergy.ps1 checks its hash).
#>
param([switch]$CheckLatest, [string]$Report = '', [switch]$ListPins)
$ErrorActionPreference = 'Stop'

# Bumping a version: change Version, Name, Url and Sha (and Tag) together here, then the places
# Test-Pins names. Repo/Tag drive -CheckLatest and the source archives attached to each release.
$items = @(
    @{ Product = 'RustDesk'; Version = '1.5.0'; Repo = 'rustdesk/rustdesk'; Tag = '1.5.0'
       Name    = 'rustdesk-1.5.0-x86_64.msi'
       Url     = 'https://github.com/rustdesk/rustdesk/releases/download/1.5.0/rustdesk-1.5.0-x86_64.msi'
       Sha     = '624FE792AB1D76B35134DAB84BFF97A6BCD14043FFD090A2C6A2800F77580495'; Signer = 'PURSLANE' }
    @{ Product = 'Deskflow'; Version = '1.27.0'; Repo = 'deskflow/deskflow'; Tag = 'v1.27.0'
       Name    = 'deskflow-1.27.0-win-x64.msi'
       Url     = 'https://github.com/deskflow/deskflow/releases/download/v1.27.0/deskflow-1.27.0-win-x64.msi'
       Sha     = '0CA5668C4731F5477D0B189BDB11196A2CA51281985D9D8C0757BF7F3B782D64'; Signer = $null }   # upstream does not sign; hash = GitHub's published digest
    @{ Product = 'Microsoft Visual C++ runtime'; Version = '14.51.36247.0'   # 2015-2022 x64; Deskflow needs 14.44+
       Name    = 'vc_redist.x64.exe'
       Url     = 'https://download.visualstudio.microsoft.com/download/pr/ebdab8e5-1d7b-4d9f-a11b-cbb1720c3b12/843068991DAAA1F73AD9F6239BCE4D0F6A07A51F18C37EA2A867E9BECA71295C/VC_redist.x64.exe'
       Latest  = 'https://aka.ms/vc14/vc_redist.x64.exe'   # Microsoft's permalink to the newest build; its target URL carries the SHA-256
       Sha     = '843068991DAAA1F73AD9F6239BCE4D0F6A07A51F18C37EA2A867E9BECA71295C'; Signer = 'Microsoft Corporation' }
)

if ($ListPins) {
    foreach ($i in $items) { [pscustomobject]$i }
    return
}

# GitHub's API and download hosts refuse TLS 1.0; old .NET Framework defaults can still offer it.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Invoke-GitHubApi([string]$path) {
    $h = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'desk-console-get-redist' }
    $tok = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }
    if ($tok) { $h['Authorization'] = "Bearer $tok" }
    Invoke-RestMethod "https://api.github.com/$path" -Headers $h -UseBasicParsing
}

# The final URL after redirects, without downloading the file (HEAD).
function Resolve-FinalUrl([string]$url) {
    $req = [Net.WebRequest]::Create($url); $req.Method = 'HEAD'; $req.AllowAutoRedirect = $true
    $resp = $req.GetResponse()
    try { $resp.ResponseUri.AbsoluteUri } finally { $resp.Close() }
}

function Test-Newer([string]$latest, [string]$pinned) {
    $a = $null; $b = $null
    if ([version]::TryParse($latest, [ref]$a) -and [version]::TryParse($pinned, [ref]$b)) { return $a -gt $b }
    $latest -ne $pinned
}

function Get-LatestRelease($i) {
    if ($i.Repo) {
        $rel   = Invoke-GitHubApi "repos/$($i.Repo)/releases/latest"
        $ver   = "$($rel.tag_name)" -replace '^v', ''
        $asset = $i.Name.Replace($i.Version, $ver)     # same file naming, new version
        $a     = @($rel.assets | Where-Object { $_.name -eq $asset }) | Select-Object -First 1
        return [pscustomobject]@{ Product = $i.Product; Pinned = $i.Version; Latest = $ver; Behind = (Test-Newer $ver $i.Version)
            Release = "$($rel.html_url)"; Asset = $(if ($a) { $asset } else { "(no $asset in that release)" }); Digest = "$($a.digest)" }
    }
    $final = Resolve-FinalUrl $i.Latest
    $sha = if ($final -match '/([0-9A-Fa-f]{64})/') { $Matches[1].ToUpperInvariant() } else { '' }
    if (-not $sha) { throw "$($i.Product): $($i.Latest) led to $final, which carries no SHA-256" }
    $same = $sha -eq $i.Sha
    # the permalink names no version; a different SHA-256 means Microsoft published another build
    [pscustomobject]@{ Product = $i.Product; Pinned = $i.Version
        Latest = $(if ($same) { $i.Version } else { "build $($sha.Substring(0, 12))" })
        Behind = -not $same; Release = $i.Latest; Asset = $final; Digest = "sha256:$($sha.ToLowerInvariant())" }
}

if ($CheckLatest) {
    try { $res = @(foreach ($i in $items) { Get-LatestRelease $i }) }
    catch { Write-Host "Upstream check FAILED: $($_.Exception.Message)" -ForegroundColor Red; exit 2 }
    foreach ($r in $res) {
        $c = if ($r.Behind) { 'Yellow' } else { 'Green' }
        $what = if ($r.Behind) { "NEWER: $($r.Latest)" } else { 'current' }
        Write-Host ("{0,-30} pinned {1,-14} {2}" -f $r.Product, $r.Pinned, $what) -ForegroundColor $c
        if ($r.Behind) { Write-Host "    $($r.Release)  $($r.Asset)  $($r.Digest)" }
    }
    if ($Report) { ConvertTo-Json -InputObject $res -Depth 3 | Set-Content $Report -Encoding UTF8 }
    if (@($res | Where-Object { $_.Behind }).Count) { exit 1 }
    exit 0
}

$dest = Join-Path (Split-Path $PSScriptRoot -Parent) 'installer\redist'
New-Item -ItemType Directory -Force $dest | Out-Null
foreach ($i in $items) {
    $f = Join-Path $dest $i.Name
    if (-not (Test-Path $f) -or (Get-FileHash $f -Algorithm SHA256).Hash -ne $i.Sha) {
        Write-Host "Downloading $($i.Name)..."
        Invoke-WebRequest $i.Url -OutFile $f -UseBasicParsing
    }
    $h = (Get-FileHash $f -Algorithm SHA256).Hash
    if ($h -ne $i.Sha) { Remove-Item $f; throw "$($i.Name): SHA-256 $h does not match $($i.Sha)" }
    if ($i.Signer) {
        $s = Get-AuthenticodeSignature $f
        if ($s.Status -ne 'Valid' -or $s.SignerCertificate.Subject -notmatch [regex]::Escape($i.Signer)) {
            throw "$($i.Name): signature $($s.Status) / $($s.SignerCertificate.Subject), expected $($i.Signer)"
        }
    }
    Write-Host "OK  $($i.Name)" -ForegroundColor Green
}

# The pins in the scripts, the installer and the notices must agree with what was just verified.
& (Join-Path $PSScriptRoot 'Test-Pins.ps1')
if ($LASTEXITCODE) { Write-Host 'Pins disagree (above) -- fix them before building.' -ForegroundColor Red; exit 1 }
