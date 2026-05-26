function Get-SolutionInventory {
    <#
    .SYNOPSIS
        List the full contents of every solution in a repo - projects of any type, solution
        folders, and solution items - plus on-disk projects that no solution references.

    .DESCRIPTION
        Where Test-SolutionConsistency compares membership and Repair-SolutionReferences finds
        dangling entries, this gives the complete picture without reading the files by hand. It
        parses each .sln/.slnx directly (not via `dotnet sln list`, which only returns
        CLI-buildable projects), so it also surfaces non-CLI project types (e.g. .pssproj),
        solution folders, and loose solution items. It then compares against the projects on disk
        and flags any that are in no solution at all.

        Read-only: one record per item, so you can group, filter, or format it however you like.

    .PARAMETER RepoRoot
        Root to scan. Accepts pipeline input (path string, or any object with a FullName/Path
        property). Defaults to the enclosing git repo root. Nested git worktrees are skipped.

    .OUTPUTS
        Emits zero or more pscustomobjects, one per item (a caller collects them as an array).
        Each has (all strings): Solution (repo-relative, or '(none)'), Kind (Project |
        SolutionFolder | SolutionItem | UnreferencedProject), Type (project extension without the
        dot, else empty), Name, and Path (as stored in the solution, or repo-relative).

    .EXAMPLE
        Get-SolutionInventory -RepoRoot . | Format-Table -AutoSize

        Shows every project, folder, and item across all solutions, and any unreferenced project.

    .EXAMPLE
        Get-SolutionInventory | Where-Object Kind -eq 'UnreferencedProject'

        Lists only the projects on disk that no solution includes.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName', 'Path', 'PSPath')]
        [string]$RepoRoot
    )

    process {
        if (-not $RepoRoot) { $RepoRoot = Get-RepoRoot -StartPath (Get-Location).Path }
        $RepoRoot = Resolve-FullPath $RepoRoot
        function _rel([string]$p) { (Get-RelativePathSafe -From $RepoRoot -To $p) }

        $solutions = @(Find-Solutions -Root $RepoRoot)
        $seen = [System.Collections.Generic.List[string]]::new()

        foreach ($sln in $solutions) {
            $rel = _rel $sln.FullName
            $content = Get-SolutionContent -SolutionFile $sln.FullName
            foreach ($p in $content.Projects) {
                $seen.Add($p.Abs)
                [pscustomobject]@{
                    Solution = $rel
                    Kind     = 'Project'
                    Type     = $p.Ext.TrimStart('.')
                    Name     = Split-Path -Leaf $p.Abs
                    Path     = $p.Stored
                }
            }
            foreach ($f in $content.Folders) {
                [pscustomobject]@{ Solution = $rel; Kind = 'SolutionFolder'; Type = ''; Name = $f; Path = '' }
            }
            foreach ($i in $content.Items) {
                [pscustomobject]@{ Solution = $rel; Kind = 'SolutionItem'; Type = ''; Name = (Split-Path -Leaf $i); Path = $i }
            }
        }

        # Projects on disk (managed and native) that no solution references at all.
        foreach ($disk in (Find-ProjectFiles -Root $RepoRoot -IncludeNative)) {
            $abs = Resolve-FullPath $disk.FullName
            if (-not (Test-PathInList -Path $abs -List $seen)) {
                [pscustomobject]@{
                    Solution = '(none)'
                    Kind     = 'UnreferencedProject'
                    Type     = $disk.Extension.TrimStart('.')
                    Name     = $disk.Name
                    Path     = _rel $abs
                }
            }
        }
    }
}
