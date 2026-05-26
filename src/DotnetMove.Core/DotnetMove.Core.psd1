@{
    RootModule           = 'DotnetMove.Core.psm1'
    ModuleVersion        = '1.1.0'
    GUID                 = 'b3f1c0e2-4a6d-4c8e-9b1a-2f7d8e5c1a90'
    Author               = 'kappasims'
    Description          = 'Cross-platform (PowerShell 7) cmdlets to move/restructure managed .NET and PowerShell projects by delegating path/GUID changes to first-party tooling (dotnet sln, dotnet reference, Update-ModuleManifest). Native C++ (.vcxproj) handling lives in the Windows-only DotnetMove.Native module.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Core', 'Desktop')
    FunctionsToExport    = @(
        'Find-PathReference',
        'Get-DotnetMoveCapability',
        'Get-SolutionInventory',
        'Move-Dotnet',
        'Move-DotnetFile',
        'Move-DotnetFolder',
        'Move-DotnetProject',
        'Move-DotnetProjectTree',
        'Move-MSBuildImport',
        'Move-PowerShell',
        'Move-PowerShellModule',
        'Move-PowerShellScript',
        'Move-Solution',
        'Register-DotnetMvGitAlias',
        'Repair-SolutionReferences',
        'Resolve-MoveEngine',
        'Sync-Solution',
        'Test-DotnetMoveUpdate',
        'Test-SolutionConsistency',
        'Unregister-DotnetMvGitAlias'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('dotnet', 'powershell', 'refactoring', 'solution', 'restructure', 'cross-platform')
            ProjectUri = 'https://github.com/kappasims/dotnet-move'
        }
    }
}
