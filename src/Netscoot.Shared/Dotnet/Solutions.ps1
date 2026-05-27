# Hoisted once: these run per line of every .sln (and per project entry) during inventory,
# consistency, and membership scans, so they are built here rather than per call.
$script:SlnProjectEntryRegex = [regex]'^\s*Project\("\{[^}]+\}"\)\s*=\s*"[^"]*",\s*"([^"]+)",\s*"\{[^}]+\}"'
$script:SlnProjectFullRegex = [regex]'^\s*Project\("\{([^}]+)\}"\)\s*=\s*"([^"]*)",\s*"([^"]+)",\s*"\{([^}]+)\}"'
$script:ProjectFileExtRegex = [regex]'\.(cs|fs|vb|vcx)proj$'

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

function Read-Solution {
    # Parse one solution file (.sln or .slnx) exactly once into a Netscoot.Solution domain object
    # that carries everything the readers need, so inventory, consistency, membership, and rebase
    # all derive from a single read instead of re-parsing the file (or shelling `dotnet sln list`)
    # per call.
    #
    # The object's shape (pscustomobject, PSTypeName='Netscoot.Solution'):
    #   Path     - absolute path to the solution file
    #   Format   - 'sln' or 'slnx'
    #   Projects - every project entry (any type, incl. .pssproj/.vcxproj that `dotnet sln list`
    #              may omit). Each: @{ Stored; Abs; Ext; TypeGuid }
    #              (TypeGuid is $null for .slnx, which records no project-type GUIDs).
    #   Folders  - solution-folder names (never reported as projects)
    #   Items    - solution items (loose files)
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SolutionFile)
    $full = Resolve-FullPath $SolutionFile
    $dir = Split-Path -Parent $full
    $projects = @(); $folders = @(); $items = @()
    if ([System.IO.Path]::GetExtension($full) -ieq '.slnx') {
        $format = 'slnx'
        $xml = Read-ProjectXml -Path $full
        foreach ($n in $xml.SelectNodes('//*[local-name()="Project"]')) {
            $p = $n.GetAttribute('Path')
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            $abs = [System.IO.Path]::GetFullPath((Join-Path $dir ($p.Replace('/', '\'))))
            $projects += [pscustomobject]@{ Stored = $p; Abs = $abs; Ext = [System.IO.Path]::GetExtension($p); TypeGuid = $null }
        }
        foreach ($n in $xml.SelectNodes('//*[local-name()="Folder"]')) {
            $name = $n.GetAttribute('Name'); if ($name) { $folders += $name }
        }
        foreach ($n in $xml.SelectNodes('//*[local-name()="File"]')) {
            $p = $n.GetAttribute('Path'); if ($p) { $items += $p }
        }
    } else {
        $format = 'sln'
        $folderTypeGuid = '2150E333-8FDC-42A3-9474-1A3956D46DE8'   # solution-folder project type
        $inItems = $false
        foreach ($line in (Get-Content -LiteralPath $full)) {
            $m = $script:SlnProjectFullRegex.Match($line)
            if ($m.Success) {
                $typeGuid = $m.Groups[1].Value; $name = $m.Groups[2].Value; $p = $m.Groups[3].Value
                if ($typeGuid -ieq $folderTypeGuid) { $folders += $name; continue }
                $abs = [System.IO.Path]::GetFullPath((Join-Path $dir $p))
                $projects += [pscustomobject]@{ Stored = $p; Abs = $abs; Ext = [System.IO.Path]::GetExtension($p); TypeGuid = $typeGuid }
            } elseif ($line -match '^\s*ProjectSection\(SolutionItems\)') {
                $inItems = $true
            } elseif ($line -match '^\s*EndProjectSection') {
                $inItems = $false
            } elseif ($inItems -and $line -match '^\s*(.+?)\s*=\s*(.+?)\s*$') {
                $items += $Matches[1].Trim()
            }
        }
    }
    return [pscustomobject]@{
        PSTypeName = 'Netscoot.Solution'
        Path       = $full
        Format     = $format
        Projects   = $projects
        Folders    = $folders
        Items      = $items
    }
}

function Get-SolutionProjectEntries {
    # The project entries stored in a solution, as the exact string written in the file plus
    # its resolved absolute path. Used to rebase a solution's relative paths when it moves.
    # Skips solution folders (their second field is a name, not a project path).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SolutionFile)
    $sln = Read-Solution -SolutionFile $SolutionFile
    $entries = @()
    foreach ($p in $sln.Projects) {
        if (-not $script:ProjectFileExtRegex.IsMatch($p.Stored)) { continue }
        $entries += [pscustomobject]@{ Stored = $p.Stored; Abs = $p.Abs }
    }
    return $entries
}

function Get-SolutionContent {
    # Full contents of one solution (both .sln and .slnx): every project entry (any type, incl.
    # .pssproj/.vcxproj that `dotnet sln list` may omit), solution folders, and solution items
    # (loose files). Solution folders are reported separately, never as projects.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SolutionFile)
    $sln = Read-Solution -SolutionFile $SolutionFile
    $projects = @()
    foreach ($p in $sln.Projects) {
        $projects += [pscustomobject]@{ Stored = $p.Stored; Abs = $p.Abs; Ext = $p.Ext }
    }
    return [pscustomobject]@{ Projects = $projects; Folders = $sln.Folders; Items = $sln.Items }
}

function Get-SolutionMembership {
    # For each solution, the absolute paths of every CLI-buildable project it lists
    # (.cs/.fs/.vb/.vcxproj), derived from a single parse of each file.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Solutions)
    $result = @()
    foreach ($sln in $Solutions) {
        $parsed = Read-Solution -SolutionFile $sln.FullName
        $projects = @()
        foreach ($p in $parsed.Projects) {
            if ($script:ProjectFileExtRegex.IsMatch($p.Stored)) { $projects += $p.Abs }
        }
        $result += [pscustomobject]@{ Solution = $sln.FullName; Projects = $projects }
    }
    return $result
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
        $parsed = Read-Solution -SolutionFile $sln.FullName
        foreach ($p in $parsed.Projects) {
            if (-not $script:ProjectFileExtRegex.IsMatch($p.Stored)) { continue }
            if (Test-PathEqual $p.Abs $target) { $hits += $sln; break }
        }
    }
    return $hits
}
