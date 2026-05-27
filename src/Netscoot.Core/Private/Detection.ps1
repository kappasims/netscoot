function Test-PathBearingFile {
    # True if $File is a non-canonical, path-hardcoding file (build/CI/hook/container) that no
    # first-party tool reconciles. Classified by location + name, not a hardcoded filename list.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$File,
        [Parameter(Mandatory)][int]$RootLen
    )
    $rel = ($File.FullName.Substring($RootLen).TrimStart('\', '/')) -replace '\\', '/'
    $name = $File.Name
    # Skip caches / vendored / the tool's own test clones - matched on the path relative to the
    # repository root (so a repository that itself lives under e.g. test-subjects/ is not wholly excluded).
    if ($rel -match '(^|/)(\.git|bin|obj|\.vs|node_modules|test-subjects)/') { return $false }
    # CI definitions
    if ($rel -match '^\.github/workflows/.*\.ya?ml$') { return $true }
    if ($rel -match '^\.circleci/') { return $true }
    if ($name -in 'azure-pipelines.yml', 'azure-pipelines.yaml', '.gitlab-ci.yml', 'appveyor.yml', '.appveyor.yml', 'bitbucket-pipelines.yml') { return $true }
    # git hooks (project-tracked) - skip the .sample templates
    if ($rel -match '^\.githooks/' -and $name -notlike '*.sample') { return $true }
    # build / container files (by name, anywhere)
    if ($name -in 'Makefile', 'makefile', 'GNUmakefile', 'Dockerfile') { return $true }
    if ($name -like 'docker-compose*.yml' -or $name -like 'docker-compose*.yaml') { return $true }
    # build/automation scripts: only at repository root or in known automation dirs (don't scan every
    # source script - that would flag the project's own code and be noisy).
    if ($File.Extension.ToLowerInvariant() -in '.ps1', '.sh', '.bat', '.cmd', '.py') {
        if ($rel -notmatch '/') { return $true }
        if ($rel -match '^(build|scripts|tools|eng|ci|\.build|automation)/') { return $true }
    }
    return $false
}

function Get-PathBearingFile {
    # Discover the class of path-hardcoding files in a repository (see Test-PathBearingFile).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string[]]$AdditionalGlob = @()
    )
    $root = (Resolve-FullPath $RepositoryRoot).TrimEnd('\', '/')
    $rootLen = $root.Length

    $nested = Get-NestedWorktreePath -Root $root   # linked worktrees hold duplicate copies

    # -Force so dot-prefixed dirs (.github, .githooks) are traversed; on Unix they are
    # "hidden" and Get-ChildItem -Recurse skips them without it.
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { (Test-PathBearingFile -File $_ -RootLen $rootLen) -and -not (Test-PathUnderAny -Path $_.FullName -Dirs $nested) })

    # .git/hooks/* active hooks live inside the excluded .git dir - add them explicitly.
    $gitHooks = Join-Path $root '.git/hooks'
    if (Test-Path -LiteralPath $gitHooks) {
        $files += @(Get-ChildItem -LiteralPath $gitHooks -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notlike '*.sample' })
    }
    foreach ($g in $AdditionalGlob) {
        $files += @(Get-ChildItem -Path (Join-Path $root $g) -File -ErrorAction SilentlyContinue)
    }

    $files | Sort-Object FullName -Unique
}
