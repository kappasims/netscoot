function Get-NetscootSolutionInventory {
    <#
    .SYNOPSIS
        List the full contents of every solution in a repository (projects of any type, solution
        folders, and solution items), plus on-disk projects that no solution references.

    .DESCRIPTION
        Where Test-NetscootSolutionConsistency compares membership and Repair-NetscootSolutionReferences finds
        dangling entries, this gives the complete picture without reading the files by hand. It
        parses each .sln/.slnx directly (not via `dotnet sln list`, which only returns
        CLI-buildable projects), so it also surfaces non-CLI project types (e.g. .pssproj),
        solution folders, and loose solution items. It then compares against the projects on disk
        and flags any that are in no solution at all.

        Read-only: One record per item, so you can group, filter, or format it however you like.

    .PARAMETER RepositoryRoot
        Root to scan. Accepts pipeline input: a path string, or a file/directory item from
        Get-Item / Get-ChildItem. Defaults to the enclosing git repository root. Nested git
        worktrees are skipped.

    .OUTPUTS
        Netscoot.SolutionItem - one per item.

    .EXAMPLE
        # Everything across all solutions, plus projects in none
        Get-NetscootSolutionInventory -RepositoryRoot . | Format-Table -AutoSize
        # Only the projects on disk that no solution references
        Get-NetscootSolutionInventory | Where-Object Kind -eq 'UnreferencedProject'
        # Only loose solution items (e.g. a README in a solution folder)
        Get-NetscootSolutionInventory | Where-Object Kind -eq 'SolutionItem'
        # Kind is the [Netscoot.SolutionItemKind] enum, so this also works
        Get-NetscootSolutionInventory | Where-Object Kind -eq ([Netscoot.SolutionItemKind]::UnreferencedProject)

    .LINK
        Test-NetscootSolutionConsistency

    .LINK
        Sync-NetscootSolution

    .LINK
        Repair-NetscootSolutionReferences
    #>
    [CmdletBinding()]
    [OutputType('Netscoot.SolutionItem')]
    param(
        [Parameter(Position = 0, ValueFromPipeline)]
        [Netscoot.PathInputTransform()]
        [string]$RepositoryRoot
    )

    begin {
        if ($MyInvocation.InvocationName -eq 'Get-SolutionInventory') {
            Write-Warning "'Get-SolutionInventory' is a deprecated alias for 'Get-NetscootSolutionInventory' and will be removed in a future release. Update to 'Get-NetscootSolutionInventory'."
        }
    }

    process {
        if (-not $RepositoryRoot) { $RepositoryRoot = Get-RepositoryRoot -StartPath (Get-Location).Path }
        $RepositoryRoot = Resolve-FullPath $RepositoryRoot
        function _rel([string]$p) { (Get-RelativePathSafe -From $RepositoryRoot -To $p) }
        # One builder for every row, so the Netscoot.SolutionItem shape (property set and order) is
        # defined in a single place rather than repeated at each call site.
        function _item([string]$Solution, [Netscoot.SolutionItemKind]$Kind, [string]$Name, [string]$Path = '', [string]$Type = '') {
            [pscustomobject]@{
                PSTypeName = 'Netscoot.SolutionItem'
                Solution   = $Solution
                Kind       = $Kind
                Type       = $Type
                Name       = $Name
                Path       = $Path
            }
        }

        # One repository parse for this invocation: solutions (each already parsed via Read-Solution)
        # and the project glob both come from the workspace, so no file is read twice.
        $workspace = Get-Workspace -RepositoryRoot $RepositoryRoot
        $solutions = @(Get-WorkspaceSolutions -Workspace $workspace)
        $seen = [System.Collections.Generic.List[string]]::new()

        foreach ($sln in $solutions) {
            $rel = _rel $sln.FullName
            # The workspace solution entry IS the parsed Netscoot.Solution, so its file contents
            # (projects of any type, folders, items) are already on it - no second Get-SolutionContent.
            $content = $sln
            foreach ($p in $content.Projects) {
                $seen.Add($p.Abs)
                _item -Solution $rel -Kind ([Netscoot.SolutionItemKind]::Project) `
                    -Name (Split-Path -Leaf $p.Abs) -Path $p.Stored -Type $p.Ext.TrimStart('.')
            }
            foreach ($f in $content.Folders) {
                _item -Solution $rel -Kind ([Netscoot.SolutionItemKind]::SolutionFolder) -Name $f
            }
            foreach ($i in $content.Items) {
                _item -Solution $rel -Kind ([Netscoot.SolutionItemKind]::SolutionItem) -Name (Split-Path -Leaf $i) -Path $i
            }
        }

        # Projects on disk (managed and native) that no solution references at all.
        foreach ($disk in (Get-WorkspaceProjectFiles -Workspace $workspace -IncludeNative)) {
            $abs = Resolve-FullPath $disk.FullName
            if (-not (Test-PathInList -Path $abs -List $seen)) {
                _item -Solution '(none)' -Kind ([Netscoot.SolutionItemKind]::UnreferencedProject) `
                    -Name $disk.Name -Path (_rel $abs) -Type $disk.Extension.TrimStart('.')
            }
        }
    }
}

Set-Alias -Name Get-SolutionInventory -Value Get-NetscootSolutionInventory
