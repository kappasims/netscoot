function Find-NetscootPathReference {
    <#
    .SYNOPSIS
        Find references to a path in non-canonical, path-hardcoding files (build/CI/hook/
        container scripts) that no first-party tool reconciles. Report-only.

    .DESCRIPTION
        Moving a project/folder breaks any path hardcoded in build.ps1, CI YAML, git hooks,
        tools scripts, Makefile/Dockerfile, etc. - and unlike .sln/.csproj/.psd1 there is no
        tool that understands their schema, so they cannot be safely auto-rewritten (a blind
        regex could corrupt logic). This detects the class of such files (by location + name,
        not a hardcoded filename list) and reports lines that reference the given path, so you
        (or an agent) can fix them deliberately. It never edits anything.

        Two confidence tiers: High when the item's repository-relative path appears (e.g.
        'lib/Tarragon.csproj' or 'lib\Tarragon.csproj'), Low when only the bare leaf name appears (e.g.
        'Tarragon.csproj'), which is likely but not certain.

        By default it scans only the class of non-canonical, path-hardcoding files (the ones no
        first-party tool reconciles), which keeps the result focused and avoids flagging the
        project's own source. Pass -AllFiles to instead search EVERY text file under the repository
        (caches, vendored dirs, and binary files excluded) - the "look literally everywhere" mode for
        when a reference may live in an ordinary source file the default classifier skips (e.g. a
        build script in a non-standard directory). Both modes are report-only and never edit.

        Run it before a move (to see what will break) or after (searching the old path).

    .PARAMETER Path
        The path whose references to find (typically a recently moved item). Accepts pipeline input:
        a path string, or a file/directory item from Get-Item / Get-ChildItem.

    .PARAMETER RepositoryRoot
        Root to scan. Defaults to the enclosing git repository root.

    .PARAMETER AdditionalGlob
        Extra repository-relative globs to include in the candidate set (e.g. 'deploy/*.sh').

    .PARAMETER AllFiles
        Search every text file under the repository instead of only the build/CI/hook/container file
        class. Caches/vendored dirs (.git, bin, obj, node_modules, ...) and binary file kinds are
        still excluded. Broader and noisier, but catches references in ordinary source files the
        default scan deliberately skips.

    .OUTPUTS
        Netscoot.PathReference - one per matching line.

    .EXAMPLE
        # Build/CI/hook lines that hardcode the path (report-only)
        Find-NetscootPathReference -Path ./lib/Tarragon.csproj
        # Scan the old path after a move to find what still points at it
        Find-NetscootPathReference -Path ./libs/Tarragon/Tarragon.csproj
        # Widen the candidate set with extra repository-relative globs
        Find-NetscootPathReference -Path ./lib/Tarragon.csproj -AdditionalGlob 'deploy/*.sh','*.psake.ps1'
        # Search EVERY text file (not just build/CI/hook files) for the reference
        Find-NetscootPathReference -Path ./lib/Tarragon.csproj -AllFiles
    #>
    [CmdletBinding()]
    [OutputType('Netscoot.PathReference')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [Netscoot.PathInputTransform()]
        [ValidateNotNullOrEmpty()]
        [string]$Path,
        [string]$RepositoryRoot,
        [string[]]$AdditionalGlob = @(),
        [switch]$AllFiles
    )

    begin {
        if ($MyInvocation.InvocationName -eq 'Find-PathReference') {
            Write-Warning "'Find-PathReference' is a deprecated alias for 'Find-NetscootPathReference' and will be removed in a future release. Update to 'Find-NetscootPathReference'."
        }
    }

    process {
        $target = Resolve-FullPath $Path
        if (-not $RepositoryRoot) {
            # Derive the repository root from the CURRENT directory, never from -Path. The canonical
            # use is sweeping the OLD identifier after a rename, where the needle no longer exists on
            # disk - so walking up from it would fail (Get-RepositoryRoot does Get-Item on the start
            # path). -Path is a string to search for, not a filesystem location. This matches every
            # other cmdlet's default (e.g. Test-NetscootSolutionConsistency, Repair-NetscootSolutionReferences).
            $RepositoryRoot = Get-RepositoryRoot -StartPath (Get-Location).Path
        }
        $root = (Resolve-FullPath $RepositoryRoot).TrimEnd('\', '/')

        $rel = ($target.Substring($root.Length).TrimStart('\', '/'))
        $relFwd = $rel.Replace('\', '/')
        $relBack = $rel.Replace('/', '\')
        $leaf = Split-Path -Leaf $target
        # The High check is a case-insensitive substring test (IndexOf, no regex). The Low check needs
        # word-boundary lookarounds, so build that regex once here (case-insensitive, as -match was)
        # rather than per line.
        $ci = [System.StringComparison]::OrdinalIgnoreCase
        $leafRegex = [regex]::new('(?<![\w.])' + [regex]::Escape($leaf) + '(?![\w])', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

        $hits = 0
        foreach ($file in (Get-PathBearingFile -RepositoryRoot $root -AdditionalGlob $AdditionalGlob -AllFiles:$AllFiles)) {
            $n = 0
            foreach ($line in (Get-Content -LiteralPath $file.FullName -ErrorAction SilentlyContinue)) {
                $n++
                $confidence = $null
                if ($line.IndexOf($relFwd, $ci) -ge 0 -or ($relBack -ne $relFwd -and $line.IndexOf($relBack, $ci) -ge 0)) {
                    $confidence = 'High'
                } elseif ($leafRegex.IsMatch($line)) {
                    $confidence = 'Low'
                }
                if ($confidence) {
                    $hits++
                    [Netscoot.PathReference]@{
                        File       = $file.FullName
                        Line       = $n
                        Confidence = $confidence
                        Text       = $line.Trim()
                    }
                }
            }
        }

        if ($hits -gt 0) {
            $scope = if ($AllFiles) { 'files across the repository' } else { 'non-canonical files (build/CI/hooks/etc.)' }
            Write-Warning "$hits reference(s) to '$leaf' found in $scope. These are not auto-reconciled - review and fix them by hand."
        }
    }
}

Set-Alias -Name Find-PathReference -Value Find-NetscootPathReference
