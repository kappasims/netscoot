function Unregister-NetscootGitAlias {
    <#
    .SYNOPSIS
        Remove the `git netscoot` alias registered by Register-NetscootGitAlias.

    .PARAMETER Scope
        'Local' (this repository, default) or 'Global'.

    .OUTPUTS
        None.

    .EXAMPLE
        # Remove the alias for this repository (default scope is Local)
        Unregister-NetscootGitAlias
        # Remove the global alias from ~/.gitconfig
        Unregister-NetscootGitAlias -Scope Global

    .LINK
        Register-NetscootGitAlias
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([void])]
    param(
        [ValidateSet('Local', 'Global')]
        [string]$Scope = 'Local'
    )

    if (-not (Test-GitAvailable)) {
        Write-CapabilityGuidance -Tool git
        $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new('git is required to remove a git alias but was not found.'),
                'GitMissing', [System.Management.Automation.ErrorCategory]::NotInstalled, $null))
        return
    }

    $scopeFlag = if ($Scope -eq 'Global') { '--global' } else { '--local' }
    if ($PSCmdlet.ShouldProcess("git config ($Scope)", 'unset alias.netscoot')) {
        # Ignore keeps Windows PowerShell 5.1 from recording git's stderr as an error, and the exit code decides.
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Ignore'
        try { & git config $scopeFlag --unset alias.netscoot 2>$null }
        finally { $ErrorActionPreference = $prev }
        # Exit 5 means the alias was not set, which counts as already removed.
        if ($LASTEXITCODE -in 0, 5) {
            Write-Host "Unregistered 'git netscoot' ($Scope)." -ForegroundColor Green
        } else {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new("git config --unset failed (exit $LASTEXITCODE). For -Scope Local you must be inside a git repository."),
                    'GitConfigFailed', [System.Management.Automation.ErrorCategory]::InvalidOperation, $null))
        }
    }
}
