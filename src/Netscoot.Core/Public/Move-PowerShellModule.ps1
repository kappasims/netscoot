function Move-PowerShellModule {
    <#
    .SYNOPSIS
        Move a PowerShell module folder and update the script paths that reference it or that
        it uses.

    .DESCRIPTION
        Moves a module directory (git mv when tracked). Scripts elsewhere that import the module
        by path (Import-Module, `using module`) or dot-source one of its files are repointed, and
        the module's own .ps1/.psm1 paths to files outside it are rebased, with the same
        encoding-preserving edits as Move-PowerShellScript. The manifest's entries are module-relative,
        so the .psd1 is left unchanged and only validated with Test-ModuleManifest.

        Limits (warned, not fixed): a path built from variables is reported as a possible dynamic
        reference. Any path computed at runtime cannot be reconciled automatically.

    .PARAMETER ModulePath
        Path to the module folder, or directly to its .psd1 manifest. Accepts a path string or a Get-ChildItem/Get-Item item from the pipeline, and rejects other object types.

    .PARAMETER Destination
        Where to move the module folder, following `git mv` rules: An existing directory means move
        into it, keeping the name. Any other path is the module's new folder path.

    .PARAMETER Force
        When git is not installed, move with a plain PowerShell `Move-Item` without asking first.
        Without -Force it asks before falling back. The plain move does not preserve git history.

    .PARAMETER NoJournal
        Skip recording this move in the undo journal for this call, even when journaling is enabled
        (Undo-Netscoot will not see this move).

    .OUTPUTS
        Netscoot.PSModuleMoveResult

    .EXAMPLE
        # Preview the callers and module paths it will update
        Move-PowerShellModule -ModulePath ./tools/Mayo -Destination ./modules/Mayo -WhatIf
        # Move it for real
        Move-PowerShellModule -ModulePath ./tools/Mayo -Destination ./modules/Mayo
        # Point at the .psd1 instead of the folder - same result
        Move-PowerShellModule -ModulePath ./tools/Mayo/Mayo.psd1 -Destination ./modules/Mayo
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType('Netscoot.PSModuleMoveResult')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [Netscoot.PathInputTransform()]
        [ValidateNotNullOrEmpty()]
        [string]$ModulePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Destination,
        [switch]$Force,
        [switch]$NoJournal
    )

    process {
    $src = Resolve-FullPath $ModulePath
    if ($src -match '\.psd1$') {
        $manifestName = Split-Path -Leaf $src
        $moduleDir    = Split-Path -Parent $src
    } else {
        $moduleDir = $src
        $manifest  = Get-ChildItem -LiteralPath $moduleDir -Filter '*.psd1' | Select-Object -First 1
        if (-not $manifest) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.IO.FileNotFoundException]::new("No .psd1 manifest found in $moduleDir"),
                    'ManifestNotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $moduleDir))
            return
        }
        $manifestName = $manifest.Name
    }

    # git mv semantics: an existing destination directory means "move the module folder into it";
    # otherwise Destination is the module's new folder path.
    $newDir = Resolve-MoveTarget -Source $moduleDir -Destination $Destination
    if (Test-Path -LiteralPath $newDir) {
        $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                [System.IO.IOException]::new("Destination already exists: $newDir"),
                'DestinationExists', [System.Management.Automation.ErrorCategory]::ResourceExists, $newDir))
        return
    }

    $newManifest = Join-Path $newDir $manifestName
    $repoRoot = Get-RepositoryRoot -StartPath $moduleDir
    $moduleName = [System.IO.Path]::GetFileNameWithoutExtension($manifestName)

    # Paths from elsewhere into the module (Import-Module by path, dot-sourcing a module file) and
    # paths from the module's own files to outside it both break when the folder moves. Manifest
    # entries are module-relative, so the .psd1 itself needs no change.
    $incoming = @()
    $outgoing = @()
    $dynamicRefs = @()
    foreach ($f in (Find-PowerShellFiles -Root $repoRoot)) {
        $scan = Get-PowerShellScriptReferences -File $f.FullName
        $fileInside = Test-PathUnder $f.FullName $moduleDir
        foreach ($ref in $scan.Paths) {
            $targetInside = (Test-PathEqual $ref.Target $moduleDir) -or (Test-PathUnder $ref.Target $moduleDir)
            if ($fileInside -and -not $targetInside) { $outgoing += $ref }
            elseif (-not $fileInside -and $targetInside) { $incoming += $ref }
        }
        if (-not $fileInside) { $dynamicRefs += @($scan.Dynamic | Where-Object { $_.Raw -match [regex]::Escape($moduleName) }) }
    }
    $inNewDir = {
        param($Path)
        $rel = $Path.Substring($moduleDir.Length).TrimStart('\', '/')
        if ($rel) { Join-Path $newDir $rel } else { $newDir }
    }

    Write-MovePlan -Cmdlet $PSCmdlet -Caption "Move-PowerShellModule $manifestName  $moduleDir -> $newDir" -Items ([ordered]@{
            'callers to update'                  = @($incoming | ForEach-Object { "$(Split-Path -Leaf $_.File): $($_.Raw)" })
            'module paths pointing outside to rebase' = @($outgoing | ForEach-Object { "$(Split-Path -Leaf $_.File): $($_.Raw)" })
        })
    foreach ($d in $dynamicRefs) {
        Write-Warning "Possible dynamic reference to module $moduleName in $($d.File): `"$($d.Raw)`" - could not resolve statically; verify by hand."
    }

    $performed = $false
    $skippedCount = 0

    if ($PSCmdlet.ShouldProcess("$moduleDir -> $newDir", 'Move PowerShell module and update the paths that reference it')) {
        $ctx = Resolve-MoveContext -Cmdlet $PSCmdlet -Force:$Force -TargetForError $moduleDir
        if (-not $ctx) { return }

        $pointAt = { param($Ref, $Target) [void]$Ref.PointAt($Target) }
        $followFile = { param($Ref, $NewFile) [void]$Ref.FollowFile($NewFile) }
        $items = @()
        foreach ($ref in $incoming) {
            $target = & $inNewDir $ref.Target
            $items += New-MoveItem -Description "caller $(Split-Path -Leaf $ref.File): $($ref.Raw) -> $($ref.RawPointingAt($target))" `
                -Reattach $pointAt -ReattachArgs @($ref, $target)
        }
        foreach ($ref in $outgoing) {
            $newFile = & $inNewDir $ref.File
            $items += New-MoveItem -Description "module file $(Split-Path -Leaf $ref.File): $($ref.Raw) -> $($ref.RawFollowing($newFile))" `
                -Reattach $followFile -ReattachArgs @($ref, $newFile)
        }

        $move = { param($UseGit, $Src, $Dst, $Repository) Move-PathTracked -UseGit $UseGit -Source $Src -Destination $Dst -RepositoryRoot $Repository }
        $backup = @($incoming | ForEach-Object { $_.File }) + @($outgoing | ForEach-Object { $_.File })
        $planResult = Invoke-MovePlan -Caption "Move module $manifestName" -Items $items -Move $move `
            -MoveArgs @($ctx.UseGit, $moduleDir, $newDir, $repoRoot) `
            -BackupPath $backup -Rollback $move -RollbackArgs @($ctx.UseGit, $newDir, $moduleDir, $repoRoot) `
            -RepositoryRoot $repoRoot -Command 'Move-PowerShellModule' -Engine 'powershell' -Source $moduleDir -Destination $newDir `
            -UndoParams @{ ModulePath = $newDir; Destination = $moduleDir; Force = [bool]$Force } -NoJournal:$NoJournal
        $performed = $true
        $skippedCount = $planResult.Skipped

        if (-not (Test-ModuleManifest -Path $newManifest -ErrorAction SilentlyContinue)) {
            Write-Warning "Test-ModuleManifest reported problems for $newManifest"
        }
    }

    New-MoveResult -TypeName 'Netscoot.PSModuleMoveResult' -Engine 'powershell' -Source $moduleDir -Destination $newDir `
        -Performed $performed -SkippedCount $skippedCount -Extra ([ordered]@{ Manifest = $manifestName })
    }
}
