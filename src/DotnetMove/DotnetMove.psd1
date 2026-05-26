@{
    RootModule           = 'DotnetMove.psm1'
    ModuleVersion        = '1.1.1'
    GUID                 = 'e5b2d8a3-7c41-49f6-bd0e-9a3c2f6b1e57'
    Author               = 'kappasims'
    Description          = 'Move/restructure .NET projects (and PowerShell, Unity, native C++) from the command line without breaking references. A single bundled package: Import-Module DotnetMove loads the .NET/PowerShell and Unity engines everywhere, and the native C++ (.vcxproj) engine on Windows.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Core', 'Desktop')
    # Single bundled package: the RootModule loads the bundled Shared + engine modules -Global
    # (native only on Windows, best-effort), so commands are surfaced by one Import-Module.
    FunctionsToExport    = @()
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags         = @('dotnet', 'powershell', 'unity', 'native', 'refactoring', 'restructure', 'cross-platform')
            ProjectUri   = 'https://github.com/kappasims/dotnet-move'
            LicenseUri   = 'https://github.com/kappasims/dotnet-move/blob/master/LICENSE'
            ReleaseNotes = 'See https://github.com/kappasims/dotnet-move/releases'
        }
    }
}
