function Find-MSBuildFiles {
    # Project files + shared .props/.targets beneath a root (anything that can <Import>).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    $exts = @('.csproj', '.fsproj', '.vbproj', '.vcxproj', '.props', '.targets')
    Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in $exts -and $_.FullName -notmatch '[\\/](bin|obj|\.vs|\.git)[\\/]' }
}

function Get-ImportPaths {
    # <Import Project="X"> entries in an MSBuild file. Literal relative paths and the
    # $(MSBuildThisFileDirectory) token (= the file's own dir) resolve to Paths (Netscoot.StoredPath);
    # a path using any other $(...) token is returned in Unresolved by its raw text, to warn about.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectFile)
    $full = Resolve-FullPath $ProjectFile
    $dir = Split-Path -Parent $full
    $xml = Read-ProjectXml -Path $full
    $paths = @()
    $unresolved = @()
    foreach ($n in $xml.SelectNodes('//*[local-name()="Import"]')) {
        $proj = $n.GetAttribute('Project')
        if ([string]::IsNullOrWhiteSpace($proj)) { continue }
        $expanded = $proj -replace '\$\(MSBuildThisFileDirectory\)', ($dir + [System.IO.Path]::DirectorySeparatorChar)
        if ($expanded -match '\$\(') { $unresolved += $proj; continue }
        $abs = [System.IO.Path]::GetFullPath((Join-Path $dir $expanded))
        $paths += [Netscoot.StoredPath]::InAttribute($full, 'Project', $proj, $abs)
    }
    return [pscustomobject]@{ Paths = $paths; Unresolved = $unresolved }
}
