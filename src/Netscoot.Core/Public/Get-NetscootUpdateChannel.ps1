function Get-NetscootUpdateChannel {
    <#
    .SYNOPSIS
        Report the effective update channel (Stable or Beta) and where it was resolved from.

    .DESCRIPTION
        netscoot ships a stable line and, alongside it, opt-in prerelease (beta) builds. The channel
        decides which the updater (Test-NetscootUpdate / Update-Netscoot) tracks:
          Stable  (default) only non-prerelease GitHub releases are offered.
          Beta    prerelease releases (e.g. v3.0.0-beta1) are offered too.

        The channel is stored in the `NETSCOOT_CHANNEL` environment variable, so it can be set with
        Set-NetscootUpdateChannel or pushed by an administrator (Group Policy / Intune / a profile).
        This resolves the value in precedence order: the current process, then (on Windows) the user
        environment, then the machine environment. A value of `beta`/`preview` is Beta; anything else
        or absent is Stable.

    .OUTPUTS
        Netscoot.UpdateChannel

    .EXAMPLE
        # See the current channel and where it came from
        Get-NetscootUpdateChannel

    .LINK
        Set-NetscootUpdateChannel

    .LINK
        Test-NetscootUpdate

    .LINK
        Update-Netscoot
    #>
    [CmdletBinding()]
    [OutputType('Netscoot.UpdateChannel')]
    param()

    # Precedence: a value set for this process wins, then the persisted user value, then the
    # machine value (where an administrator's GPO/Intune push lands). User/Machine targets are
    # Windows-only; on Unix only the process environment is meaningful.
    $resolved = $null
    $source = 'Default'
    $scopes = @('Process')
    if (Test-IsWindowsHost) { $scopes += @('User', 'Machine') }
    foreach ($scope in $scopes) {
        $v = [Environment]::GetEnvironmentVariable('NETSCOOT_CHANNEL', $scope)
        if (-not [string]::IsNullOrWhiteSpace($v)) { $resolved = $v; $source = $scope; break }
    }

    $channel = switch -regex (("$resolved").Trim().ToLowerInvariant()) {
        '^(beta|preview)$' { 'Beta'; break }
        default { 'Stable' }
    }

    [Netscoot.UpdateChannel]@{
        Channel = $channel
        Source  = $source
        Value   = $resolved
    }
}
