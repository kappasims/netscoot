@{
    RootModule           = 'Netscoot.Shared.psm1'
    ModuleVersion        = '2.0.1'
    GUID                 = 'f0448d52-8cf4-4e39-a620-1d4b4c3503f5'
    Author               = 'kappasims'
    Description          = 'Shared cross-platform helpers for the Netscoot toolkit (path/git/MSBuild/solution primitives). A support module required by Netscoot.Core/.Unity/.Native; not used directly.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Core', 'Desktop')
    # Default table views for the diagnostic/list result types and the undo-journal entries. Loaded
    # here (Shared is imported first by every engine and the umbrella) so the views are available
    # whenever any Netscoot type is emitted.
    FormatsToProcess     = @('Netscoot.Format.ps1xml')
    FunctionsToExport    = @(
        'Assert-DotnetAvailable',
        'Find-ProjectFiles',
        'Find-Solutions',
        'Get-ConsumingProjects',
        'Get-ExternalTool',
        'Get-InterruptedMove',
        'Get-MoveJournalEntries',
        'Get-MoveJournalPath',
        'Get-NestedWorktreePath',
        'Get-PathSuffixScore',
        'Get-ProjectReferencePaths',
        'Get-RelativePathSafe',
        'Get-RepositoryRoot',
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
        'Remove-MoveJournalEntry',
        'Test-MoveJournalEnabled',
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
            ProjectUri = 'https://github.com/kappasims/netscoot'
        }
    }
}
