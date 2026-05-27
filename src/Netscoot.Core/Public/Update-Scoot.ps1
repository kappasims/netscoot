function Update-Scoot {
    <#
    .SYNOPSIS
        Update an installed netscoot to the latest GitHub release, in place. The one-command
        update for non-clone installs.

    .DESCRIPTION
        Checks GitHub for a newer release (via Test-ScootUpdate) and, if the installed version
        is behind, runs the release's install.ps1 to overwrite the modules on your module path. No
        git, no clone. Does nothing when already current unless -Force. Honors -WhatIf/-Confirm.

        After it runs, reload the module in the current session with `Import-Module Netscoot -Force`.
        Needs network access to GitHub. For Gallery installs, `Update-Module Netscoot` is the
        simpler path; this command updates installer/clone installs in place from the GitHub release.

        Policy kill-switch: when $env:NETSCOOT_AUTOUPDATE is set to a falsy value (0/false/off/no/
        disabled) - e.g. pushed by IT via Group Policy / Intune - this refuses to update so machine
        state stays managed. -Force overrides the policy (and also reinstalls when already current).

    .PARAMETER Force
        Reinstall the latest release even if already current, and override the
        $env:NETSCOOT_AUTOUPDATE policy block.

    .PARAMETER Repository
        owner/name of the GitHub repository. Defaults to the project repository.

    .OUTPUTS
        Netscoot.Update - the record from Test-ScootUpdate, so the decision is inspectable. Nothing on a failed check.

    .EXAMPLE
        # Update to the latest release if the installed copy is behind
        Update-Scoot
        # Report what it would do without downloading or installing
        Update-Scoot -WhatIf
        # Reinstall the latest even if already up to date
        Update-Scoot -Force
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType('Netscoot.Update')]
    param(
        [switch]$Force,
        [ValidatePattern('^[^/]+/[^/]+$')]
        [string]$Repository = 'kappasims/netscoot'
    )

    # Policy kill-switch (GPO/Intune-friendly): refuse when auto-update is explicitly disabled, so a
    # managed fleet does not self-update outside its own pipeline. -Force overrides. Checked before
    # the network call so a disabled fleet makes no request.
    if ((-not $Force) -and (("$env:NETSCOOT_AUTOUPDATE").Trim().ToLowerInvariant() -match '^(0|false|off|no|disabled)$')) {
        Write-Warning 'Updates are disabled by policy ($env:NETSCOOT_AUTOUPDATE is off). Use -Force to override, or have IT clear the setting.'
        return
    }

    $check = Test-ScootUpdate -Repository $Repository
    if (-not $check) { return }   # connection error already surfaced by Test-ScootUpdate

    if (-not $check.UpdateAvailable -and -not $Force) {
        Write-Host "netscoot is already up to date (installed $($check.Installed))." -ForegroundColor Green
        return $check
    }

    if ($PSCmdlet.ShouldProcess('Netscoot', "update to $($check.Tag) from GitHub")) {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("netscoot_update_" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
        try {
            # -OutFile writes the installer without a content-write cmdlet (keeps the first-party
            # drift monitor happy); Unblock-File clears the mark-of-the-web so it can run.
            Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$Repository/$($check.Tag)/install.ps1" `
                -OutFile $tmp -Headers @{ 'User-Agent' = 'Netscoot' } -ErrorAction Stop
            if (Get-Command Unblock-File -ErrorAction SilentlyContinue) { Unblock-File -LiteralPath $tmp }
            & $tmp
            Write-Host 'Reload it in this session: Import-Module Netscoot -Force' -ForegroundColor Cyan
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    return $check
}
