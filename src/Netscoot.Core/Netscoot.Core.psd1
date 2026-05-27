@{
    RootModule           = 'Netscoot.Core.psm1'
    ModuleVersion        = '1.3.2'
    GUID                 = 'c8d7847d-bd74-4cc8-8705-bbcb7116e372'
    Author               = 'kappasims'
    Description          = 'Cross-platform (PowerShell 7) cmdlets to move/restructure managed .NET and PowerShell projects by delegating path/GUID changes to first-party tooling (dotnet sln, dotnet reference, Update-ModuleManifest). Native C++ (.vcxproj) handling lives in the Windows-only Netscoot.Native module.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Core', 'Desktop')
    # No RequiredModules: shipped as one bundled Netscoot package; the umbrella loads the bundled
    # Netscoot.Shared (-Global) before this engine. (In dev, tests/build/the forwarder do the same.)
    FunctionsToExport    = @(
        'Clear-ScootJournal',
        'Find-PathReference',
        'Get-ScootCapability',
        'Get-SolutionInventory',
        'Invoke-Scoot',
        'Move-DotnetFile',
        'Move-DotnetFolder',
        'Move-DotnetProject',
        'Move-DotnetProjectTree',
        'Move-MSBuildImport',
        'Move-PowerShell',
        'Move-PowerShellModule',
        'Move-PowerShellScript',
        'Move-Solution',
        'Register-ScootGitAlias',
        'Repair-SolutionReferences',
        'Resolve-MoveEngine',
        'Set-ScootJournal',
        'Sync-Solution',
        'Test-ScootUpdate',
        'Test-SolutionConsistency',
        'Undo-Scoot',
        'Update-Scoot',
        'Unregister-ScootGitAlias'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @('Scoot')
    PrivateData          = @{
        PSData = @{
            Tags       = @('dotnet', 'powershell', 'refactoring', 'solution', 'restructure', 'cross-platform')
            ProjectUri = 'https://github.com/kappasims/netscoot'
        }
    }
}
