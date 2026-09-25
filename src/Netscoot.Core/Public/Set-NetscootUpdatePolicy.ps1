function Set-NetscootUpdatePolicy {
    <#
    .SYNOPSIS
        Set netscoot's auto-update policy to Enabled, Disabled, or Manual.

    .DESCRIPTION
        Writes the `NETSCOOT_AUTOUPDATE` environment variable that governs update behavior (see
        Get-NetscootUpdatePolicy for the three states). The change always takes effect in the current
        session, and the scope controls how far it persists:
          -Scope User    (default) persists for the current user (Windows).
          -Scope Machine persists for all users (Windows), and needs an elevated session.
          -Scope Process this session only, with nothing persisted.
        On non-Windows, User/Machine cannot be persisted programmatically, so this sets the session
        value and prints the line to add to your shell profile.

        An administrator can achieve the same fleet-wide by pushing `NETSCOOT_AUTOUPDATE` through
        Group Policy / Intune. This cmdlet is the per-user equivalent.

    .PARAMETER State
        Enabled, Disabled, or Manual.

    .PARAMETER Scope
        How far to persist: User (default, Windows), Machine (Windows, elevated), or Process (this
        session only).

    .OUTPUTS
        Netscoot.UpdatePolicy - the resulting effective policy.

    .EXAMPLE
        # Opt in to automatic checks (Test-NetscootUpdate -Auto, e.g. from a SessionStart hook you configure)
        Set-NetscootUpdatePolicy -State Enabled
        # Block updates on this machine for every user (run elevated)
        Set-NetscootUpdatePolicy -State Disabled -Scope Machine
        # Back to the default: no auto-check, manual Update-Netscoot still works
        Set-NetscootUpdatePolicy -State Manual

    .LINK
        Get-NetscootUpdatePolicy

    .LINK
        Test-NetscootUpdate

    .LINK
        Update-Netscoot
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Netscoot.UpdatePolicy')]
    param(
        [Parameter(Mandatory)][ValidateSet('Enabled', 'Disabled', 'Manual')][string]$State,
        [ValidateSet('User', 'Machine', 'Process')][string]$Scope = 'User'
    )

    # Manual is the neutral default, represented by clearing the variable.
    $value = switch ($State) { 'Enabled' { '1' } 'Disabled' { '0' } 'Manual' { $null } }

    if (-not $PSCmdlet.ShouldProcess("NETSCOOT_AUTOUPDATE ($Scope)", "set update policy to $State")) {
        return Get-NetscootUpdatePolicy
    }

    # Always update the current process so the new policy applies right away.
    if ($null -eq $value) { Remove-Item Env:\NETSCOOT_AUTOUPDATE -ErrorAction SilentlyContinue }
    else { Set-Item -Path Env:\NETSCOOT_AUTOUPDATE -Value $value }

    # Persist beyond the session for User/Machine; -Scope Process is session-only (nothing more to do).
    if ($Scope -ne 'Process') {
        if (Test-IsWindowsHost) {
            try {
                [Environment]::SetEnvironmentVariable('NETSCOOT_AUTOUPDATE', $value, $Scope)
            } catch {
                $hint = if ($Scope -eq 'Machine') { ' Machine scope needs an elevated (Administrator) session.' } else { '' }
                $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                        [System.InvalidOperationException]::new("Could not persist the update policy at $Scope scope: $($_.Exception.Message).$hint"),
                        'SetPolicyFailed', [System.Management.Automation.ErrorCategory]::PermissionDenied, $Scope))
            }
        } else {
            # Unix: not persistable from here. Set for the session (done above) and show the profile line.
            $line = if ($null -eq $value) { 'unset NETSCOOT_AUTOUPDATE' } else { "export NETSCOOT_AUTOUPDATE=$value" }
            Write-Host "Set for this session. To persist, add to your shell profile: $line" -ForegroundColor Cyan
        }
    }

    Get-NetscootUpdatePolicy
}
