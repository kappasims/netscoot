function Find-PathReference {
    <#
    .SYNOPSIS
        Find references to a path in non-canonical, path-hardcoding files (build/CI/hook/
        container scripts) that no first-party tool reconciles. report-only.

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

        Run it before a move (to see what will break) or after (searching the old path).

    .PARAMETER Path
        The item being/that was moved. Accepts pipeline input.

    .PARAMETER RepositoryRoot
        Root to scan. Defaults to the enclosing git repository root.

    .PARAMETER AdditionalGlob
        Extra repository-relative globs to include in the candidate set (e.g. 'deploy/*.sh').

    .OUTPUTS
        Netscoot.PathReference - one per matching line.

    .EXAMPLE
        # Build/CI/hook lines that hardcode the path (report-only)
        Find-PathReference -Path ./lib/Tarragon.csproj
        # Scan the old path after a move to find what still points at it
        Find-PathReference -Path ./libs/Tarragon/Tarragon.csproj
        # Widen the candidate set with extra repository-relative globs
        Find-PathReference -Path ./lib/Tarragon.csproj -AdditionalGlob 'deploy/*.sh','*.psake.ps1'
    #>
    [CmdletBinding()]
    [OutputType('Netscoot.PathReference')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName', 'PSPath')]
        [ValidateNotNullOrEmpty()]
        [string]$Path,
        [string]$RepositoryRoot,
        [string[]]$AdditionalGlob = @()
    )

    process {
        $target = Resolve-FullPath $Path
        if (-not $RepositoryRoot) {
            $start = if (Test-Path -LiteralPath $target -PathType Container) { $target } else { Split-Path -Parent $target }
            $RepositoryRoot = Get-RepositoryRoot -StartPath $start
        }
        $root = (Resolve-FullPath $RepositoryRoot).TrimEnd('\', '/')

        $rel = ($target.Substring($root.Length).TrimStart('\', '/'))
        $relFwd = $rel -replace '\\', '/'
        $relBack = $rel -replace '/', '\'
        $leaf = Split-Path -Leaf $target

        $hits = 0
        foreach ($file in (Get-PathBearingFile -RepositoryRoot $root -AdditionalGlob $AdditionalGlob)) {
            $n = 0
            foreach ($line in (Get-Content -LiteralPath $file.FullName -ErrorAction SilentlyContinue)) {
                $n++
                $confidence = $null
                if ($line -match [regex]::Escape($relFwd) -or ($relBack -ne $relFwd -and $line -match [regex]::Escape($relBack))) {
                    $confidence = 'High'
                } elseif ($line -match "(?<![\w.])$([regex]::Escape($leaf))(?![\w])") {
                    $confidence = 'Low'
                }
                if ($confidence) {
                    $hits++
                    [pscustomobject]@{
                        PSTypeName = 'Netscoot.PathReference'
                        File       = $file.FullName
                        Line       = $n
                        Confidence = $confidence
                        Text       = $line.Trim()
                    }
                }
            }
        }

        if ($hits -gt 0) {
            Write-Warning "$hits path-bearing reference(s) to '$leaf' found in non-canonical files (build/CI/hooks/etc.). These are not auto-reconciled - review and fix them by hand."
        }
    }
}
