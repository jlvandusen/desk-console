<#
  Get-Redist.ps1 -- download the third-party installers the setup bundles, into installer\redist\,
  and check each one's SHA-256 (and Authenticode signature where the vendor signs it).
  Run before building installer\DeskConsole.iss. Nothing here is committed to git.

    powershell -ExecutionPolicy Bypass -File tools\Get-Redist.ps1

  Synergy is commercial and is never downloaded or bundled: put its MSI in the shared folder's
  installer\ folder yourself if you use it (Setup-Synergy.ps1 checks its hash).
#>
$ErrorActionPreference = 'Stop'
$dest = Join-Path (Split-Path $PSScriptRoot -Parent) 'installer\redist'
New-Item -ItemType Directory -Force $dest | Out-Null

$items = @(
    @{ Name = 'rustdesk-1.5.0-x86_64.msi'
       Url  = 'https://github.com/rustdesk/rustdesk/releases/download/1.5.0/rustdesk-1.5.0-x86_64.msi'
       Sha  = '624FE792AB1D76B35134DAB84BFF97A6BCD14043FFD090A2C6A2800F77580495'; Signer = 'PURSLANE' }
    @{ Name = 'deskflow-1.27.0-win-x64.msi'
       Url  = 'https://github.com/deskflow/deskflow/releases/download/v1.27.0/deskflow-1.27.0-win-x64.msi'
       Sha  = '0CA5668C4731F5477D0B189BDB11196A2CA51281985D9D8C0757BF7F3B782D64'; Signer = $null }   # upstream does not sign
    @{ Name = 'vc_redist.x64.exe'   # Microsoft Visual C++ 2015-2022 runtime 14.44.35211.0 (Deskflow needs 14.44+)
       Url  = 'https://download.visualstudio.microsoft.com/download/pr/990c720a-46ce-4dc7-87b9-c2eb615d34b9/CC0FF0EB1DC3F5188AE6300FAEF32BF5BEEBA4BDD6E8E445A9184072096B713B/VC_redist.x64.exe'
       Sha  = 'CC0FF0EB1DC3F5188AE6300FAEF32BF5BEEBA4BDD6E8E445A9184072096B713B'; Signer = 'Microsoft Corporation' }
)

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
