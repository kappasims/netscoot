@{
    RootModule           = 'Netscoot.Unity.psm1'
    ModuleVersion        = '2.3.0'
    GUID                 = '4d828031-bd82-44dd-84a7-305d78a0394f'
    Author               = 'kappasims'
    Description          = 'Cross-platform extension of Netscoot for Unity projects. Moves assets/folders while preserving their paired .meta files (and the GUIDs that asset/asmdef references depend on), and validates .meta integrity. Supports mobile and all Unity targets - asmdef platform fields are preserved by the move.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Core', 'Desktop')
    # No RequiredModules: bundled into the single Netscoot package; the umbrella loads
    # NetscootShared (-Global) before this engine.
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
            ProjectUri = 'https://github.com/kappasims/netscoot'
        }
    }
}
