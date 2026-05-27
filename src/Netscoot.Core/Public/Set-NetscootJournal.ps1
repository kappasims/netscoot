function Set-NetscootJournal {
    <#
    .SYNOPSIS
        Turn the move journal on or off, per repository (default) or for every repository (-Global).

    .DESCRIPTION
        Journaling is on by default. This cmdlet writes the git setting that the precedence stack
        reads (git config netscoot.journal), so the choice persists across sessions and rides along
        with the repository's git config - no environment variable to remember. Local config (the
        default here) wins over global, matching the resolution order in Test-MoveJournalEnabled.

        With -Global it writes the user's global git config, switching the default for every
        repository on the machine in one place. Requires git; with no git, set $env:NETSCOOT_JOURNAL
        instead.

    .PARAMETER Enabled
        $true to journal moves (the default behavior), $false to stop journaling.

    .PARAMETER Global
        Write the user's global git config instead of the repository's local config.

    .PARAMETER RepositoryRoot
        Repository whose local config to write. Defaults to the enclosing git repository root.
        Ignored with -Global.

    .OUTPUTS
        None.

    .EXAMPLE
        # Stop journaling in this repository only
        Set-NetscootJournal -Enabled $false
        # Turn it back on
        Set-NetscootJournal -Enabled $true
        # Turn journaling off for every repository on the machine
        Set-NetscootJournal -Enabled $false -Global
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][bool]$Enabled,
        [switch]$Global,
        [string]$RepositoryRoot
    )

    $value = if ($Enabled) { 'true' } else { 'false' }

    if ($Global) {
        $scope = 'global git config'
        $gitArgs = @('config', '--global', 'netscoot.journal', $value)
    } else {
        if (-not $RepositoryRoot) { $RepositoryRoot = Get-RepositoryRoot -StartPath (Get-Location).Path }
        $repoFull = Resolve-FullPath $RepositoryRoot
        $scope = "local git config of '$repoFull'"
        $gitArgs = @('-C', $repoFull, 'config', 'netscoot.journal', $value)
    }

    if (-not $PSCmdlet.ShouldProcess($scope, "Set netscoot.journal = $value")) { return }

    & git @gitArgs 2>$null
    if ($LASTEXITCODE -ne 0) {
        $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new("Could not write $scope. Is git installed and (for local scope) is this a git repository? With no git, set `$env:NETSCOOT_JOURNAL instead."),
                'GitConfigFailed', [System.Management.Automation.ErrorCategory]::InvalidOperation, $scope))
        return
    }
    Write-Host "Journaling $(if ($Enabled) { 'on' } else { 'off' }) ($scope)." -ForegroundColor DarkGray
}
