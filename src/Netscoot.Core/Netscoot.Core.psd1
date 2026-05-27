@{
    RootModule           = 'Netscoot.Core.psm1'
    ModuleVersion        = '2.1.1'
    GUID                 = 'c8d7847d-bd74-4cc8-8705-bbcb7116e372'
    Author               = 'kappasims'
    Description          = 'Cross-platform (PowerShell 7) cmdlets to move/restructure managed .NET and PowerShell projects by delegating path/GUID changes to first-party tooling (dotnet sln, dotnet reference, Update-ModuleManifest). Native C++ (.vcxproj) handling lives in the Windows-only Netscoot.Native module.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Core', 'Desktop')
    # No RequiredModules: shipped as one bundled Netscoot package; the umbrella loads the bundled
    # Netscoot.Shared (-Global) before this engine. (In dev, tests/build/the forwarder do the same.)
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
        'Move-PowerShell',
        'Move-PowerShellModule',
        'Move-PowerShellScript',
        'Move-Solution',
        'Register-NetscootGitAlias',
        'Repair-NetscootJournal',
        'Repair-SolutionReferences',
        'Resolve-MoveEngine',
        'Set-NetscootJournal',
        'Set-NetscootUpdatePolicy',
        'Sync-Solution',
        'Test-NetscootUpdate',
        'Test-SolutionConsistency',
        'Undo-Netscoot',
        'Update-Netscoot',
        'Unregister-NetscootGitAlias'
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
