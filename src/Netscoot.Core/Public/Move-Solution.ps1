function Move-Solution {
    <#
    .SYNOPSIS
        Move a solution file (.sln/.slnx) and rebase the relative project paths it stores, so
        every project it references still resolves from the solution's new location.

    .DESCRIPTION
        A solution stores each project as a path relative to the solution file. Moving the
        solution changes that base directory, so every entry must be recomputed. The dotnet
        CLI has no "rebase" command, so this rewrites the stored paths with precise,
        formatting- and BOM-preserving edits. It replaces the exact path token captured from the
        file (the .slnx `<Project Path="...">` or the .sln project line), not a blind regex, and
        keeps each format's separator convention (/ for .slnx, \ for .sln). Project-to-project
        references are unaffected by a solution move and are left alone.

        git is used when available (else confirmed plain-move fallback via -Force). -WhatIf
        supported. dotnet is not required.

    .PARAMETER Path
        The .sln/.slnx file to move. Accepts pipeline input (a path string or a Get-ChildItem/Get-Item item; other object types are rejected).

    .PARAMETER Destination
        New file path (or a folder, in which case the solution keeps its name).

    .PARAMETER Force
        Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.

    .PARAMETER NoJournal
        Skip recording this move in the undo journal for this call, even when journaling is enabled
        (Undo-Netscoot will not see this move).

    .OUTPUTS
        Netscoot.SolutionMoveResult

    .EXAMPLE
        # Preview moving a solution and rebasing the project paths it stores
        Move-Solution -Path ./Demo.slnx -Destination ./build/Demo.slnx -WhatIf
        # Destination is an existing folder -> lands at ./build/Demo.slnx
        Move-Solution -Path ./Demo.slnx -Destination ./build
        # Works the same for .sln
        Move-Solution -Path ./Demo.sln -Destination ./build/Demo.sln
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType('Netscoot.SolutionMoveResult')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [Netscoot.PathInputTransform()]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Destination,

        [switch]$Force,
        [switch]$NoJournal
    )

    process {
        $src = Resolve-FullPath $Path
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.IO.FileNotFoundException]::new("Solution not found: $Path"),
                    'SolutionNotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $Path))
            return
        }
        $ext = [System.IO.Path]::GetExtension($src)
        if ($ext -notin '.sln', '.slnx') {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new("Not a solution file (.sln/.slnx): $Path"),
                    'NotASolution', [System.Management.Automation.ErrorCategory]::InvalidArgument, $Path))
            return
        }

        $name = Split-Path -Leaf $src
        # git mv semantics (shared by every mover): existing dir -> move into it; else rename.
        $newPath = Resolve-MoveTarget -Source $src -Destination $Destination
        if (Test-Path -LiteralPath $newPath) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.IO.IOException]::new("Destination already exists: $newPath"),
                    'DestinationExists', [System.Management.Automation.ErrorCategory]::ResourceExists, $newPath))
            return
        }
        $newDir = Split-Path -Parent $newPath

        $entries = @(Get-SolutionProjectEntries -SolutionFile $src)
        Write-MovePlan -Cmdlet $PSCmdlet -Caption "Move-Solution $name  $src -> $newPath" -Items ([ordered]@{
                'project paths to rebase' = @($entries | ForEach-Object { $_.Stored })
            })

        $performed = $false
        $rebased = 0
        $skippedCount = 0

        if ($PSCmdlet.ShouldProcess("$src -> $newPath", "Move solution and rebase $($entries.Count) project path(s)")) {
            $ctx = Resolve-MoveContext -Cmdlet $PSCmdlet -Force:$Force -TargetForError $src
            if (-not $ctx) { return }
            $repoFull = Get-RepositoryRoot -StartPath (Split-Path -Parent $src)

            # The solution-path rebases happen after the move, so they are Reattach-only items.
            $counter = @{ N = 0 }
            $rebaseSb = { param($File, $Old, $New, $Counter) if (Set-RawFileReplacement -File $File -Old $Old -New $New) { $Counter.N++ } }
            $items = @()
            foreach ($e in $entries) {
                $rel = Get-RelativePathSafe -From $newDir -To $e.Abs
                if ($ext -ieq '.slnx') { $rel = $rel -replace '\\', '/'; $old = "Path=`"$($e.Stored)`""; $new = "Path=`"$rel`"" }
                else { $old = "`"$($e.Stored)`""; $new = "`"$rel`"" }
                $items += New-MoveItem -Description "rebase path: $($e.Stored) -> $rel" `
                    -Reattach $rebaseSb -ReattachArgs @($newPath, $old, $new, $counter)
            }
            $move = { param($UseGit, $Src, $Dst, $Repository) Move-PathTracked -UseGit $UseGit -Source $Src -Destination $Dst -RepositoryRoot $Repository }

            $planResult = Invoke-MovePlan -Caption "Move solution $name" -Items $items -Move $move `
                -MoveArgs @($ctx.UseGit, $src, $newPath, $repoFull) `
                -RepositoryRoot $repoFull -Command 'Move-Solution' -Engine 'dotnet' -Source $src -Destination $newPath `
                -UndoParams @{ Path = $newPath; Destination = $src; Force = [bool]$Force } -NoJournal:$NoJournal
            $performed = $true
            $rebased = $counter.N
            $skippedCount = $planResult.Skipped
        }

        New-MoveResult -TypeName 'Netscoot.SolutionMoveResult' -Engine 'dotnet' -Source $src -Destination $newPath `
            -Performed $performed -SkippedCount $skippedCount -Extra ([ordered]@{
                ProjectsRebased = $rebased
            })
    }
}
