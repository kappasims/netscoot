@{
    RootModule           = 'Netscoot.psm1'
    ModuleVersion        = '2.6.7'
    GUID                 = '917ef9d9-9117-4ee4-a07f-eb1c1902b9d6'
    Author               = 'kappasims'
    Description          = 'A safer way for your agent to restructure .NET, PowerShell, Unity, and native C++ projects. Instead of the agent hand-editing solution and project files, netscoot uses each format''s own tooling where one exists and otherwise changes only the paths. A move that fails is rolled back on a best-effort basis. Its analysis commands (solution consistency, dangling and hardcoded references) and repair commands (solution sync, broken references, interrupted moves) also work on their own.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Core', 'Desktop')
    # Single bundled package: the RootModule loads Shared -Global and imports each engine nested,
    # re-exporting its cmdlets (native only on Windows, best-effort). This list is the export filter
    # for those re-exported cmdlets, and the PowerShell Gallery indexes it to list the cmdlets by name.
    # tests/UmbrellaSurface.Tests.ps1 checks it against the engines' exports (Shared plumbing excluded).
    # Move-NativeProject is Windows-only at runtime but part of the package.
    FunctionsToExport    = @(
        'Clear-NetscootJournal',
        'Find-PathReference',
        'Get-NetscootCapability',
        'Get-NetscootUpdatePolicy',
        'Get-SolutionInventory',
        'Invoke-Netscoot',
        'Move-DotnetFile',
        'Move-DotnetFolder',
        'Move-DotnetProject',
        'Move-DotnetProjectTree',
        'Move-MSBuildImport',
        'Move-NativeProject',
        'Move-PowerShell',
        'Move-PowerShellModule',
        'Move-PowerShellScript',
        'Move-Solution',
        'Move-UnityAsset',
        'Register-NetscootGitAlias',
        'Repair-NetscootJournal',
        'Repair-SolutionReferences',
        'Resolve-MoveEngine',
        'Set-NetscootJournal',
        'Set-NetscootUpdatePolicy',
        'Sync-Solution',
        'Test-EditorSolutionGuard',
        'Test-NetscootUpdate',
        'Test-SolutionConsistency',
        'Test-UnityMetaIntegrity',
        'Undo-Netscoot',
        'Unregister-NetscootGitAlias',
        'Update-Netscoot'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @('Scoot')
    PrivateData          = @{
        PSData = @{
            # OS tags (Windows/Linux/macOS) surface the platform badges on the Gallery; PowerShellGet
            # adds PSEdition_Core/PSEdition_Desktop from CompatiblePSEditions. The rest aid discovery.
            Tags         = @('dotnet', 'powershell', 'unity', 'native', 'refactoring', 'restructure', 'cross-platform', 'solution', 'msbuild', 'csproj', 'slnx', 'migration', 'Windows', 'Linux', 'macOS')
            ProjectUri   = 'https://github.com/kappasims/netscoot'
            LicenseUri   = 'https://github.com/kappasims/netscoot/blob/master/LICENSE'
            ReleaseNotes = 'See https://github.com/kappasims/netscoot/releases'
        }
    }
}
