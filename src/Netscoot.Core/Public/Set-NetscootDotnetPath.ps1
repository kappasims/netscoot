function Set-NetscootDotnetPath {
    <#
    .SYNOPSIS
        Store the dotnet executable netscoot runs, for a machine where dotnet is not on PATH.

    .DESCRIPTION
        Checks that the executable reports a .NET SDK version, then stores its path in the per-user
        settings file, next to the move journal. Every later netscoot command uses the stored
        path, and it takes precedence over a dotnet on PATH. To use a different install, store
        its path. Get-NetscootCapability lists the installs found on the machine and shows which
        dotnet is in use.

        A stored path that no longer exists stops a .NET command with an error naming it. netscoot
        does not switch to another install by itself.

    .PARAMETER Path
        The dotnet executable to store, for example 'C:\Program Files\dotnet\dotnet.exe'.

    .OUTPUTS
        None.

    .EXAMPLE
        # See which installs the machine has, then store one
        (Get-NetscootCapability).DotnetInstalls
        Set-NetscootDotnetPath -Path 'C:\Program Files\dotnet\dotnet.exe'
        # Preview without storing
        Set-NetscootDotnetPath -Path ~/.dotnet/dotnet -WhatIf

    .LINK
        Clear-NetscootDotnetPath

    .LINK
        Get-NetscootCapability
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    $full = Resolve-FullPath $Path
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                [System.IO.FileNotFoundException]::new("There is no file at '$full'. Give the path to the dotnet executable itself."),
                'DotnetPathNotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $full))
        return
    }
    $version = Get-ExternalToolVersion -Path $full
    if (-not $version) {
        $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new("'$full' did not report a .NET SDK version, so netscoot cannot use it. A dotnet with only a runtime installed has no SDK."),
                'DotnetPathHasNoSdk', [System.Management.Automation.ErrorCategory]::InvalidArgument, $full))
        return
    }

    if (-not $PSCmdlet.ShouldProcess((Get-NetscootSettingFile), "Store dotnet path '$full'")) { return }
    Save-StoredDotnetPath -Path $full
    Write-Host "netscoot will use $full (.NET SDK $version) from now on." -ForegroundColor DarkGray
}
