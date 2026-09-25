function Get-NetscootUpdatePolicy {
    <#
    .SYNOPSIS
        Report the effective auto-update policy and where it was resolved from.

    .DESCRIPTION
        netscoot's update behavior is governed by one policy with three states:
          Enabled   automatic checks run (Test-NetscootUpdate -Auto), and Update-Netscoot is allowed.
          Manual    (default) no automatic check runs, but a Update-Netscoot you invoke yourself works.
          Disabled  automatic checks do nothing, and Update-Netscoot refuses (-Force overrides).

        The policy is stored in the `NETSCOOT_AUTOUPDATE` environment variable, so it can be set with
        Set-NetscootUpdatePolicy or pushed by an administrator (Group Policy / Intune / a profile).
        An administrator's machine-wide Disabled always applies. Otherwise the value resolves in
        precedence order: the current process, then (on Windows) the user environment, then the
        machine environment. A truthy value (`1`/`true`/`on`) is Enabled, a falsy one
        (`0`/`false`/`off`) is Disabled, and absent or unrecognized is Manual.

    .OUTPUTS
        Netscoot.UpdatePolicy

    .EXAMPLE
        # See the current policy and where it came from
        Get-NetscootUpdatePolicy

    .LINK
        Set-NetscootUpdatePolicy

    .LINK
        Test-NetscootUpdate

    .LINK
        Update-Netscoot
    #>
    [CmdletBinding()]
    [OutputType('Netscoot.UpdatePolicy')]
    param()

    # An administrator's machine-scope Disabled wins outright. Otherwise a value set for this process
    # wins, then the persisted user value, then the machine value. User/Machine targets are
    # Windows-only; on Unix only the process environment is meaningful.
    $toState = {
        param([string]$Value)
        switch -regex (("$Value").Trim().ToLowerInvariant()) {
            '^(1|true|on|yes|enabled)$' { 'Enabled'; break }
            '^(0|false|off|no|disabled)$' { 'Disabled'; break }
            default { 'Manual' }
        }
    }
    $resolved = $null
    $source = 'Default'
    $scopes = @('Process')
    if (Test-IsWindowsHost) {
        $machine = [Environment]::GetEnvironmentVariable('NETSCOOT_AUTOUPDATE', 'Machine')
        $scopes = if ((& $toState $machine) -eq 'Disabled') { @('Machine') } else { @('Process', 'User', 'Machine') }
    }
    foreach ($scope in $scopes) {
        $v = [Environment]::GetEnvironmentVariable('NETSCOOT_AUTOUPDATE', $scope)
        if (-not [string]::IsNullOrWhiteSpace($v)) { $resolved = $v; $source = $scope; break }
    }
    $state = & $toState $resolved

    [pscustomobject]@{
        PSTypeName = 'Netscoot.UpdatePolicy'
        State      = $state
        Source     = $source
        Value      = $resolved
    }
}
