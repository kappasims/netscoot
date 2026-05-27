function Repair-SolutionReferences {
    <#
    .SYNOPSIS
        Scan a repository for broken solution membership and dangling ProjectReferences and repair them
        by re-pointing each entry at the project's new location.

    .DESCRIPTION
        Finds solution entries and <ProjectReference>s that point at a project file which no longer
        exists at the recorded path (usually because a project was moved or renamed without
        reconciling). Read-only by default: it returns one object per problem, each tagged with a
        Resolution of Relocatable, Missing, or Ambiguous.

        With -Fix it repairs every Relocatable entry: it searches the repository for a project file of the
        same name and re-points the entry at it through the dotnet CLI (remove the stale path, add
        the found one). When one project of that name exists it is used directly; when several do,
        the one that keeps the most of the original path's trailing folders is chosen, since a moved
        project usually keeps its own folder name. Entries it cannot resolve are left untouched and
        reported, Missing (no such project anywhere) or Ambiguous (several equally-good candidates).

        With -Prune it removes the Missing entries, the genuinely deleted ones, through the dotnet
        CLI. -Prune never touches Relocatable or Ambiguous entries. -Fix and -Prune can be combined.

    .PARAMETER RepoRoot
        Root to scan. Defaults to the enclosing git repository root of the current directory.

    .PARAMETER Fix
        Re-point each dangling entry at the moved project when its new location is unambiguous.
        Honors -WhatIf.

    .PARAMETER Prune
        Remove entries whose project cannot be found anywhere in the repository. Honors -WhatIf.

    .OUTPUTS
        Netscoot.RepairResult - one per dangling entry.

    .EXAMPLE
        # Report dangling entries only - read-only (each tagged Relocatable, Missing, or Ambiguous)
        Repair-SolutionReferences -RepoRoot .
        # Re-point relocatable entries at the project's new location (relocates; never deletes)
        Repair-SolutionReferences -RepoRoot . -Fix
        # Also remove entries whose project is gone for good - preview the whole thing first
        Repair-SolutionReferences -RepoRoot . -Fix -Prune -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Netscoot.RepairResult')]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName', 'Path', 'PSPath')]
        [string]$RepoRoot,
        [switch]$Fix,
        [switch]$Prune
    )

    process {
        if (-not (Assert-DotnetAvailable -Cmdlet $PSCmdlet)) { return }
        if (-not $RepoRoot) { $RepoRoot = Get-RepoRoot -StartPath (Get-Location).Path }
        $RepoRoot = Resolve-FullPath $RepoRoot

        # Index existing project files by leaf name, so a dangling target can be matched to where
        # its project now lives.
        $byLeaf = @{}
        foreach ($pf in (Find-ProjectFiles -Root $RepoRoot)) {
            if (-not $byLeaf.ContainsKey($pf.Name)) { $byLeaf[$pf.Name] = [System.Collections.Generic.List[string]]::new() }
            $byLeaf[$pf.Name].Add($pf.FullName)
        }

        # First pass: collect the dangling entries (a path recorded somewhere points at a project
        # file that no longer exists there).
        $dangling = [System.Collections.Generic.List[object]]::new()
        foreach ($sln in (Find-Solutions -Root $RepoRoot)) {
            $slnDir = Split-Path -Parent $sln.FullName
            $listed = Invoke-DotnetRead sln $sln.FullName list
            if ($LASTEXITCODE -ne 0) { continue }
            foreach ($line in $listed) {
                $line = $line.Trim()
                if ($line -notmatch '\.(cs|fs|vb|vcx)proj$') { continue }
                $abs = [System.IO.Path]::GetFullPath((Join-Path $slnDir $line))
                if (-not (Test-Path -LiteralPath $abs)) {
                    $dangling.Add([pscustomobject]@{ Kind = 'Solution'; Container = $sln.FullName; Missing = $line; MissingAbs = $abs })
                }
            }
        }
        foreach ($proj in (Find-ProjectFiles -Root $RepoRoot)) {
            foreach ($ref in (Get-ProjectReferencePaths -ProjectFile $proj.FullName)) {
                # Non-literal references (MSBuild property / glob / conditional) have no single
                # resolved path, so they cannot be "dangling" in a way we could repair - skip them.
                if (-not $ref.IsLiteral) { continue }
                if (-not (Test-Path -LiteralPath $ref.FullPath)) {
                    $dangling.Add([pscustomobject]@{ Kind = 'Reference'; Container = $proj.FullName; Missing = $ref.Raw; MissingAbs = $ref.FullPath })
                }
            }
        }

        # Second pass: classify each by where (if anywhere) its project now lives.
        $problems = [System.Collections.Generic.List[object]]::new()
        foreach ($d in $dangling) {
            $leaf = Split-Path -Leaf $d.MissingAbs
            $cands = @()
            if ($byLeaf.ContainsKey($leaf)) { $cands = @($byLeaf[$leaf]) }
            $n = $cands.Count
            if ($n -eq 0) {
                $resolution = 'Missing'; $newPath = $null
            } elseif ($n -eq 1) {
                $resolution = 'Relocatable'; $newPath = $cands[0]
            } else {
                # Several projects share this leaf name. Disambiguate by which candidate keeps the
                # most of the original path's trailing folders (a moved project usually keeps its
                # own folder name); only auto-resolve when that best match is unique.
                $best = Select-BestSuffixMatch -Original $d.MissingAbs -Candidates $cands
                if ($best) { $resolution = 'Relocatable'; $newPath = $best }
                else { $resolution = 'Ambiguous'; $newPath = $null }
            }
            $problems.Add([pscustomobject]@{
                    Kind       = $d.Kind
                    Resolution = $resolution
                    Missing    = $d.Missing
                    NewPath    = $newPath
                    Container  = $d.Container
                    MissingAbs = $d.MissingAbs
                    Candidates = $cands
                })
        }

        if ($problems.Count -eq 0) {
            Write-Host 'No dangling solution entries or project references found.' -ForegroundColor Green
            return
        }

        Write-Host "Found $($problems.Count) dangling entr$(if ($problems.Count -eq 1) { 'y' } else { 'ies' }):" -ForegroundColor Yellow
        ($problems | Format-Table Kind, Resolution, Missing, Container -AutoSize | Out-String) | Write-Host

        if (-not ($Fix -or $Prune)) {
            Write-Host 'Run with -Fix to re-point movable entries, or -Prune to remove ones whose project is gone.' -ForegroundColor Cyan
            return $problems
        }

        foreach ($p in $problems) {
            if ($Fix -and $p.Resolution -eq 'Relocatable') {
                if ($p.Kind -eq 'Solution') {
                    if ($PSCmdlet.ShouldProcess($p.Container, "re-point $($p.Missing) -> $($p.NewPath)")) {
                        Invoke-Dotnet sln $p.Container remove $p.MissingAbs
                        Invoke-Dotnet sln $p.Container add $p.NewPath
                    }
                } else {
                    if ($PSCmdlet.ShouldProcess($p.Container, "re-point reference $($p.Missing) -> $($p.NewPath)")) {
                        Invoke-Dotnet remove $p.Container reference $p.MissingAbs
                        Invoke-Dotnet add $p.Container reference $p.NewPath
                    }
                }
            } elseif ($Prune -and $p.Resolution -eq 'Missing') {
                if ($p.Kind -eq 'Solution') {
                    if ($PSCmdlet.ShouldProcess($p.Container, "remove gone entry $($p.Missing)")) { Invoke-Dotnet sln $p.Container remove $p.MissingAbs }
                } else {
                    if ($PSCmdlet.ShouldProcess($p.Container, "remove gone reference $($p.Missing)")) { Invoke-Dotnet remove $p.Container reference $p.MissingAbs }
                }
            } else {
                $why = switch ($p.Resolution) {
                    'Relocatable' { 'movable, run with -Fix' }
                    'Missing' { 'project not found, run with -Prune to remove' }
                    'Ambiguous' { 'more than one candidate, resolve by hand' }
                }
                Write-Host "  skipped [$($p.Kind)] $($p.Missing): $why" -ForegroundColor DarkYellow
            }
        }
        return $problems
    }
}
