$script:ManagedProjectExtensions = @('.csproj', '.fsproj', '.vbproj')
$script:NativeProjectExtensions = @('.vcxproj')

function Test-IsNativeProject {
    # C++/native (.vcxproj). dotnet CLI lists these in solutions but can't reconcile
    # their link model (AdditionalLibraryDirectories/Dependencies, .props imports).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return ([System.IO.Path]::GetExtension($Path) -in $script:NativeProjectExtensions)
}

function Find-ProjectFiles {
    # MSBuild project files beneath a root. Managed by default; -IncludeNative also returns .vcxproj.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [switch]$IncludeNative
    )
    $exts = $script:ManagedProjectExtensions
    if ($IncludeNative) { $exts = $exts + $script:NativeProjectExtensions }
    $nested = Get-NestedWorktreePath -Root $Root   # linked worktrees hold duplicate copies
    Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in $exts -and $_.FullName -notmatch '[\\/](bin|obj|\.vs|\.git)[\\/]' -and -not (Test-PathUnderAny -Path $_.FullName -Dirs $nested) }
}

function Read-ProjectXml {
    # Read text (File.ReadAllText auto-detects BOM/encoding on both editions), strip any
    # residual BOM, then LoadXml from the string. Avoids both the 5.1 [xml]-cast BOM failure
    # and Load(path) URI quirks.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $full = Resolve-FullPath $Path
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "Project file not found for XML read: $full"
    }
    $text = [System.IO.File]::ReadAllText($full).TrimStart([char]0xFEFF)
    $xml = New-Object System.Xml.XmlDocument
    # Harden against XXE: a null resolver stops external DTD/entity resolution (local file read / SSRF)
    # when parsing an untrusted project file. Windows PowerShell 5.1's XmlDocument resolves entities by
    # default; .NET Core does not, but set it on both for safety.
    $xml.XmlResolver = $null
    $xml.LoadXml($text)
    return $xml
}

function Get-ProjectReferencePaths {
    # Every <ProjectReference Include=...> in a project file, classified. A reference is literal
    # only when its Include is a plain relative path; an Include built from an MSBuild property
    # ($(...)), an item list (@(...)), or a wildcard (* ?) cannot be resolved to one file, and a
    # reference (or its enclosing ItemGroup) carrying a Condition may not always apply. Non-literal
    # references get FullPath = $null, since there is no single path to reconcile.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectFile)
    $projDir = Split-Path -Parent (Resolve-FullPath $ProjectFile)
    $xml = Read-ProjectXml -Path $ProjectFile
    $refs = @()
    foreach ($node in $xml.SelectNodes('//*[local-name()="ProjectReference"]')) {
        $include = $node.GetAttribute('Include')
        if ([string]::IsNullOrWhiteSpace($include)) { continue }
        $isLiteral = -not ($include -match '\$\(|@\(|[*?]')
        $hasCondition = -not [string]::IsNullOrWhiteSpace($node.GetAttribute('Condition')) -or
            ($null -ne $node.ParentNode -and -not [string]::IsNullOrWhiteSpace($node.ParentNode.GetAttribute('Condition')))
        $abs = if ($isLiteral) { [System.IO.Path]::GetFullPath((Join-Path $projDir $include)) } else { $null }
        $refs += [pscustomobject]@{ Raw = $include; FullPath = $abs; IsLiteral = $isLiteral; HasCondition = $hasCondition }
    }
    return $refs
}

function Get-UnreconcilableReferences {
    # ProjectReferences the dotnet CLI cannot safely reconcile on a move: a non-literal Include
    # (MSBuild property / item list / wildcard) or a conditional reference. Reported, not rewritten.
    # Reads the project's references from $Workspace's parse-once cache when one is supplied,
    # otherwise parses the file directly.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectFile,
        [object]$Workspace
    )
    $refs = if ($Workspace) { Get-WorkspaceProjectRefs -Workspace $Workspace -ProjectFile $ProjectFile }
            else { Get-ProjectReferencePaths -ProjectFile $ProjectFile }
    return @($refs | Where-Object { -not $_.IsLiteral -or $_.HasCondition })
}

