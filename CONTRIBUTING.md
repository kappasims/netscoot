# Contributing to netscoot

This covers building netscoot from a clone, running the test suite, cutting a release, and the
module layout. For installing and using netscoot, see the [README](README.md).

## Building

```powershell
./build.ps1                          # run the Pester suite (imports all modules first), CI-friendly exit code
./build.ps1 -Fast                    # skip the 'Integration'-tagged tests that build fixtures on disk
./build.ps1 -Task Analyze            # PSScriptAnalyzer over src/ (skipped if not installed)
./build.ps1 -Task Install            # copy all modules into the per-user PowerShell module path
./build.ps1 -Task Install -InstallPath D:\Modules
./build.ps1 -Task Docs               # regenerate the README Command reference section from the cmdlets' help
./build.ps1 -Task CheckDocs          # fail if the generated reference or the plugin version is stale
./build.ps1 -Task Release -Version 1.2.0                    # from develop: stable release, end to end
./build.ps1 -Task Release -Version 3.0.0 -Prerelease beta5  # from 3.0-beta: prerelease, end to end
./build.ps1 -Task Publish                                   # stage + validate the single bundled package (dry run)
```

Building and testing needs PowerShell 7+ (or Windows PowerShell 5.1), the .NET 10 SDK (the suite
creates and builds real projects), git, and Pester 5.7.1. `-Task Test` prints the install command for
Pester if it is missing, and nothing here auto-installs. `-Task Docs`, `-Task CheckDocs`,
`-Task Release` and `-Task Publish` need PowerShell 7. `-Task Release` also needs the GitHub CLI
(`gh`), signed in. CI pins PSScriptAnalyzer to 1.25.0, so install that version for a matching local
`-Task Analyze`:

```powershell
Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser
```

To run one test file, or to run the suite under Windows PowerShell 5.1:

```powershell
Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester ./tests/Move-Solution.Tests.ps1
powershell -NoProfile -File ./build.ps1
```

A test that builds fixtures in a temp directory is an integration test. Its `Describe` carries
`-Tag 'Integration'`, so `-Fast` skips it. Tests that run entirely in memory stay untagged. Three
untagged tests gate every run, `-Fast` included: `UmbrellaSurface.Tests.ps1` checks that every public
engine export is in the umbrella's `FunctionsToExport`, `SkillCoverage.Tests.ps1` checks that every
exported cmdlet appears in a `src/skills/*/SKILL.md`, and `SkillFrontmatter.Tests.ps1` checks that
every skill description is a folded block scalar, so the YAML always parses.

`Install` copies every module (Shared, the engines, and the `netscoot` umbrella) to your module
path. Once it is on `$env:PSModulePath`, `Import-Module Netscoot` loads Shared and every
available engine in one call (native on Windows only).

Per-push CI (`.github/workflows/ci.yml`) runs the suite on windows-latest (PowerShell 7) and
Windows PowerShell 5.1, plus PSScriptAnalyzer and CheckDocs. `markdownlint.yml` lints the Markdown.
Linux and macOS run automatically on a `release: vX.Y.Z` commit. For an ad-hoc Linux and macOS run
on any branch, use `tools/Invoke-PlatformCI.ps1` (`platforms.yml`).

## Coding conventions

- A mutating `git` or `dotnet` call in `src/` goes through `Invoke-Git` or `Invoke-Dotnet`, never a
  bare `& git` or `& dotnet`. Windows PowerShell 5.1 turns any native stderr into a terminating error
  under `$ErrorActionPreference = 'Stop'`, and the wrappers guard against it.
- A test's temp directory comes from `New-TempRoot -Prefix '<name>'` (`tests/TestHelpers.ps1`),
  never a raw `GetTempPath()`. It canonicalizes the path on macOS, where `dotnet sln add` would
  otherwise store an absolute path.
- One named test per case, never `-ForEach` or `-TestCases`.

## Releasing

Releases ship from `master`, which is branch-protected: its required CI checks are enforced even
for admins, so `master` only ever receives a commit that already passed CI. The release is
therefore prepared on `develop` and `master` is fast-forwarded to it. From a clean `develop`,
`./build.ps1 -Task Release -Version X.Y.Z` does the whole release in one run:

1. **Prepare:** it checks the docs and that `CHANGELOG.md` has a `## [X.Y.Z]` entry, stamps the
   version into every manifest, commits `release: vX.Y.Z` and pushes `develop`.
2. **Wait:** every workflow run on that commit must pass, including the Linux and macOS jobs that
   `ci.yml` runs only on a release commit. The analyzer and the tests run there, not locally.
3. **Tag:** it fast-forwards `master` to the release commit (the protected push is accepted only
   because the checks passed on it), tags it, creates the GitHub release, and returns you to
   `develop`.
4. **Publish:** the tag push starts `publish.yml`, which publishes the single bundled package to
   the PowerShell Gallery. The command waits for it and reports the result.

