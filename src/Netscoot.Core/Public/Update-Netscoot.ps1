function Update-Netscoot {
    <#
    .SYNOPSIS
        Update an installed netscoot to the latest GitHub release, in place. The one-command
        update for non-clone installs.

    .DESCRIPTION
        Checks GitHub for a newer release (via Test-NetscootUpdate) and, if the installed version
        is behind, downloads the release's source archive and copies its module folders to the
        current user's module path, the same place install.ps1 installs to. It runs nothing it
        downloads. No git, no clone. Does nothing when already current unless -Force. Honors
        -WhatIf/-Confirm.

        After it runs, reload the module in the current session with `Import-Module Netscoot -Force`.
        Needs network access to GitHub. For Gallery installs, use `Update-Module Netscoot` (with
        `-AllowPrerelease` for betas) instead. This command updates installer installs in place from
        the GitHub release, and replaces a Gallery install's folder with an installer copy. The Claude
        Code plugin carries its own copy of the module and updates it itself. This command never
        touches that copy.

        When the update policy is Disabled (see Set-NetscootUpdatePolicy), this refuses to update.
        -Force overrides a policy you set for yourself, never one an administrator set.

    .PARAMETER Force
        Reinstall the latest release even if already current, and override a Disabled update policy
        that you set for yourself.

    .PARAMETER Repository
        The GitHub repository to install from, in `owner/name` form. Defaults to the project
        repository.

    .PARAMETER Channel
        Which releases to consider: Stable or Beta (prerelease releases too). Defaults to the resolved
        channel (Get-NetscootUpdateChannel). Set Beta to track prerelease builds.

    .OUTPUTS
        Netscoot.Update - the record from Test-NetscootUpdate, so the decision is inspectable. Nothing
        when the update policy blocks the update or the check fails.

    .EXAMPLE
        # Update to the latest release if the installed copy is behind
        Update-Netscoot
        # Report what it would do without downloading or installing
        Update-Netscoot -WhatIf
        # Reinstall the latest even if already up to date
        Update-Netscoot -Force

    .LINK
        Test-NetscootUpdate

    .LINK
        Get-NetscootUpdatePolicy

    .LINK
        Set-NetscootUpdatePolicy
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType('Netscoot.Update')]
    param(
        [switch]$Force,
        [ValidatePattern('^[^/]+/[^/]+$')]
        [string]$Repository = 'kappasims/netscoot',
        [ValidateSet('Stable', 'Beta')]
        [string]$Channel = (Get-NetscootUpdateChannel).Channel
    )

    # Policy kill-switch, checked before the network call so a disabled fleet makes no request.
    # -Force overrides a Disabled the user set for themselves, never an administrator's.
    $policy = Get-NetscootUpdatePolicy
    if ($policy.State -eq 'Disabled') {
        if ($policy.Source -eq 'Machine') {
            Write-Warning 'Updates are disabled by an administrator (machine-scope policy); -Force cannot override. Update through your managed pipeline, or contact your administrator.'
            return
        }
        if (-not $Force) {
            Write-Warning 'Updates are disabled by the update policy. Use -Force to override, or run Set-NetscootUpdatePolicy -State Manual.'
            return
        }
    }

    $check = Test-NetscootUpdate -Repository $Repository -Channel $Channel
    if (-not $check) { return }   # connection error already surfaced by Test-NetscootUpdate

    if (-not $check.UpdateAvailable -and -not $Force) {
        Write-Host "netscoot is already up to date (installed $($check.Installed))." -ForegroundColor Green
        return $check
    }

    if ($PSCmdlet.ShouldProcess('Netscoot', "update to $($check.Tag) from GitHub")) {
        $modulesRoot = if (Test-IsWindowsHost) {
            $editionDir = if ($PSVersionTable.PSEdition -eq 'Core') { 'PowerShell' } else { 'WindowsPowerShell' }
            Join-Path ([Environment]::GetFolderPath('MyDocuments')) (Join-Path $editionDir 'Modules')
        } else {
            Join-Path $HOME '.local/share/powershell/Modules'
        }
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('netscoot_update_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            $zip = Join-Path $tmp 'src.zip'
            Invoke-WebRequest -Uri "https://github.com/$Repository/archive/refs/tags/$($check.Tag).zip" `
                -OutFile $zip -UseBasicParsing -Headers @{ 'User-Agent' = 'Netscoot' } -ErrorAction Stop
            Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
            $srcRoot = Join-Path (Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1).FullName 'src'
            if (-not (Test-Path -LiteralPath $srcRoot)) { throw "The $($check.Tag) release archive has no src/ folder." }
            # A module folder holds a manifest of its own name, which skips the plugin's skills/ and .claude-plugin/.
            $moduleFolders = @(Get-ChildItem -LiteralPath $srcRoot -Directory |
                    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "$($_.Name).psd1") })
            New-Item -ItemType Directory -Path $modulesRoot -Force | Out-Null
            foreach ($folder in $moduleFolders) {
                $dest = Join-Path $modulesRoot $folder.Name
                if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
                Copy-Item -LiteralPath $folder.FullName -Destination $dest -Recurse -Force
            }
            Write-Host "Installed netscoot $($check.Tag) to $modulesRoot" -ForegroundColor Green
            Write-Host 'Reload it in this session: Import-Module Netscoot -Force' -ForegroundColor Cyan
        } finally {
            # A throw here would replace the update's own error, so a failed cleanup is a warning.
            try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction Stop }
            catch { Write-Warning "Could not remove the temporary folder ${tmp}: $($_.Exception.Message)" }
        }
    }
    return $check
}
