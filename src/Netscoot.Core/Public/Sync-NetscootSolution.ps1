function Sync-NetscootSolution {
    <#
    .SYNOPSIS
        Resolve solution-membership divergence by adding each project to the solutions that are
        missing it, within each group of solutions that share projects.

    .DESCRIPTION
        The companion to Test-NetscootSolutionConsistency, which only reports divergence. It works
        on the same groups: solutions that share at least one project, such as a .sln and its .slnx
        mirror. A solution that shares no project with another is left alone. Within a group, every
        managed project present in one solution but absent from another is added where it is
        missing, through `dotnet sln add`. The dotnet CLI cannot load a .vcxproj or .pssproj, so a
        missing one is reported as a warning to add in Visual Studio. It only adds and never
        removes, so a project in no solution is left alone (use Get-NetscootSolutionInventory to find
        those).

        Uniform membership within a group is the assumption. If a solution is intentionally a
        subset of another it shares projects with, preview with -WhatIf first and add specific
        projects by hand.

    .PARAMETER RepositoryRoot
        Root to scan. Accepts pipeline input: a path string, or a file/directory item from
        Get-Item / Get-ChildItem. Defaults to the enclosing git repository root. Nested git
        worktrees are skipped.

    .OUTPUTS
        Netscoot.SyncResult - one per project added to a solution.

    .EXAMPLE
        # Preview which projects would be added to which solutions to make membership uniform
        Sync-NetscootSolution -RepositoryRoot . -WhatIf
        # Add each divergent project to the solutions missing it (only adds, never removes)
        Sync-NetscootSolution -RepositoryRoot .

    .LINK
        Get-NetscootSolutionInventory

    .LINK
        Test-NetscootSolutionConsistency

    .LINK
        Repair-NetscootSolutionReferences
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType('Netscoot.SyncResult')]
    param(
        [Parameter(Position = 0, ValueFromPipeline)]
        [Netscoot.PathInputTransform()]
        [string]$RepositoryRoot
    )

    begin {
        if ($MyInvocation.InvocationName -eq 'Sync-Solution') {
            Write-Warning "'Sync-Solution' is a deprecated alias for 'Sync-NetscootSolution' and will be removed in 4.0. Update to 'Sync-NetscootSolution'."
        }
    }

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

        # Sync only solutions that share at least one project, the same groups Test-SolutionConsistency
        # compares, so intentionally-separate solutions (a client, a submodule) are left alone.
        $membership = Get-SolutionMembership -Solutions $solutions
        $clusters = @(Group-SolutionsBySharedProjects -Membership $membership | Where-Object { @($_.Solutions).Count -ge 2 })
        $added = 0
        foreach ($cluster in $clusters) {
            $group = @($cluster.Solutions)
            foreach ($proj in ($group.Projects | Sort-Object -Unique)) {
                $absent = @($group | Where-Object { $_.Projects -notcontains $proj })
                if (-not $absent.Count) { continue }
                # The dotnet CLI cannot load a native or PowerShell project, so those are reported only.
                if ([System.IO.Path]::GetExtension($proj) -notin '.csproj', '.fsproj', '.vbproj') {
                    Write-Warning "$(_rel $proj) is missing from $(($absent.Solution | ForEach-Object { _rel $_ }) -join ', '). Add it in Visual Studio."
                    continue
                }
                foreach ($m in $absent) {
                    if ($PSCmdlet.ShouldProcess($m.Solution, "add $(_rel $proj)")) {
                        Invoke-Dotnet sln $m.Solution add $proj
                        $added++
                        [Netscoot.SyncResult]@{ Solution = (_rel $m.Solution); Added = (_rel $proj) }
                    }
                }
            }
        }

        if ($added -eq 0) {
            Write-Host 'Every group of solutions that share projects already lists the same managed projects.' -ForegroundColor Green
        }
    }
}

Set-Alias -Name Sync-Solution -Value Sync-NetscootSolution
