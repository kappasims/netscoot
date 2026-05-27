function Move-NativeProject {
    <#
    .SYNOPSIS
        Move a native / C++/CLI project (.vcxproj). Windows-only. Does the parts the
        dotnet CLI can delegate (solution membership, the move itself) and reports the
        native path-bearing settings it cannot reconcile so they are never silently broken.

    .DESCRIPTION
        Native projects link through MSBuild settings the dotnet CLI does not touch:
        AdditionalIncludeDirectories / AdditionalLibraryDirectories / AdditionalDependencies,
        <Import> of shared .props/.targets, $(SolutionDir)-relative OutDir, and the paired
        .vcxproj.filters. C++/CLI is Windows-only, so this cmdlet refuses to run elsewhere.

        It will: update .sln/.slnx membership via 'dotnet sln' (which understands .vcxproj),
        move the folder (git mv when tracked), move the paired .vcxproj.filters alongside,
        and then emit a report of every relative/SolutionDir-relative native setting that a
        human (or a future native engine) must verify. It deliberately does not rewrite those
        MSBuild paths yet - surfacing them beats silently mis-editing them.

    .PARAMETER Project
        Path to the .vcxproj. Accepts pipeline input.

    .PARAMETER Destination
        Where to move the project folder, following `git mv` rules: an existing directory means
        move into it (keeping the name); otherwise it is the new folder path. Errors if it exists.

    .PARAMETER RepoRoot
        Root to scan for solutions. Defaults to the enclosing git repository root.

    .PARAMETER Force
        Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.

    .PARAMETER NoJournal
        Skip recording this move in the undo journal for this call, even when journaling is enabled
        (Undo-Netscoot will not see this move).

    .OUTPUTS
        Netscoot.NativeMoveResult

    .EXAMPLE
        # Preview; reports the native path settings it cannot reconcile (verify by hand after)
        Move-NativeProject -Project ./Aleppo/Aleppo.vcxproj -Destination ./native/Aleppo -WhatIf
        # Move it (also moves the paired .vcxproj.filters)
        Move-NativeProject -Project ./Aleppo/Aleppo.vcxproj -Destination ./native/Aleppo
        # Move into an existing folder (lands at ./native/Aleppo)
        Move-NativeProject -Project ./Aleppo/Aleppo.vcxproj -Destination ./native
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType('Netscoot.NativeMoveResult')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName', 'Path', 'PSPath')]
        [ValidateNotNullOrEmpty()]
        [string]$Project,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Destination,
        [string]$RepoRoot,
        [switch]$Force,
        [switch]$NoJournal
    )

    process {
        if (-not (Test-IsWindowsHost)) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.PlatformNotSupportedException]::new("Native/C++ projects are Windows-only; Move-NativeProject cannot run on this OS."),
                    'WindowsOnly', [System.Management.Automation.ErrorCategory]::NotImplemented, $Project))
            return
        }
        if (-not (Assert-DotnetAvailable -Cmdlet $PSCmdlet)) { return }

        $projFull = Resolve-FullPath $Project
        if (-not (Test-Path -LiteralPath $projFull)) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.IO.FileNotFoundException]::new("Project not found: $Project"),
                    'ProjectNotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $Project))
            return
        }
        if ([System.IO.Path]::GetExtension($projFull).ToLowerInvariant() -eq '.vcproj') {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.NotSupportedException]::new("'$Project' is a legacy Visual C++ project (.vcproj, pre-VS2010), which predates MSBuild and is not supported. Convert it to .vcxproj (open it in Visual Studio 2010 or later), then retry."),
                    'LegacyVcprojNotSupported', [System.Management.Automation.ErrorCategory]::NotImplemented, $Project))
            return
        }
        if (-not (Test-IsNativeProject $projFull)) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new("Not a native project (.vcxproj): $Project. Use Move-DotnetProject for managed projects."),
                    'NotANativeProject', [System.Management.Automation.ErrorCategory]::InvalidArgument, $Project))
            return
        }

        $oldDir = Split-Path -Parent $projFull
        $projFile = Split-Path -Leaf $projFull
        if (-not $RepoRoot) { $RepoRoot = Get-RepoRoot -StartPath $oldDir }
        $repoFull = Resolve-FullPath $RepoRoot
        # git mv semantics: an existing destination directory means "move the project folder into
        # it"; otherwise Destination is the project's new folder path.
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

        $allSolutions = @(Find-Solutions -Root $repoFull)
        $solutions = @(Get-SolutionsReferencing -ProjectFile $projFull -Candidates $allSolutions)
        $nativeSettings = @(Get-NativePathSettings -ProjectFile $projFull)
        $filters = "$projFull.filters"
        $hasFilters = Test-Path -LiteralPath $filters

        $slnNames = @(); foreach ($s in $solutions) { $slnNames += $s.Name }
        Write-Verbose "Plan: $projFile  $oldDir -> $newDir"
        Write-Verbose "  solutions : $($solutions.Count) ($($slnNames -join ', '))"
        Write-Verbose "  .filters  : $hasFilters"
        Write-Verbose "  unreconciled native settings : $($nativeSettings.Count)"

        $performed = $false
        $skippedCount = 0

        if ($PSCmdlet.ShouldProcess("$projFile : $oldDir -> $newDir", 'Move native project (solution membership + folder; native paths reported only)')) {
            $ctx = Resolve-MoveContext -Cmdlet $PSCmdlet -Force:$Force -TargetForError $projFull
            if (-not $ctx) { return }

            $items = New-DotnetReferenceItems -Solutions $solutions -OldProj $projFull -NewProj $newProj
            $move = { param($UseGit, $Src, $Dst, $Repository) Move-PathTracked -UseGit $UseGit -Source $Src -Destination $Dst -RepoRoot $Repository }

            $planResult = Invoke-MovePlan -Caption "Move native $projFile" -Items $items -Move $move `
                -MoveArgs @($ctx.UseGit, $oldDir, $newDir, $repoFull)
            $performed = $true
            $skippedCount = $planResult.Skipped
            Register-MoveUndo -RepoRoot $repoFull -Command 'Move-NativeProject' -Engine 'native' `
                -Source $projFull -Destination $newProj `
                -UndoParams @{ Project = $newProj; Destination = $oldDir; Force = [bool]$Force } -NoJournal:$NoJournal
        }

        if ($nativeSettings.Count -gt 0) {
            Write-Warning "$($nativeSettings.Count) native path setting(s) in $projFile are not auto-reconciled - verify by hand or with a native engine:"
            foreach ($s in $nativeSettings) { Write-Warning "  [$($s.Kind)] $($s.Value)" }
        }
        if ($hasFilters) {
            Write-Warning "Paired .filters for $projFile moved with the folder; its entries are project-relative and usually survive, but confirm no parent-relative entries broke."
        }

        New-MoveResult -TypeName 'Netscoot.NativeMoveResult' -Engine 'native' -Source $projFull -Destination $newProj `
            -Performed $performed -SkippedCount $skippedCount -Extra @{
            Solutions            = $slnNames
            UnreconciledSettings = $nativeSettings
            HadFilters           = $hasFilters
        }
    }
}
