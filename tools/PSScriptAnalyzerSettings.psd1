# PSScriptAnalyzer settings for tools\Test-Repo.ps1 and CI (.github\workflows\ci.yml).
# Error severity only: the default Warning/Information rules report ~90 items that are noise for
# this codebase (Write-Host in console tools, plural nouns, ...), and a gate nobody can pass gets ignored.
@{
    Severity     = @('Error')
    ExcludeRules = @(
        # Setup-Synergy.ps1 turns the wizard's password (handed over in the secrets file) into the
        # SecureString New-LocalUser / Set-LocalUser need; there is no encrypted form to start from.
        'PSAvoidUsingConvertToSecureStringWithPlainText'
    )
    Rules        = @{
        # The PCs run Windows PowerShell 5.1: no ??, ?:, ?., && or || (they parse only in 7).
        PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') }
    }
}
