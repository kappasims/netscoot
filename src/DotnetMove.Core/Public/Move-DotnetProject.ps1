function Move-DotnetProject {
    <#
    .SYNOPSIS
        Move a .NET project folder and reconcile every solution and project reference
        that points at it, delegating all path/GUID changes to the dotnet CLI.

    .DESCRIPTION
        Enumerates the solutions that include the project, the projects that reference it,
        and the project's own references. Removes those links while the old paths still
        resolve, moves the directory (git mv when tracked), then re-adds every link so the
        dotnet CLI recomputes fresh relative paths and preserves GUIDs. The solution and
        project XML (.sln/.slnx, .csproj) is never hand-edited.

        Diagnostics follow invocation: -Verbose narrates the plan, -Debug emits the full
        solution-membership matrix, and divergence (the project living in some but not all
        of the repo's solutions) is surfaced as a Warning (or, with -Strict, a non-
        terminating error honoring -ErrorAction).

    .PARAMETER Project
        Path to the project file (.csproj/.fsproj/.vbproj). Accepts pipeline input - pipe a
        path string or any object with a FullName/Path property (e.g. Get-Item output).

    .PARAMETER Destination
        New folder for the project. The project file and its sibling contents move here.

    .PARAMETER RepoRoot
        Root to scan for solutions/consumers. Defaults to the enclosing git repo root.

    .PARAMETER Strict
        Escalate solution-divergence warnings to non-terminating errors.

    .PARAMETER NoBuild
        Skip the verifying 'dotnet build' at the end.

    .PARAMETER Force
        Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.

    .OUTPUTS
        A single DotnetMove.MoveResult object: Engine, Source, Destination (strings), Performed
        (bool), SkippedCount, ConsumerCount, OwnRefCount (ints), Solutions (string[], the solution
        names updated), and Built (bool, or $null with -NoBuild).

    .EXAMPLE
        Move-DotnetProject -Project ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon -WhatIf

        Previews the move and emits the plan object; nothing is changed.

    .EXAMPLE
        Get-Item ./src/Tarragon/Tarragon.csproj | Move-DotnetProject -Destination ./libs/Tarragon

        Same move, taking the project from the pipeline.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName', 'Path', 'PSPath')]
        [ValidateNotNullOrEmpty()]
        [string]$Project,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Destination,

        [string]$RepoRoot,
        [switch]$Strict,
        [switch]$NoBuild,
        [switch]$Force
    )

    process {
        if (-not (Assert-DotnetAvailable -Cmdlet $PSCmdlet)) { return }

        $projFull = Resolve-FullPath $Project
        if (-not (Test-Path -LiteralPath $projFull)) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.IO.FileNotFoundException]::new("Project not found: $Project"),
                    'ProjectNotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $Project))
            return
        }
        if (Test-IsNativeProject $projFull) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.NotSupportedException]::new("'$Project' is a native (.vcxproj) project. Moving it safely requires reconciling AdditionalLibraryDirectories/AdditionalDependencies, <Import> of .props, and .vcxproj.filters, which the dotnet CLI cannot do. Use Move-NativeProject (Windows-only)."),
                    'NativeProjectNotSupported', [System.Management.Automation.ErrorCategory]::NotImplemented, $Project))
            return
        }
        if ($projFull -notmatch '\.(cs|fs|vb)proj$') {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new("Not a managed project file: $Project"),
                    'NotAProject', [System.Management.Automation.ErrorCategory]::InvalidArgument, $Project))
            return
        }

        $oldDir = Split-Path -Parent $projFull
        $projFile = Split-Path -Leaf $projFull
        if (-not $RepoRoot) { $RepoRoot = Get-RepoRoot -StartPath $oldDir }
        $repoFull = Resolve-FullPath $RepoRoot

        $newDir = [System.IO.Path]::GetFullPath($Destination)
        $newProj = Join-Path $newDir $projFile
        if (Test-Path -LiteralPath $newProj) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.IO.IOException]::new("Destination already has a project: $newProj"),
                    'DestinationExists', [System.Management.Automation.ErrorCategory]::ResourceExists, $newProj))
            return
        }
        if (Test-PathOverlap $newDir $oldDir) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new("Destination '$newDir' overlaps the source '$oldDir'; a project folder cannot be moved into itself or its own subtree."),
                    'PathOverlap', [System.Management.Automation.ErrorCategory]::InvalidArgument, $Destination))
            return
        }

        Write-Verbose "Scanning repo root: $repoFull"
        $allSolutions = @(Find-Solutions -Root $repoFull)
        $allProjects = @(Find-ProjectFiles -Root $repoFull)

        $solutions = @(Get-SolutionsReferencing -ProjectFile $projFull -Candidates $allSolutions)
        $consumers = @(Get-ConsumingProjects -ProjectFile $projFull -Candidates $allProjects)
        # Only literal references are reconciled by the CLI; non-literal/conditional ones are
        # warned about below (Write-UnreconcilableReferenceWarning) and left untouched.
        $ownRefs = @(Get-ProjectReferencePaths -ProjectFile $projFull | Where-Object { $_.IsLiteral })

        $slnNames = @(); foreach ($s in $solutions) { $slnNames += $s.Name }
        Write-Verbose "Plan: $projFile  $oldDir -> $newDir"
        Write-Verbose "  solutions referencing it : $($solutions.Count) ($($slnNames -join ', '))"
        Write-Verbose "  consumer projects        : $($consumers.Count)"
        Write-Verbose "  its own references       : $($ownRefs.Count)"

        # Debug: full membership matrix for the whole repo.
        if ($DebugPreference -ne 'SilentlyContinue') {
            foreach ($m in (Get-SolutionMembership -Solutions $allSolutions)) {
                Write-Debug "Solution $($m.Solution) lists $($m.Projects.Count) project(s):"
                foreach ($p in $m.Projects) { Write-Debug "    $p" }
            }
        }

        # Divergence: the project is in some solutions but not others in the same repo.
        $refSlnPaths = @(); foreach ($s in $solutions) { $refSlnPaths += $s.FullName }
        $notReferencing = @($allSolutions | Where-Object { $refSlnPaths -notcontains $_.FullName })
        if ($solutions.Count -gt 0 -and $notReferencing.Count -gt 0) {
            $inNames = ($slnNames -join ', ')
            $outNameList = @(); foreach ($s in $notReferencing) { $outNameList += $s.Name }
            $outNames = ($outNameList -join ', ')
            $msg = "Solution divergence: '$projFile' is referenced by [$inNames] but not by [$outNames] in the same repo. Only the referencing solution(s) will be updated."
            if ($Strict) {
                $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                        [System.InvalidOperationException]::new($msg),
                        'SolutionDivergence', [System.Management.Automation.ErrorCategory]::InvalidData, $projFull))
            } else {
                Write-Warning $msg
            }
        }

        Test-DirectoryBuildInheritance -OldDir $oldDir -NewDir $newDir -RepoRoot $repoFull
        Write-UnreconcilableReferenceWarning -MovedProject $projFull -AllProjects $allProjects -LiteralConsumers $consumers

        $built = $null
        $performed = $false
        $skippedCount = 0

        if ($PSCmdlet.ShouldProcess("$projFile : $oldDir -> $newDir", 'Move .NET project and reconcile references')) {
            $ctx = Resolve-MoveContext -Cmdlet $PSCmdlet -Force:$Force -TargetForError $projFull
            if (-not $ctx) { return }

            $items = New-DotnetReferenceItems -Solutions $solutions -Consumers $consumers -OwnRefs $ownRefs `
                -OldProj $projFull -NewProj $newProj
            $move = { param($UseGit, $Src, $Dst, $Repo) Move-PathTracked -UseGit $UseGit -Source $Src -Destination $Dst -RepoRoot $Repo }

            # Files the reconciliation edits (for rollback): each solution, each consumer project,
            # and the moved project's own file. Reverse-move returns the folder to its old place.
            $backup = @($solutions | ForEach-Object { $_.FullName }) + @($consumers) + @($projFull)
            $planResult = Invoke-MovePlan -Caption "Move $projFile" -Items $items -Move $move `
                -MoveArgs @($ctx.UseGit, $oldDir, $newDir, $repoFull) `
                -BackupPath $backup -Rollback $move -RollbackArgs @($ctx.UseGit, $newDir, $oldDir, $repoFull)
            $performed = $true
            $skippedCount = $planResult.Skipped

            if (-not $NoBuild) {
                & dotnet build $newProj
                $built = ($LASTEXITCODE -eq 0)
                if (-not $built) {
                    Write-Warning "Build failed after move. Review with 'git status'; revert with 'git restore .' if needed."
                }
            }
        }

        New-MoveResult -TypeName 'DotnetMove.MoveResult' -Engine 'dotnet' -Source $projFull -Destination $newProj `
            -Performed $performed -SkippedCount $skippedCount -Extra @{
            Solutions     = $slnNames
            ConsumerCount = $consumers.Count
            OwnRefCount   = $ownRefs.Count
            Built         = $built
        }
    }
}
