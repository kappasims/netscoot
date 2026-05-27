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
        of the repository's solutions) is surfaced as a Warning (or, with -Strict, a non-
        terminating error honoring -ErrorAction).

    .PARAMETER Project
        Path to the project file (.csproj/.fsproj/.vbproj). Accepts pipeline input - pipe a
        path string or any object with a FullName/Path property (e.g. Get-Item output).

    .PARAMETER Destination
        Where to move the project folder, following `git mv` rules: if Destination is an existing
        directory the folder moves into it (keeping its name, e.g. './libs' -> './libs/Tarragon');
        otherwise Destination is the project's new folder path (a rename, './libs/Tarragon'). The
        project file and its sibling contents move as one. Errors if the resulting folder exists.

    .PARAMETER RepositoryRoot
        Root to scan for solutions/consumers. Defaults to the enclosing git repository root.

    .PARAMETER Strict
        Escalate solution-divergence warnings to non-terminating errors.

    .PARAMETER NoBuild
        Skip the verifying 'dotnet build' at the end.

    .PARAMETER Force
        Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.

    .PARAMETER NoJournal
        Skip recording this move in the undo journal for this call, even when journaling is enabled
        (Undo-Netscoot will not see this move).

    .OUTPUTS
        Netscoot.MoveResult

    .EXAMPLE
        # Preview the move and emit the plan object; nothing changes
        Move-DotnetProject -Project ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon -WhatIf
        # Rename the project folder src/Tarragon -> libs/Tarragon
        Move-DotnetProject -Project ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon
        # Destination is an existing folder -> moves into it, landing at libs/Tarragon
        Move-DotnetProject -Project ./src/Tarragon/Tarragon.csproj -Destination ./libs
        # Skip the verifying 'dotnet build' at the end
        Move-DotnetProject -Project ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon -NoBuild
        # Treat solution-membership divergence as a non-terminating error, not a warning
        Move-DotnetProject -Project ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon -Strict
        # Take the project from the pipeline
        Get-Item ./src/Tarragon/Tarragon.csproj | Move-DotnetProject -Destination ./libs/Tarragon
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType('Netscoot.MoveResult')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName', 'Path', 'PSPath')]
        [ValidateNotNullOrEmpty()]
        [string]$Project,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Destination,

        [string]$RepositoryRoot,
        [switch]$Strict,
        [switch]$NoBuild,
        [switch]$Force,
        [switch]$NoJournal
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
        if (-not $RepositoryRoot) { $RepositoryRoot = Get-RepositoryRoot -StartPath $oldDir }
        $repoFull = Resolve-FullPath $RepositoryRoot

        # git mv semantics: an existing destination directory means "move the project folder into
        # it" (libs -> libs/Tarragon); otherwise Destination is the project's new folder path.
        $newDir = Resolve-MoveTarget -Source $oldDir -Destination $Destination
        $newProj = Join-Path $newDir $projFile
        if (Test-Path -LiteralPath $newDir) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.IO.IOException]::new("Destination already exists: $newDir"),
                    'DestinationExists', [System.Management.Automation.ErrorCategory]::ResourceExists, $newDir))
            return
        }
        if (Test-PathOverlap $newDir $oldDir) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new("Destination '$newDir' overlaps the source '$oldDir'; a project folder cannot be moved into itself or its own subtree."),
                    'PathOverlap', [System.Management.Automation.ErrorCategory]::InvalidArgument, $Destination))
            return
        }

        Write-Verbose "Scanning repository root: $repoFull"
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

        # Debug: full membership matrix for the whole repository.
        if ($DebugPreference -ne 'SilentlyContinue') {
            foreach ($m in (Get-SolutionMembership -Solutions $allSolutions)) {
                Write-Debug "Solution $($m.Solution) lists $($m.Projects.Count) project(s):"
                foreach ($p in $m.Projects) { Write-Debug "    $p" }
            }
        }

        # Divergence: the project is in some solutions but not others in the same repository.
        $refSlnPaths = @(); foreach ($s in $solutions) { $refSlnPaths += $s.FullName }
        $notReferencing = @($allSolutions | Where-Object { $refSlnPaths -notcontains $_.FullName })
        if ($solutions.Count -gt 0 -and $notReferencing.Count -gt 0) {
            $inNames = ($slnNames -join ', ')
            $outNameList = @(); foreach ($s in $notReferencing) { $outNameList += $s.Name }
            $outNames = ($outNameList -join ', ')
            $msg = "Solution divergence: '$projFile' is referenced by [$inNames] but not by [$outNames] in the same repository. Only the referencing solution(s) will be updated."
            if ($Strict) {
                $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                        [System.InvalidOperationException]::new($msg),
                        'SolutionDivergence', [System.Management.Automation.ErrorCategory]::InvalidData, $projFull))
            } else {
                Write-Warning $msg
            }
        }

        Test-DirectoryBuildInheritance -OldDir $oldDir -NewDir $newDir -RepositoryRoot $repoFull
        Write-UnreconcilableReferenceWarning -MovedProject $projFull -AllProjects $allProjects -LiteralConsumers $consumers

        $built = $null
        $performed = $false
        $skippedCount = 0

        if ($PSCmdlet.ShouldProcess("$projFile : $oldDir -> $newDir", 'Move .NET project and reconcile references')) {
            $ctx = Resolve-MoveContext -Cmdlet $PSCmdlet -Force:$Force -TargetForError $projFull
            if (-not $ctx) { return }

            $items = New-DotnetReferenceItems -Solutions $solutions -Consumers $consumers -OwnRefs $ownRefs `
                -OldProj $projFull -NewProj $newProj
            $move = { param($UseGit, $Src, $Dst, $Repository) Move-PathTracked -UseGit $UseGit -Source $Src -Destination $Dst -RepositoryRoot $Repository }

            # Files the reconciliation edits (for rollback): each solution, each consumer project,
            # and the moved project's own file. Reverse-move returns the folder to its old place.
            $backup = @($solutions | ForEach-Object { $_.FullName }) + @($consumers) + @($projFull)
            $planResult = Invoke-MovePlan -Caption "Move $projFile" -Items $items -Move $move `
                -MoveArgs @($ctx.UseGit, $oldDir, $newDir, $repoFull) `
                -BackupPath $backup -Rollback $move -RollbackArgs @($ctx.UseGit, $newDir, $oldDir, $repoFull)
            $performed = $true
            $skippedCount = $planResult.Skipped
            Register-MoveUndo -RepositoryRoot $repoFull -Command 'Move-DotnetProject' -Engine 'dotnet' `
                -Source $projFull -Destination $newProj `
                -UndoParams @{ Project = $newProj; Destination = $oldDir; Force = [bool]$Force } -NoJournal:$NoJournal

            if (-not $NoBuild) {
                & dotnet build $newProj
                $built = ($LASTEXITCODE -eq 0)
                if (-not $built) {
                    Write-Warning "Build failed after move. Review with 'git status'; revert with 'git restore .' if needed."
                }
            }
        }

        New-MoveResult -TypeName 'Netscoot.MoveResult' -Engine 'dotnet' -Source $projFull -Destination $newProj `
            -Performed $performed -SkippedCount $skippedCount -Extra @{
            Solutions     = $slnNames
            ConsumerCount = $consumers.Count
            OwnRefCount   = $ownRefs.Count
            Built         = $built
        }
    }
}
