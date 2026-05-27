function Move-UnityAsset {
    <#
    .SYNOPSIS
        Move a Unity asset or folder while keeping its paired .meta file(s), so the GUIDs
        that scene/prefab/asmdef references depend on survive the move.

    .DESCRIPTION
        In Unity every asset and folder has a sibling '<name>.meta' carrying a stable GUID.
        References (in scenes, prefabs, and asmdef "references" entries of the form
        "GUID:...") resolve by that GUID, not by path. If you move files on disk without
        their .meta, Unity regenerates fresh GUIDs and every reference to them breaks.

        This cmdlet moves the asset (git mv when tracked) together with its own .meta; for a
        folder, the descendant .meta files travel inside it and the folder's sibling .meta is
        moved too. asmdef references are by name/GUID (not path), so they do not need editing
        - when moving an .asmdef this reports who references it, for your awareness only.

        Cross-platform and target-agnostic: asmdef includePlatforms/excludePlatforms (iOS,
        Android, etc.) are plain fields untouched by a move, so mobile layouts are preserved.

    .PARAMETER AssetPath
        Asset file or folder to move (under Assets/ or a package). Accepts pipeline input.

    .PARAMETER Destination
        Where to move the asset/folder, following `git mv` rules: an existing directory means move
        into it (keeping the name); otherwise it is the new path. Errors if it exists.

    .PARAMETER RepoRoot
        Root to scan for asmdef referencers. Defaults to the enclosing git repository root.

    .PARAMETER Force
        Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.

    .PARAMETER NoJournal
        Skip recording this move in the undo journal for this call, even when journaling is enabled
        (Undo-Netscoot will not see this move).

    .OUTPUTS
        Netscoot.UnityMoveResult

    .EXAMPLE
        # Preview; moves the asset/folder together with its .meta so GUIDs survive
        Move-UnityAsset -AssetPath ./Assets/Plugins/Tarragon -Destination ./Assets/Lib/Tarragon -WhatIf
        # Move it for real
        Move-UnityAsset -AssetPath ./Assets/Plugins/Tarragon -Destination ./Assets/Lib/Tarragon
        # Destination is an existing folder -> lands at ./Assets/Lib/Tarragon
        Move-UnityAsset -AssetPath ./Assets/Plugins/Tarragon -Destination ./Assets/Lib
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType('Netscoot.UnityMoveResult')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName', 'Path', 'PSPath')]
        [ValidateNotNullOrEmpty()]
        [string]$AssetPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Destination,
        [string]$RepoRoot,
        [switch]$Force,
        [switch]$NoJournal
    )

    process {
        $src = Resolve-FullPath $AssetPath
        if (-not (Test-Path -LiteralPath $src)) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.IO.FileNotFoundException]::new("Asset not found: $AssetPath"),
                    'AssetNotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $AssetPath))
            return
        }

        $srcMeta = "$src.meta"
        $hasMeta = Test-Path -LiteralPath $srcMeta -PathType Leaf
        # git mv semantics (shared by every mover): existing dir -> move into it; else rename.
        $dst = Resolve-MoveTarget -Source $src -Destination $Destination
        $dstMeta = "$dst.meta"
        if (Test-Path -LiteralPath $dst) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.IO.IOException]::new("Destination already exists: $dst"),
                    'DestinationExists', [System.Management.Automation.ErrorCategory]::ResourceExists, $dst))
            return
        }

        if (-not $RepoRoot) { $RepoRoot = Get-RepoRoot -StartPath (Split-Path -Parent $src) }
        $repoFull = Resolve-FullPath $RepoRoot

        if ($src -notmatch '[\\/](Assets|Packages)[\\/]') {
            Write-Warning "Asset is not under an 'Assets/' or 'Packages/' folder; .meta/GUID semantics only apply inside a Unity project."
        }
        if (-not $hasMeta) {
            Write-Warning "No .meta found for $([System.IO.Path]::GetFileName($src)); Unity will generate a new GUID on import, which can break existing references."
        }

        # When moving an .asmdef, report who references it (name/GUID refs are stable - info only).
        $referencers = @()
        $isAsmdef = ([System.IO.Path]::GetExtension($src) -eq '.asmdef')
        if ($isAsmdef) { $referencers = @(Get-AsmdefReferencers -AsmdefPath $src -RepoRoot $repoFull) }

        Write-Verbose "Plan: $([System.IO.Path]::GetFileName($src))  $src -> $dst  (meta: $hasMeta)"
        if ($referencers.Count -gt 0) {
            Write-Verbose "  referenced by $($referencers.Count) asmdef(s) - references are by name/GUID and survive the move:"
            foreach ($r in $referencers) { Write-Verbose "    $r" }
        }

        $performed = $false
        if ($PSCmdlet.ShouldProcess("$src -> $dst (with .meta)", 'Move Unity asset and its .meta')) {
            $ctx = Resolve-MoveContext -Cmdlet $PSCmdlet -Force:$Force -TargetForError $src
            if (-not $ctx) { return }

            # Unity references resolve by GUID (carried in the .meta), so there are no
            # reference edits to confirm - moving the asset + its .meta is the whole operation.
            $move = {
                param($UseGit, $Src, $Dst, $SrcMeta, $DstMeta, $HasMeta, $RepoFull)
                Move-PathTracked -UseGit $UseGit -Source $Src -Destination $Dst -RepoRoot $RepoFull
                if ($HasMeta) { Move-PathTracked -UseGit $UseGit -Source $SrcMeta -Destination $DstMeta -RepoRoot $RepoFull }
            }
            Invoke-MovePlan -Caption "Move Unity asset $(Split-Path -Leaf $src)" -Items @() -Move $move `
                -MoveArgs @($ctx.UseGit, $src, $dst, $srcMeta, $dstMeta, $hasMeta, $repoFull) | Out-Null
            $performed = $true
            Register-MoveUndo -RepoRoot $repoFull -Command 'Move-UnityAsset' -Engine 'unity' `
                -Source $src -Destination $dst `
                -UndoParams @{ AssetPath = $dst; Destination = $src; Force = [bool]$Force } -NoJournal:$NoJournal
            Write-Verbose "Moved asset$(if ($hasMeta) { ' + .meta' })."
        }

        New-MoveResult -TypeName 'Netscoot.UnityMoveResult' -Engine 'unity' -Source $src -Destination $dst `
            -Performed $performed -SkippedCount 0 -Extra @{
            MetaMoved    = ($performed -and $hasMeta)
            IsAsmdef     = $isAsmdef
            ReferencedBy = $referencers
        }
    }
}
