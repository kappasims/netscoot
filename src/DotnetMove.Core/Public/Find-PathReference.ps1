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

        Two confidence tiers: High when the item's repo-relative path appears (e.g.
        'lib/Tarragon.csproj' or 'lib\Tarragon.csproj'), Low when only the bare leaf name appears (e.g.
        'Tarragon.csproj'), which is likely but not certain.

        Run it before a move (to see what will break) or after (searching the old path).

    .PARAMETER Path
        The item being/that was moved. Accepts pipeline input.

    .PARAMETER RepoRoot
        Root to scan. Defaults to the enclosing git repo root.

    .PARAMETER AdditionalGlob
        Extra repo-relative globs to include in the candidate set (e.g. 'deploy/*.sh').

    .OUTPUTS
        Emits zero or more pscustomobjects, one per matching line (a caller collects them as an
        array). Each has: File (string), Line (int), Confidence (string, High|Low), and Text
        (string). Returns nothing when no references are found.

    .EXAMPLE
        Find-PathReference -Path ./lib/Tarragon.csproj

        Lists the build/CI/hook lines that hardcode lib/Tarragon.csproj so you can fix them by hand.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName', 'PSPath')]
        [ValidateNotNullOrEmpty()]
        [string]$Path,
        [string]$RepoRoot,
        [string[]]$AdditionalGlob = @()
    )

    process {
        $target = Resolve-FullPath $Path
        if (-not $RepoRoot) {
            $start = if (Test-Path -LiteralPath $target -PathType Container) { $target } else { Split-Path -Parent $target }
            $RepoRoot = Get-RepoRoot -StartPath $start
        }
        $root = (Resolve-FullPath $RepoRoot).TrimEnd('\', '/')

        $rel = ($target.Substring($root.Length).TrimStart('\', '/'))
        $relFwd = $rel -replace '\\', '/'
        $relBack = $rel -replace '/', '\'
        $leaf = Split-Path -Leaf $target

        $hits = 0
        foreach ($file in (Get-PathBearingFile -RepoRoot $root -AdditionalGlob $AdditionalGlob)) {
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
                        PSTypeName = 'DotnetMove.PathReference'
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
