@{
    RootModule           = 'DotnetMove.Shared.psm1'
    ModuleVersion        = '1.2.0'
    GUID                 = 'a7c5e1d4-2b9f-4e63-8a17-0d6c9f3b21e8'
    Author               = 'kappasims'
    Description          = 'Shared cross-platform helpers for the DotnetMove toolkit (path/git/MSBuild/solution primitives). A support module required by DotnetMove.Core/.Unity/.Native; not used directly.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Core', 'Desktop')
    FunctionsToExport    = @(
        'Assert-DotnetAvailable',
        'Find-ProjectFiles',
        'Find-Solutions',
        'Get-ConsumingProjects',
        'Get-ExternalTool',
        'Get-NestedWorktreePath',
        'Get-PathSuffixScore',
        'Get-ProjectReferencePaths',
        'Get-RelativePathSafe',
        'Get-RepoRoot',
        'Get-SolutionContent',
        'Get-SolutionMembership',
        'Get-SolutionProjectEntries',
        'Get-SolutionsReferencing',
        'Get-UnreconcilableReferences',
        'Invoke-Dotnet',
        'Invoke-DotnetRead',
        'Invoke-MovePlan',
        'Move-PathTracked',
        'New-DotnetReferenceItems',
        'New-MoveItem',
        'New-MoveResult',
        'Read-ProjectXml',
        'Resolve-FullPath',
        'Resolve-GitUsage',
        'Resolve-MoveContext',
        'Resolve-MoveTarget',
        'Resolve-SymlinkPath',
        'Select-BestSuffixMatch',
        'Test-DirectoryBuildInheritance',
        'Test-DotnetAvailable',
        'Test-GitAvailable',
        'Test-GitTracked',
        'Test-IsNativeProject',
        'Test-IsWindowsHost',
        'Test-PathEqual',
        'Test-PathInList',
        'Test-PathOverlap',
        'Test-PathUnder',
        'Test-PathUnderAny',
        'Write-CapabilityGuidance',
        'Write-UnreconcilableReferenceWarning'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('dotnet', 'powershell', 'restructure', 'cross-platform')
            ProjectUri = 'https://github.com/kappasims/dotnet-move'
        }
    }
}
