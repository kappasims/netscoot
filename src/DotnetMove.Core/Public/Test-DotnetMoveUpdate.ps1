function Test-DotnetMoveUpdate {
    <#
    .SYNOPSIS
        Check GitHub for a newer DotnetMove release and report whether the installed version is
        behind. On-demand and read-only: it never updates anything itself.

    .DESCRIPTION
        DotnetMove is installed from a clone (not yet on the PowerShell Gallery), so there is no
        automatic update channel. This is the pull-based check: it GETs the latest GitHub release
        and compares its tag (the "available" version) against the installed module's ModuleVersion
        (the "installed" version). It prints what to do when behind, but performs no update - an
        agent or user runs it when they want to know.

        Needs network access to api.github.com. Honors -ErrorAction if the request fails (offline,
        rate-limited, or no releases yet).

    .PARAMETER Repository
        owner/name of the GitHub repository to check. Defaults to the project repository.

    .OUTPUTS
        A pscustomobject with Installed (version), Latest (version), Tag, UpdateAvailable (bool),
        and Url.

    .EXAMPLE
        Test-DotnetMoveUpdate

        Reports whether a newer release exists and, if so, how to update.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidatePattern('^[^/]+/[^/]+$')]
        [string]$Repository = 'kappasims/dotnet-move'
    )

    # The version of the module that exports this function (all DotnetMove manifests share it).
    $installed = $MyInvocation.MyCommand.Module.Version
    if (-not $installed) { $installed = (Get-Module DotnetMove.Core | Select-Object -First 1).Version }

    $uri = "https://api.github.com/repos/$Repository/releases/latest"
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
