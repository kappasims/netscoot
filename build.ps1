#requires -Version 5.1
<#
.SYNOPSIS
    Build entry point for netscoot: run tests, lint, or install the modules.

.DESCRIPTION
    Tasks:
      Test    (default) - import the modules and run the Pester suite (validates they load).
                          Non-zero exit on failure (for CI).
      Analyze           - run PSScriptAnalyzer over src/ if it is available.
      Install           - copy all modules (Shared, the engines, and the netscoot umbrella) into
                          a PowerShell module path so `Import-Module Netscoot` works by name.
      Docs              - regenerate the "Command reference" section of README.md from the
                          cmdlets' comment-based help.
      CheckDocs         - gate the docs: fail if the README reference is stale (someone edited
                          cmdlet help without regenerating) or if README/skills carry an old-brand
                          token or name a cmdlet that no longer exists. Part of the Release gate.
      Release -Version  - run from develop. Without -Publish (prepare): stamp the semver into every
                          manifest, gate on static analysis (required + clean) and the tests, then
                          commit `release: vX.Y.Z` and push develop so CI runs on it. With -Publish
                          (finalize, after CI is green on all platforms): fast-forward master to that
                          commit, tag, push, and create the GitHub release. master is protected, so it
                          only ever receives a CI-passed commit; ModuleVersion stays equal to the tag.
      Publish           - assemble the single bundled netscoot package, validate and smoke-import
                          it, then Publish-Module to the PowerShell Gallery (dry run without -ApiKey).
                          After a successful publish it unlists every prior version (only the new one
                          stays listed); pass -KeepOldVersions to keep the full history listed.

.EXAMPLE
    ./build.ps1                       # run the tests
    ./build.ps1 -Task Analyze
    ./build.ps1 -Task Install         # into the per-user module path
    ./build.ps1 -Task Install -InstallPath D:\Modules
    ./build.ps1 -Task Docs            # regenerate the README Command reference section
    ./build.ps1 -Task Release -Version 1.2.0           # prepare on develop: stamp, gate, commit + push
    ./build.ps1 -Task Release -Version 1.2.0 -Publish  # finalize (after CI green): fast-forward master, tag, release
#>
[CmdletBinding()]
param(
    [ValidateSet('Test', 'Analyze', 'Install', 'Docs', 'CheckDocs', 'Release', 'Publish')]
    [string]$Task = 'Test',
    [string]$InstallPath,
    # Publish: PowerShell Gallery NuGet API key. Without it, Publish only stages + validates the
    # bundled package (dry run) - it does not publish.
    [string]$ApiKey,
    # Release: the semver to stamp into every module manifest (keeps ModuleVersion == the tag).
    [string]$Version,
    # Release: also commit, tag vX.Y.Z, push, and create the GitHub release. Without it, Release
    # only stamps the manifests locally so you can review the bump before publishing.
    [switch]$Publish,
    # Publish: by DEFAULT, after a successful Gallery publish, unlist every previously-published
    # version so only the just-published one is listed (hidden from search and from un-versioned
    # Install-Module; still installable by explicit -RequiredVersion - the Gallery never hard-deletes).
    # Pass -KeepOldVersions to skip the unlisting and leave the full version history listed.
    [switch]$KeepOldVersions,
    # Release: override the "no src/ change since the last tag" guard. A module release only makes
    # sense when src/ (the Gallery-packaged code) changed; doc/skill/tooling changes ship via the
    # plugin instead (see CONTRIBUTING "Two release cadences"). Use this only for a deliberate
    # module-identical bump (e.g. version parity).
    [switch]$AllowEmptyModuleRelease,
    # Release (prepare): skip the expensive local gate (PSScriptAnalyzer + the full Pester suite) and
    # only stamp + commit + push. For the automated release.yml, where CI runs the full matrix on the
    # pushed commit instead. The cheap prep checks (docs-not-stale, CHANGELOG entry, src-change guard)
    # still run. Do NOT use for a local hand-run release - there the local gate is the safety net.
    [switch]$SkipGate,
    # Test: split the test files into -ShardCount slices and run only the -ShardIndex'th (1-based).
    # Used by CI to run the suite as parallel jobs (separate processes - the tests share process-
    # global state, so they cannot be parallelized in-process). The default runs the whole suite.
    [int]$ShardIndex = 0,
    [int]$ShardCount = 1
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
# Shared first: the engines call its helpers, so it must import/install before them.
$modules = 'NetscootShared', 'Netscoot.Core', 'Netscoot.Native', 'Netscoot.Unity'
# The umbrella bootstrap imports the engines above; it ships but is not in the per-engine
# import/test loop (importing it would pull the engines in a second time).
$umbrella = 'Netscoot'

function script:Test-IsWindowsBuild {
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return $true }
    if (Test-Path Variable:\IsWindows) { return [bool](Get-Variable -Name IsWindows -ValueOnly) }
    return $false
}

