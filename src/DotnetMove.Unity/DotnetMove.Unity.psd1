@{
    RootModule           = 'DotnetMove.Unity.psm1'
    ModuleVersion        = '1.2.0'
    GUID                 = 'a2c8f3d5-6e1b-4a92-8d7c-3b4e9f0a1c62'
    Author               = 'kappasims'
    Description          = 'Cross-platform extension of DotnetMove for Unity projects. Moves assets/folders while preserving their paired .meta files (and the GUIDs that asset/asmdef references depend on), and validates .meta integrity. Supports mobile and all Unity targets - asmdef platform fields are preserved by the move.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Core', 'Desktop')
    # No RequiredModules: bundled into the single DotnetMove package; the umbrella loads
    # DotnetMove.Shared (-Global) before this engine.
    FunctionsToExport    = @(
        'Move-UnityAsset',
        'Test-UnityMetaIntegrity'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('unity', 'gamedev', 'asmdef', 'meta', 'refactoring', 'mobile', 'cross-platform')
            ProjectUri = 'https://github.com/kappasims/dotnet-move'
        }
    }
}
