function Unregister-ScootGitAlias {
    <#
    .SYNOPSIS
        Remove the `git netscoot` alias registered by Register-ScootGitAlias.

    .PARAMETER Scope
        'Local' (this repository, default) or 'Global'.

    .OUTPUTS
        None.

    .EXAMPLE
        # Remove the alias for this repository (default scope is Local)
        Unregister-ScootGitAlias
        # Remove the global alias from ~/.gitconfig
        Unregister-ScootGitAlias -Scope Global
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [ValidateSet('Local', 'Global')]
        [string]$Scope = 'Local'
    )

    if (-not (Test-GitAvailable)) {
        Write-CapabilityGuidance -Tool git
        $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new('git is required but was not found.'),
                'GitMissing', [System.Management.Automation.ErrorCategory]::NotInstalled, $null))
        return
    }

    $scopeFlag = if ($Scope -eq 'Global') { '--global' } else { '--local' }
    if ($PSCmdlet.ShouldProcess("git config ($Scope)", 'unset alias.netscoot')) {
        & git config $scopeFlag --unset alias.netscoot 2>$null
        # exit 5 = key not present; treat as already-removed (idempotent).
        if ($LASTEXITCODE -in 0, 5) {
            Write-Host "Unregistered 'git netscoot' ($Scope)." -ForegroundColor Green
        } else {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new("git config --unset failed (exit $LASTEXITCODE)."),
                    'GitConfigFailed', [System.Management.Automation.ErrorCategory]::InvalidOperation, $null))
        }
    }
}