function Invoke-TestTask {
    if (-not (Get-Module -ListAvailable Pester | Where-Object Version -eq ([version]'5.7.1'))) {
        # Do not auto-install (matches the toolkit's "never auto-install" stance); instruct instead.
        throw "Pester 5.7.1 is required to run the tests. Install it: Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -SkipPublisherCheck"
    }
    Import-Module Pester -RequiredVersion 5.7.1 -Force

    # Import Shared first, then the engines (mirrors how the umbrella loads them) before tests run.
    foreach ($m in $modules) {
        Import-Module ([System.IO.Path]::Combine($root, 'src', $m, "$m.psd1")) -Force
    }
    Write-Host "Imported: $((Get-Command -Module $modules).Count) cmdlets across $($modules.Count) modules." -ForegroundColor Green

    $cfg = New-PesterConfiguration
    $cfg.Run.Exit = $true          # non-zero exit on failure (CI)
    $cfg.Output.Verbosity = 'Detailed'

    if ($ShardCount -gt 1) {
        # Balance the test files across ShardCount slices by cost and run this one. A plain
        # round-robin (by name) clustered the heavy end-to-end tests (real dotnet build/restore) into
        # one shard, so it ran 3-4x longer than the lightest and gated total CI wall time. Instead use
        # longest-processing-time bin packing: take files largest-first (file size is a proxy for cost
        # - more It blocks / fixtures = a bigger file) and assign each to the currently-lightest shard.
        # File size is identical on every runner, so all shards compute the SAME partition: slices stay
        # disjoint and cover every file. Each shard runs in its own CI job (process); no shared state.
        $idx = if ($ShardIndex -lt 1) { 1 } else { $ShardIndex }
        $all = @(Get-ChildItem -Path (Join-Path $root 'tests') -Recurse -File -Filter '*.Tests.ps1')
        # Heaviest first; the FullName secondary key makes the order total (no ties) so the packing is
        # deterministic regardless of Sort-Object stability.
        $ordered = @($all | Sort-Object -Property @{ Expression = 'Length'; Descending = $true }, @{ Expression = 'FullName'; Descending = $false })
        $loads = New-Object 'System.Int64[]' $ShardCount
        $buckets = @{}; for ($s = 0; $s -lt $ShardCount; $s++) { $buckets[$s] = @() }
        foreach ($f in $ordered) {
            $target = 0
            for ($s = 1; $s -lt $ShardCount; $s++) { if ($loads[$s] -lt $loads[$target]) { $target = $s } }
            $buckets[$target] += $f
            $loads[$target] += $f.Length
        }
        $mine = @($buckets[$idx - 1])
        if (-not $mine.Count) {
            Write-Host "Shard ${idx}/${ShardCount} has no test files; nothing to run." -ForegroundColor Yellow
            return
        }
        Write-Host "Shard ${idx}/${ShardCount}: running $($mine.Count) of $($all.Count) test files." -ForegroundColor Cyan
        $cfg.Run.Path = $mine.FullName
    } else {
        $cfg.Run.Path = Join-Path $root 'tests'
    }
    Invoke-Pester -Configuration $cfg
}

$script:AnalyzerFields = @('RuleName', 'Severity', 'ScriptName', 'Line', 'Message')

$script:AnalyzerIsolatedRetries = 3

