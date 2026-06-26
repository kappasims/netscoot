function Set-NetscootUpdateChannel {
    <#
    .SYNOPSIS
        Set netscoot's update channel to Stable or Beta.

    .DESCRIPTION
        Writes the `NETSCOOT_CHANNEL` environment variable that governs which releases the updater
        offers (see Get-NetscootUpdateChannel). The change always takes effect in the current session;
        the scope controls how far it persists:
          -Scope Process (default) this session only; nothing is persisted.
          -Scope User    persists for the current user (Windows).
          -Scope Machine persists for all users (Windows); needs an elevated session.
        On non-Windows, User/Machine cannot be persisted programmatically, so this sets the session
        value and prints the line to add to your shell profile.

        Stable is the neutral default, represented by clearing the variable; Beta sets it to `beta`.

    .PARAMETER Channel
        Stable or Beta. Beta opts the updater into prerelease releases (e.g. v3.0.0-beta1).

    .PARAMETER Scope
        How far to persist: Process (default, this session only), User (Windows), or Machine (Windows,
        elevated).

    .OUTPUTS
        Netscoot.UpdateChannel - the resulting effective channel.

    .EXAMPLE
        # Opt into prerelease (beta) updates for this session
        Set-NetscootUpdateChannel -Channel Beta
        # Persist beta for the current user (Windows)
        Set-NetscootUpdateChannel -Channel Beta -Scope User
        # Back to the default stable line
        Set-NetscootUpdateChannel -Channel Stable

    .LINK
        Get-NetscootUpdateChannel

    .LINK
        Test-NetscootUpdate

    .LINK
        Update-Netscoot
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType('Netscoot.UpdateChannel')]
    param(
        [Parameter(Mandatory)][ValidateSet('Stable', 'Beta')][string]$Channel,
        [ValidateSet('Process', 'User', 'Machine')][string]$Scope = 'Process'
    )

    # Stable is the neutral default, represented by clearing the variable.
    $value = switch ($Channel) { 'Beta' { 'beta' } 'Stable' { $null } }

    if (-not $PSCmdlet.ShouldProcess("NETSCOOT_CHANNEL ($Scope)", "set update channel to $Channel")) {
        return Get-NetscootUpdateChannel
    }

    # Always update the current process so the new channel applies right away.
    if ($null -eq $value) { Remove-Item Env:\NETSCOOT_CHANNEL -ErrorAction SilentlyContinue }
    else { Set-Item -Path Env:\NETSCOOT_CHANNEL -Value $value }

    # Persist beyond the session for User/Machine; -Scope Process is session-only (nothing more to do).
    if ($Scope -ne 'Process') {
        if (Test-IsWindowsHost) {
            try {
                [Environment]::SetEnvironmentVariable('NETSCOOT_CHANNEL', $value, $Scope)
            } catch {
                $hint = if ($Scope -eq 'Machine') { ' Machine scope needs an elevated (Administrator) session.' } else { '' }
                $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                        [System.InvalidOperationException]::new("Could not persist the update channel at $Scope scope: $($_.Exception.Message).$hint"),
                        'SetChannelFailed', [System.Management.Automation.ErrorCategory]::PermissionDenied, $Scope))
            }
        } else {
            # Unix: not persistable from here. Set for the session (done above) and show the profile line.
            $line = if ($null -eq $value) { 'unset NETSCOOT_CHANNEL' } else { "export NETSCOOT_CHANNEL=$value" }
            Write-Host "Set for this session. To persist, add to your shell profile: $line" -ForegroundColor Cyan
        }
    }

    Get-NetscootUpdateChannel
}
