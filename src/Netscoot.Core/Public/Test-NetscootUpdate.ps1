function Test-NetscootUpdate {
    <#
    .SYNOPSIS
        Check GitHub for a newer netscoot release and report whether the installed version is
        behind. On-demand and read-only: it never updates anything itself.

    .DESCRIPTION
        netscoot does not update automatically, however it is installed (PowerShell Gallery,
        installer, or a clone). This is the pull-based check: It GETs the latest GitHub release
        and compares its tag (the "available" version) against the installed module's ModuleVersion
        (the "installed" version). It prints what to do when behind, but performs no update - an
        agent or user runs it when they want to know.

        Needs network access to api.github.com. Honors -ErrorAction if the request fails (offline,
        rate-limited, or no releases yet).

        A plain Test-NetscootUpdate always checks. -Auto is the automation/SessionStart entry point:
        It runs the check only when the update policy is Enabled (see Set-NetscootUpdatePolicy), and
        is a silent no-op otherwise. So a hook can call it unconditionally; nothing happens until the
        policy is opted in, and an administrator can disable it fleet-wide. Either way it never
        updates - it only reports.

    .PARAMETER Repository
        The GitHub repository to check, in `owner/name` form. Defaults to the project repository.

    .PARAMETER Auto
        Run as the automatic check (for a SessionStart hook or other automation): proceed only when
        the update policy is Enabled, otherwise do nothing. Still read-only - it never updates.

    .PARAMETER Channel
        Which releases to consider: Stable (only non-prerelease releases) or Beta (prerelease releases
        too, e.g. v3.0.0-beta1). Defaults to the resolved channel (Get-NetscootUpdateChannel).

    .OUTPUTS
        Netscoot.Update - none (writes a non-terminating error) when the release cannot be fetched,
        and nothing at all when -Auto is set but the update policy is not Enabled.

    .EXAMPLE
        # Compare the installed module to the latest GitHub release
        Test-NetscootUpdate
        # Check a fork or a different repository (owner/name)
        Test-NetscootUpdate -Repository myfork/netscoot
        # SessionStart hook: checks only when the update policy is Enabled
        Test-NetscootUpdate -Auto

    .LINK
        Update-Netscoot

    .LINK
        Get-NetscootUpdatePolicy

    .LINK
        Set-NetscootUpdatePolicy
    #>
    [CmdletBinding()]
    [OutputType('Netscoot.Update')]
    param(
        [ValidatePattern('^[^/]+/[^/]+$')]
        [string]$Repository = 'kappasims/netscoot',
        [switch]$Auto,
        [ValidateSet('Stable', 'Beta')]
        [string]$Channel = (Get-NetscootUpdateChannel).Channel
    )

    # Automatic check: do nothing unless the update policy is Enabled. Manual is the default, so a
    # hook calling -Auto stays quiet until someone opts in via Set-NetscootUpdatePolicy.
    if ($Auto -and (Get-NetscootUpdatePolicy).State -ne 'Enabled') {
        Write-Verbose 'Auto-update check skipped: the update policy is not Enabled.'
        return
    }

    # The version of the module that exports this function (all netscoot manifests share it).
    $installed = $MyInvocation.MyCommand.Module.Version
    if (-not $installed) { $installed = (Get-Module Netscoot.Core | Select-Object -First 1).Version }

    # The full installed identity is ModuleVersion + any umbrella PSData.Prerelease (e.g. 3.0.0 +
    # 'beta1' -> 3.0.0-beta1), so a beta install correctly compares against newer betas / the stable.
    # Guarded member access: the umbrella module may not be loaded (Core-only sessions), and StrictMode
    # turns a missing PrivateData/PSData property into a terminating error otherwise.
    $installedPre = $null
    $umbrella = Get-Module Netscoot -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($umbrella -and $umbrella.PrivateData -is [hashtable] -and $umbrella.PrivateData.ContainsKey('PSData')) {
        $psData = $umbrella.PrivateData['PSData']
        if ($psData -is [hashtable] -and $psData.ContainsKey('Prerelease')) { $installedPre = $psData['Prerelease'] }
    }
    $installedFull = "$installed"
    if (-not [string]::IsNullOrWhiteSpace("$installedPre")) { $installedFull = "$installed-$installedPre" }

    $release = $null
    if ($Channel -eq 'Beta') {
        # Beta tracks prereleases too. /releases returns an array (newest-first by publish date); pick
        # the newest by SemVer precedence (Compare-NetscootSemVer), which correctly ranks prereleases.
        $uri = "https://api.github.com/repos/$Repository/releases?per_page=20"
        $list = $null
        try {
            $list = Invoke-RestMethod -Uri $uri -Headers @{ 'User-Agent' = 'Netscoot'; 'Accept' = 'application/vnd.github+json' } -ErrorAction Stop
        } catch {
            Write-Verbose "Release check request failed: $($_.Exception.Message)"   # reported by the null-check below
        }
        foreach ($r in @($list)) {
            if ([string]::IsNullOrWhiteSpace("$($r.tag_name)")) { continue }
            if ($null -eq $release -or (Compare-NetscootSemVer -Reference "$($r.tag_name)" -Difference "$($release.tag_name)") -gt 0) {
                $release = $r
            }
        }
    } else {
        # Stable: /repos/<owner>/<name>/releases/latest - NOT /repositories/, which is the numeric-
        # repo-id endpoint and 404s for an owner/name string (the 404 was swallowed and surfaced as a
        # generic "could not get release", so every update check failed regardless of network state).
        # /releases/latest never returns a prerelease, so Stable never sees beta tags.
        $uri = "https://api.github.com/repos/$Repository/releases/latest"
        try {
            $release = Invoke-RestMethod -Uri $uri -Headers @{ 'User-Agent' = 'Netscoot'; 'Accept' = 'application/vnd.github+json' } -ErrorAction Stop
        } catch {
            Write-Verbose "Release check request failed: $($_.Exception.Message)"   # reported by the null-check below
        }
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

    # SemVer-aware compare on the FULL identities (prerelease-inclusive), replacing the old core-only
    # -gt. An update is available when the release outranks what's installed.
    $available = $false
    if ($null -ne $latest -and $null -ne $installed) {
        $available = (Compare-NetscootSemVer -Reference $tag -Difference $installedFull) -gt 0
    }
    $result = [pscustomobject]@{
        Installed       = $installed
        Latest          = $latest
        Tag             = $tag
        UpdateAvailable = $available
        Url             = "$($release.html_url)"
        Channel         = $Channel
    }

    if ($available) {
        Write-Host "netscoot $tag is available (installed $installed)." -ForegroundColor Yellow
        Write-Host "Update from your clone: git pull, then ./build.ps1 -Task Install" -ForegroundColor Yellow
        Write-Host $result.Url -ForegroundColor DarkGray
    } else {
        Write-Host "netscoot is up to date (installed $installed, latest $tag)." -ForegroundColor Green
    }
    $result
}