function script:Invoke-AnalyzerInChildProcess {
    # Re-analyze ONE file in a fresh PowerShell process so PSScriptAnalyzer's reflection-emit state
    # starts clean. This is the recovery path for an analyzer-engine crash in the shared in-process
    # loop (see Invoke-AnalyzeTask). Paths go through the environment to dodge any quoting pitfalls.
    # PSScriptAnalyzer's NullReferenceException is intermittent and can recur even in a fresh process,
    # so attempt the isolated run up to $AnalyzerIsolatedRetries times; only a crash (non-zero exit)
    # triggers a retry, never a real finding (which exits 0 with results), so retries can't mask a
    # lint violation. Returns the file's findings as plain objects; throws only if every attempt crashes.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Settings)
    $exeName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
    if (script:Test-IsWindowsBuild) { $exeName += '.exe' }
    $psExe = Join-Path $PSHOME $exeName
    $env:NS_ANALYZE_FILE = $Path
    $env:NS_ANALYZE_SETTINGS = $Settings
    try {
        $cmd = 'Import-Module PSScriptAnalyzer; ' +
        'Invoke-ScriptAnalyzer -Path $env:NS_ANALYZE_FILE -Settings $env:NS_ANALYZE_SETTINGS | ' +
        'Select-Object ' + ($script:AnalyzerFields -join ',') + ' | ConvertTo-Json -Depth 4 -Compress'
        for ($attempt = 1; $attempt -le $script:AnalyzerIsolatedRetries; $attempt++) {
            $json = & $psExe -NoProfile -NonInteractive -Command $cmd
            if ($LASTEXITCODE -eq 0) {
                if ([string]::IsNullOrWhiteSpace(($json -join ''))) { return @() }
                return @($json | ConvertFrom-Json)
            }
            $leaf = Split-Path $Path -Leaf
            if ($attempt -lt $script:AnalyzerIsolatedRetries) {
                Write-Warning "PSScriptAnalyzer crashed analyzing $leaf in an isolated process (exit $LASTEXITCODE, attempt $attempt/$($script:AnalyzerIsolatedRetries)); retrying."
            } else {
                throw "PSScriptAnalyzer crashed analyzing $leaf in $($script:AnalyzerIsolatedRetries) isolated attempts (exit $LASTEXITCODE)."
            }
        }
    } finally {
        Remove-Item Env:\NS_ANALYZE_FILE, Env:\NS_ANALYZE_SETTINGS -ErrorAction SilentlyContinue
    }
}

function Invoke-AnalyzeTask {
    if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
        Write-Warning 'PSScriptAnalyzer not installed; skipping. (Install-Module PSScriptAnalyzer -Scope CurrentUser)'
        return
    }
    Import-Module PSScriptAnalyzer
    $settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
    # Enumerate the files ourselves and analyze each in-process (the fast path). Two analyzer-engine
    # crashes are NOT findings and must not fail the run: Invoke-ScriptAnalyzer's own -Recurse walk
    # throws a NullReferenceException on some runner versions, and analyzing many files in one process
    # intermittently hits "more than one dynamic module in each dynamic assembly" once the analyzer's
    # accumulated reflection-emit state fills the dynamic assembly. So catch a crash per file and
    # re-analyze just that file in a fresh child process (clean state); only fail on a real finding or
    # if the isolated retry also crashes.
    $files = Get-ChildItem -Path (Join-Path $root 'src') -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1'
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $files) {
        try {
            $r = Invoke-ScriptAnalyzer -Path $f.FullName -Settings $settings -ErrorAction Stop
            foreach ($d in @($r)) { $results.Add(($d | Select-Object $script:AnalyzerFields)) }
        } catch {
            $first = "$($_.Exception.Message)".Split([char]10)[0].Trim()
            Write-Warning "PSScriptAnalyzer crashed on $($f.Name) in-process ($first); retrying in an isolated process."
            foreach ($d in @(script:Invoke-AnalyzerInChildProcess -Path $f.FullName -Settings $settings)) { $results.Add($d) }
        }
    }
    if ($results.Count) {
        $results | Format-Table -AutoSize | Out-String | Write-Host
        throw "PSScriptAnalyzer reported $($results.Count) finding(s)."
    }
    Write-Host 'PSScriptAnalyzer: clean.' -ForegroundColor Green
}