If CI fails, fix it on `develop`, commit, and run the same command again. It commits a fresh
release commit on top and carries on from there.

A prerelease runs the same way from its own branch (for example `3.0-beta`) with
`-Prerelease <label>`. It tags that branch, marks the GitHub release as a prerelease, and never
touches `master`.

`publish.yml` reads the Gallery API key from the `PSGALLERY_API_KEY` secret of the `gallery`
environment. Give the key the "Push only new package versions" and "Unlist package" scopes, limited
to the `Netscoot` package, and limit the environment's deployments to `v*` tags. A prerelease, or
a version below one already on the Gallery (a 2.x patch while a 3.0 beta is listed), keeps every
other version listed. Otherwise the publish unlists the older ones.
`./build.ps1 -Task Publish -ApiKey <key>` still publishes by hand from PowerShell 7.

## The Claude Code plugin

The plugin is the `src/` folder: the module folders, the skills in `src/skills/`, and
`src/.claude-plugin/plugin.json` with its icon. Each skill loads
`${CLAUDE_PLUGIN_ROOT}/Netscoot/Netscoot.psd1`, the module from the same commit, so the skills and the
code they describe never drift apart. Build and CI tooling, tests and docs stay outside `src/`, so
they are not part of the plugin. The marketplace file at the repository root lists the plugin as
`./src`, which resolves on the branch the marketplace was added from. `master` is the default branch,
so `/plugin marketplace add kappasims/netscoot` gives users only released code, and
`kappasims/netscoot#3.0-beta` gives the beta. A release stamps the release version into `plugin.json`
alongside the manifests. A skill change therefore reaches users with the next release,
and `-Task Release` counts a skill change as a reason to release. `-Task CheckDocs` fails when the
plugin version differs from the module version.

To try skill changes before a release, start Claude Code with the clone's `src/` loaded as a plugin.
Its skills then load your working tree's module:

```bash
claude --plugin-dir path/to/netscoot/src
```

Build and CI tooling and standalone docs land on `develop` and need no release.

## Modules

Split by platform so the cross-platform core never ships native, Windows-only code. It ships as
one bundled Gallery package. The engines declare no `RequiredModules`. The `netscoot` umbrella loads
Shared `-Global` first, because the engines resolve its helpers at runtime, then imports each
available engine as a nested module and re-exports its cmdlets.

- `NetscootShared`: cross-platform path/git/MSBuild/solution helpers used by the engines. Not
  imported directly. `Get-Command -Module Netscoot` lists the public cmdlets, and
  `Get-Command -Module NetscootShared` lists the internal helpers.
- `Netscoot.Core`: cross-platform (PowerShell 7 and Windows PowerShell 5.1). The .NET and
  PowerShell engines, the `Invoke-Netscoot` dispatcher, and the utilities.
- `Netscoot.Unity`: cross-platform Unity engine.
- `Netscoot.Native`: Windows-only native C++ engine (loaded best-effort, absent elsewhere).
- `netscoot`: the umbrella package (what you `Import-Module`).

## Path-style convention in outputs

Move-result objects (`Netscoot.MoveResult`, `Netscoot.TreeMoveResult`, etc.) carry **absolute**
`Source`/`Destination` because those record the actual on-disk locations the move acted on. A
result emitted from a script run in one directory still names the right paths when consumed later
from a different working directory. Every other surface (verbose plan output via `-Verbose`,
inventory rows, repair reports, `Find-PathReference` rows) uses **repository-relative** paths so
the human-facing read of "where in this repository" stays short and stable across machines. Pick
whichever matches the consumer. Scripts that need to re-locate the moved file use the absolute
fields, and humans or agents looking at a working tree read the relative ones.

## Layout

```text
build.ps1                Test / Analyze / Install / Docs / CheckDocs / Release / Publish tasks
.github/workflows/       ci.yml (tests, PSScriptAnalyzer, CheckDocs), markdownlint.yml, publish.yml,
                         platforms.yml (ad-hoc Linux + macOS), powershell.yml (security scan)
src/NetscootShared/      shared helpers module (Common/ + Dotnet/), loaded by the umbrella first
src/Netscoot/            umbrella module (loads Shared + every available engine)
src/Netscoot.Core/       cross-platform module: Private/ = helpers, Public/ = cmdlets
src/Netscoot.Native/     Windows-only native module
src/Netscoot.Unity/      cross-platform Unity module
src/skills/              restructure-dotnet / -powershell / -unity / -native, netscoot-analyze, netscoot-manage
src/.claude-plugin/      plugin.json and icon.svg: src/ is the Claude Code plugin
.claude-plugin/          marketplace.json, which lists the plugin
docs/                    data for the generated reference (categories, output types, dispatch diagrams)
tools/                   the reference generator, and ad-hoc CI and UX tools
tests/                   Pester tests + fixtures
```
