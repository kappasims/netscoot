function Move-NativeProject {
    <#
    .SYNOPSIS
        Move a native or C++/CLI project (.vcxproj), update the solutions and projects that
        reference it, and report the native path-bearing settings it does not rewrite so they
        are never silently broken. Windows-only.

    .DESCRIPTION
        Native projects link through MSBuild settings that a move can break:
        AdditionalIncludeDirectories / AdditionalLibraryDirectories / AdditionalDependencies,
        `<Import>` of shared .props/.targets, $(SolutionDir)-relative OutDir, and the paired
        .vcxproj.filters. C++/CLI is Windows-only, so this cmdlet refuses to run elsewhere.

        It will: move the folder (git mv when tracked) with its paired .vcxproj.filters; rewrite
        the project's path in each .sln/.slnx entry, in every ProjectReference to it (native or
        managed consumers) and in its own ProjectReferences, keeping GUIDs, platform mappings and
        solution folders as they are; and report every relative/SolutionDir-relative native
        setting, in the moved project or in another project pointing into its folder, for a
        human to verify. It does not rewrite those MSBuild settings. The dotnet CLI is not used:
        it cannot load a .vcxproj outside Visual Studio's MSBuild.

    .PARAMETER Project
        Path to the .vcxproj. Accepts pipeline input (a path string or a Get-ChildItem/Get-Item item; other object types are rejected).

    .PARAMETER Destination
        Where to move the project folder, following `git mv` rules: An existing directory means
        move into it (keeping the name); otherwise it is the new folder path.

    .PARAMETER RepositoryRoot
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
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [Netscoot.PathInputTransform()]
        [ValidateNotNullOrEmpty()]
        [string]$Project,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Destination,
        [string]$RepositoryRoot,
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
        if (-not $RepositoryRoot) { $RepositoryRoot = Get-RepositoryRoot -StartPath $oldDir }
        $repoFull = Resolve-FullPath $RepositoryRoot
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

        # One repository parse for this invocation; solutions-referencing reuses the embedded parse.
        $workspace = Get-Workspace -RepositoryRoot $repoFull
        $allSolutions = @(Get-WorkspaceSolutions -Workspace $workspace)
        $solutions = @(Get-SolutionsReferencing -ProjectFile $projFull -Candidates $allSolutions)
        $nativeSettings = @(Get-NativePathSettings -ProjectFile $projFull)
        $filters = "$projFull.filters"
        $hasFilters = Test-Path -LiteralPath $filters

        # The dotnet CLI cannot evaluate a .vcxproj outside Visual Studio's MSBuild and would drop the
        # entry's platform mapping and GUID, so every path is rewritten in place instead.
        $pointAt = { param($Ref, $Target) [void]$Ref.PointAt($Target) }
        $followFile = { param($Ref, $NewFile) [void]$Ref.FollowFile($NewFile) }
        $incoming = @()
        foreach ($s in $solutions) {
            $incoming += @(Get-SolutionProjectEntries -SolutionFile $s.FullName | Where-Object { Test-PathEqual $_.Target $projFull })
        }
        $consumers = @(Get-WorkspaceConsumingProjects -Workspace $workspace -ProjectFile $projFull)
        foreach ($c in $consumers) {
            foreach ($r in @(Get-WorkspaceProjectRefs -Workspace $workspace -ProjectFile $c | Where-Object { $_.IsLiteral -and (Test-PathEqual $_.FullPath $projFull) })) {
                $incoming += [Netscoot.StoredPath]::InAttribute($c, 'Include', $r.Raw, $projFull)
            }
        }
        $outgoing = @(Get-WorkspaceProjectRefs -Workspace $workspace -ProjectFile $projFull | Where-Object { $_.IsLiteral } |
            ForEach-Object { [Netscoot.StoredPath]::InAttribute($projFull, 'Include', $_.Raw, $_.FullPath) } |
            Where-Object { $_.RawFollowing($newProj) -ne $_.Raw })
        $items = @()
        foreach ($ref in $incoming) {
            $items += New-MoveItem -Description "$(Split-Path -Leaf $ref.File): $($ref.Raw) -> $($ref.RawPointingAt($newProj))" `
                -Reattach $pointAt -ReattachArgs @($ref, $newProj)
        }
        foreach ($ref in $outgoing) {
            $items += New-MoveItem -Description "own reference: $($ref.Raw) -> $($ref.RawFollowing($newProj))" `
                -Reattach $followFile -ReattachArgs @($ref, $newProj)
        }
        Write-UnreconcilableReferenceWarning -MovedProject $projFull -AllProjects @(Get-WorkspaceProjectFiles -Workspace $workspace -IncludeNative) `
            -LiteralConsumers $consumers -Workspace $workspace

        # Other projects' native settings that resolve into the moved folder break too; report them.
        $pointingIn = @()
        foreach ($other in @(Get-WorkspaceProjectFiles -Workspace $workspace -IncludeNative | Where-Object { $_.Extension -eq '.vcxproj' })) {
            if (Test-PathEqual $other.Abs $projFull) { continue }
            $otherDir = Split-Path -Parent $other.Abs
            foreach ($setting in @(Get-NativePathSettings -ProjectFile $other.Abs)) {
                foreach ($entry in ($setting.Value -split ';')) {
                    $candidate = $entry.Trim() -replace '^\$\((ProjectDir|MSBuildThisFileDirectory)\)', ''
                    if (-not $candidate -or $candidate -match '[$%]\(') { continue }
                    $abs = [System.IO.Path]::GetFullPath((Join-Path $otherDir $candidate.Replace('\', [System.IO.Path]::DirectorySeparatorChar)))
                    if ((Test-PathEqual $abs $oldDir) -or (Test-PathUnder $abs $oldDir)) {
                        $pointingIn += "$($other.Name): [$($setting.Kind)] $($entry.Trim())"
                    }
                }
            }
        }

        $slnNames = @(); foreach ($s in $solutions) { $slnNames += $s.Name }
        $settingLines = @($nativeSettings | ForEach-Object { "[$($_.Kind)] $($_.Value)" })
        Write-MovePlan -Cmdlet $PSCmdlet -Caption "Move-NativeProject $projFile  $oldDir -> $newDir" -Items ([ordered]@{
                'solutions to update'                          = $slnNames
                'consuming projects to update'                 = @($consumers | ForEach-Object { Split-Path -Leaf $_ })
                'paired .filters file moving'                  = $hasFilters
                'unreconciled native settings (manual review)' = $settingLines
                'other projects pointing into the folder'      = $pointingIn
            })

        $performed = $false
        $skippedCount = 0

        if ($PSCmdlet.ShouldProcess("$projFile : $oldDir -> $newDir", 'Move native project and update solution entries and project references (native paths reported only)')) {
            $ctx = Resolve-MoveContext -Cmdlet $PSCmdlet -Force:$Force -TargetForError $projFull
            if (-not $ctx) { return }

            $move = { param($UseGit, $Src, $Dst, $Repository) Move-PathTracked -UseGit $UseGit -Source $Src -Destination $Dst -RepositoryRoot $Repository }

            $backup = @($incoming | ForEach-Object { $_.File }) + @($projFull)
            $planResult = Invoke-MovePlan -Caption "Move native $projFile" -Items $items -Move $move `
                -MoveArgs @($ctx.UseGit, $oldDir, $newDir, $repoFull) `
                -BackupPath $backup -Rollback $move -RollbackArgs @($ctx.UseGit, $newDir, $oldDir, $repoFull) `
                -RepositoryRoot $repoFull -Command 'Move-NativeProject' -Engine 'native' -Source $projFull -Destination $newProj `
                -UndoParams @{ Project = $newProj; Destination = $oldDir; Force = [bool]$Force } -NoJournal:$NoJournal
            $performed = $true
            $skippedCount = $planResult.Skipped
        }

        if ($nativeSettings.Count -gt 0) {
            Write-Warning "$($nativeSettings.Count) native path setting(s) in $projFile are not auto-reconciled - verify by hand or with a native engine:"
            foreach ($s in $nativeSettings) { Write-Warning "  [$($s.Kind)] $($s.Value)" }
        }
        if ($hasFilters) {
            Write-Warning "Paired .filters for $projFile moved with the folder; its entries are project-relative and usually survive, but confirm no parent-relative entries broke."
        }
        foreach ($line in $pointingIn) {
            Write-Warning "Points into the moved folder, not auto-reconciled - verify by hand: $line"
        }

        New-MoveResult -TypeName 'Netscoot.NativeMoveResult' -Engine 'native' -Source $projFull -Destination $newProj `
            -Performed $performed -SkippedCount $skippedCount -Extra ([ordered]@{
                Solutions            = $slnNames
                UnreconciledSettings = $nativeSettings
                HadFilters           = $hasFilters
            })
    }
}
