function Sync-Solution {
    <#
    .SYNOPSIS
        Resolve solution-membership divergence by adding each project to the solutions that are
        missing it, so every solution in the repo lists the same projects.

    .DESCRIPTION
        The companion to Test-SolutionConsistency, which only reports divergence. This makes
        membership uniform: for every project present in at least one solution but absent from
        others, it adds the project to the solutions missing it, delegating to `dotnet sln add`
        (never hand-editing the .sln/.slnx). It only adds; it never removes, so a project in no
        solution is left alone (use Get-SolutionInventory to find those).

        Uniform membership is the assumption. If a solution is intentionally a subset, do not run
        this against the whole repo; preview with -WhatIf first and add specific projects by hand.

    .PARAMETER RepoRoot
        Root to scan. Accepts pipeline input. Defaults to the enclosing git repo root. Nested git
        worktrees are skipped.

    .OUTPUTS
        Emits zero or more pscustomobjects, one per addition (a caller collects them as an array).
        Each has (both strings): Solution (repo-relative) and Added (repo-relative project path).
        Returns nothing when every solution already contains every project.

    .EXAMPLE
        Sync-Solution -RepoRoot . -WhatIf

        Previews which projects would be added to which solutions to make membership uniform.

    .EXAMPLE
        Sync-Solution -RepoRoot .

        Adds every divergent project to the solutions missing it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName', 'Path', 'PSPath')]
        [string]$RepoRoot
    )

    process {
        if (-not (Assert-DotnetAvailable -Cmdlet $PSCmdlet)) { return }
        if (-not $RepoRoot) { $RepoRoot = Get-RepoRoot -StartPath (Get-Location).Path }
        $RepoRoot = Resolve-FullPath $RepoRoot
        function _rel([string]$p) { (Get-RelativePathSafe -From $RepoRoot -To $p) }

        $solutions = @(Find-Solutions -Root $RepoRoot)
        if ($solutions.Count -lt 2) {
            Write-Verbose "Fewer than two solutions under $RepoRoot; nothing to sync."
            return
        }

        $membership = Get-SolutionMembership -Solutions $solutions
        $allProjects = $membership.Projects | Sort-Object -Unique
        $added = 0
        foreach ($proj in $allProjects) {
            $absent = @($membership | Where-Object { $_.Projects -notcontains $proj })
            foreach ($m in $absent) {
                if ($PSCmdlet.ShouldProcess($m.Solution, "add $(_rel $proj)")) {
                    Invoke-Dotnet sln $m.Solution add $proj
                    $added++
                    [pscustomobject]@{ Solution = (_rel $m.Solution); Added = (_rel $proj) }
                }
            }
        }

        if ($added -eq 0) {
            Write-Host "All $($solutions.Count) solutions already contain every project." -ForegroundColor Green
        }
    }
}
