function Get-RepositoryRoot {
    # Walk up from $StartPath looking for a .git dir/file; fall back to the start path.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StartPath)
    $dir = Get-Item -LiteralPath $StartPath
    if (-not $dir.PSIsContainer) { $dir = $dir.Directory }
    while ($null -ne $dir) {
        if (Test-Path (Join-Path $dir.FullName '.git')) { return $dir.FullName }
        $dir = $dir.Parent
    }
    return (Get-Item -LiteralPath $StartPath).FullName
}

function Get-NestedWorktreePath {
    # Absolute paths of git worktrees that live strictly inside $Root - linked worktrees (e.g.
    # under .claude/worktrees/<id>/) hold duplicate copies of the repository's solutions/projects and
    # would poison a recursive scan (double-counted membership, etc.). Callers exclude these.
    # Empty when git is unavailable, $Root is not in a repository, or nothing nests under it.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    if (-not (Test-GitAvailable)) { return @() }
    $rootFull = Resolve-FullPath $Root
    if (-not (Test-Path -LiteralPath $rootFull)) { return @() }
    $lines = $null
    Push-Location $rootFull
    try { $lines = & git worktree list --porcelain 2>$null; $ok = ($LASTEXITCODE -eq 0) }
    catch { $ok = $false }
    finally { Pop-Location }
    if (-not $ok) { return @() }
    $nested = @()
    foreach ($l in $lines) {
        if ($l -match '^worktree\s+(.+)$') {
            $wt = Resolve-FullPath ($Matches[1].Trim())
            if (Test-PathUnder -Path $wt -Dir $rootFull) { $nested += $wt }   # strictly under root only
        }
    }
    return $nested
}

function Move-PathTracked {
    # Move one path: git mv when tracked (preserves history), else Move-Item. Creates the
    # destination parent if needed. Shared by every move cmdlet's filesystem step.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$UseGit,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$RepositoryRoot
    )
    $parent = Split-Path -Parent $Destination
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if ($UseGit -and (Test-GitTracked -Path $Source)) {
        Push-Location $RepositoryRoot
        try { & git mv -- $Source $Destination; if ($LASTEXITCODE -ne 0) { throw "git mv failed: $Source -> $Destination" } }
        finally { Pop-Location }
    } else {
        # No -Force on purpose: a plain Move-Item refuses an existing destination instead of
        # clobbering it. With Resolve-MoveTarget already rejecting an existing target, this keeps the
        # non-git path non-destructive even if a tampered journal sets Force. Do NOT add -Force here.
        Move-Item -LiteralPath $Source -Destination $Destination
    }
}

function Test-GitTracked {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Parent $Path
    try {
        Push-Location $dir
        & git ls-files --error-unmatch -- $Path *> $null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
    finally { Pop-Location }
}