function Invoke-InstallTask {
    if (-not $InstallPath) {
        # Default to the CurrentUser module directory for the edition running this script, so the
        # install lands somewhere already on $env:PSModulePath (PowerShell 7 and Windows
        # PowerShell 5.1 use different folders).
        $InstallPath = if (Test-IsWindowsBuild) {
            $editionDir = if ($PSVersionTable.PSEdition -eq 'Core') { 'PowerShell' } else { 'WindowsPowerShell' }
            Join-Path ([Environment]::GetFolderPath('MyDocuments')) (Join-Path $editionDir 'Modules')
        } else {
            Join-Path $HOME '.local/share/powershell/Modules'
        }
    }
    New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
    foreach ($name in ($modules + $umbrella)) {
        $dest = Join-Path $InstallPath $name
        if (Test-Path $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        Copy-Item -LiteralPath (Join-Path $root (Join-Path 'src' ($name))) -Destination $dest -Recurse -Force
    }
    Write-Host "Installed netscoot (all engines + Shared) to: $InstallPath" -ForegroundColor Green

    $sep = [System.IO.Path]::PathSeparator
    $onPath = ($env:PSModulePath -split $sep) | Where-Object { $_.TrimEnd('\', '/') -ieq $InstallPath.TrimEnd('\', '/') }
    if ($onPath) {
        Write-Host 'Ready. Import it by name:' -ForegroundColor Green
        Write-Host '    Import-Module Netscoot          # all engines'
        Write-Host '    Register-NetscootGitAlias -Scope Global   # optional: enable `git netscoot`'
    } else {
        Write-Host "That folder is NOT on `$env:PSModulePath. Add it for this session with:" -ForegroundColor Yellow
        Write-Host "    `$env:PSModulePath = '$InstallPath' + '$sep' + `$env:PSModulePath"
        Write-Host '    Import-Module Netscoot'
    }
}

# The README "Command reference" generator (Invoke-DocsTask) is large enough to live on its own;
# see tools/Build-DocsReference.ps1. Dot-sourced so it shares this script's scope ($root,
# $modules, $umbrella) and defines Invoke-DocsTask before Assert-DocsNotStale and the dispatch use it.
. ([System.IO.Path]::Combine($PSScriptRoot, 'tools', 'Build-DocsReference.ps1'))

function Assert-DocsNotStale {
    # Release gate: fail if the docs have drifted from the code. Two checks (run with a clean tree):
    #   1. Stale README - regenerating the Command reference must be a no-op. If it changes, someone
    #      edited cmdlet help without running -Task Docs.
    #   2. Stale README + skills - no leftover old-brand tokens, and every product cmdlet the docs name
    #      must still be exported (catches a rename/removal the docs did not follow).
    Write-Host 'Checking docs are current (README reference + brand/command references)...' -ForegroundColor Cyan

    # (1) README reference drift. Save the current content, regenerate, compare (ignoring EOL), then
    # restore the saved content. File save/restore - never `git checkout` - so this never discards
    # uncommitted README work even if run on a dirty tree.
    $readmePath = [System.IO.Path]::Combine($root, 'README.md')
    $before = [System.IO.File]::ReadAllText($readmePath)
    Invoke-DocsTask | Out-Null
    $after = [System.IO.File]::ReadAllText($readmePath)
    [System.IO.File]::WriteAllText($readmePath, $before, [System.Text.UTF8Encoding]::new($false))
    if (($before -replace "`r`n", "`n") -ne ($after -replace "`r`n", "`n")) {
        throw 'README is stale: its generated Command reference does not match the cmdlet help. Run ./build.ps1 -Task Docs and commit.'
    }

    $docFiles = @([System.IO.Path]::Combine($root, 'README.md'))
    $docFiles += @(Get-ChildItem -Path (Join-Path $root '.claude/skills') -Recurse -Filter '*.md' -ErrorAction SilentlyContinue | ForEach-Object FullName)

    # (2a) Leftover old-brand tokens (an incomplete rebrand).
    foreach ($f in $docFiles) {
        $text = [System.IO.File]::ReadAllText($f)
        foreach ($bad in 'DotnetMove', 'dotnet-move', 'DOTNETMOVE', 'dotnetmv') {
            if ($text.Contains($bad)) { throw "Stale brand token '$bad' in $(Split-Path -Leaf $f); update it to the current brand." }
        }
        if ($text -cmatch '\bMove-Dotnet\b') { throw "Stale 'Move-Dotnet' (the umbrella is now Invoke-Netscoot) in $(Split-Path -Leaf $f)." }
    }

    # (2b) Every product cmdlet the docs name must be exported (a distinctive-noun match avoids
    # flagging generic PowerShell/dotnet commands that legitimately appear in examples).
    foreach ($m in $modules) { Import-Module ([System.IO.Path]::Combine($root, 'src', $m, "$m.psd1")) -Force }
    $exported = @(Get-Command -Module $modules -CommandType Function | ForEach-Object Name)
    $stem = 'Netscoot|Dotnet|PowerShell|Native|Unity|MSBuild|MoveEngine|SolutionReferences|SolutionConsistency|SolutionInventory|PathReference'
    foreach ($f in $docFiles) {
        $text = [System.IO.File]::ReadAllText($f)
        foreach ($mch in [regex]::Matches($text, "\b[A-Z][a-z]+-($stem)\w*\b")) {
            if ($mch.Value -notin $exported) { throw "Docs name a cmdlet that does not exist: '$($mch.Value)' in $(Split-Path -Leaf $f) (renamed or removed?). Update the docs." }
        }
    }

    # (2c) Category-map coverage. Every documented (public engine) cmdlet must appear in the
    # functional taxonomy exactly once, and the map must name no command that is not exported. This
    # is what forces a new cmdlet to be categorized before it can ship (the index is generated from
    # this map, so an uncategorized command would otherwise just be silently absent from the index).
    $documented = @(Get-Command -Module ($modules | Where-Object { $_ -ne 'NetscootShared' }) -CommandType Function | ForEach-Object Name)
    $categories = Import-PowerShellDataFile ([System.IO.Path]::Combine($root, 'docs', 'command-categories.psd1'))
    $mapped = foreach ($cat in $categories.Categories) {
        if ($cat.Commands) { $cat.Commands }
        foreach ($sub in $cat.Subcategories) { $sub.Commands }
    }
    $mapped = @($mapped | Where-Object { $_ })
    $dupes = @($mapped | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
    if ($dupes.Count) { throw "command-categories.psd1 lists these command(s) more than once: $($dupes -join ', '). Each command must be categorized exactly once." }
    $uncategorized = @($documented | Where-Object { $_ -notin $mapped })
    if ($uncategorized.Count) { throw "These exported cmdlet(s) are not in command-categories.psd1: $($uncategorized -join ', '). Add each to a category so it appears in the Command reference." }
    $ghosts = @($mapped | Where-Object { $_ -notin $documented })
    if ($ghosts.Count) { throw "command-categories.psd1 names cmdlet(s) that are not exported: $($ghosts -join ', '). Remove or rename them." }

    # (3) markdownlint-cli2, mirroring the CI step in .github/workflows/markdownlint.yml. Run in-tree
    # when npx is on PATH so MD013/MD024/MD032 etc. fail at -Task CheckDocs / -Task Release prepare,
    # not at CI time after the release commit has already been stamped and pushed. The CI workflow
    # remains the authoritative gate; this just shifts the failure left for developers who have Node.
    # Skipped (not failed) when npx is absent - so contributors without Node aren't blocked locally.
    $npx = Get-Command npx -ErrorAction SilentlyContinue
    if (-not $npx) {
        Write-Host 'markdownlint-cli2 skipped (npx not on PATH). The CI workflow markdownlint.yml is the authoritative gate.' -ForegroundColor DarkYellow
    } else {
        Write-Host 'Running markdownlint-cli2 (CI parity)...' -ForegroundColor Cyan
        Push-Location $root
        try {
            & npx --yes markdownlint-cli2 '**/*.md'
            if ($LASTEXITCODE -ne 0) {
                throw 'markdownlint-cli2 reported violations (see above). Fix the source markdown or the comment-based help that regenerates into README.md, then re-run.'
            }
        } finally { Pop-Location }
    }

    Write-Host 'Docs are current.' -ForegroundColor Green
}

function Invoke-ReleaseTask {
    # Releases are cut from master, which is branch-protected: the CI checks are required and enforced
    # for admins, so master may only ever receive a commit that already passed CI. This task therefore
    # PREPARES the release on develop (stamp + commit + push, so CI runs on that exact commit), and
    # -Publish then FINALIZES by fast-forwarding master to that green commit and tagging it. Two phases,
    # both run from develop:
    #   ./build.ps1 -Task Release -Version X.Y.Z            # prepare: stamp, gate, commit + push develop
    #   (wait for CI green on all platforms)
    #   ./build.ps1 -Task Release -Version X.Y.Z -Publish   # finalize: fast-forward master, tag, release
    # ModuleVersion in every manifest is kept equal to the tag, so installed version == released tag.
    if (-not $Version) { throw "Release needs -Version, e.g. ./build.ps1 -Task Release -Version 1.2.0" }
    if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Version must be semver (x.y.z): '$Version'" }
    $tag = "v$Version"

    $branch = "$(& git -C $root rev-parse --abbrev-ref HEAD)".Trim()
    if ($branch -ne 'develop') { throw "Run Release from develop (currently on '$branch'); master is fast-forwarded from develop." }

    if (-not $Publish) {
        # PREPARE on develop: stamp, gate locally, commit the bump, push so CI runs on that commit.
        if (& git -C $root status --porcelain) { throw 'Working tree is not clean; commit or stash first so the release commit is only the version bump.' }

        # Gate: a module release must actually change src/ (the only thing the Gallery package ships).
        # Doc/skill/tooling changes since the last tag are NOT a module release - they reach users via
        # the plugin (bump .claude-plugin/plugin.json + /plugin update) or just by fast-forwarding
        # master. This guard stops accidental module-identical bumps (see CONTRIBUTING). Skipped when
        # there is no prior tag (first release) or when overridden with -AllowEmptyModuleRelease.
        $lastTag = "$(& git -C $root describe --tags --abbrev=0 --match 'v*' 2>$null)".Trim()
        if ($lastTag -and -not $AllowEmptyModuleRelease) {
            & git -C $root diff --quiet "$lastTag" HEAD -- src/
            if ($LASTEXITCODE -eq 0) {
                throw "No src/ changes since $lastTag, so a module release would be byte-identical to it. " +
                "Skill/doc/tooling changes ship via the plugin (bump .claude-plugin/plugin.json, then users " +
                "/plugin update) - see CONTRIBUTING 'Two release cadences'. To force a module-identical bump " +
                "anyway (e.g. version parity), re-run with -AllowEmptyModuleRelease."
            }
        }

        # Gate: docs must not be stale (README reference current; README + skills reference no removed
        # brand/cmdlets). Run while the tree is clean, before stamping.
        Assert-DocsNotStale

        # Gate: CHANGELOG.md must document this version, so updating it is a required step of every
        # release rather than an afterthought. Matches a "## [X.Y.Z]" heading (Keep a Changelog).
        $changelog = Join-Path $root 'CHANGELOG.md'
        if (-not (Test-Path $changelog)) { throw "CHANGELOG.md not found at $changelog; add it before releasing." }
        if ([System.IO.File]::ReadAllText($changelog) -notmatch "(?m)^##\s*\[$([regex]::Escape($Version))\]") {
            throw "CHANGELOG.md has no '## [$Version]' entry. Document $tag in CHANGELOG.md first."
        }

        $manifests = foreach ($m in ($modules + $umbrella)) { Join-Path $root (Join-Path 'src' (Join-Path $m "$m.psd1")) }
        $changed = $false
        foreach ($mf in $manifests) {
            $text = [System.IO.File]::ReadAllText($mf)
            $new = [regex]::Replace($text, "(?m)^(\s*ModuleVersion\s*=\s*')[^']*(')", "`${1}$Version`$2")
            if ($new -cne $text) { [System.IO.File]::WriteAllText($mf, $new); $changed = $true; Write-Host "Stamped $Version into $(Split-Path -Leaf $mf)" -ForegroundColor Green }
        }
        if (-not $changed) { throw "No manifest changed - already at $Version?" }

        # Static analysis is a hard gate here (must be installed AND clean), then the full suite.
        # -SkipGate (CI/release.yml) skips both because CI runs the full matrix on the pushed commit.
        if ($SkipGate) {
            Write-Host 'Skipping the local Analyze + Test gate (-SkipGate); CI gates the pushed commit.' -ForegroundColor Yellow
        } else {
            Write-Host 'Static analysis (release prerequisite)...' -ForegroundColor Cyan
            if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) { throw 'Release requires PSScriptAnalyzer. Install: Install-Module PSScriptAnalyzer -Scope CurrentUser' }
            Invoke-AnalyzeTask
            Write-Host 'Running the test suite before release...' -ForegroundColor Cyan
            Invoke-TestTask
        }

        & git -C $root add (($modules + $umbrella) | ForEach-Object { "src/$_/$_.psd1" })
        & git -C $root commit -m "release: $tag"
        if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }
        & git -C $root push origin develop
        if ($LASTEXITCODE -ne 0) { throw 'git push develop failed' }
        Write-Host "Prepared $tag on develop and pushed. Now wait for CI to pass on all platforms:" -ForegroundColor Yellow
        Write-Host '  - ci.yml (Windows, Windows PowerShell 5.1, PSScriptAnalyzer) runs on the push' -ForegroundColor Yellow
        Write-Host '  - run platforms.yml for Linux + macOS (tools/Invoke-PlatformCI.ps1)' -ForegroundColor Yellow
        Write-Host "Then finalize:  ./build.ps1 -Task Release -Version $Version -Publish" -ForegroundColor Yellow
        return
    }

    # FINALIZE: develop HEAD must be the prepared release commit; fast-forward master to it. The
    # protected push to master is accepted only because the required CI checks passed on this commit.
    $headSubject = "$(& git -C $root log -1 --format=%s)".Trim()
    if ($headSubject -ne "release: $tag") { throw "develop HEAD is '$headSubject', not 'release: $tag'. Run the prepare phase first (without -Publish)." }

    & git -C $root fetch -q origin
    & git -C $root checkout master
    if ($LASTEXITCODE -ne 0) { throw 'git checkout master failed' }
    & git -C $root merge --ff-only develop
    if ($LASTEXITCODE -ne 0) { & git -C $root checkout develop; throw 'master could not fast-forward to develop (diverged?). Resolve, then re-run -Publish.' }
    & git -C $root push origin master
    if ($LASTEXITCODE -ne 0) { & git -C $root checkout develop; throw "Pushing master was rejected - the required CI checks are likely not green yet on $tag. Wait for CI, then re-run -Publish." }
    & git -C $root tag -a $tag -m "netscoot $Version"
    & git -C $root push origin $tag
    & gh release create $tag --title "netscoot $Version" --generate-notes
    & git -C $root checkout develop
    Write-Host "Released $tag from master; back on develop." -ForegroundColor Green
}

function Invoke-PublishTask {
    # Assemble the SINGLE bundled netscoot package and publish it to the PowerShell Gallery. The
    # shipped package is one module folder: the umbrella at the root, with Shared + each engine as
    # subfolders the umbrella's RootModule loads (-Global; native only on Windows, best-effort). No
    # separate Shared/Core/Unity/Native packages. Without -ApiKey this only stages + validates.
    $stage = Join-Path ([System.IO.Path]::GetTempPath()) ("netscoot_pkg_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $pkg = Join-Path $stage 'Netscoot'
    New-Item -ItemType Directory -Path $pkg -Force | Out-Null

    # Remove the staging dir on every exit path (success, dry run, smoke-import failure, network
    # error during Publish-Module) so $env:TEMP doesn't accumulate one netscoot_pkg_* per publish.
    try {
        # Umbrella files (manifest + RootModule) at the package root...
        Copy-Item -Path (Join-Path $root (Join-Path 'src' (Join-Path 'Netscoot' '*'))) -Destination $pkg -Recurse -Force
        # ...then Shared + the engines as subfolders the umbrella loads.
        foreach ($name in 'NetscootShared', 'Netscoot.Core', 'Netscoot.Unity', 'Netscoot.Native') {
            Copy-Item -Path (Join-Path $root (Join-Path 'src' $name)) -Destination (Join-Path $pkg $name) -Recurse -Force
        }

        $manifest = Join-Path $pkg 'Netscoot.psd1'
        Write-Host "Validating bundled manifest: $manifest" -ForegroundColor Cyan
        $null = Test-ModuleManifest -Path $manifest

        # Smoke-import in a clean child pwsh to prove the single package self-loads with no separate
        # modules on the path (this is what catches missing-bundle / load-order bugs).
        Write-Host 'Smoke-importing the bundled package in a clean session...' -ForegroundColor Cyan
        & pwsh -NoProfile -Command "Import-Module '$manifest' -Force; if (-not (Get-Command Invoke-Netscoot -ErrorAction SilentlyContinue)) { throw 'Invoke-Netscoot was not surfaced by the bundled package.' }; 'bundled import OK'"
        if ($LASTEXITCODE -ne 0) { throw 'The bundled package failed to import in a clean session.' }

        Write-Host "Staged single package at: $pkg" -ForegroundColor Green
        if (-not $ApiKey) {
            Write-Host 'No -ApiKey given: staged + validated only (dry run). Re-run with -ApiKey to publish.' -ForegroundColor Yellow
            return
        }

        # Capture the versions already listed on the Gallery BEFORE publishing, so we know exactly
        # which ones to unlist afterward (everything that existed before this publish). Captured up
        # front to avoid any post-publish indexing lag on the new version.
        $priorVersions = @()
        if (-not $KeepOldVersions) {
            $priorVersions = @(Find-Module -Name Netscoot -AllVersions -Repository PSGallery -ErrorAction SilentlyContinue |
                    ForEach-Object { "$($_.Version)" })
        }

        Publish-Module -Path $pkg -NuGetApiKey $ApiKey -Repository PSGallery
        Write-Host 'Published netscoot to the PowerShell Gallery.' -ForegroundColor Green

        # Unlist every prior version (default; -KeepOldVersions opts out) so only the just-published
        # one is listed. Unlist != delete: the Gallery never hard-deletes, so an existing dependent
        # pinned to an old version still resolves it by explicit -RequiredVersion; the version just
        # stops appearing in search and in an un-versioned Install-Module. Done via the NuGet v2
        # DELETE-is-unlist endpoint (Publish-Module has no unlist verb). Per-version and tolerant:
        # one failure warns and the rest proceed, so a transient error never aborts the release.
        if (-not $KeepOldVersions) {
            $toUnlist = @($priorVersions | Where-Object { $_ -and $_ -ne $Version })
            if ($toUnlist.Count) {
                Write-Host "Unlisting $($toUnlist.Count) prior version(s) so only $Version is listed..." -ForegroundColor Cyan
                foreach ($v in $toUnlist) {
                    $uri = "https://www.powershellgallery.com/api/v2/package/Netscoot/$v"
                    try {
                        Invoke-RestMethod -Method Delete -Uri $uri -Headers @{ 'X-NuGet-ApiKey' = $ApiKey } -ErrorAction Stop | Out-Null
                        Write-Host "  unlisted Netscoot $v" -ForegroundColor DarkGray
                    } catch {
                        Write-Warning "Could not unlist Netscoot ${v}: $($_.Exception.Message). Unlist it by hand on the Gallery if needed."
                    }
                }
            } else {
                Write-Host 'No prior listed versions to unlist.' -ForegroundColor DarkGray
            }
        } else {
            Write-Host 'Kept all prior versions listed (-KeepOldVersions).' -ForegroundColor DarkGray
        }
    } finally {
        if (Test-Path -LiteralPath $stage) {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

switch ($Task) {
    'Test' { Invoke-TestTask }
    'Analyze' { Invoke-AnalyzeTask }
    'Install' { Invoke-InstallTask }
    'Docs' { Invoke-DocsTask }
    'CheckDocs' { Assert-DocsNotStale }
    'Release' { Invoke-ReleaseTask }
    'Publish' { Invoke-PublishTask }
}
