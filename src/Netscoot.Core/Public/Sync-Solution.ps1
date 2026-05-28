function Sync-Solution {
    <#
    .SYNOPSIS
        Resolve solution-membership divergence by adding each project to the solutions that are
        missing it, so every solution in the repository lists the same projects.

    .DESCRIPTION
        The companion to Test-SolutionConsistency, which only reports divergence. This makes
        membership uniform: For every project present in at least one solution but absent from
        others, it adds the project to the solutions missing it, delegating to `dotnet sln add`
        (never hand-editing the .sln/.slnx). It only adds; it never removes, so a project in no
        solution is left alone (use Get-SolutionInventory to find those).

        Uniform membership is the assumption. If a solution is intentionally a subset, do not run
        this against the whole repository; preview with -WhatIf first and add specific projects by hand.

    .PARAMETER RepositoryRoot
        Root to scan. Accepts pipeline input. Defaults to the enclosing git repository root. Nested git
        worktrees are skipped.

    .OUTPUTS
        Netscoot.SyncResult - one per project added.

    .EXAMPLE
        # Preview which projects would be added to which solutions to make membership uniform
        Sync-Solution -RepositoryRoot . -WhatIf
        # Add each divergent project to the solutions missing it (only adds, never removes)
        Sync-Solution -RepositoryRoot .
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Netscoot.SyncResult')]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName', 'Path', 'PSPath')]
        [string]$RepositoryRoot
    )

    process {
        if (-not (Assert-DotnetAvailable -Cmdlet $PSCmdlet)) { return }
        if (-not $RepositoryRoot) { $RepositoryRoot = Get-RepositoryRoot -StartPath (Get-Location).Path }
        $RepositoryRoot = Resolve-FullPath $RepositoryRoot
        function _rel([string]$p) { (Get-RelativePathSafe -From $RepositoryRoot -To $p) }

        # One repository parse for this invocation; membership reuses the embedded solution parse.
        $workspace = Get-Workspace -RepositoryRoot $RepositoryRoot
        $solutions = @(Get-WorkspaceSolutions -Workspace $workspace)
        if ($solutions.Count -lt 2) {
            Write-Verbose "Fewer than two solutions under $RepositoryRoot; nothing to sync."
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
                    [pscustomobject]@{ PSTypeName = 'Netscoot.SyncResult'; Solution = (_rel $m.Solution); Added = (_rel $proj) }
                }
            }
        }

        if ($added -eq 0) {
            Write-Host "All $($solutions.Count) solutions already contain every project." -ForegroundColor Green
        }
    }
}
