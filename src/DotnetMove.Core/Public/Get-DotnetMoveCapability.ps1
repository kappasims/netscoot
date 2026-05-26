function Get-DotnetMoveCapability {
    <#
    .SYNOPSIS
        Resolve DotnetMove's external-tool capabilities (git, dotnet) and platform. This is the
        canonical "what can I do here" probe - DotnetMove does not auto-install anything.

    .DESCRIPTION
        PowerShell has no manifest mechanism to declare external-CLI prerequisites, so this is a
        runtime probe via Get-Command; dotnet is required for .NET project moves (the delegation
        target), and git is optional (without it, moves fall back to a plain move with no history
        preserved).

    .OUTPUTS
        A single DotnetMove.Capability object: Platform (string), PSEdition (string),
        DotnetSupportsSlnx (bool), and Git and Dotnet - each itself a nested object with Present
        (bool), Version (string), and Path (string).

    .EXAMPLE
        Get-DotnetMoveCapability

        Returns an object with Platform, PSEdition, Git, Dotnet, and DotnetSupportsSlnx.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $git = Get-ExternalTool -Name git
    $dotnet = Get-ExternalTool -Name dotnet

    # .slnx solution support landed in the .NET 9 SDK; infer from the major version.
    $slnx = $false
    if ($dotnet.Present -and $dotnet.Version -match '^(\d+)\.') {
        $slnx = ([int]$Matches[1] -ge 9)
    }

    $platform =
        if (Test-IsWindowsHost) { 'Windows' }
        elseif ((Test-Path Variable:\IsMacOS) -and (Get-Variable IsMacOS -ValueOnly)) { 'macOS' }
        else { 'Linux' }

    [pscustomobject]@{
        PSTypeName         = 'DotnetMove.Capability'
        Platform           = $platform
        PSEdition          = $PSVersionTable.PSEdition
        Git                = $git
        Dotnet             = $dotnet
        DotnetSupportsSlnx = $slnx
    }
}
