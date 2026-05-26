function Test-DotnetMoveUpdate {
    <#
    .SYNOPSIS
        Check GitHub for a newer DotnetMove release and report whether the installed version is
        behind. On-demand and read-only: it never updates anything itself.

    .DESCRIPTION
        DotnetMove does not update automatically, however it is installed (PowerShell Gallery,
        installer, or a clone). This is the pull-based check: it GETs the latest GitHub release
        and compares its tag (the "available" version) against the installed module's ModuleVersion
        (the "installed" version). It prints what to do when behind, but performs no update - an
        agent or user runs it when they want to know.

        Needs network access to api.github.com. Honors -ErrorAction if the request fails (offline,
        rate-limited, or no releases yet).

        -EnableAutoUpdate makes this the automation/SessionStart entry point: it runs the check ONLY
        when $env:DOTNETMOVE_AUTOUPDATE is set to a truthy value (1/true/on/yes/enabled), and is a
        silent no-op otherwise. So a hook can call it unconditionally; nothing happens until a user
        opts in, and IT can disable it fleet-wide by clearing or setting the variable to false via
        Group Policy / Intune / a profile. A plain Test-DotnetMoveUpdate (no switch) always checks.

    .PARAMETER Repository
        owner/name of the GitHub repository to check. Defaults to the project repository.

    .PARAMETER EnableAutoUpdate
        Run as the gated auto-check (for a SessionStart hook or other automation): proceed only when
        $env:DOTNETMOVE_AUTOUPDATE is truthy, otherwise do nothing. Still read-only - it never updates.

    .OUTPUTS
        DotnetMove.Update - none (writes a non-terminating error) when the release cannot be fetched,
        and nothing at all when -EnableAutoUpdate is set but $env:DOTNETMOVE_AUTOUPDATE is not enabled.

    .EXAMPLE
        # Compare the installed module to the latest GitHub release
        Test-DotnetMoveUpdate
        # Check a fork or a different repository (owner/name)
        Test-DotnetMoveUpdate -Repository myfork/dotnet-move
        # SessionStart hook: checks only if the user/fleet opted in via $env:DOTNETMOVE_AUTOUPDATE
        Test-DotnetMoveUpdate -EnableAutoUpdate
    #>
    [CmdletBinding()]
    [OutputType('DotnetMove.Update')]
    param(
        [ValidatePattern('^[^/]+/[^/]+$')]
        [string]$Repository = 'kappasims/dotnet-move',
        [switch]$EnableAutoUpdate
    )

    # Gated auto-check: do nothing unless the user/fleet opted in. Default is OFF (no auto-check),
    # so a hook calling this stays quiet until $env:DOTNETMOVE_AUTOUPDATE is turned on.
    if ($EnableAutoUpdate -and (("$env:DOTNETMOVE_AUTOUPDATE").Trim().ToLowerInvariant() -notmatch '^(1|true|on|yes|enabled)$')) {
        Write-Verbose 'Auto-update check skipped: $env:DOTNETMOVE_AUTOUPDATE is not enabled.'
        return
    }

    # The version of the module that exports this function (all DotnetMove manifests share it).
    $installed = $MyInvocation.MyCommand.Module.Version
    if (-not $installed) { $installed = (Get-Module DotnetMove.Core | Select-Object -First 1).Version }

    $uri = "https://api.github.com/repositories/$Repository/releases/latest"
    $release = $null
    try {
        $release = Invoke-RestMethod -Uri $uri -Headers @{ 'User-Agent' = 'DotnetMove'; 'Accept' = 'application/vnd.github+json' } -ErrorAction Stop
    } catch {
        Write-Verbose "Release check request failed: $($_.Exception.Message)"   # reported by the null-check below
    }
    if ($null -eq $release -or [string]::IsNullOrWhiteSpace("$($release.tag_name)")) {
        $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new("Could not get the latest release from $uri (offline, rate-limited, or no release yet)."),
                'UpdateCheckFailed', [System.Management.Automation.ErrorCategory]::ConnectionError, $uri))
        return
    }

    $tag = "$($release.tag_name)"
    $latest = $null
    if ($tag -match '(\d+\.\d+\.\d+)') { $latest = [version]$Matches[1] }

    $available = ($null -ne $latest -and $null -ne $installed -and $latest -gt $installed)
    $result = [pscustomobject]@{
        Installed       = $installed
        Latest          = $latest
        Tag             = $tag
        UpdateAvailable = $available
        Url             = "$($release.html_url)"
    }

    if ($available) {
        Write-Host "DotnetMove $tag is available (installed $installed)." -ForegroundColor Yellow
        Write-Host "Update from your clone: git pull, then ./build.ps1 -Task Install" -ForegroundColor Yellow
        Write-Host $result.Url -ForegroundColor DarkGray
    } else {
        Write-Host "DotnetMove is up to date (installed $installed, latest $tag)." -ForegroundColor Green
    }
    $result
}
