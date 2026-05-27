function Find-Solutions {
    # All .sln and .slnx files beneath a root.
    # Filter by extension via Where-Object, not Get-ChildItem -Include: on Windows
    # PowerShell 5.1, -Include is ignored when combined with -LiteralPath (returns
    # every file). Where-Object behaves identically on both editions.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    $nested = Get-NestedWorktreePath -Root $Root   # linked worktrees hold duplicate copies
    Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.sln', '.slnx' -and $_.FullName -notmatch '[\\/](bin|obj|\.vs|\.git)[\\/]' -and -not (Test-PathUnderAny -Path $_.FullName -Dirs $nested) }
}

function Get-SolutionsReferencing {
    # Solutions (from $Candidates) whose project list includes $ProjectFile.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectFile,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidates
    )
    $target = Resolve-FullPath $ProjectFile
    $hits = @()
    foreach ($sln in $Candidates) {
        $slnDir = Split-Path -Parent $sln.FullName
        $listed = Invoke-DotnetRead sln $sln.FullName list
        if ($LASTEXITCODE -ne 0) { continue }
        foreach ($line in $listed) {
            $line = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($line) -or $line -notmatch '\.(cs|fs|vb|vcx)proj$') { continue }
            $abs = [System.IO.Path]::GetFullPath((Join-Path $slnDir $line))
            if (Test-PathEqual $abs $target) { $hits += $sln; break }
        }
    }
    return $hits
}

function Get-SolutionProjectEntries {
    # The project entries stored in a solution, as the exact string written in the file plus
    # its resolved absolute path. Used to rebase a solution's relative paths when it moves.
    # Skips solution folders (their second field is a name, not a project path).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SolutionFile)
    $full = Resolve-FullPath $SolutionFile
    $dir = Split-Path -Parent $full
    $entries = @()
    if ([System.IO.Path]::GetExtension($full) -ieq '.slnx') {
        $xml = Read-ProjectXml -Path $full
        foreach ($n in $xml.SelectNodes('//*[local-name()="Project"]')) {
            $p = $n.GetAttribute('Path')
            if ([string]::IsNullOrWhiteSpace($p) -or $p -notmatch '\.(cs|fs|vb|vcx)proj$') { continue }
            $abs = [System.IO.Path]::GetFullPath((Join-Path $dir ($p -replace '/', '\')))
            $entries += [pscustomobject]@{ Stored = $p; Abs = $abs }
        }
    } else {
        foreach ($line in (Get-Content -LiteralPath $full)) {
            if ($line -match '^\s*Project\("\{[^}]+\}"\)\s*=\s*"[^"]*",\s*"([^"]+)",\s*"\{[^}]+\}"') {
                $p = $Matches[1]
                if ($p -notmatch '\.(cs|fs|vb|vcx)proj$') { continue }
                $abs = [System.IO.Path]::GetFullPath((Join-Path $dir $p))
                $entries += [pscustomobject]@{ Stored = $p; Abs = $abs }
            }
        }
    }
    return $entries
}

function Get-SolutionContent {
    # Full contents of one solution (both .sln and .slnx): every project entry (any type, incl.
    # .pssproj/.vcxproj that `dotnet sln list` may omit), solution folders, and solution items
    # (loose files). Solution folders are reported separately, never as projects.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SolutionFile)
    $full = Resolve-FullPath $SolutionFile
    $dir = Split-Path -Parent $full
    $projects = @(); $folders = @(); $items = @()
    if ([System.IO.Path]::GetExtension($full) -ieq '.slnx') {
        $xml = Read-ProjectXml -Path $full
        foreach ($n in $xml.SelectNodes('//*[local-name()="Project"]')) {
            $p = $n.GetAttribute('Path')
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            $abs = [System.IO.Path]::GetFullPath((Join-Path $dir ($p -replace '/', '\')))
            $projects += [pscustomobject]@{ Stored = $p; Abs = $abs; Ext = [System.IO.Path]::GetExtension($p) }
        }
        foreach ($n in $xml.SelectNodes('//*[local-name()="Folder"]')) {
            $name = $n.GetAttribute('Name'); if ($name) { $folders += $name }
        }
        foreach ($n in $xml.SelectNodes('//*[local-name()="File"]')) {
            $p = $n.GetAttribute('Path'); if ($p) { $items += $p }
        }
    } else {
        $folderTypeGuid = '2150E333-8FDC-42A3-9474-1A3956D46DE8'   # solution-folder project type
        $inItems = $false
        foreach ($line in (Get-Content -LiteralPath $full)) {
            if ($line -match '^\s*Project\("\{([^}]+)\}"\)\s*=\s*"([^"]*)",\s*"([^"]+)",\s*"\{[^}]+\}"') {
                $typeGuid = $Matches[1]; $name = $Matches[2]; $p = $Matches[3]
                if ($typeGuid -ieq $folderTypeGuid) { $folders += $name; continue }
                $abs = [System.IO.Path]::GetFullPath((Join-Path $dir $p))
                $projects += [pscustomobject]@{ Stored = $p; Abs = $abs; Ext = [System.IO.Path]::GetExtension($p) }
            } elseif ($line -match '^\s*ProjectSection\(SolutionItems\)') {
                $inItems = $true
            } elseif ($line -match '^\s*EndProjectSection') {
                $inItems = $false
            } elseif ($inItems -and $line -match '^\s*(.+?)\s*=\s*(.+?)\s*$') {
                $items += $Matches[1].Trim()
            }
        }
    }
    return [pscustomobject]@{ Projects = $projects; Folders = $folders; Items = $items }
}

function Get-SolutionMembership {
    # For each solution, the absolute paths of every project it lists.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Solutions)
    $result = @()
    foreach ($sln in $Solutions) {
        $slnDir = Split-Path -Parent $sln.FullName
        $projects = @()
        $listed = Invoke-DotnetRead sln $sln.FullName list
        if ($LASTEXITCODE -eq 0) {
            foreach ($line in $listed) {
                $line = $line.Trim()
                if ([string]::IsNullOrWhiteSpace($line) -or $line -notmatch '\.(cs|fs|vb|vcx)proj$') { continue }
                $projects += [System.IO.Path]::GetFullPath((Join-Path $slnDir $line))
            }
        }
        $result += [pscustomobject]@{ Solution = $sln.FullName; Projects = $projects }
    }
    return $result
}
