@{
    RootModule           = 'DotnetMove.Native.psm1'
    ModuleVersion        = '1.1.1'
    GUID                 = 'd7e4a9c1-2b8f-4e6a-9c3d-1f0a6b5e2d44'
    Author               = 'kappasims'
    Description          = 'Windows-only extension of DotnetMove for native / C++/CLI (.vcxproj) projects. Delegates solution membership + the folder move, and reports the native MSBuild path settings the dotnet CLI cannot reconcile.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Core', 'Desktop')
    RequiredModules      = @('DotnetMove.Core')
    FunctionsToExport    = @(
        'Move-NativeProject'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('dotnet', 'cpp', 'vcxproj', 'native', 'refactoring', 'windows')
            ProjectUri = 'https://github.com/kappasims/dotnet-move'
        }
    }
}