function Write-UnreconcilableReferenceWarning {
    # Warn about references that a move cannot auto-fix: the moved project's own non-literal /
    # conditional references, and any other repository project that has such references (which may point
    # at the moved project through a variable/glob and so was never detected as a consumer).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MovedProject,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$AllProjects,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$LiteralConsumers,
        [object]$Workspace
    )
    $movedFull = Resolve-FullPath $MovedProject
    foreach ($r in (Get-UnreconcilableReferences -ProjectFile $movedFull -Workspace $Workspace)) {
        $why = if (-not $r.IsLiteral) { 'non-literal path' } else { 'conditional' }
        Write-Warning ("$(Split-Path -Leaf $movedFull) has an unreconcilable ProjectReference '$($r.Raw)' ($why); verify it by hand after the move.")
    }
    foreach ($proj in $AllProjects) {
        $pf = Resolve-FullPath $proj.FullName
        if ((Test-PathEqual $pf $movedFull) -or (Test-PathInList $pf $LiteralConsumers)) { continue }
        if (@(Get-UnreconcilableReferences -ProjectFile $pf -Workspace $Workspace).Count -gt 0) {
            Write-Warning ("$(Split-Path -Leaf $pf) has non-literal/conditional ProjectReference(s); if any point at $(Split-Path -Leaf $movedFull), they were not reconciled - verify by hand.")
        }
    }
}

function Get-ConsumingProjects {
    # Project files that have a literal ProjectReference to $ProjectFile. With -Workspace, reads the
    # prebuilt target->consumers index (each project parsed once for the whole invocation); otherwise
    # walks $Candidates and parses each. Both return the same consumer FullName paths.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectFile,
        [AllowEmptyCollection()][object[]]$Candidates,
        [object]$Workspace
    )
    if ($Workspace) { return @(Get-WorkspaceConsumingProjects -Workspace $Workspace -ProjectFile $ProjectFile) }
    $target = Resolve-FullPath $ProjectFile
    $hits = @()
    foreach ($proj in $Candidates) {
        if (Test-PathEqual (Resolve-FullPath $proj.FullName) $target) { continue }
        foreach ($ref in (Get-ProjectReferencePaths -ProjectFile $proj.FullName)) {
            if (-not $ref.IsLiteral) { continue }   # non-literal Include resolves to no single path
            if (Test-PathEqual $ref.FullPath $target) { $hits += $proj.FullName; break }
        }
    }
    return $hits
}

function Test-DirectoryBuildInheritance {
    # Warn if moving from $OldDir to $NewDir changes which inherited MSBuild file applies. Covers
    # Directory.Build.props/.targets (SDK auto-imports) and Directory.Packages.props (Central
    # Package Management). MSBuild and CPM each import only the NEAREST ancestor file of a given
    # name (the project's own directory counts), so inheritance changes when that nearest file
    # changes - comparing by full path, not leaf name, since every level uses the same filename.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OldDir,
        [Parameter(Mandatory)][string]$NewDir,
        [Parameter(Mandatory)][string]$RepositoryRoot
    )
    $rootFull = (Resolve-FullPath $RepositoryRoot)
    function _nearest([string]$start, [string]$name) {
        $d = [System.IO.DirectoryInfo]::new((Resolve-FullPath $start))
        while ($null -ne $d) {
            $p = Join-Path $d.FullName $name
            if (Test-Path -LiteralPath $p) { return (Resolve-FullPath $p) }
            if (Test-PathEqual (Resolve-FullPath $d.FullName) $rootFull) { break }
            $d = $d.Parent
        }
        return $null
    }
    $changes = foreach ($name in 'Directory.Build.props', 'Directory.Build.targets', 'Directory.Packages.props') {
        $b = _nearest $OldDir $name
        $a = _nearest $NewDir $name
        $same = ($b -and $a -and (Test-PathEqual $b $a)) -or (-not $b -and -not $a)
        if (-not $same) { [pscustomobject]@{ Name = $name; Before = $b; After = $a } }
    }
    if ($changes) {
        Write-Warning "Directory.Build.* / Directory.Packages.props inheritance changes with this move:"
        foreach ($c in $changes) {
            $b = if ($c.Before) { $c.Before } else { '(none)' }
            $a = if ($c.After) { $c.After } else { '(none)' }
            Write-Warning "  $($c.Name): $b -> $a"
        }
    }
}
