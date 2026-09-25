function Get-NetscootCapability {
    <#
    .SYNOPSIS
        Resolve Netscoot's external-tool capabilities (git, dotnet) and platform. This is the
        canonical "what can I do here" probe - netscoot does not auto-install anything.

    .DESCRIPTION
        PowerShell has no manifest mechanism to declare external-CLI prerequisites, so this is a
        runtime probe via Get-Command. dotnet is required for .NET project moves (the delegation
        target). git is optional. Without it, a move asks before falling back to a plain PowerShell
        `Move-Item`, which preserves no history, and -Force skips the question.

    .OUTPUTS
        Netscoot.Capability

    .EXAMPLE
        # Probe machine capabilities (returns an object with Platform, PSEdition, Git, Dotnet, DotnetSupportsSlnx)
        Get-NetscootCapability
    #>
    [CmdletBinding()]
    [OutputType('Netscoot.Capability')]
    param()

    $git = Get-ExternalTool -Name git
    $dotnet = Get-ExternalTool -Name dotnet

    # `dotnet sln` gained .slnx support in SDK 9.0.200.
    $slnx = $false
    if ($dotnet.Present -and $dotnet.Version -match '^(\d+)\.(\d+)\.(\d+)') {
        $slnx = ([int]$Matches[1] -gt 9) -or ([int]$Matches[1] -eq 9 -and [int]$Matches[3] -ge 200)
    }

    $platform =
        if (Test-IsWindowsHost) { 'Windows' }
        elseif ((Test-Path Variable:\IsMacOS) -and (Get-Variable IsMacOS -ValueOnly)) { 'macOS' }
        else { 'Linux' }

    [pscustomobject]@{
        PSTypeName         = 'Netscoot.Capability'
        Platform           = $platform
        PSEdition          = $PSVersionTable.PSEdition
        Git                = $git
        Dotnet             = $dotnet
        DotnetSupportsSlnx = $slnx
    }
}
