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
        New folder for the project.

    .PARAMETER RepoRoot
        Root to scan for solutions. Defaults to the enclosing git repo root.

    .PARAMETER Force
        Proceed with a plain file move when git is unavailable instead of aborting. A plain
        move does not preserve git history.

    .OUTPUTS
        A single DotnetMove.NativeMoveResult object: Engine, Source, Destination (strings),
        Performed (bool), SkippedCount (int), HadFilters (bool), Solutions (string[], the solution
        names updated), and UnreconciledSettings (object[], one per native path setting that must
        be verified/fixed by hand - each with the setting name and value).

    .EXAMPLE
        Move-NativeProject -Project ./Aleppo/Aleppo.vcxproj -Destination ./native/Aleppo -WhatIf

        Previews the native move and reports the MSBuild path settings it cannot reconcile.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName', 'Path', 'PSPath')]
        [ValidateNotNullOrEmpty()]
        [string]$Project,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Destination,
        [string]$RepoRoot,
        [switch]$Force
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
        $newDir = [System.IO.Path]::GetFullPath($Destination)
        $newProj = Join-Path $newDir $projFile

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
            $move = { param($UseGit, $Src, $Dst, $Repo) Move-PathTracked -UseGit $UseGit -Source $Src -Destination $Dst -RepoRoot $Repo }

            $planResult = Invoke-MovePlan -Caption "Move native $projFile" -Items $items -Move $move `
                -MoveArgs @($ctx.UseGit, $oldDir, $newDir, $repoFull)
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

        New-MoveResult -TypeName 'DotnetMove.NativeMoveResult' -Engine 'native' -Source $projFull -Destination $newProj `
            -Performed $performed -SkippedCount $skippedCount -Extra @{
            Solutions            = $slnNames
            UnreconciledSettings = $nativeSettings
            HadFilters           = $hasFilters
        }
    }
}
