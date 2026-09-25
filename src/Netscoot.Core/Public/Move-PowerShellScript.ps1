function Move-PowerShellScript {
    <#
    .SYNOPSIS
        Move a standalone .ps1 script and fix the relative paths in scripts that dot-source or
        call it (and the moved script's own dot-source/call paths).

    .DESCRIPTION
        Finds references via the PowerShell AST: dot-source (`. path`), call (`& path`) and
        Import-Module invocations whose path is a literal string or a $PSScriptRoot-based string
        resolving to the moved script. A relative path is resolved against the referencing
        script's own folder. It rewrites those paths as whole tokens, keeping each file's encoding
        and the original style ($PSScriptRoot-prefixed or .\-relative, and the / or \ separator).
        The moved script's own dot-source, call, Import-Module and `using module` paths are
        rebased too.

        HEURISTIC LIMIT: only literal and $PSScriptRoot-based string paths are resolved and
        rewritten. A string built from other variables (e.g. one rooted at $dir), or a string
        literal elsewhere in a script (e.g. a Join-Path argument), whose leaf matches the moved
        script is reported as a possible dynamic reference to verify by hand. A path assembled
        with no string naming the script cannot be detected at all - grep to be sure. Treat the
        result as "fixed what could be proven," not "guaranteed complete."

        git is used when available (else confirmed plain-move fallback via -Force). -WhatIf
        supported; dotnet not required.

    .PARAMETER Path
        The .ps1 to move. Accepts pipeline input (a path string or a Get-ChildItem/Get-Item item; other object types are rejected).

    .PARAMETER Destination
        New file path (or a folder, in which case the script keeps its name).

    .PARAMETER RepositoryRoot
        Root to scan for referencing scripts. Defaults to the enclosing git repository root.

    .PARAMETER Force
        When git is not installed, move with a plain PowerShell `Move-Item` without asking first.
        Without -Force it asks before falling back. The plain move does not preserve git history.

    .PARAMETER NoJournal
        Skip recording this move in the undo journal for this call, even when journaling is enabled
        (Undo-Netscoot will not see this move).

    .OUTPUTS
        Netscoot.ScriptMoveResult

    .EXAMPLE
        # Preview; rewrites dot-source/call paths in referencing scripts and the script's own refs
        Move-PowerShellScript -Path ./lib/helpers.ps1 -Destination ./shared/helpers.ps1 -WhatIf
        # Move it for real
        Move-PowerShellScript -Path ./lib/helpers.ps1 -Destination ./shared/helpers.ps1
        # Limit the scan for referencing scripts to a specific root
        Move-PowerShellScript -Path ./lib/helpers.ps1 -Destination ./shared/helpers.ps1 -RepositoryRoot ./lib
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType('Netscoot.ScriptMoveResult')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [Netscoot.PathInputTransform()]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Destination,

        [string]$RepositoryRoot,
        [switch]$Force,
        [switch]$NoJournal
    )

    process {
        $src = Resolve-FullPath $Path
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.IO.FileNotFoundException]::new("Script not found: $Path"),
                    'ScriptNotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $Path))
            return
        }
        if ([System.IO.Path]::GetExtension($src) -ne '.ps1') {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new("Not a .ps1 script: $Path"),
                    'NotAScript', [System.Management.Automation.ErrorCategory]::InvalidArgument, $Path))
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

        if (-not $RepositoryRoot) { $RepositoryRoot = Get-RepositoryRoot -StartPath (Split-Path -Parent $src) }
        $repoFull = Resolve-FullPath $RepositoryRoot

        # Referencers: scripts that dot-source/call the moved file.
        $referencers = @()
        $unresolvedRefs = @()
        foreach ($f in (Find-PowerShellFiles -Root $repoFull)) {
            if (Test-PathEqual $f.FullName $src) { continue }
            $scan = Get-PowerShellScriptReferences -File $f.FullName
            $referencers += @($scan.Paths | Where-Object { Test-PathEqual $_.Target $src })
            $unresolvedRefs += @($scan.Dynamic | Where-Object { ($_.Raw -split '[\\/]')[-1] -eq $name })
        }
        # The moved script's own paths (break when its location changes).
        $ownRefs = @((Get-PowerShellScriptReferences -File $src).Paths | Where-Object { $_.RawFollowing($newPath) -ne $_.Raw })

        $refRels = @($referencers | ForEach-Object { $_.File })
        $ownRels = @($ownRefs | ForEach-Object { $_.Raw })
        Write-MovePlan -Cmdlet $PSCmdlet -Caption "Move-PowerShellScript $name  $src -> $newPath" -Items ([ordered]@{
                'referencing scripts to fix' = $refRels
                'own references to fix'      = $ownRels
            })
        foreach ($u in $unresolvedRefs) {
            Write-Warning "Possible dynamic reference to $name in $($u.File): `"$($u.Raw)`" - could not resolve statically; verify by hand."
        }

        $performed = $false
        $skippedCount = 0

        if ($PSCmdlet.ShouldProcess("$src -> $newPath", 'Move script and fix dot-source/call references')) {
            $ctx = Resolve-MoveContext -Cmdlet $PSCmdlet -Force:$Force -TargetForError $src
            if (-not $ctx) { return }

            # Reference fixes happen after the move; Reattach-only items.
            $pointAt = { param($Ref, $Target) [void]$Ref.PointAt($Target) }
            $followFile = { param($Ref, $NewFile) [void]$Ref.FollowFile($NewFile) }
            $items = @()
            foreach ($ref in $referencers) {
                $items += New-MoveItem -Description "referencer $(Split-Path -Leaf $ref.File): $($ref.Raw) -> $($ref.RawPointingAt($newPath))" `
                    -Reattach $pointAt -ReattachArgs @($ref, $newPath)
            }
            foreach ($ref in $ownRefs) {
                $items += New-MoveItem -Description "own reference: $($ref.Raw) -> $($ref.RawFollowing($newPath))" `
                    -Reattach $followFile -ReattachArgs @($ref, $newPath)
            }
            $move = { param($UseGit, $Src, $Dst, $Repository) Move-PathTracked -UseGit $UseGit -Source $Src -Destination $Dst -RepositoryRoot $Repository }

            $backup = @($referencers | ForEach-Object { $_.File }) + @($src)
            $planResult = Invoke-MovePlan -Caption "Move script $name" -Items $items -Move $move `
                -MoveArgs @($ctx.UseGit, $src, $newPath, $repoFull) `
                -BackupPath $backup -Rollback $move -RollbackArgs @($ctx.UseGit, $newPath, $src, $repoFull) `
                -RepositoryRoot $repoFull -Command 'Move-PowerShellScript' -Engine 'powershell' -Source $src -Destination $newPath `
                -UndoParams @{ Path = $newPath; Destination = $src; Force = [bool]$Force } -NoJournal:$NoJournal
            $performed = $true
            $skippedCount = $planResult.Skipped
        }

        New-MoveResult -TypeName 'Netscoot.ScriptMoveResult' -Engine 'powershell' -Source $src -Destination $newPath `
            -Performed $performed -SkippedCount $skippedCount -Extra ([ordered]@{
                ReferencersFixed = $referencers.Count
                OwnRefsFixed     = $ownRefs.Count
                UnresolvedRefs   = $unresolvedRefs.Count
            })
    }
}
