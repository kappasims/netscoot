# Hoisted once: these run per line of every .sln (and per project entry) during inventory,
# consistency, and membership scans, so they are built here rather than per call.
$script:SlnProjectEntryRegex = [regex]'^\s*Project\("\{[^}]+\}"\)\s*=\s*"[^"]*",\s*"([^"]+)",\s*"\{[^}]+\}"'
$script:SlnProjectFullRegex = [regex]'^\s*Project\("\{([^}]+)\}"\)\s*=\s*"([^"]*)",\s*"([^"]+)",\s*"\{([^}]+)\}"'
# Project-file extensions that count as a "project" for membership comparison and sync. Includes
# managed (cs/fs/vb), native (vcx), and PowerShell (pss). Get-SolutionInventory shows pssproj rows;
# Test-SolutionConsistency / Sync-Solution must compare them too, otherwise the inventory and the
# consistency check disagree (a pssproj in slnx but not sln reads as "all solutions agree").
$script:ProjectFileExtRegex = [regex]'\.(cs|fs|vb|vcx|pss)proj$'

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
        $parsed = if ($sln.PSObject.TypeNames -contains 'Netscoot.Solution') { $sln } else { Read-Solution -SolutionFile $sln.FullName }
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
        $parsed = if ($sln.PSObject.TypeNames -contains 'Netscoot.Solution') { $sln } else { Read-Solution -SolutionFile $sln.FullName }
        foreach ($p in $parsed.Projects) {
            if (-not $script:ProjectFileExtRegex.IsMatch($p.Stored)) { continue }
            if (Test-PathEqual $p.Abs $target) { $hits += $sln; break }
        }
    }
    return $hits
}

function Get-Workspace {
    # Parse-once domain model for one repository, so a single read/analysis cmdlet builds ONE of
    # these and derives membership, consuming projects, solutions-referencing, and reference data
    # from it instead of re-globbing the tree and re-parsing every .sln/.csproj per helper call.
    # Internal type (Netscoot.Workspace); not a public cmdlet output.
    #
    # Solutions are parsed eagerly (cheap, and every read path needs them). The project glob and the
    # reference index are built LAZILY on first access (Get-WorkspaceProjectFiles / *Refs /
    # *ConsumingProjects), so a solution-only cmdlet (Test-SolutionConsistency, Sync-Solution) never
    # pays to glob projects or parse their references, while a cmdlet that needs them pays once.
    #
    #   Root        - resolved repository root.
    #   Solutions   - one entry per .sln/.slnx; each is the parsed Netscoot.Solution with .FullName
    #                 /.Name added, so it reads like a Find-Solutions result AND the solution helpers
    #                 detect the embedded parse to avoid re-reading the file.
    #   Projects    - (lazy) one Find-ProjectFiles glob (managed + native). Each entry mirrors the
    #                 FileInfo shape (.FullName/.Name/.Extension) plus .Abs (resolved) and .IsManaged.
    #   ProjectRefs - (lazy) resolved project path -> its Get-ProjectReferencePaths (parsed once).
    #   Consumers   - (lazy) literal target path -> consumer paths (target->consumers; built with
    #                 ProjectRefs in one project parse).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $root = Resolve-FullPath $RepositoryRoot

    # One solution parse each. Wrap so the entry both reads like a Find-Solutions result
    # (.FullName/.Name) and is itself a Netscoot.Solution (so helpers skip the re-parse).
    $solutions = @()
    foreach ($sf in (Find-Solutions -Root $root)) {
        $parsed = Read-Solution -SolutionFile $sf.FullName
        $parsed | Add-Member -NotePropertyName FullName -NotePropertyValue $parsed.Path -Force
        $parsed | Add-Member -NotePropertyName Name -NotePropertyValue (Split-Path -Leaf $parsed.Path) -Force
        $solutions += $parsed
    }

    return [pscustomobject]@{
        PSTypeName  = 'Netscoot.Workspace'
        Root        = $root
        Solutions   = $solutions
        Projects    = $null   # lazy: built by Initialize-WorkspaceProjects on first access
        ProjectRefs = $null   # lazy
        Consumers   = $null   # lazy
    }
}

