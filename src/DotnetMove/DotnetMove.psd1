@{
    RootModule           = 'DotnetMove.psm1'
    ModuleVersion        = '1.1.0'
    GUID                 = 'e5b2d8a3-7c41-49f6-bd0e-9a3c2f6b1e57'
    Author               = 'kappasims'
    Description          = 'Umbrella bootstrap for DotnetMove. A single Import-Module DotnetMove loads every engine: the cross-platform .NET/PowerShell core and Unity extensions always, and the Windows-only native C++ (.vcxproj) extension on Windows. Each engine remains independently importable.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Core', 'Desktop')
    # Engines are imported -Global by the RootModule (native is Windows-only, so it cannot be a
    # hard RequiredModules entry). Their commands are surfaced into the session that way.
    FunctionsToExport    = @()
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('dotnet', 'powershell', 'unity', 'native', 'refactoring', 'restructure', 'cross-platform')
            ProjectUri = 'https://github.com/kappasims/dotnet-move'
        }
    }
}
