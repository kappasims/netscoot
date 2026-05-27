@{
    # Functional grouping for the README "Command reference" index tables. Every exported function
    # must appear here exactly once; the CheckDocs gate fails on any uncategorized or ghost command.
    # Order is the render order. (We start functional; engine-specific tables may split out later.)
    Categories = @(
        @{
            Name  = 'Move'
            Blurb = 'Relocate a project, folder, file, module, or asset and reconcile what the move would otherwise break.'
            Commands = @(
                'Invoke-Netscoot', 'Move-DotnetProject', 'Move-DotnetProjectTree', 'Move-DotnetFile',
                'Move-DotnetFolder', 'Move-MSBuildImport', 'Move-Solution', 'Move-PowerShell',
                'Move-PowerShellScript', 'Move-PowerShellModule', 'Move-NativeProject', 'Move-UnityAsset'
            )
        },
        @{
            Name  = 'Inspect'
            Blurb = 'Read-only audits. These change nothing.'
            Commands = @(
                'Resolve-MoveEngine', 'Get-NetscootCapability', 'Test-SolutionConsistency',
                'Get-SolutionInventory', 'Find-PathReference', 'Test-UnityMetaIntegrity'
            )
        },
        @{
            Name  = 'Manage'
            Blurb = 'Reconcile a repository, undo moves, and control the journal.'
            Subcategories = @(
                @{ Name = 'Reconcile';      Commands = @('Repair-SolutionReferences', 'Sync-Solution') }
                @{ Name = 'Undo & journal'; Commands = @('Undo-Netscoot', 'Repair-NetscootJournal', 'Set-NetscootJournal', 'Clear-NetscootJournal') }
            )
        },
        @{
            Name  = 'Install & environment'
            Blurb = 'Manage the installation itself and wire up the git integration.'
            Subcategories = @(
                @{ Name = 'Stay current';  Commands = @('Test-NetscootUpdate', 'Update-Netscoot') }
                @{ Name = 'Update policy'; Commands = @('Get-NetscootUpdatePolicy', 'Set-NetscootUpdatePolicy') }
                @{ Name = 'Git verb';      Commands = @('Register-NetscootGitAlias', 'Unregister-NetscootGitAlias') }
            )
        }
    )
}
