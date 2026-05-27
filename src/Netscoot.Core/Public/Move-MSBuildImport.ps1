function Move-MSBuildImport {
    <#
    .SYNOPSIS
        Move a shared MSBuild .props/.targets file and fix every project (or other
        props/targets) that imports it via `<Import Project="...">`.

    .DESCRIPTION
        There is no dotnet CLI for `<Import>`, so this reconciles the relative Import paths
        directly with precise, formatting- and BOM-preserving text edits (it replaces the
        exact `Project="<value>"` token captured from the XML, not a blind regex). It also
        fixes the moved file's own outgoing `<Import>` paths, which break when its location
        changes. The $(MSBuildThisFileDirectory) token is resolved/preserved; other $(...)
        tokens are reported as unresolved rather than guessed.

        Note: Directory.Build.props/.targets (and Directory.Packages.props, etc.) are imported
        by location, not an explicit `<Import>` - moving one changes inheritance scope, which
        cannot be "fixed" by editing imports. For those this warns (like the inheritance check)
        and only fixes the file's own outgoing imports.

        Importers may include native .vcxproj files; their `<Import>` path is fixed on any OS (a
        best-effort, path-only update), but a .vcxproj's native link settings are never
        reconciled off Windows; that remains Move-NativeProject's Windows-only job.

        dotnet is not required here; git is used when available (else confirmed plain-move
        fallback via -Force). Supports -WhatIf.

    .PARAMETER Path
        The .props/.targets file to move. Accepts pipeline input (a path string or a Get-ChildItem/Get-Item item; other object types are rejected).

    .PARAMETER Destination
        New file path (or a folder, in which case the file keeps its name).

    .PARAMETER RepositoryRoot
        Root to scan for importers. Defaults to the enclosing git repository root.

    .PARAMETER Force
        Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.

    .PARAMETER NoJournal
        Skip recording this move in the undo journal for this call, even when journaling is enabled
        (Undo-Netscoot will not see this move).

    .OUTPUTS
        Netscoot.ImportMoveResult

    .EXAMPLE
        # Move a shared props/targets and fix every consumer's Import path
        Move-MSBuildImport -Path ./Shared.props -Destination ./build/Shared.props -WhatIf
        # Move into an existing folder (lands at ./build/Shared.props)
        Move-MSBuildImport -Path ./Shared.props -Destination ./build
        # A by-location import (Directory.Build.props): moving it changes inheritance scope - reported
        Move-MSBuildImport -Path ./src/Directory.Build.props -Destination ./Directory.Build.props
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType('Netscoot.ImportMoveResult')]
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
                    [System.IO.FileNotFoundException]::new("File not found: $Path"),
                    'FileNotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $Path))
            return
        }
        if ([System.IO.Path]::GetExtension($src) -notin '.props', '.targets') {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new("Not a .props/.targets file: $Path"),
                    'NotAnImportFile', [System.Management.Automation.ErrorCategory]::InvalidArgument, $Path))
            return
        }

        $srcName = Split-Path -Leaf $src
        # git mv semantics (shared by every mover): existing dir -> move into it; else rename.
        $newPath = Resolve-MoveTarget -Source $src -Destination $Destination
        $newDir = Split-Path -Parent $newPath
        if (Test-Path -LiteralPath $newPath) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.IO.IOException]::new("Destination already exists: $newPath"),
                    'DestinationExists', [System.Management.Automation.ErrorCategory]::ResourceExists, $newPath))
            return
        }

        if (-not $RepositoryRoot) { $RepositoryRoot = Get-RepositoryRoot -StartPath (Split-Path -Parent $src) }
        $repoFull = Resolve-FullPath $RepositoryRoot

        $autoImported = ($srcName -match '^Directory\.(Build|Packages|Solution)\.(props|targets)$')

        # Importers: files whose <Import> resolves to the moved file.
        $importers = @()
        if (-not $autoImported) {
            foreach ($f in (Find-MSBuildFiles -Root $repoFull)) {
                if (Test-PathEqual $f.FullName $src) { continue }
                foreach ($imp in (Get-ImportPaths -ProjectFile $f.FullName)) {
                    if ($imp.FullPath -and (Test-PathEqual $imp.FullPath $src)) {
                        $importers += [pscustomobject]@{ File = $f.FullName; OldRaw = $imp.Raw }
                    }
                }
            }
        }

        # The moved file's own outgoing imports (break when its location changes).
        $ownImports = @(Get-ImportPaths -ProjectFile $src | Where-Object { -not $_.Unresolved -and $_.FullPath })
        $ownUnresolved = @(Get-ImportPaths -ProjectFile $src | Where-Object { $_.Unresolved })

        Write-Verbose "Plan: move import $srcName  $src -> $newPath"
        Write-Verbose "  importers to fix  : $($importers.Count)"
        Write-Verbose "  own imports to fix: $($ownImports.Count)"
        if ($autoImported) {
            Write-Warning "$srcName is imported by location (auto-import). Moving it changes which projects inherit it; that inheritance cannot be fixed by editing <Import> - verify the new location applies to the intended projects."
        }
        foreach ($u in $ownUnresolved) {
            Write-Warning "Own <Import Project=`"$($u.Raw)`"> uses an unresolved MSBuild variable; fix it by hand if its target is outside the moved file."
        }

        $performed = $false
        $skippedCount = 0

        if ($PSCmdlet.ShouldProcess("$src -> $newPath", 'Move MSBuild import and fix <Import> consumers')) {
            $ctx = Resolve-MoveContext -Cmdlet $PSCmdlet -Force:$Force -TargetForError $src
            if (-not $ctx) { return }

            # Import fixes happen after the move; Reattach-only items. New paths are computable now.
            $fixSb = { param($File, $Old, $New) [void](Set-RawImportValue -File $File -OldValue $Old -NewValue $New) }
            $items = @()
            foreach ($imp in $importers) {
                $newRaw = Get-NewImportRaw -ImporterDir (Split-Path -Parent $imp.File) -TargetAbs $newPath -OldRaw $imp.OldRaw
                $items += New-MoveItem -Description "importer $(Split-Path -Leaf $imp.File): $($imp.OldRaw) -> $newRaw" `
                    -Reattach $fixSb -ReattachArgs @($imp.File, $imp.OldRaw, $newRaw)
            }
            foreach ($own in $ownImports) {
                $newRaw = Get-NewImportRaw -ImporterDir $newDir -TargetAbs $own.FullPath -OldRaw $own.Raw
                if ($newRaw -ne $own.Raw) {
                    $items += New-MoveItem -Description "own import: $($own.Raw) -> $newRaw" `
                        -Reattach $fixSb -ReattachArgs @($newPath, $own.Raw, $newRaw)
                }
            }
            $move = { param($UseGit, $Src, $Dst, $Repository) Move-PathTracked -UseGit $UseGit -Source $Src -Destination $Dst -RepositoryRoot $Repository }

            $planResult = Invoke-MovePlan -Caption "Move import $srcName" -Items $items -Move $move `
                -MoveArgs @($ctx.UseGit, $src, $newPath, $repoFull) `
                -RepositoryRoot $repoFull -Command 'Move-MSBuildImport' -Engine 'dotnet' -Source $src -Destination $newPath `
                -UndoParams @{ Path = $newPath; Destination = $src; Force = [bool]$Force } -NoJournal:$NoJournal
            $performed = $true
            $skippedCount = $planResult.Skipped
        }

        New-MoveResult -TypeName 'Netscoot.ImportMoveResult' -Engine 'dotnet' -Source $src -Destination $newPath `
            -Performed $performed -SkippedCount $skippedCount -Extra @{
            ImportersFixed  = $importers.Count
            OwnImportsFixed = $ownImports.Count
            AutoImported    = $autoImported
        }
    }
}
