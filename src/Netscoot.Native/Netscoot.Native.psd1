@{
    RootModule           = 'Netscoot.Native.psm1'
    ModuleVersion        = '2.1.1'
    GUID                 = 'a04eb714-497e-477b-99d3-ea09801d7dc5'
    Author               = 'kappasims'
    Description          = 'Windows-only extension of Netscoot for native / C++/CLI (.vcxproj) projects. Delegates solution membership + the folder move, and reports the native MSBuild path settings the dotnet CLI cannot reconcile.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Core', 'Desktop')
    # No RequiredModules: bundled into the single Netscoot package; the umbrella loads
    # Netscoot.Shared (-Global) before this engine.
    FunctionsToExport    = @(
        'Move-NativeProject'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('dotnet', 'cpp', 'vcxproj', 'native', 'refactoring', 'windows')
            ProjectUri = 'https://github.com/kappasims/netscoot'
        }
    }
}
