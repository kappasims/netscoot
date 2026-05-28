function Test-SolutionConsistency {
    <#
    .SYNOPSIS
        Report projects whose membership diverges across the solution files in a repository
        (present in some solutions but absent from others).

    .DESCRIPTION
        When a repository carries more than one solution (e.g. a classic .sln alongside a .slnx),
        they can drift out of sync so the same project is listed in one but not the other.
        This emits one object per divergent project and surfaces it through the standard streams
        so behavior follows invocation: By default it writes a Warning per divergent project;
        -Strict escalates each to a non-terminating error (honoring -ErrorAction); -Debug adds the
        full membership matrix of every solution and its projects.

    .PARAMETER RepositoryRoot
        Root to scan. Accepts pipeline input: a path string, or a file/directory item from
        Get-Item / Get-ChildItem. Defaults to the enclosing git repository root.

    .PARAMETER Strict
        Escalate divergences from warnings to non-terminating errors.

    .OUTPUTS
        Netscoot.ConsistencyResult - one per divergent project.

    .EXAMPLE
        # Report projects whose membership diverges across solutions (warnings)
        Test-SolutionConsistency -RepositoryRoot .
        # Add the full solution/project membership matrix
        Test-SolutionConsistency -RepositoryRoot . -Debug
        # Escalate divergence to non-terminating errors (e.g. to gate CI)
        Test-SolutionConsistency -RepositoryRoot . -Strict
        # Check several repositories from the pipeline
        Get-Item ./repoA, ./repoB | Test-SolutionConsistency -Strict
    #>
    [CmdletBinding()]
    [OutputType('Netscoot.ConsistencyResult')]
    param(
        [Parameter(Position = 0, ValueFromPipeline)]
        [Netscoot.PathInputTransform()]
        [string]$RepositoryRoot,
        [switch]$Strict
    )

    process {
        if (-not (Assert-DotnetAvailable -Cmdlet $PSCmdlet)) { return }
        if (-not $RepositoryRoot) { $RepositoryRoot = Get-RepositoryRoot -StartPath (Get-Location).Path }
        $RepositoryRoot = Resolve-FullPath $RepositoryRoot

        # One repository parse for this invocation; membership is derived from the solutions it
        # already parsed (Get-SolutionMembership reuses the embedded parse rather than re-reading).
        $workspace = Get-Workspace -RepositoryRoot $RepositoryRoot
        $solutions = @(Get-WorkspaceSolutions -Workspace $workspace)
        if ($solutions.Count -lt 2) {
            Write-Verbose "Fewer than two solutions under $RepositoryRoot; nothing to diverge."
            return
        }

        $membership = Get-SolutionMembership -Solutions $solutions

        # Debug: the full matrix, always available under -Debug.
        foreach ($m in $membership) {
            Write-Debug "Solution $($m.Solution) lists $($m.Projects.Count) project(s):"
            foreach ($p in $m.Projects) { Write-Debug "    $p" }
        }

        # Repository-relative solution names so two solutions with the same file name in different
        # folders are still distinguishable (a bare leaf would render them identically).
        function _rel([string]$p) { (Get-RelativePathSafe -From $RepositoryRoot -To $p) }

        # Union of every project across all solutions.
        $allProjects = $membership.Projects | Sort-Object -Unique
        $divergences = 0
        foreach ($proj in $allProjects) {
            $present = @($membership | Where-Object { $_.Projects -contains $proj })
            $absent = @($membership | Where-Object { $_.Projects -notcontains $proj })
            if ($absent.Count -eq 0) { continue } # in every solution - consistent
            $divergences++

            $record = [pscustomobject]@{
                PSTypeName = 'Netscoot.ConsistencyResult'
                Project   = $proj
                PresentIn = @($present.Solution)
                AbsentFrom = @($absent.Solution)
            }

            $msg = "Project '$(_rel $proj)' diverges: present in [$(($present.Solution | ForEach-Object { _rel $_ }) -join ', ')] but absent from [$(($absent.Solution | ForEach-Object { _rel $_ }) -join ', ')]. To resolve, add it where missing with: dotnet sln <solution> add <project>"
            if ($Strict) {
                Write-Error -Message $msg -Category InvalidData -TargetObject $record -ErrorId 'SolutionDivergence'
            } else {
                Write-Warning $msg
            }
            $record # emit to pipeline regardless, so it is capturable/filterable
        }

        if ($divergences -eq 0) {
            Write-Host "All $($solutions.Count) solutions agree on project membership." -ForegroundColor Green
        }
    }
}
