function Move-DotnetProjectTree {
    <#
    .SYNOPSIS
        Move a folder that contains one or more managed .NET projects, reconciling solution
        membership and every external project reference in one operation. This is the bulk
        "restructure" case (e.g. wrapping several projects into a new parent folder).

    .DESCRIPTION
        Enumerates the managed projects (.csproj/.fsproj/.vbproj) under the folder and treats
        them as a single co-moving set. It reconciles only what crosses the folder boundary:
        solution membership for each moved project (dotnet sln remove/add), external consumers
        (projects outside the folder that reference one inside), and the moved projects' own
        references to projects outside the folder.
        References between two co-moved projects are left untouched - their relative path is
        unchanged because both move by the same delta. Everything is delegated to the dotnet
        CLI; nothing is hand-edited.

        Like Move-DotnetProject: dotnet is required; git is used when available (else a
        confirmed plain-move fallback via -Force / ShouldContinue); supports -WhatIf.

    .PARAMETER Path
        The folder to move. Accepts pipeline input.

    .PARAMETER Destination
        Where to move the folder, following `git mv` rules: an existing directory means move into
        it (keeping the name); otherwise it is the folder's new path. Errors if the result exists.

    .PARAMETER RepoRoot
        Root to scan. Defaults to the enclosing git repository root.

    .PARAMETER NoBuild
        Skip the verifying build of the moved projects.

    .PARAMETER Force
        Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.

    .PARAMETER NoJournal
        Skip recording this move in the undo journal for this call, even when journaling is enabled
        (Undo-Netscoot will not see this move).

    .OUTPUTS
        Netscoot.TreeMoveResult

    .EXAMPLE
        # Preview moving a whole folder of projects as one set
        Move-DotnetProjectTree -Path ./src/Group -Destination ./libs/Group -WhatIf
        # Move it: only references that cross the folder boundary are reconciled (internal ones are untouched)
        Move-DotnetProjectTree -Path ./src/Group -Destination ./libs/Group
        # Move into an existing folder (lands at ./libs/Group)
        Move-DotnetProjectTree -Path ./src/Group -Destination ./libs
        # Skip the verifying build
        Move-DotnetProjectTree -Path ./src/Group -Destination ./libs/Group -NoBuild
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType('Netscoot.TreeMoveResult')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName', 'PSPath')]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Destination,

        [string]$RepoRoot,
        [switch]$NoBuild,
        [switch]$Force,
        [switch]$NoJournal
    )

    process {
        if (-not (Assert-DotnetAvailable -Cmdlet $PSCmdlet)) { return }

        # Trim any trailing slash: $srcDir is used as a string prefix when rebasing project paths
        # under the destination (below), so a trailing slash would drop the separator and corrupt
        # the rebased paths.
        $srcDir = (Resolve-FullPath $Path).TrimEnd([char]'\', [char]'/')
        if (-not (Test-Path -LiteralPath $srcDir -PathType Container)) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.IO.DirectoryNotFoundException]::new("Folder not found: $Path"),
                    'FolderNotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $Path))
            return
        }
        # git mv semantics: an existing destination directory means "move the tree into it";
        # otherwise Destination is the tree's new path (a rename).
        $newDir = Resolve-MoveTarget -Source $srcDir -Destination $Destination
        if (Test-Path -LiteralPath $newDir) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.IO.IOException]::new("Destination already exists: $newDir"),
                    'DestinationExists', [System.Management.Automation.ErrorCategory]::ResourceExists, $newDir))
            return
        }

        if (Test-PathOverlap $newDir $srcDir) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new("Destination '$newDir' overlaps the source '$srcDir'; a folder cannot be moved into itself or its own subtree."),
                    'PathOverlap', [System.Management.Automation.ErrorCategory]::InvalidArgument, $Destination))
            return
        }

        if (-not $RepoRoot) { $RepoRoot = Get-RepoRoot -StartPath $srcDir }
        $repoFull = Resolve-FullPath $RepoRoot

        $moved = @(Find-ProjectFiles -Root $srcDir | ForEach-Object { Resolve-FullPath $_.FullName })
        if ($moved.Count -eq 0) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new("No managed projects (.csproj/.fsproj/.vbproj) found under $srcDir."),
                    'NoProjectsInFolder', [System.Management.Automation.ErrorCategory]::InvalidData, $Path))
            return
        }

        $allSolutions = @(Find-Solutions -Root $repoFull)
        $allProjects = @(Find-ProjectFiles -Root $repoFull)

        # Per moved project: which solutions list it, and which outside projects consume it.
        $plan = @()
        foreach ($p in $moved) {
            $extConsumers = @(Get-ConsumingProjects -ProjectFile $p -Candidates $allProjects |
                    Where-Object { -not (Test-PathUnder -Path $_ -Dir $srcDir) })
            $extRefs = @(Get-ProjectReferencePaths -ProjectFile $p |
                    Where-Object { $_.IsLiteral -and -not (Test-PathUnder -Path $_.FullPath -Dir $srcDir) })
            $slns = @(Get-SolutionsReferencing -ProjectFile $p -Candidates $allSolutions)
            $newP = $newDir + $p.Substring($srcDir.Length)   # rebase under destination
            $plan += [pscustomobject]@{ Old = $p; New = $newP; Solutions = $slns; ExtConsumers = $extConsumers; ExtRefs = $extRefs }
        }

        # Accumulate explicitly (member-enumeration like $plan.ExtConsumers trips StrictMode
        # when entries are empty / the array has a single element).
        $allExt = @(); $allSln = @()
        foreach ($it in $plan) { $allExt += $it.ExtConsumers; $allSln += $it.Solutions }
        $totalConsumers = @($allExt | Select-Object -Unique).Count
        Write-Verbose "Plan: move tree $srcDir -> $newDir"
        Write-Verbose "  projects moving      : $($moved.Count)"
        Write-Verbose "  external consumers   : $totalConsumers"
        Write-Verbose "  solutions touched    : $(@($allSln | Select-Object -Unique).Count)"

        # Relocating the whole folder changes its depth, so warn if which Directory.Build.*
        # files apply differs at the destination. Checked once at the tree root (files inside
        # the tree move with it; only ancestors outside it change) and before the move so the
        # source chain still resolves.
        Test-DirectoryBuildInheritance -OldDir $srcDir -NewDir $newDir -RepoRoot $repoFull

        # Warn about references the CLI cannot reconcile on a move (non-literal path or conditional).
        foreach ($p in $moved) {
            foreach ($r in (Get-UnreconcilableReferences -ProjectFile $p)) {
                $why = if (-not $r.IsLiteral) { 'non-literal path' } else { 'conditional' }
                Write-Warning ("$(Split-Path -Leaf $p) has an unreconcilable ProjectReference '$($r.Raw)' ($why); verify it by hand after the move.")
            }
        }

        $performed = $false
        $built = $null
        $skippedCount = 0

        if ($PSCmdlet.ShouldProcess("$srcDir -> $newDir ($($moved.Count) project(s))", 'Move project tree and reconcile external references')) {
            $ctx = Resolve-MoveContext -Cmdlet $PSCmdlet -Force:$Force -TargetForError $srcDir
            if (-not $ctx) { return }

            $items = @()
            foreach ($item in $plan) {
                $items += New-DotnetReferenceItems -Solutions $item.Solutions -Consumers $item.ExtConsumers -OwnRefs $item.ExtRefs `
                    -OldProj $item.Old -NewProj $item.New -Label (Split-Path -Leaf $item.Old)
            }
            $move = { param($UseGit, $Src, $Dst, $Repository) Move-PathTracked -UseGit $UseGit -Source $Src -Destination $Dst -RepoRoot $Repository }

            # Files the reconciliation edits (for rollback): every touched solution, every external
            # consumer, and each moved project's own file. Reverse-move returns the whole tree.
            $backup = @()
            foreach ($item in $plan) {
                $backup += @($item.Solutions | ForEach-Object { $_.FullName })
                $backup += @($item.ExtConsumers)
            }
            $backup += @($moved)
            $planResult = Invoke-MovePlan -Caption "Move tree $(Split-Path -Leaf $srcDir)" -Items $items -Move $move `
                -MoveArgs @($ctx.UseGit, $srcDir, $newDir, $repoFull) `
                -BackupPath $backup -Rollback $move -RollbackArgs @($ctx.UseGit, $newDir, $srcDir, $repoFull)
            $performed = $true
            $skippedCount = $planResult.Skipped
            Register-MoveUndo -RepoRoot $repoFull -Command 'Move-DotnetProjectTree' -Engine 'dotnet' `
                -Source $srcDir -Destination $newDir `
                -UndoParams @{ Path = $newDir; Destination = $srcDir; Force = [bool]$Force } -NoJournal:$NoJournal

            if (-not $NoBuild) {
                foreach ($item in $plan) { & dotnet build $item.New | Out-Null }
                $built = ($LASTEXITCODE -eq 0)
                if (-not $built) { Write-Warning "A build failed after the tree move. Review with 'git status'; revert with 'git restore .' if needed." }
            }
        }

        New-MoveResult -TypeName 'Netscoot.TreeMoveResult' -Engine 'dotnet' -Source $srcDir -Destination $newDir `
            -Performed $performed -SkippedCount $skippedCount -Extra @{
            ProjectsMoved = $moved.Count
            ConsumerCount = $totalConsumers
            Built         = $built
        }
    }
}