function Initialize-WorkspaceProjects {
    # Build (once, memoized) the workspace's project glob and reference index. Called lazily the
    # first time any project/reference accessor runs, so solution-only cmdlets never pay for it.
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Workspace)
    if ($null -ne $Workspace.Projects) { return }

    # One project glob (managed + native); tag each so a managed-only caller filters in memory.
    $projects = @()
    foreach ($pf in (Find-ProjectFiles -Root $Workspace.Root -IncludeNative)) {
        $projects += [pscustomobject]@{
            FullName  = $pf.FullName
            Name      = $pf.Name
            Extension = $pf.Extension
            Abs       = Resolve-FullPath $pf.FullName
            IsManaged = ($pf.Extension -in $script:ManagedProjectExtensions)
        }
    }

    # Reference index: parse each project's ProjectReferences exactly once. Index target->consumers
    # by resolved literal target path (non-literal Includes resolve to no single path, so they index
    # nothing - matching Get-ConsumingProjects' literal-only contract).
    $cmp = if (Test-IsWindowsHost) { [System.StringComparer]::OrdinalIgnoreCase } else { [System.StringComparer]::Ordinal }
    $projectRefs = [System.Collections.Generic.Dictionary[string, object]]::new($cmp)
    $consumers = [System.Collections.Generic.Dictionary[string, object]]::new($cmp)
    foreach ($p in $projects) {
        $refs = @(Get-ProjectReferencePaths -ProjectFile $p.FullName)
        $projectRefs[$p.Abs] = $refs
        foreach ($r in $refs) {
            if (-not $r.IsLiteral) { continue }
            if (-not $consumers.ContainsKey($r.FullPath)) { $consumers[$r.FullPath] = [System.Collections.Generic.List[string]]::new() }
            $consumers[$r.FullPath].Add($p.FullName)
        }
    }

    $Workspace.Projects = $projects
    $Workspace.ProjectRefs = $projectRefs
    $Workspace.Consumers = $consumers
}

function Get-WorkspaceSolutions {
    # The workspace solutions (each reads as a Find-Solutions result via .FullName/.Name and is the
    # parsed Netscoot.Solution). Streamed; callers wrap with @(...) as they do for Find-Solutions.
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Workspace)
    foreach ($s in $Workspace.Solutions) { $s }
}

function Get-WorkspaceProjectFiles {
    # The workspace project entries, mirroring Find-ProjectFiles output (.FullName/.Name/.Extension).
    # Managed-only by default; -IncludeNative also returns .vcxproj. No re-globbing. Streamed, so
    # callers wrap with @(...) exactly as they do for Find-ProjectFiles.
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Workspace, [switch]$IncludeNative)
    Initialize-WorkspaceProjects -Workspace $Workspace
    foreach ($p in $Workspace.Projects) { if ($IncludeNative -or $p.IsManaged) { $p } }
}

function Get-WorkspaceConsumingProjects {
    # Project paths in the workspace with a literal ProjectReference to $ProjectFile, read from the
    # prebuilt target->consumers index. Same result as Get-ConsumingProjects, with no re-parsing.
    # Streamed; callers wrap with @(...).
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Workspace, [Parameter(Mandatory)][string]$ProjectFile)
    Initialize-WorkspaceProjects -Workspace $Workspace
    $target = Resolve-FullPath $ProjectFile
    if (-not $Workspace.Consumers.ContainsKey($target)) { return }
    # Exclude a self-reference, matching Get-ConsumingProjects (it skips the target itself).
    foreach ($c in $Workspace.Consumers[$target]) {
        if (-not (Test-PathEqual (Resolve-FullPath $c) $target)) { $c }
    }
}

function Get-WorkspaceProjectRefs {
    # The parsed ProjectReferences of one project from the workspace cache; falls back to a direct
    # parse for a project outside the indexed glob. Streamed; callers wrap with @(...).
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Workspace, [Parameter(Mandatory)][string]$ProjectFile)
    Initialize-WorkspaceProjects -Workspace $Workspace
    $abs = Resolve-FullPath $ProjectFile
    $refs = if ($Workspace.ProjectRefs.ContainsKey($abs)) { $Workspace.ProjectRefs[$abs] } else { @(Get-ProjectReferencePaths -ProjectFile $abs) }
    foreach ($r in $refs) { $r }
}
