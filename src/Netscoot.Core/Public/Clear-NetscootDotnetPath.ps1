function Clear-NetscootDotnetPath {
    <#
    .SYNOPSIS
        Remove the dotnet path stored with Set-NetscootDotnetPath.

    .DESCRIPTION
        Deletes the stored path from the per-user settings file. netscoot is then as it was before
        a path was stored: it runs the dotnet on PATH, and when there is none, the next .NET
        command asks which install to use.

    .OUTPUTS
        None.

    .EXAMPLE
        # Remove the stored path
        Clear-NetscootDotnetPath
        # Preview without removing
        Clear-NetscootDotnetPath -WhatIf

    .LINK
        Set-NetscootDotnetPath

    .LINK
        Get-NetscootCapability
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param()

    $stored = Get-StoredDotnetPath
    if (-not $stored) {
        Write-Host 'No dotnet path is stored.' -ForegroundColor DarkGray
        return
    }
    if (-not $PSCmdlet.ShouldProcess((Get-NetscootSettingFile), "Remove stored dotnet path '$stored'")) { return }
    Remove-StoredDotnetPath
    Write-Host "Removed the stored dotnet path '$stored'." -ForegroundColor DarkGray
}
