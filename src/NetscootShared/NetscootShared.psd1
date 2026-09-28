@{
    RootModule           = 'NetscootShared.psm1'
    ModuleVersion        = '2.8.0'
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
        'ConvertFrom-Jsonc',
        'Find-DotnetInstall',
        'Find-ProjectFiles',
        'Find-Solutions',
        'Get-ConsumingProjects',
        'Get-ExternalTool',
        'Get-ExternalToolVersion',
        'Get-InterruptedMove',
        'Get-MoveJournalEntries',
        'Get-MoveJournalPath',
        'Get-NetscootSettingFile',
        'Get-NestedWorktreePath',
        'Get-PathSuffixScore',
        'Get-ProjectReferencePaths',
        'Get-RelativePathSafe',
        'Get-RepositoryRoot',
        'Get-SolutionContent',
        'Get-SolutionItemEntries',
        'Get-SolutionMembership',
        'Get-SolutionProjectEntries',
        'Get-SolutionsReferencing',
        'Get-StoredDotnetPath',
        'Get-TreeItem',
        'Get-UnreconcilableReferences',
        'Get-Workspace',
        'Get-WorkspaceConsumingProjects',
        'Get-WorkspaceProjectFiles',
        'Get-WorkspaceProjectRefs',
        'Get-WorkspaceSolutions',
        'Group-SolutionsBySharedProjects',
        'Invoke-Dotnet',
        'Invoke-Git',
        'Invoke-MovePhase',
        'Invoke-MovePlan',
        'Move-PathTracked',
        'New-DotnetReferenceItems',
        'New-ForwardArgs',
        'New-MoveItem',
        'New-MoveResult',
        'Read-DotnetInstallChoice',
        'Read-ProjectXml',
        'Read-Solution',
        'Remove-MoveJournalEntry',
        'Remove-StoredDotnetPath',
        'Resolve-DotnetCommand',
        'Save-StoredDotnetPath',
        'Test-MoveJournalEnabled',
        'Resolve-FullPath',
        'Resolve-GitUsage',
        'Resolve-MoveContext',
        'Resolve-MoveTarget',
        'Resolve-SymlinkPath',
        'Select-BestSuffixMatch',
        'Test-DirectoryBuildInheritance',
        'Test-DotnetAvailable',
        'Test-DotnetBuild',
        'Test-GitAvailable',
        'Test-GitTracked',
        'Test-InteractiveSession',
        'Test-IsNativeProject',
        'Test-IsWindowsHost',
        'Test-PathEqual',
        'Test-PathInList',
        'Test-PathOverlap',
        'Test-PathUnder',
        'Test-PathUnderAny',
        'Write-CapabilityGuidance',
        'Write-MovePlan',
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
