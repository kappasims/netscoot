# Contributing to netscoot

This covers building netscoot from a clone, running the test suite, cutting a release, and the
module layout. For installing and using netscoot, see the [README](README.md).

## Building

```powershell
./build.ps1                          # run the Pester suite (imports all modules first); CI-friendly exit code
./build.ps1 -Task Analyze            # PSScriptAnalyzer over src/ (skipped if not installed)
./build.ps1 -Task Install            # copy all modules into the per-user PowerShell module path
./build.ps1 -Task Install -InstallPath D:\Modules
./build.ps1 -Task Docs               # regenerate the README Command reference section from the cmdlets' help
./build.ps1 -Task Release -Version 1.2.0           # prepare on develop: stamp manifests, gate on analyze + tests, commit + push
./build.ps1 -Task Release -Version 1.2.0 -Publish  # finalize (after CI green): fast-forward master, tag vX.Y.Z, GitHub release
./build.ps1 -Task Publish                          # stage + validate the single bundled package (dry run)
./build.ps1 -Task Publish -ApiKey <key>            # publish that one netscoot package to the PowerShell Gallery
```

Building and testing needs PowerShell 7+ (or Windows PowerShell 5.1), the .NET SDK (the suite
creates and builds real projects), git, and Pester 5. `-Task Test` prints the install command for
Pester if it is missing; nothing here auto-installs.

`Install` copies every module (Shared, the engines, and the `netscoot` umbrella) to your module
path. Once it is on `$env:PSModulePath`, `Import-Module Netscoot` loads Shared and every
available engine in one call (native on Windows only).

Per-push CI (`.github/workflows/ci.yml`) runs the suite on windows-latest (PowerShell 7) and
Windows PowerShell 5.1, plus lint. Linux and macOS are on-demand (`platforms.yml`, via
`tools/Invoke-PlatformCI.ps1`); run them before a release.

## Releasing

Releases ship from `master`, which is branch-protected: the CI checks are required and enforced
even for admins, so `master` only ever receives a commit that already passed CI. The release is
therefore prepared on `develop` and `master` is fast-forwarded to it. Run both from `develop`:

1. **Prepare:** `./build.ps1 -Task Release -Version X.Y.Z`. From a clean `develop`, it stamps the
   version into every manifest, gates on PSScriptAnalyzer (required + clean) and the full suite,
   then commits `release: vX.Y.Z` and pushes `develop` so CI runs on that exact commit.
2. **Wait for green on all platforms:** `ci.yml` (Windows, Windows PowerShell 5.1, PSScriptAnalyzer)
   runs on the push; run `platforms.yml` for Linux and macOS (`tools/Invoke-PlatformCI.ps1`).
3. **Finalize:** `./build.ps1 -Task Release -Version X.Y.Z -Publish`. It fast-forwards `master` to
   that commit (the protected push is accepted only because the checks passed on it), tags, pushes,
   creates the GitHub release, and returns you to `develop`. `master` is protected and rejects any
   commit whose CI checks are not green (admins included), so a tag can only ever sit on a
   CI-passed commit, with `ModuleVersion` in every manifest equal to it.

The PowerShell Gallery is a separate step: `./build.ps1 -Task Publish -ApiKey <key>` assembles and
publishes the single bundled package (a dry run without `-ApiKey`).

## Two release cadences

netscoot ships two independently-versioned artifacts. A change goes through the cadence that matches
what it touches - never both unless it changes both:

- **The module** (`src/`) - the PowerShell engines that ship as the bundled Gallery package. Cut a
  module release (above) only when `src/` actually changes. `-Task Release` enforces this: it refuses
  a bump with no `src/` change since the last tag (override with `-AllowEmptyModuleRelease` only for a
  deliberate parity bump). This is what stopped the module-identical churn that used to ride along on
  doc and skill edits.
- **The plugin** (`.claude-plugin/` + the skills in `.claude/skills/`) - the AI-agent skills. They
  reach users via `/plugin update`, gated on the `version` in `.claude-plugin/plugin.json`, which is
  versioned independently of the module. The marketplace tracks the repository's default branch
  (`develop`), so a skill or plugin fix ships with **no module release and no `master` involvement**:

  1. Make the change and bump `version` in `.claude-plugin/plugin.json`.
  2. Commit and push `develop`. Once it is on `develop`, `/plugin update netscoot` picks it up.

  No manifest stamp, no Gallery publish, no `master` fast-forward, no full module gate. (`master` is
  only for module releases - the Gallery package and its tag.) Build/CI tooling and standalone docs
  ride along the same way: they land on `develop` and need no module version bump.

## Modules

Split by platform so the cross-platform core never ships native, Windows-only code. It ships as
one bundled Gallery package: the engines declare no `RequiredModules`; the `netscoot` umbrella
loads Shared first, then each available engine, with `-Global` so all their commands surface
together.

- `NetscootShared`: cross-platform path/git/MSBuild/solution helpers used by the engines. Not
  imported directly. The umbrella owns and re-exports its cmdlets, so the canonical public-surface
  query is the natural one: `Get-Command -Module Netscoot` returns exactly the 31 public cmdlets.
  **Naming asymmetry, still on purpose**: the public engines all use `Netscoot.<X>` while the
  internal helpers module is `NetscootShared` (no dot), so the literal-dot wildcard
  `Get-Command -Module Netscoot.*` also returns just the public surface and never the 58 internal
  helpers. Avoid the trailing-star `Get-Command -Module Netscoot*` (no literal dot): the `*` matches
  the missing dot, so it over-matches `NetscootShared` and the per-engine duplicates. Pick the right
  query: `-Module Netscoot` (or `Netscoot.*`) for the public surface, `-Module NetscootShared` to
  opt in to plumbing.
- `Netscoot.Core`: cross-platform (PowerShell 7 and Windows PowerShell 5.1). The .NET and
  PowerShell engines, the `Invoke-Netscoot` dispatcher, and the utilities.
- `Netscoot.Unity`: cross-platform Unity engine.
- `Netscoot.Native`: Windows-only native C++ engine (loaded best-effort; absent elsewhere).
- `netscoot`: the umbrella package (what you `Import-Module`).

## Path-style convention in outputs

Move-result objects (`Netscoot.MoveResult`, `Netscoot.TreeMoveResult`, etc.) carry **absolute**
`Source`/`Destination` because those record the actual on-disk locations the move acted on - a
result emitted from a script run in one directory still names the right paths when consumed later
from a different working directory. Every other surface (verbose plan output via `-Verbose`,
inventory rows, repair reports, `Find-PathReference` rows) uses **repository-relative** paths so
the human-facing read of "where in this repo" stays short and stable across machines. Pick whichever
matches the consumer: scripts that need to re-locate the moved file use the absolute fields;
humans/agents looking at a working tree read the relative ones. The asymmetry is deliberate.

## Layout

```text
build.ps1                Test / Analyze / Install / Docs / Release / Publish tasks
.github/workflows/      ci.yml (push: Windows + PS 5.1 + lint); platforms.yml (on-demand: Linux + macOS)
src/NetscootShared/   shared helpers module (Common/ + Dotnet/); loaded by the umbrella first
src/Netscoot/          umbrella module (loads Shared + every available engine)
src/Netscoot.Core/     cross-platform module; Private/ = helpers, Public/ = cmdlets
src/Netscoot.Native/   Windows-only native module
src/Netscoot.Unity/    cross-platform Unity module
tests/                   Pester tests + fixtures
.claude/skills/          restructure-dotnet / -powershell / -unity / -native
```
