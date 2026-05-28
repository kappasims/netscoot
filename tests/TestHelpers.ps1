# Shared test fixtures. `dotnet new classlib/console` dominates suite time (template engine +
# restore, ~1-2s each), so these write the equivalent minimal SDK projects as text instantly.
# They build and behave identically for `dotnet sln add` / `dotnet add reference` / `dotnet build`.
# Mirrors `dotnet new <tmpl> -n <Name> -o <Directory>`: creates <Directory>/<Name>.csproj and
# returns that path.

# The engine modules declare Netscoot.Shared in RequiredModules; load it (by path) up front so a
# test that imports an engine from src can resolve that dependency. Dot-source this helper before
# importing any engine module.
Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'src', 'Netscoot.Shared', 'Netscoot.Shared.psd1')) -Force -Global

# Per-process list of throwaway directories to remove when the pwsh process exits, so a test session
# doesn't leave its fixture-template cache and journal-home behind in $env:TEMP. Pester scopes its
# BeforeAll per file (re-dot-sourcing this helper), so we anchor the list and the engine-exit
# subscription in the global scope and gate registration on whether the global already exists.
if (-not (Test-Path Variable:Global:NetscootTestCleanup)) {
    $global:NetscootTestCleanup = [System.Collections.Generic.List[string]]::new()
    Register-EngineEvent PowerShell.Exiting -SupportEvent -Action {
        foreach ($p in $global:NetscootTestCleanup) {
            if ($p -and (Test-Path -LiteralPath $p)) {
                Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } | Out-Null
}

function New-TempRoot {
    # Create a throwaway temp directory and return its CANONICAL path. On macOS the temp root
    # /var/folders/... is a symlink to /private/var/folders/...; if a fixture used the /var form,
    # git and `dotnet sln` (which canonicalize) would store cross-boundary relative paths and the
    # reconciliation would mismatch. Resolving it up front keeps every path in one form. Every
    # test temp root (and journal-home + fixture-template-root) goes through this so the contract is
    # enforced in one place. The returned path is also registered for session-end cleanup, so a
    # crashed test or a finally that only did Pop-Location doesn't leave behind a temp dir.
    param([string]$Prefix = 'netscoot')
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ($Prefix + '_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $d | Out-Null
    if (($PSVersionTable.PSEdition -eq 'Core') -and -not $IsWindows) {
        $real = (& realpath $d 2>$null)
        if ($LASTEXITCODE -eq 0 -and $real) { $d = ("$real").Trim() }
    }
    [void]$global:NetscootTestCleanup.Add($d)
    return $d
}

# Redirect the per-user undo journal to a throwaway temp dir for the whole test session, so moves in
# the suite never write into the real LocalAppData/Application Support store. Each test file
# dot-sources this; set it once, through New-TempRoot so macOS canonicalization applies.
if (-not $env:NETSCOOT_JOURNAL_HOME) {
    # New-TempRoot registers the dir for session-end cleanup; a developer's persistently-set
    # NETSCOOT_JOURNAL_HOME is left alone (we never enter this branch in that case).
    $env:NETSCOOT_JOURNAL_HOME = New-TempRoot -Prefix 'dnm-jhome'
}

# Fixtures `git init` + `git commit` a starting state. A bare CI runner has no git identity, so the
# commit fails with "empty ident name" - the move still works (git mv stages the index), but the
# output is noisy and any fixture relying on a real HEAD runs degraded. Set an identity for the test
# process via GIT_* env vars (authoritative, bypasses the config requirement) without mutating the
# machine's global git config. Only fill what is unset, so a developer's real identity is respected.
foreach ($kv in @(
        @('GIT_AUTHOR_NAME', 'netscoot tests'), @('GIT_AUTHOR_EMAIL', 'tests@netscoot.invalid'),
        @('GIT_COMMITTER_NAME', 'netscoot tests'), @('GIT_COMMITTER_EMAIL', 'tests@netscoot.invalid'))) {
    if (-not [Environment]::GetEnvironmentVariable($kv[0])) { Set-Item -Path "Env:$($kv[0])" -Value $kv[1] }
}

function New-StubClassLib {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Directory)
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $csproj = Join-Path $Directory "$Name.csproj"
    Set-Content -LiteralPath $csproj -Encoding UTF8 -Value @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
  </PropertyGroup>
</Project>
'@
    Set-Content -LiteralPath (Join-Path $Directory 'Class1.cs') -Encoding UTF8 -Value "namespace $Name { public class Class1 { } }"
    return $csproj
}

function New-StubConsole {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Directory)
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $csproj = Join-Path $Directory "$Name.csproj"
    Set-Content -LiteralPath $csproj -Encoding UTF8 -Value @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
  </PropertyGroup>
</Project>
'@
    Set-Content -LiteralPath (Join-Path $Directory 'Program.cs') -Encoding UTF8 -Value 'System.Console.WriteLine("ok");'
    return $csproj
}

# `dotnet new sln` + `dotnet sln add` + `dotnet add reference` cost ~1-2s of CLI startup EACH, and a
# fixture runs several of them; multiplied across the suite that is the dominant test cost. The trees
# they build are deterministic and `dotnet sln`/git store only repo-relative paths, so a fixture
# copied to a fresh temp root is byte-for-byte valid with no rewriting. Copy-FixtureTemplate builds a
# given shape exactly ONCE per session (lazily, the first time a Key is requested), keeps that as an
# immutable template, then hands every caller a fast directory COPY in its own throwaway root. The
# template is parked in its own session dir so per-test `Remove-Item $root` never touches it. This
# keeps each test fully independent (its own working tree + .git), so it is safe under CI sharding.

$script:FixtureTemplateRoot = New-TempRoot -Prefix 'dnm-fixtpl'
$script:FixtureTemplates = @{}

function Copy-Directory {
    # Fast, faithful recursive copy. robocopy (Windows) is dramatically quicker than Copy-Item for a
    # tree of small files; elsewhere fall back to Copy-Item. Both copy the whole subtree (incl. .git).
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        # /E all subdirs incl. empty, /NFL /NDL /NJH /NJS /NP quiet, /R:0 /W:0 no retries.
        & robocopy $Source $Destination /E /NFL /NDL /NJH /NJS /NP /R:0 /W:0 | Out-Null
        # robocopy exit codes 0-7 are success (8+ is failure); normalise so callers see no error.
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE) copying $Source -> $Destination" }
        $global:LASTEXITCODE = 0
    } else {
        # Linux/macOS: enumerate the top-level entries (Get-ChildItem -Force includes .git and other
        # dotfiles the fixtures depend on) and copy each into $Destination. Avoids the bug where
        # Copy-Item -LiteralPath "$Source/*" treats the wildcard literally and throws ItemNotFound.
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        foreach ($entry in (Get-ChildItem -LiteralPath $Source -Force)) {
            Copy-Item -LiteralPath $entry.FullName -Destination $Destination -Recurse -Force
        }
    }
}

function Copy-FixtureTemplate {
    # Return a fresh, independent copy of the fixture identified by -Key, building it once via -Build.
    # -Build is a scriptblock that creates the fixture and returns its repo-root path (the same
    # contract the old New-*Fixture bodies already had); it runs at most once per Key per session.
    # -Prefix names the per-test temp root.
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][scriptblock]$Build,
        [string]$Prefix = 'netscoot'
    )
    if (-not $script:FixtureTemplates.ContainsKey($Key)) {
        $built = & $Build
        $tpl = Join-Path $script:FixtureTemplateRoot $Key
        Copy-Directory -Source $built -Destination $tpl
        Remove-Item -LiteralPath $built -Recurse -Force -ErrorAction SilentlyContinue
        $script:FixtureTemplates[$Key] = $tpl
    }
    $dest = New-TempRoot -Prefix $Prefix
    Copy-Directory -Source $script:FixtureTemplates[$Key] -Destination $dest
    return $dest
}
