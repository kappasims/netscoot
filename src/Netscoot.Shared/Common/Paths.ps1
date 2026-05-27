function Resolve-SymlinkPath {
    # Resolve symlinked ancestors of an absolute path, segment by segment, over the portion that
    # exists; any not-yet-existing tail (e.g. a move destination) is appended unchanged. This makes
    # our paths match the canonical form git and the dotnet CLI use - on macOS the temp/repository root
    # /var/folders/... is a symlink to /private/var/folders/..., and without this our /var-form
    # paths diverge from dotnet sln / git bookkeeping, breaking reconciliation on a repository under a
    # symlinked directory.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Full)
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $cur = "$sep"
    foreach ($part in ($Full.Split($sep))) {
        if ([string]::IsNullOrEmpty($part)) { continue }
        $cand = [System.IO.Path]::Combine($cur, $part)
        if (Test-Path -LiteralPath $cand) {
            $item = Get-Item -LiteralPath $cand -Force
            $link = $null
            try { $link = $item.ResolveLinkTarget($true) } catch { $link = $null }
            $cur = if ($link) { $link.FullName } else { $item.FullName }
        } else {
            $cur = $cand   # nothing below here exists yet; keep as typed
        }
    }
    return $cur
}

function Resolve-FullPath {
    # Absolute, normalized path. Does not require the path to exist and emits no errors. On Unix it
    # also resolves symlinked ancestors so the result is canonical (matching git/dotnet); Windows
    # GetFullPath is sufficient (no /var-style ancestor symlinks).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $full = if ([System.IO.Path]::IsPathRooted($Path)) {
        [System.IO.Path]::GetFullPath($Path)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
    }
    if (Test-IsWindowsHost) { return $full }
    return (Resolve-SymlinkPath -Full $full)
}

function Test-PathEqual {
    # OS-aware path equality (see Platform.ps1 for $script:PathComparison).
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$A,
          [Parameter(Mandatory)][AllowEmptyString()][string]$B)
    return [string]::Equals($A.TrimEnd('\', '/'), $B.TrimEnd('\', '/'), $script:PathComparison)
}

function Test-PathInList {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,
          [string[]]$List)
    foreach ($item in $List) { if (Test-PathEqual $Path $item) { return $true } }
    return $false
}

function Get-RelativePathSafe {
    # Relative path from directory $From to file/dir $To, returned with the platform separator
    # (MSBuild accepts both). On PowerShell 7 we use [IO.Path]::GetRelativePath, which is correct
    # on Windows and Unix. Windows PowerShell 5.1 (.NET Framework 4.x) lacks GetRelativePath, so
    # there we fall back to Uri.MakeRelativeUri - which only works for Windows drive-letter paths,
    # but 5.1 is Windows-only so that is fine.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$From,
          [Parameter(Mandatory)][string]$To)
    $fromFull = (Resolve-FullPath $From).TrimEnd('\', '/')
    $toFull = Resolve-FullPath $To
    if ($PSVersionTable.PSEdition -eq 'Core') {
        return [System.IO.Path]::GetRelativePath($fromFull, $toFull)
    }
    $fromUri = [Uri]($fromFull + [System.IO.Path]::DirectorySeparatorChar)
    $toUri = [Uri]$toFull
    $rel = [Uri]::UnescapeDataString($fromUri.MakeRelativeUri($toUri).ToString())
    return ($rel -replace '/', '\')
}

function Test-PathUnderAny {
    # True if $Path is strictly inside any directory in $Dirs. OS-aware.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,
          [AllowEmptyCollection()][string[]]$Dirs = @())
    foreach ($d in $Dirs) { if (Test-PathUnder -Path $Path -Dir $d) { return $true } }
    return $false
}

function Get-PathSuffixScore {
    # Count of matching trailing path segments between two paths (OS-aware, separator-agnostic).
    # E.g. 'src/Widgets/Widgets.csproj' vs 'tools/Widgets/Widgets.csproj' -> 2 (Widgets, Widgets.csproj).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$A,
          [Parameter(Mandatory)][string]$B)
    $sa = ($A -replace '/', '\').TrimEnd('\').Split('\')
    $sb = ($B -replace '/', '\').TrimEnd('\').Split('\')
    $i = $sa.Length - 1
    $j = $sb.Length - 1
    $n = 0
    while ($i -ge 0 -and $j -ge 0 -and [string]::Equals($sa[$i], $sb[$j], $script:PathComparison)) {
        $n++; $i--; $j--
    }
    return $n
}

function Select-BestSuffixMatch {
    # Given the original (now-broken) path and a set of candidate paths that share its leaf name,
    # return the single candidate sharing the most trailing path segments - but only when that
    # maximum is unique. Returns $null on a tie, which the caller treats as genuinely ambiguous.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Original,
          [Parameter(Mandatory)][string[]]$Candidates)
    $scored = foreach ($c in $Candidates) {
        [pscustomobject]@{ Path = $c; Score = (Get-PathSuffixScore -A $Original -B $c) }
    }
    $max = ($scored | Measure-Object -Property Score -Maximum).Maximum
    $top = @($scored | Where-Object { $_.Score -eq $max })
    if ($top.Count -eq 1) { return $top[0].Path }
    return $null
}

function Test-PathOverlap {
    # True if two directory paths overlap: identical, or one nested inside the other. Used to
    # refuse a move whose destination sits inside the source (or vice versa) - that move cannot
    # complete and would otherwise leave a half-reconciled repository behind.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$A,
          [Parameter(Mandatory)][string]$B)
    return (Test-PathEqual $A $B) -or (Test-PathUnder -Path $A -Dir $B) -or (Test-PathUnder -Path $B -Dir $A)
}

function Test-PathUnder {
    # True if $Path is strictly inside directory $Dir (not equal to it). OS-aware compare.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,
          [Parameter(Mandatory)][string]$Dir)
    $p = (Resolve-FullPath $Path).TrimEnd('\', '/')
    $d = (Resolve-FullPath $Dir).TrimEnd('\', '/')
    if (Test-PathEqual $p $d) { return $false }
    # Normalize separators so the prefix test is separator-agnostic.
    $pn = ($p -replace '/', '\') + '\'
    $dn = ($d -replace '/', '\') + '\'
    return $pn.StartsWith($dn, $script:PathComparison)
}

function Resolve-MoveTarget {
    # Resolve a move's final target path the way `git mv` does, so every mover behaves the same:
    #   - Destination is an existing directory -> move INTO it, keeping the source's leaf name
    #     (git mv src/Tarragon libs  ->  libs/Tarragon).
    #   - otherwise -> Destination IS the new path (a rename: git mv src/Tarragon libs/Tarragon).
    # Returns the absolute final path. Does not check for conflicts - the caller errors if the
    # returned path already exists (mirroring git mv, which refuses without -f).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Source,
          [Parameter(Mandatory)][string]$Destination)
    # Normalize away a trailing slash: GetFullPath keeps it, and it would otherwise leak into the
    # rename target (and make `git mv src dest/` error where `git mv src dest` renames). A trailing
    # slash is treated as a no-op here, so './libs' and './libs/' behave identically.
    $dest = [System.IO.Path]::GetFullPath($Destination)
    $trimmed = $dest.TrimEnd([char]'\', [char]'/')
    if ($trimmed) { $dest = $trimmed }
    if (Test-Path -LiteralPath $dest -PathType Container) {
        return (Join-Path $dest (Split-Path -Leaf $Source))
    }
    return $dest
}
