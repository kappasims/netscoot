function Update-DotnetMove {
    <#
    .SYNOPSIS
        Update an installed DotnetMove to the latest GitHub release, in place. The one-command
        update for non-clone installs.

    .DESCRIPTION
        Checks GitHub for a newer release (via Test-DotnetMoveUpdate) and, if the installed version
        is behind, runs the release's install.ps1 to overwrite the modules on your module path. No
        git, no clone. Does nothing when already current unless -Force. Honors -WhatIf/-Confirm.

        After it runs, reload the module in the current session with `Import-Module DotnetMove -Force`.
        Needs network access to GitHub. For Gallery installs, `Update-Module DotnetMove` is the
        simpler path; this command updates installer/clone installs in place from the GitHub release.

    .PARAMETER Force
        Reinstall the latest release even if the installed version is already current.

    .PARAMETER Repository
        owner/name of the GitHub repository. Defaults to the project repository.

    .OUTPUTS
        DotnetMove.Update - the record from Test-DotnetMoveUpdate, so the decision is inspectable. Nothing on a failed check.

    .EXAMPLE
        # Update to the latest release if the installed copy is behind
        Update-DotnetMove
        # Report what it would do without downloading or installing
        Update-DotnetMove -WhatIf
        # Reinstall the latest even if already up to date
        Update-DotnetMove -Force
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType('DotnetMove.Update')]
    param(
        [switch]$Force,
        [ValidatePattern('^[^/]+/[^/]+$')]
        [string]$Repository = 'kappasims/dotnet-move'
    )

    $check = Test-DotnetMoveUpdate -Repository $Repository
    if (-not $check) { return }   # connection error already surfaced by Test-DotnetMoveUpdate

    if (-not $check.UpdateAvailable -and -not $Force) {
        Write-Host "DotnetMove is already up to date (installed $($check.Installed))." -ForegroundColor Green
        return $check
    }

    if ($PSCmdlet.ShouldProcess('DotnetMove', "update to $($check.Tag) from GitHub")) {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("dotnetmove_update_" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
        try {
            # -OutFile writes the installer without a content-write cmdlet (keeps the first-party
            # drift monitor happy); Unblock-File clears the mark-of-the-web so it can run.
            Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$Repository/$($check.Tag)/install.ps1" `
                -OutFile $tmp -Headers @{ 'User-Agent' = 'DotnetMove' } -ErrorAction Stop
            if (Get-Command Unblock-File -ErrorAction SilentlyContinue) { Unblock-File -LiteralPath $tmp }
            & $tmp
            Write-Host 'Reload it in this session: Import-Module DotnetMove -Force' -ForegroundColor Cyan
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    return $check
}
