function Move-PowerShellModule {
    <#
    .SYNOPSIS
        Move a PowerShell module folder and reconcile its manifest, delegating manifest
        edits to Update-ModuleManifest rather than hand-editing the .psd1.

    .DESCRIPTION
        Moves a module directory (git mv when tracked), then rewrites RootModule,
        NestedModules and FileList in the .psd1 via Update-ModuleManifest so relative
        references stay valid. Validates the result with Test-ModuleManifest.

        Limits (warned, not fixed): dot-sourced relative paths inside .psm1/.ps1 files,
        and any path computed at runtime, cannot be reconciled automatically.

    .PARAMETER ModulePath
        Path to the module folder, or directly to its .psd1 manifest.

    .PARAMETER Destination
        Where to move the module folder, following `git mv` rules: an existing directory means move
        into it (keeping the name); otherwise it is the module's new folder path. Errors if it exists.

    .PARAMETER Force
        Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.

    .PARAMETER NoJournal
        Skip recording this move in the undo journal for this call, even when journaling is enabled
        (Undo-Netscoot will not see this move).

    .OUTPUTS
        Netscoot.PSModuleMoveResult

    .EXAMPLE
        # Preview; reconciles RootModule/NestedModules/FileList via Update-ModuleManifest
        Move-PowerShellModule -ModulePath ./tools/Mayo -Destination ./modules/Mayo -WhatIf
        # Move it for real
        Move-PowerShellModule -ModulePath ./tools/Mayo -Destination ./modules/Mayo
        # Point at the .psd1 instead of the folder - same result
        Move-PowerShellModule -ModulePath ./tools/Mayo/Mayo.psd1 -Destination ./modules/Mayo
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType('Netscoot.PSModuleMoveResult')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName', 'Path', 'PSPath')]
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
        if (-not $manifest) { throw "No .psd1 manifest found in $moduleDir" }
        $manifestName = $manifest.Name
    }

    # git mv semantics: an existing destination directory means "move the module folder into it";
    # otherwise Destination is the module's new folder path.
    $newDir = Resolve-MoveTarget -Source $moduleDir -Destination $Destination
    if (Test-Path -LiteralPath $newDir) { throw "Destination already exists: $newDir" }

    Write-Verbose "Plan: move module $manifestName  $moduleDir -> $newDir"
    $newManifest = Join-Path $newDir $manifestName

    $performed = $false
    $skippedCount = 0

    if ($PSCmdlet.ShouldProcess("$moduleDir -> $newDir", 'Move PowerShell module and reconcile manifest')) {
        $ctx = Resolve-MoveContext -Cmdlet $PSCmdlet -Force:$Force -TargetForError $moduleDir
        if (-not $ctx) { return }

        # The manifest refresh + validate happens after the move (reads the new layout).
        $manifestFix = {
            param($NewDir, $NewManifest)
            $files = Get-ChildItem -LiteralPath $NewDir -Recurse -File |
                ForEach-Object { $_.FullName.Substring($NewDir.Length).TrimStart('\', '/') }
            try { Update-ModuleManifest -Path $NewManifest -FileList $files; Write-Verbose "Manifest FileList refreshed ($($files.Count) files)." }
            catch { Write-Warning "Update-ModuleManifest failed: $_" }
            $r = Test-ModuleManifest -Path $NewManifest -ErrorAction SilentlyContinue
            if ($r) { Write-Verbose "Test-ModuleManifest OK: $($r.Name) $($r.Version)" }
            else { Write-Warning "Test-ModuleManifest reported problems for $NewManifest" }
        }
        $items = @( New-MoveItem -Description "refresh manifest $manifestName (FileList + validate)" -Reattach $manifestFix -ReattachArgs @($newDir, $newManifest) )

        $move = { param($UseGit, $Src, $Dst, $Repository) Move-PathTracked -UseGit $UseGit -Source $Src -Destination $Dst -RepoRoot $Repository }
        $repoRoot = Get-RepoRoot -StartPath $moduleDir
        $planResult = Invoke-MovePlan -Caption "Move module $manifestName" -Items $items -Move $move `
            -MoveArgs @($ctx.UseGit, $moduleDir, $newDir, $repoRoot)
        $performed = $true
        $skippedCount = $planResult.Skipped
        Register-MoveUndo -RepoRoot $repoRoot -Command 'Move-PowerShellModule' -Engine 'powershell' `
            -Source $moduleDir -Destination $newDir `
            -UndoParams @{ ModulePath = $newDir; Destination = $moduleDir; Force = [bool]$Force } -NoJournal:$NoJournal

        Write-Warning "Reminder: dot-sourced relative paths inside .psm1/.ps1 are not auto-fixed. Grep the module for '. \$PSScriptRoot' style references if depth changed."
    }

    New-MoveResult -TypeName 'Netscoot.PSModuleMoveResult' -Engine 'powershell' -Source $moduleDir -Destination $newDir `
        -Performed $performed -SkippedCount $skippedCount -Extra @{ Manifest = $manifestName }
    }
}
