# Summary

DotnetMove moves a .NET project folder and fixes everything the move would otherwise break: the
solution file, the references that point at it, and the GUID wiring. Visual Studio does that for you
when you drag a project in its GUI; DotnetMove does it from the command line, everywhere Visual
Studio is not, including VS Code, Rider, CI, Linux, macOS, and AI coding agents.

> **Not a Microsoft product.** DotnetMove is an independent, community-maintained tool. It is **not
> affiliated with, sponsored by, or endorsed by Microsoft**. ".NET", "dotnet", and related names are
> trademarks of Microsoft Corporation, used here only to describe the .NET projects and tooling this
> works with.

```powershell
# moves the files and fixes the .sln, references, and GUIDs
Move-Dotnet -Path ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon

# the same move as a git verb (not a plain git mv); --whatif previews it
git dotnetmv src/Tarragon/Tarragon.csproj libs/Tarragon --whatif
```

Each format is reconciled by the tool that owns it where one exists (the dotnet CLI, git mv,
Update-ModuleManifest), and by a targeted in-place rewrite where none does (a solution's stored
paths, MSBuild `<Import>`s, a script's dot-source/call references). Beyond managed .NET this reaches
PowerShell modules and scripts, Unity `.meta` GUIDs, and native C++ `.vcxproj` projects, reporting
the link settings it cannot safely rewrite rather than guessing at them.

For AI agents, the repository ships Claude Code skills that run these commands, triggering on phrases
like "move this project" (see [Skills](#skills)).

# Setup

## Requirements

- PowerShell 7+ (Windows, Linux, macOS), or Windows PowerShell 5.1.
- The .NET SDK (`dotnet`) on PATH for .NET project moves; the .NET 9 SDK or later for `.slnx`
  solutions. Moving PowerShell or Unity files does not need it.
- git is optional: with it, moves use `git mv` (history kept); without it, `-Force` does a plain
  `Move-Item` (no history). `Get-DotnetMoveCapability` reports what the machine has.

## Footprint

Everything DotnetMove creates or changes, so there are no surprises:

**Installing** (the installer or `./build.ps1 -Task Install`):

- Copies the module folders to your CurrentUser module path: `~/Documents/PowerShell/Modules`
  (or `WindowsPowerShell` for 5.1) on Windows, `~/.local/share/powershell/Modules` elsewhere, or a
  `-InstallPath` you choose (which you add to `$env:PSModulePath` yourself). That default path is
  already on `$env:PSModulePath`; nothing else on the environment is touched.
- Downloads the release zip to the system temp dir, extracts it, and deletes it when done. Install
  and update are the only things that reach the network (`api.github.com` / `github.com`).

**Running a move:**

- Edits the target repository's solution/project files to reconcile the move. That is the operation
  itself, done through first-party tooling (see [the Contract](#the-contract)).
- Writes an undo journal inside the git directory (`.git/dotnetmove/journal.jsonl`), so it is never
  tracked, never shown by `git status`, and needs no `.gitignore`. With no git it falls back to the
  system temp dir, keyed by the repository root. On by default; see [Undoing](#undoing) to opt out.
- Snapshots the files it edits to the system temp dir for rollback, and removes the snapshot when
  the move finishes (success or failure). Never written into the repository.

**Only when you ask:**

- `Register-DotnetMvGitAlias` adds one `alias.dotnetmv` line to your git config (repository-local, or
  `~/.gitconfig` with `-Scope Global`); `Unregister-DotnetMvGitAlias` removes it.
- `install.ps1 -NoJournal` turns the undo journal off persistently (`git config --global
  dotnetmove.journal false` when git is present, else the `DOTNETMOVE_JOURNAL` env var).
- `Set-DotnetMoveJournal` writes the `dotnetmove.journal` git setting (repository-local, or `-Global`
  for every repository); `Clear-DotnetMoveJournal` deletes a repository's journal file.

### What it doesn't do

It never uses AppData, never edits `PATH`, never auto-installs git or the .NET SDK, and sends no
telemetry.

## Install

Install from the [PowerShell Gallery](https://www.powershellgallery.com/packages/DotnetMove):

```powershell
Install-Module DotnetMove -Scope CurrentUser
```

This installs the single bundled package (all engines). Update later with `Update-Module DotnetMove`.

Installing from GitHub instead lets you read the installer before running it, or pin a specific
release. The installer downloads a release and copies the five module folders onto your CurrentUser
module path.

**Recommended:** download [the installer](https://github.com/kappasims/dotnet-move/blob/master/install.ps1), read it, then run it.

```powershell
irm https://raw.githubusercontent.com/kappasims/dotnet-move/master/install.ps1 -OutFile install.ps1
# look it over, then:
./install.ps1
```

**No-script option:** download the latest release zip from the
[Releases page](https://github.com/kappasims/dotnet-move/releases), unzip it, and copy the
`DotnetMove.Shared`, `DotnetMove.Core`, `DotnetMove.Unity`, `DotnetMove.Native`, and `DotnetMove`
folders out of `src/` into any directory on your `$env:PSModulePath`.

Or pipe it straight in for a **YOLO install** (easiest) if you are comfortable running [the install script](https://github.com/kappasims/dotnet-move/blob/master/install.ps1) unread:

```powershell
irm https://raw.githubusercontent.com/kappasims/dotnet-move/master/install.ps1 | iex
```

Then load it, and optionally enable the git verb:

```powershell
Import-Module DotnetMove                   # all engines, by name
Register-DotnetMvGitAlias -Scope Global    # optional: enable `git dotnetmv` (one git-config line)
```

DotnetMove keeps an undo journal inside the git directory so you can reverse a move later (see [Undoing](#undoing)).
It is **on by default**. To install with it off, add `-NoJournal` (sets `git config --global
dotnetmove.journal false`, or the `DOTNETMOVE_JOURNAL` env var with no git; updates never turn it back on):

```powershell
./install.ps1 -NoJournal
```

To work on DotnetMove itself, install from a clone instead, or import directly:

```powershell
./build.ps1 -Task Install                          # copy this clone's modules to your module path
Import-Module ./src/DotnetMove/DotnetMove.psd1     # or import straight from the clone (loads Shared + all engines)
```

## Updating

Nothing updates automatically. For Gallery installs, `Update-Module DotnetMove` is the one-liner.
Otherwise `Test-DotnetMoveUpdate` checks GitHub for a newer release and `Update-DotnetMove` (or
re-running the installer) applies it in place. The Claude Code skills are separate files: refresh
them with `git pull` in a clone, or re-sync `.claude/skills` if installed globally.

# Usage

## Moving

Every move recomputes the stored paths after the files move, delegating each change to the tool
that owns the format. The commands, most general first (full per-parameter docs in the
[Reference](#reference)):

Level 1, one command for anything:

| <small>Command</small> | <small>Moves</small> |
|:---|:---|
| <small>`Move-Dotnet`</small> | <small>any supported file or folder; detects the type and routes</small> |

Level 2, the everyday movers: hand them a file or a folder and they route to the right specialist.

| <small>Command</small> | <small>Moves</small> |
|:---|:---|
| <small>`Move-DotnetFile`</small> | <small>a .NET file: `.csproj`/`.fsproj`/`.vbproj`, `.sln`/`.slnx`, `.props`/`.targets`</small> |
| <small>`Move-DotnetFolder`</small> | <small>a folder of .NET projects</small> |
| <small>`Move-PowerShell`</small> | <small>a `.ps1`, a `.psd1`, or a module folder</small> |
| <small>`Move-UnityAsset`</small> | <small>a Unity asset or folder (with its `.meta`)</small> |
| <small>`Move-NativeProject`</small> | <small>a native C++ `.vcxproj` (Windows)</small> |

Level 3, specialists, when you want one specific reconciliation:

| <small>Command</small> | <small>Moves</small> | <small>Reconciles via</small> |
|:---|:---|:---|
| <small>`Move-DotnetProject`</small> | <small>one .NET project</small> | <small>`dotnet sln add/remove`, `dotnet add/remove reference`</small> |
| <small>`Move-DotnetProjectTree`</small> | <small>many projects under a folder</small> | <small>same, for every cross-boundary reference</small> |
| <small>`Move-Solution`</small> | <small>a solution (`.sln`/`.slnx`)</small> | <small>rebases the stored project paths</small> |
| <small>`Move-MSBuildImport`</small> | <small>a shared `.props`/`.targets`</small> | <small>fixes `<Import>` paths in consumers</small> |
| <small>`Move-PowerShellScript`</small> | <small>a `.ps1`</small> | <small>rewrites dot-source/call references from the AST</small> |
| <small>`Move-PowerShellModule`</small> | <small>a module folder</small> | <small>`Update-ModuleManifest` (`RootModule`/`NestedModules`/`FileList`)</small> |

`Move-UnityAsset` moves the asset together with its `.meta`, so the GUIDs scenes and prefabs
reference are preserved (nothing to rewrite). `Directory.Build.props/.targets` and
`Directory.Packages.props` (Central Package Management) inheritance is the one thing no move can
fix, because it changes with folder depth; the move detects when the nearest inherited file
changes and reports it.

Moving a shared `.props`/`.targets` also fixes the `<Import>` path in any consuming `.vcxproj` on
every OS (path-only); a `.vcxproj`'s native link settings are reconciled only by `Move-NativeProject`
(Windows). A `Move-DotnetProject` run, step by step:

1. Enumerate the solutions, consumers, and own references of the project.
2. Remove references and solution membership while the old paths still resolve.
3. Move the directory (`git mv` if tracked, else `Move-Item`).
4. Re-add membership and references so the CLI recomputes fresh paths.
5. Build and report. If any step fails, the move rolls back to the original state.

Every move supports `-WhatIf`/`-Confirm`; `-Force` enables the no-git fallback.

## Undoing

Every move is recorded in a journal inside the git directory (`.git/dotnetmove/journal.jsonl`, or the
system temp dir with no git) so you can reverse it later, even from a fresh session. `Undo-DotnetMove` replays the recorded inverse (the same move with
source and destination swapped), re-reconciling from the current state rather than restoring a stale
snapshot. By default it reverses the most recent move; `-Id` reverses a specific entry, and `-List`
shows what is available.

A successful undo removes that entry from the journal, and the reversing move is not itself recorded,
so repeated calls walk the history backwards rather than toggling one move on and off. Reversing an
entry other than the most recent is allowed, but a later move may have built on it, so prefer reverse
order.

Undo applies to the move commands. `Sync-Solution` and `Repair-SolutionReferences` are not journaled;
both take `-WhatIf` to preview before they change anything.

```powershell
Undo-DotnetMove -List          # what can be undone (oldest first)
Undo-DotnetMove -WhatIf        # preview reversing the most recent move
Undo-DotnetMove                # reverse the most recent move and pop it; call again to walk back further
Undo-DotnetMove -Id a1b2c3d4   # reverse a specific entry (prefer reverse order; later moves may depend on it)
Undo-DotnetMove -All           # reverse every move, newest first (high-impact: prompts; -Force to skip, -WhatIf to preview)
```

`-All` walks back the entire history in one operation, so it prompts for a yes/no confirmation that
`-Confirm:$false` does not silence; pass `-Force` to bypass it (for automation) or `-WhatIf` to list
the reversals first.

The journal is **on by default** and stays out of the working tree: it lives inside `.git/`, so git
never tracks it, `git status` never shows it, and your own `.gitignore` is left untouched. With no
git it falls back to the system temp dir.

To opt out, turn it off per repository (or for every repository) with `Set-DotnetMoveJournal`, which
writes the `dotnetmove.journal` git setting:

```powershell
Set-DotnetMoveJournal -Enabled $false           # this repository only
Set-DotnetMoveJournal -Enabled $false -Global    # every repository on the machine
Clear-DotnetMoveJournal                          # also discard the existing undo history
```

The enabled state resolves in this order, first match wins: an internal suppression flag (set by
`Undo` around its own reverse move) → `git config dotnetmove.journal` (local wins over global, the
durable git setting) → the `DOTNETMOVE_JOURNAL` env var (`off`/`0`/`false`; the no-git escape hatch)
→ on. Installing with `-NoJournal` writes the global git setting (see [Install](#install)). Because
the git setting outranks the env var and rides along with your git config, installing or updating
never switches journaling back on for you.

The journal prunes itself on every write: it drops entries older than 180 days and, oldest first,
anything beyond a 1 MB cap, always keeping the newest move.

## Inspecting

DotnetMove can be used purely to inspect a repository. These commands are read-only and change nothing.

| <small>Command</small> | <small>Reports</small> |
|:---|:---|
| <small>`Test-SolutionConsistency`</small> | <small>projects with divergent solution membership across solutions</small> |
| <small>`Get-SolutionInventory`</small> | <small>full solution contents beyond `dotnet sln list` (non-CLI types like `.pssproj`, folders, items) + projects in no solution</small> |
| <small>`Find-PathReference`</small> | <small>path references in build/CI/hook scripts that no move reconciles</small> |
| <small>`Test-UnityMetaIntegrity`</small> | <small>missing or orphan Unity `.meta`</small> |
| <small>`Resolve-MoveEngine`</small> | <small>which engine a given path classifies to</small> |
| <small>`Get-DotnetMoveCapability`</small> | <small>whether git and dotnet are present, plus the platform</small> |
| <small>`Test-DotnetMoveUpdate`</small> | <small>whether a newer DotnetMove release is available on GitHub</small> |

## Repairing

It can also fix a repository whose solution entries or `<ProjectReference>`s were left dangling by a
move done outside DotnetMove, without moving anything itself. `Repair-SolutionReferences` finds
entries pointing at a project that no longer exists at the recorded path and reports each as
relocatable, missing, or ambiguous (read-only by default).

| <small>Flag</small> | <small>Does</small> |
|:---|:---|
| <small>(none)</small> | <small>report the dangling entries and whether each can be repaired</small> |
| <small>`-Fix`</small> | <small>re-point each relocatable entry at the project's new location</small> |
| <small>`-Prune`</small> | <small>remove entries whose project is gone for good</small> |

To resolve the membership divergence that `Test-SolutionConsistency` reports, `Sync-Solution` adds
each project to the solutions missing it (via `dotnet sln add`), making membership uniform. It only
adds, never removes; preview with `-WhatIf` first.

# Interfaces

## PowerShell usage

```powershell
Import-Module DotnetMove   # all engines (native is loaded on Windows only)

# Top-level dispatcher; works for any supported type:
Move-Dotnet -Path ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon -WhatIf
Move-Dotnet -Path ./build/helpers.ps1 -Destination ./shared/helpers.ps1
Move-Dotnet -Path ./Assets/Plugins/Tarragon -Destination ./Assets/Lib/Tarragon

# Or call an engine command directly:
Move-DotnetProject     -Project ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon
Move-DotnetProjectTree -Path ./src/Group -Destination ./libs/Group
Move-Solution          -Path ./Demo.slnx -Destination ./build/Demo.slnx
Move-MSBuildImport     -Path ./Shared.props -Destination ./build/Shared.props
Move-PowerShell        -Path ./tools/Mayo -Destination ./modules/Mayo
Move-NativeProject     -Project ./Aleppo/Aleppo.vcxproj -Destination ./native/Aleppo   # Windows

# Validate without moving:
Repair-SolutionReferences -RepoRoot . -Fix -WhatIf
Test-SolutionConsistency  -RepoRoot .
```

## git usage

An opt-in alias gives `git dotnetmv`, a single verb that forwards to `Move-Dotnet`. It sets one
reversible git-config line and does not edit PATH or install anything.

```powershell
Register-DotnetMvGitAlias -Scope Local -WhatIf   # preview the exact git config command
Register-DotnetMvGitAlias -Scope Local           # set it
Unregister-DotnetMvGitAlias -Scope Local         # undo
```

```sh
git dotnetmv src/Tarragon/Tarragon.csproj libs/Tarragon --whatif   # dry run
git dotnetmv src/Tarragon/Tarragon.csproj libs/Tarragon            # do it (like git mv, no prompt)
git dotnetmv Assets/Plugins/Tarragon Assets/Lib/Tarragon      # routes to the Unity engine
git dotnetmv Aleppo/Aleppo.vcxproj native/Aleppo          # routes to the native engine (Windows)
```

Flags: `--whatif` (preview), `--force` (plain `Move-Item` fallback when git is unavailable),
`--nobuild` (skip the .NET build step). Unity and native engines are loaded on demand.

## Skills

Four Claude Code skills (`.claude/skills/`), one per engine, trigger on natural language and run
the commands above:

| <small>Skill</small> | <small>Triggers on</small> |
|:---|:---|
| <small>`restructure-dotnet`</small> | <small>moving a `.csproj/.fsproj/.vbproj`, reorganizing a solution</small> |
| <small>`restructure-powershell`</small> | <small>moving a `.ps1` script or a PowerShell module</small> |
| <small>`restructure-unity`</small> | <small>moving a Unity asset, folder, or `.asmdef`</small> |
| <small>`restructure-native`</small> | <small>moving a native C++ `.vcxproj` (Windows)</small> |

# For developers

## The Contract

Every move upholds these guarantees:

1. **No hand-written solution or project files.** Every path/GUID change is delegated to
   first-party tooling:
   - `dotnet sln add/remove` and `dotnet add/remove reference` for solution membership and references
   - `git mv` for the move itself (a plain `Move-Item` only under `-Force`, when git is absent)
   - `Update-ModuleManifest` for PowerShell module manifests
2. **No direct file writes, except as provided in this clause.** As the sole exception to §1, formats
   that no first-party tool reconciles are rewritten in place through the BOM-preserving `Set-Raw*`
   helpers, limited to:
   - a solution's stored project paths
   - MSBuild `<Import>` paths
   - a script's dot-source/call references
3. **No speculative parsing.** Files are read through first-party readers, and parsed directly only
   where no such reader surfaces what is needed.
4. **No unverified compliance.** These guarantees are enforced, not merely promised:
   `tests/FirstPartyDrift.Tests.ps1` fails the build if a new file writes file content or a new cmdlet
   calls the raw writers.

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
./build.ps1 -Task Publish -ApiKey <key>            # publish that one DotnetMove package to the PowerShell Gallery
```

Building and testing needs PowerShell 7+ (or Windows PowerShell 5.1), the .NET SDK (the suite
creates and builds real projects), git, and Pester 5. `-Task Test` prints the install command for
Pester if it is missing; nothing here auto-installs.

`Install` copies every module (Shared, the engines, and the `DotnetMove` umbrella) to your module
path. Once it is on `$env:PSModulePath`, `Import-Module DotnetMove` loads Shared and every
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
   creates the GitHub release, and returns you to `develop`.

The requirements, restated:

- **From `master`, always** - never tag `develop`. The tooling enforces it: `master` is protected
  and rejects any commit whose CI checks are not green, admins included.
- **All three platforms green** (Windows, Linux, macOS) **plus static analysis**, before the tag.
  GitHub enforces the `ci.yml` checks; the Linux/macOS `platforms.yml` run is the manual step in 2.
- **Version equals the tag** - `ModuleVersion` in every manifest matches `vX.Y.Z`.

The PowerShell Gallery is a separate step: `./build.ps1 -Task Publish -ApiKey <key>` assembles and
publishes the single bundled package (a dry run without `-ApiKey`).

## Modules

Split by platform so the cross-platform core never ships native, Windows-only code. It ships as
one bundled Gallery package: the engines declare no `RequiredModules`; the `DotnetMove` umbrella
loads Shared first, then each available engine, with `-Global` so all their commands surface
together.

- `DotnetMove.Shared`: cross-platform path/git/MSBuild/solution helpers used by the engines. Not
  imported directly.
- `DotnetMove.Core`: cross-platform (PowerShell 7 and Windows PowerShell 5.1). The .NET and
  PowerShell engines, the `Move-Dotnet` dispatcher, and the utilities.
- `DotnetMove.Unity`: cross-platform Unity engine.
- `DotnetMove.Native`: Windows-only native C++ engine (loaded best-effort; absent elsewhere).
- `DotnetMove`: the umbrella package (what you `Import-Module`).

## Layout

```
build.ps1                Test / Analyze / Install / Docs / Release / Publish tasks
.github/workflows/      ci.yml (push: Windows + PS 5.1 + lint); platforms.yml (on-demand: Linux + macOS)
src/DotnetMove.Shared/   shared helpers module (Common/ + Dotnet/); loaded by the umbrella first
src/DotnetMove/          umbrella module (loads Shared + every available engine)
src/DotnetMove.Core/     cross-platform module; Private/ = helpers, Public/ = cmdlets
src/DotnetMove.Native/   Windows-only native module
src/DotnetMove.Unity/    cross-platform Unity module
tests/                   Pester tests + fixtures
.claude/skills/          restructure-dotnet / -powershell / -unity / -native
```

# Reference

<!-- BEGIN GENERATED REFERENCE -->
<!-- Regenerate with ./build.ps1 -Task Docs. Generated from the cmdlets' comment-based help in src/; do not hand-edit between these markers. -->

## Command reference

**.NET and PowerShell**

| <small>Command</small> | <small>What it does</small> |
|:---|:---|
| <small>[Clear-DotnetMoveJournal](#clear-dotnetmovejournal)</small> | <small>Delete a repository's move journal, discarding its undo history.</small> |
| <small>[Find-PathReference](#find-pathreference)</small> | <small>Find references to a path in non-canonical, path-hardcoding files (build/CI/hook/ container scripts) that no first-party tool reconciles.</small> |
| <small>[Get-DotnetMoveCapability](#get-dotnetmovecapability)</small> | <small>Resolve DotnetMove's external-tool capabilities (git, dotnet) and platform.</small> |
| <small>[Get-SolutionInventory](#get-solutioninventory)</small> | <small>List the full contents of every solution in a repository - projects of any type, solution folders, and solution items - plus on-disk projects that no solution references.</small> |
| <small>[Move-Dotnet](#move-dotnet)</small> | <small>Move any supported item and reconcile references, routing by detected type to the right per-namespace front door.</small> |
| <small>[Move-DotnetFile](#move-dotnetfile)</small> | <small>Move a single managed .NET file and reconcile references, routing by extension to the right specialist.</small> |
| <small>[Move-DotnetFolder](#move-dotnetfolder)</small> | <small>Move a folder of managed .NET projects, reconciling references.</small> |
| <small>[Move-DotnetProject](#move-dotnetproject)</small> | <small>Move a .NET project folder and reconcile every solution and project reference that points at it, delegating all path/GUID changes to the dotnet CLI.</small> |
| <small>[Move-DotnetProjectTree](#move-dotnetprojecttree)</small> | <small>Move a folder that contains one or more managed .NET projects, reconciling solution membership and every external project reference in one operation.</small> |
| <small>[Move-MSBuildImport](#move-msbuildimport)</small> | <small>Move a shared MSBuild .props/.targets file and fix every project (or other props/targets) that imports it via &lt;Import Project="..."&gt;.</small> |
| <small>[Move-PowerShell](#move-powershell)</small> | <small>Move a PowerShell item and reconcile references, routing by type to the right specialist.</small> |
| <small>[Move-PowerShellModule](#move-powershellmodule)</small> | <small>Move a PowerShell module folder and reconcile its manifest, delegating manifest edits to Update-ModuleManifest rather than hand-editing the .psd1.</small> |
| <small>[Move-PowerShellScript](#move-powershellscript)</small> | <small>Move a standalone .ps1 script and fix the relative paths in scripts that dot-source or call it (and the moved script's own dot-source/call paths).</small> |
| <small>[Move-Solution](#move-solution)</small> | <small>Move a solution file (.sln/.slnx) and rebase the relative project paths it stores, so every project it references still resolves from the solution's new location.</small> |
| <small>[Register-DotnetMvGitAlias](#register-dotnetmvgitalias)</small> | <small>Opt-in: register a `git dotnetmv` alias pointing at DotnetMove's forwarder.</small> |
| <small>[Repair-SolutionReferences](#repair-solutionreferences)</small> | <small>Scan a repository for broken solution membership and dangling ProjectReferences and repair them by re-pointing each entry at the project's new location.</small> |
| <small>[Resolve-MoveEngine](#resolve-moveengine)</small> | <small>Classify a path to the reconciliation engine that should move it: dotnet, native, unity, ps-script, ps-module, or unknown.</small> |
| <small>[Set-DotnetMoveJournal](#set-dotnetmovejournal)</small> | <small>Turn the move journal on or off, per repository (default) or for every repository (`-Global`).</small> |
| <small>[Sync-Solution](#sync-solution)</small> | <small>Resolve solution-membership divergence by adding each project to the solutions that are missing it, so every solution in the repository lists the same projects.</small> |
| <small>[Test-DotnetMoveUpdate](#test-dotnetmoveupdate)</small> | <small>Check GitHub for a newer DotnetMove release and report whether the installed version is behind.</small> |
| <small>[Test-SolutionConsistency](#test-solutionconsistency)</small> | <small>Report projects whose membership diverges across the solution files in a repository (present in some solutions but absent from others).</small> |
| <small>[Undo-DotnetMove](#undo-dotnetmove)</small> | <small>Reverse a previous DotnetMove move, using the journal at the repository root.</small> |
| <small>[Unregister-DotnetMvGitAlias](#unregister-dotnetmvgitalias)</small> | <small>Remove the `git dotnetmv` alias registered by Register-DotnetMvGitAlias.</small> |
| <small>[Update-DotnetMove](#update-dotnetmove)</small> | <small>Update an installed DotnetMove to the latest GitHub release, in place.</small> |

**Native C++ (Windows)**

| <small>Command</small> | <small>What it does</small> |
|:---|:---|
| <small>[Move-NativeProject](#move-nativeproject)</small> | <small>Move a native / C++/CLI project (.vcxproj).</small> |

**Unity**

| <small>Command</small> | <small>What it does</small> |
|:---|:---|
| <small>[Move-UnityAsset](#move-unityasset)</small> | <small>Move a Unity asset or folder while keeping its paired .meta file(s), so the GUIDs that scene/prefab/asmdef references depend on survive the move.</small> |
| <small>[Test-UnityMetaIntegrity](#test-unitymetaintegrity)</small> | <small>Report Unity .meta integrity problems under a root: assets missing a .meta, and orphan .meta files whose asset is gone.</small> |

---

### Clear-DotnetMoveJournal

Delete a repository's move journal, discarding its undo history.

**Syntax**

```powershell
Clear-DotnetMoveJournal [[-RepoRoot] <string>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Removes the journal file (under the git dir, .git/dotnetmove/journal.jsonl, or the temp
fallback with no git). The journal prunes itself on every write (entries older than the age
cap, then oldest-first past the size cap), so this is rarely needed; use it to wipe the undo
history outright. After clearing, Undo-DotnetMove has nothing to reverse until the next move.
It does not change whether journaling is on - use Set-DotnetMoveJournal for that.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`‑RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>Repository whose journal to delete. Defaults to the enclosing git repository root.</small> |
| <small>`‑WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`‑Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

**Output**

None.

**Examples**

```powershell
# Discard the undo history for this repository
Clear-DotnetMoveJournal

# Preview without deleting
Clear-DotnetMoveJournal -WhatIf
```

---

### Find-PathReference

Find references to a path in non-canonical, path-hardcoding files (build/CI/hook/
container scripts) that no first-party tool reconciles. report-only.

**Syntax**

```powershell
Find-PathReference [-Path] <string> [-RepoRoot <string>] [-AdditionalGlob <string[]>] [<CommonParameters>]
```

Moving a project/folder breaks any path hardcoded in build.ps1, CI YAML, git hooks,
tools scripts, Makefile/Dockerfile, etc. - and unlike .sln/.csproj/.psd1 there is no
tool that understands their schema, so they cannot be safely auto-rewritten (a blind
regex could corrupt logic). This detects the class of such files (by location + name,
not a hardcoded filename list) and reports lines that reference the given path, so you
(or an agent) can fix them deliberately. It never edits anything.

Two confidence tiers: High when the item's repository-relative path appears (e.g.
'lib/Tarragon.csproj' or 'lib\Tarragon.csproj'), Low when only the bare leaf name appears (e.g.
'Tarragon.csproj'), which is likely but not certain.

Run it before a move (to see what will break) or after (searching the old path).

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`‑Path`</small> | <small>String</small> | <small>true</small> | <small>true (ByValue, ByPropertyName)</small> | <small>The item being/that was moved. Accepts pipeline input.</small> |
| <small>`‑RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>Root to scan. Defaults to the enclosing git repository root.</small> |
| <small>`‑AdditionalGlob`</small> | <small>String[]</small> | <small>false</small> | <small>false</small> | <small>Extra repository-relative globs to include in the candidate set (e.g. 'deploy/*.sh').</small> |

**Output**

Returns zero or more [DotnetMove.PathReference](#dotnetmovepathreference), collected as an array (`$null` when none).
One per matching line.

```text
DotnetMove.PathReference
  File        string  repo-relative file containing the line
  Line        int     1-based line number
  Confidence  string  High | Low
  Text        string  the matching line
```

**Examples**

```powershell
# Build/CI/hook lines that hardcode the path (report-only)
Find-PathReference -Path ./lib/Tarragon.csproj

# Scan the old path after a move to find what still points at it
Find-PathReference -Path ./libs/Tarragon/Tarragon.csproj

# Widen the candidate set with extra repository-relative globs
Find-PathReference -Path ./lib/Tarragon.csproj -AdditionalGlob 'deploy/*.sh','*.psake.ps1'
```

---

### Get-DotnetMoveCapability

Resolve DotnetMove's external-tool capabilities (git, dotnet) and platform. This is the
canonical "what can I do here" probe - DotnetMove does not auto-install anything.

**Syntax**

```powershell
Get-DotnetMoveCapability [<CommonParameters>]
```

PowerShell has no manifest mechanism to declare external-CLI prerequisites, so this is a
runtime probe via Get-Command; dotnet is required for .NET project moves (the delegation
target), and git is optional (without it, moves fall back to a plain move (PowerShell `Move-Item`) with no history preserved).

**Output**

Returns a single [DotnetMove.Capability](#dotnetmovecapability).

```text
DotnetMove.Capability
  Platform            string
  PSEdition           string
  DotnetSupportsSlnx  bool
  Git                 DotnetMove.ToolInfo
  Dotnet              DotnetMove.ToolInfo
```

**Examples**

```powershell
Get-DotnetMoveCapability
```

Returns an object with Platform, PSEdition, Git, Dotnet, and DotnetSupportsSlnx.

---

### Get-SolutionInventory

List the full contents of every solution in a repository - projects of any type, solution
folders, and solution items - plus on-disk projects that no solution references.

**Syntax**

```powershell
Get-SolutionInventory [[-RepoRoot] <string>] [<CommonParameters>]
```

Where Test-SolutionConsistency compares membership and Repair-SolutionReferences finds
dangling entries, this gives the complete picture without reading the files by hand. It
parses each .sln/.slnx directly (not via `dotnet sln list`, which only returns
CLI-buildable projects), so it also surfaces non-CLI project types (e.g. .pssproj),
solution folders, and loose solution items. It then compares against the projects on disk
and flags any that are in no solution at all.

Read-only: one record per item, so you can group, filter, or format it however you like.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`‑RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>true (ByValue, ByPropertyName)</small> | <small>Root to scan. Accepts pipeline input (path string, or any object with a FullName/Path property). Defaults to the enclosing git repository root. Nested git worktrees are skipped.</small> |

**Output**

Returns zero or more [DotnetMove.SolutionItem](#dotnetmovesolutionitem), collected as an array.
One per item.

```text
DotnetMove.SolutionItem
  Solution  string                       repo-relative, or '(none)' for an unreferenced project
  Kind      DotnetMove.SolutionItemKind  enum: Project | SolutionFolder | SolutionItem | UnreferencedProject
  Type      string                       project extension without the dot, else empty
  Name      string
  Path      string                       as stored in the solution, or repo-relative
```

**Examples**

```powershell
# Everything across all solutions, plus projects in none
Get-SolutionInventory -RepoRoot . | Format-Table -AutoSize

# Only the projects on disk that no solution references
Get-SolutionInventory | Where-Object Kind -eq 'UnreferencedProject'

# Only loose solution items (e.g. a README in a solution folder)
Get-SolutionInventory | Where-Object Kind -eq 'SolutionItem'

# Kind is the [DotnetMove.SolutionItemKind] enum, so this also works
Get-SolutionInventory | Where-Object Kind -eq ([DotnetMove.SolutionItemKind]::UnreferencedProject)
```

---

### Move-Dotnet

Move any supported item and reconcile references, routing by detected type to the right
per-namespace front door. The single top-level entry point (the `git dotnetmv` alias
calls this).

**Syntax**

```powershell
Move-Dotnet [-Path] <string> -Destination <string> [-RepoRoot <string>] [-NoBuild] [-Force] [-NoJournal] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Classifies the target with Resolve-MoveEngine, then dispatches to the namespace front door
that performs the appropriate file/folder move (see Output for the routing). The Unity and
native C++ front doors load DotnetMove.Unity / DotnetMove.Native on demand.

"dotnet" here is the .NET-platform umbrella (CLR/CoreCLR), not just the dotnet CLI - the
verb spans every engine. Each engine's behavior lives in its own cmdlet; this only routes.
`-WhatIf`/`-Confirm`/`-Verbose` propagate; `-Force`/`-RepoRoot`/`-NoBuild` are forwarded where the
target's engine accepts them.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`‑Path`</small> | <small>String</small> | <small>true</small> | <small>true (ByValue, ByPropertyName)</small> | <small>The item to move (file or folder). Accepts pipeline input.</small> |
| <small>`‑Destination`</small> | <small>String</small> | <small>true</small> | <small>false</small> | <small>New path - passed through to the engine.</small> |
| <small>`‑RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>Repository root the engine scans for references. Defaults to the enclosing git repository root. Not used by the Unity engine.</small> |
| <small>`‑NoBuild`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Skip the verifying 'dotnet build'. Only the .NET engine builds; ignored by the others.</small> |
| <small>`‑Force`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history. Forwarded to the engine.</small> |
| <small>`‑NoJournal`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Skip recording this move in the undo journal for this call (forwarded to the engine), even when journaling is enabled.</small> |
| <small>`‑WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`‑Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

**Output**

```text
.csproj  .fsproj  .vbproj  ->  DotnetMove.MoveResult
folder of .NET projects    ->  DotnetMove.TreeMoveResult
.sln  .slnx                ->  DotnetMove.SolutionMoveResult
.props  .targets           ->  DotnetMove.ImportMoveResult
.ps1                       ->  DotnetMove.ScriptMoveResult
.psd1  module folder       ->  DotnetMove.PSModuleMoveResult
.vcxproj                   ->  DotnetMove.NativeMoveResult
Unity asset  .meta         ->  DotnetMove.UnityMoveResult
```

These share a common shape (Engine, Source, Destination, Performed, SkippedCount) and each adds its own fields; they are plain pscustomobjects with no shared base type. See [Output types](#output-types).

**Examples**

```powershell
# Preview any move - detects the engine, changes nothing
Move-Dotnet -Path ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon -WhatIf

# Rename: ./libs/Tarragon does not exist yet, so src/Tarragon becomes libs/Tarragon
Move-Dotnet -Path ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon

# Move into an existing folder: ./libs exists, so it lands at ./libs/Tarragon
Move-Dotnet -Path ./src/Tarragon/Tarragon.csproj -Destination ./libs

# Any supported type routes through the same call (here a PowerShell module folder)
Move-Dotnet -Path ./tools/Mayo -Destination ./modules/Mayo

# No git in the repository? -Force falls back to a plain Move-Item (history not preserved)
Move-Dotnet -Path ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon -Force
```

---

### Move-DotnetFile

Move a single managed .NET file and reconcile references, routing by extension to the
right specialist. The front door for file moves in the .NET family.

**Syntax**

```powershell
Move-DotnetFile [-Path] <string> -Destination <string> [-RepoRoot <string>] [-NoBuild] [-Force] [-NoJournal] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Dispatches a managed .NET file to the right specialist by extension (see Output for the
routing). Native (.vcxproj), PowerShell (.ps1/.psd1) and Unity assets are deliberately not
handled here - use Move-NativeProject / Move-PowerShellScript / Move-PowerShellModule /
Move-UnityAsset. `-WhatIf`/`-Confirm`/`-Verbose` propagate to the specialist; `-Force` and
`-RepoRoot`/`-NoBuild` are forwarded where the specialist accepts them.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`‑Path`</small> | <small>String</small> | <small>true</small> | <small>true (ByValue, ByPropertyName)</small> | <small>The .NET file to move. Accepts pipeline input.</small> |
| <small>`‑Destination`</small> | <small>String</small> | <small>true</small> | <small>false</small> | <small>New path (file or folder) - passed through to the specialist.</small> |
| <small>`‑RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>Repository root the specialist scans for references. Defaults to the enclosing git repository root.</small> |
| <small>`‑NoBuild`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Skip the verifying 'dotnet build' (forwarded to the project/import specialist).</small> |
| <small>`‑Force`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.</small> |
| <small>`‑NoJournal`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Skip recording this move in the undo journal for this call (forwarded to the specialist), even when journaling is enabled.</small> |
| <small>`‑WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`‑Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

**Output**

```text
.csproj  .fsproj  .vbproj  ->  Move-DotnetProject   ->  DotnetMove.MoveResult
.sln  .slnx                ->  Move-Solution        ->  DotnetMove.SolutionMoveResult
.props  .targets           ->  Move-MSBuildImport   ->  DotnetMove.ImportMoveResult
```

These share a common shape (Engine, Source, Destination, Performed, SkippedCount) and each adds its own fields; they are plain pscustomobjects with no shared base type. See [Output types](#output-types).

**Examples**

```powershell
# A project file routes to Move-DotnetProject
Move-DotnetFile -Path ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon

# A solution routes to Move-Solution (rebases stored project paths)
Move-DotnetFile -Path ./Demo.slnx -Destination ./build/Demo.slnx

# A shared import routes to Move-MSBuildImport (fixes <Import> in consumers)
Move-DotnetFile -Path ./Shared.props -Destination ./build/Shared.props
```

---

### Move-DotnetFolder

Move a folder of managed .NET projects, reconciling references. The front door for
folder moves in the .NET family; delegates to Move-DotnetProjectTree (which handles a
single project or many).

**Syntax**

```powershell
Move-DotnetFolder [-Path] <string> -Destination <string> [-RepoRoot <string>] [-NoBuild] [-Force] [-NoJournal] [-WhatIf] [-Confirm] [<CommonParameters>]
```

A folder move always goes through Move-DotnetProjectTree: it treats every managed
project under the folder as one co-moving set and reconciles only the references that
cross the folder boundary (internal references ride along unchanged). If the folder
contains no managed projects, that specialist reports it. `-WhatIf`/`-Confirm`/`-Verbose`
propagate; `-Force`/`-RepoRoot`/`-NoBuild` are forwarded.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`‑Path`</small> | <small>String</small> | <small>true</small> | <small>true (ByValue, ByPropertyName)</small> | <small>The folder to move. Accepts pipeline input.</small> |
| <small>`‑Destination`</small> | <small>String</small> | <small>true</small> | <small>false</small> | <small>New folder path.</small> |
| <small>`‑RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>Repository root scanned for references. Defaults to the enclosing git repository root.</small> |
| <small>`‑NoBuild`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Skip the verifying 'dotnet build' (forwarded to Move-DotnetProjectTree).</small> |
| <small>`‑Force`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.</small> |
| <small>`‑NoJournal`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Skip recording this move in the undo journal for this call (forwarded to the specialist), even when journaling is enabled.</small> |
| <small>`‑WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`‑Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

**Output**

Returns a single [DotnetMove.TreeMoveResult](#dotnetmovetreemoveresult).
From Move-DotnetProjectTree.

```text
DotnetMove.TreeMoveResult
  Engine         string
  Source         string
  Destination    string
  Performed      bool    false under -WhatIf
  SkippedCount   int
  ProjectsMoved  int
  ConsumerCount  int     external references repointed
  Built          bool?   $null with -NoBuild
```

**Examples**

```powershell
# Preview moving a folder of .NET projects (delegates to the tree mover)
Move-DotnetFolder -Path ./src/Group -Destination ./libs/Group -WhatIf

# Move into an existing folder (lands at ./libs/Group)
Move-DotnetFolder -Path ./src/Group -Destination ./libs
```

---

### Move-DotnetProject

Move a .NET project folder and reconcile every solution and project reference
that points at it, delegating all path/GUID changes to the dotnet CLI.

**Syntax**

```powershell
Move-DotnetProject [-Project] <string> -Destination <string> [-RepoRoot <string>] [-Strict] [-NoBuild] [-Force] [-NoJournal] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Enumerates the solutions that include the project, the projects that reference it,
and the project's own references. Removes those links while the old paths still
resolve, moves the directory (git mv when tracked), then re-adds every link so the
dotnet CLI recomputes fresh relative paths and preserves GUIDs. The solution and
project XML (.sln/.slnx, .csproj) is never hand-edited.

Diagnostics follow invocation: `-Verbose` narrates the plan, `-Debug` emits the full
solution-membership matrix, and divergence (the project living in some but not all
of the repository's solutions) is surfaced as a Warning (or, with `-Strict`, a non-
terminating error honoring `-ErrorAction`).

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`‑Project`</small> | <small>String</small> | <small>true</small> | <small>true (ByValue, ByPropertyName)</small> | <small>Path to the project file (.csproj/.fsproj/.vbproj). Accepts pipeline input - pipe a path string or any object with a FullName/Path property (e.g. Get-Item output).</small> |
| <small>`‑Destination`</small> | <small>String</small> | <small>true</small> | <small>false</small> | <small>Where to move the project folder, following `git mv` rules: if Destination is an existing directory the folder moves into it (keeping its name, e.g. './libs' -&gt; './libs/Tarragon'); otherwise Destination is the project's new folder path (a rename, './libs/Tarragon'). The project file and its sibling contents move as one. Errors if the resulting folder exists.</small> |
| <small>`‑RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>Root to scan for solutions/consumers. Defaults to the enclosing git repository root.</small> |
| <small>`‑Strict`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Escalate solution-divergence warnings to non-terminating errors.</small> |
| <small>`‑NoBuild`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Skip the verifying 'dotnet build' at the end.</small> |
| <small>`‑Force`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.</small> |
| <small>`‑NoJournal`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Skip recording this move in the undo journal for this call, even when journaling is enabled (Undo-DotnetMove will not see this move).</small> |
| <small>`‑WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`‑Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

**Output**

Returns a single [DotnetMove.MoveResult](#dotnetmovemoveresult).

```text
DotnetMove.MoveResult
  Engine         string
  Source         string
  Destination    string
  Performed      bool      false under -WhatIf
  SkippedCount   int
  ConsumerCount  int       external references repointed
  OwnRefCount    int       the moved project's own references rebased
  Solutions      string[]  solution names updated
  Built          bool?     $null with -NoBuild
```

**Examples**

```powershell
# Preview the move and emit the plan object; nothing changes
Move-DotnetProject -Project ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon -WhatIf

# Rename the project folder src/Tarragon -> libs/Tarragon
Move-DotnetProject -Project ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon

# Destination is an existing folder -> moves into it, landing at libs/Tarragon
Move-DotnetProject -Project ./src/Tarragon/Tarragon.csproj -Destination ./libs

# Skip the verifying 'dotnet build' at the end
Move-DotnetProject -Project ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon -NoBuild

# Treat solution-membership divergence as a non-terminating error, not a warning
Move-DotnetProject -Project ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon -Strict

# Take the project from the pipeline
Get-Item ./src/Tarragon/Tarragon.csproj | Move-DotnetProject -Destination ./libs/Tarragon
```

---

### Move-DotnetProjectTree

Move a folder that contains one or more managed .NET projects, reconciling solution
membership and every external project reference in one operation. This is the bulk
"restructure" case (e.g. wrapping several projects into a new parent folder).

**Syntax**

```powershell
Move-DotnetProjectTree [-Path] <string> -Destination <string> [-RepoRoot <string>] [-NoBuild] [-Force] [-NoJournal] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Enumerates the managed projects (.csproj/.fsproj/.vbproj) under the folder and treats
them as a single co-moving set. It reconciles only what crosses the folder boundary:
solution membership for each moved project (dotnet sln remove/add), external consumers
(projects outside the folder that reference one inside), and the moved projects' own
references to projects outside the folder.
References between two co-moved projects are left untouched - their relative path is
unchanged because both move by the same delta. Everything is delegated to the dotnet
CLI; nothing is hand-edited.

Like Move-DotnetProject: dotnet is required; git is used when available (else a
confirmed plain-move fallback via `-Force` / ShouldContinue); supports `-WhatIf`.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`‑Path`</small> | <small>String</small> | <small>true</small> | <small>true (ByValue, ByPropertyName)</small> | <small>The folder to move. Accepts pipeline input.</small> |
| <small>`‑Destination`</small> | <small>String</small> | <small>true</small> | <small>false</small> | <small>Where to move the folder, following `git mv` rules: an existing directory means move into it (keeping the name); otherwise it is the folder's new path. Errors if the result exists.</small> |
| <small>`‑RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>Root to scan. Defaults to the enclosing git repository root.</small> |
| <small>`‑NoBuild`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Skip the verifying build of the moved projects.</small> |
| <small>`‑Force`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.</small> |
| <small>`‑NoJournal`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Skip recording this move in the undo journal for this call, even when journaling is enabled (Undo-DotnetMove will not see this move).</small> |
| <small>`‑WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`‑Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

**Output**

Returns a single [DotnetMove.TreeMoveResult](#dotnetmovetreemoveresult).

```text
DotnetMove.TreeMoveResult
  Engine         string
  Source         string
  Destination    string
  Performed      bool    false under -WhatIf
  SkippedCount   int
  ProjectsMoved  int
  ConsumerCount  int     external references repointed
  Built          bool?   $null with -NoBuild
```

**Examples**

```powershell
# Preview moving a whole folder of projects as one set
Move-DotnetProjectTree -Path ./src/Group -Destination ./libs/Group -WhatIf

# Move it: only references that cross the folder boundary are reconciled (internal ones are untouched)
Move-DotnetProjectTree -Path ./src/Group -Destination ./libs/Group

# Move into an existing folder (lands at ./libs/Group)
Move-DotnetProjectTree -Path ./src/Group -Destination ./libs

# Skip the verifying build
Move-DotnetProjectTree -Path ./src/Group -Destination ./libs/Group -NoBuild
```

---

### Move-MSBuildImport

Move a shared MSBuild .props/.targets file and fix every project (or other
props/targets) that imports it via &lt;Import Project="..."&gt;.

**Syntax**

```powershell
Move-MSBuildImport [-Path] <string> -Destination <string> [-RepoRoot <string>] [-Force] [-NoJournal] [-WhatIf] [-Confirm] [<CommonParameters>]
```

There is no dotnet CLI for &lt;Import&gt;, so this reconciles the relative Import paths
directly with precise, formatting- and BOM-preserving text edits (it replaces the
exact Project="&lt;value&gt;" token captured from the XML, not a blind regex). It also
fixes the moved file's own outgoing &lt;Import&gt; paths, which break when its location
changes. The `$(MSBuildThisFileDirectory)` token is resolved/preserved; other `$(...)`
tokens are reported as unresolved rather than guessed.

Note: Directory.Build.props/.targets (and Directory.Packages.props, etc.) are imported
by location, not an explicit &lt;Import&gt; - moving one changes inheritance scope, which
cannot be "fixed" by editing imports. For those this warns (like the inheritance check)
and only fixes the file's own outgoing imports.

Importers may include native .vcxproj files; their &lt;Import&gt; path is fixed on any OS (a
best-effort, path-only update), but a .vcxproj's native link settings are never
reconciled off Windows; that remains Move-NativeProject's Windows-only job.

dotnet is not required here; git is used when available (else confirmed plain-move
fallback via `-Force`). Supports `-WhatIf`.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`‑Path`</small> | <small>String</small> | <small>true</small> | <small>true (ByValue, ByPropertyName)</small> | <small>The .props/.targets file to move. Accepts pipeline input.</small> |
| <small>`‑Destination`</small> | <small>String</small> | <small>true</small> | <small>false</small> | <small>New file path (or a folder, in which case the file keeps its name).</small> |
| <small>`‑RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>Root to scan for importers. Defaults to the enclosing git repository root.</small> |
| <small>`‑Force`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.</small> |
| <small>`‑NoJournal`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Skip recording this move in the undo journal for this call, even when journaling is enabled (Undo-DotnetMove will not see this move).</small> |
| <small>`‑WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`‑Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

**Output**

Returns a single [DotnetMove.ImportMoveResult](#dotnetmoveimportmoveresult).

```text
DotnetMove.ImportMoveResult
  Engine           string
  Source           string
  Destination      string
  Performed        bool    false under -WhatIf
  SkippedCount     int
  ImportersFixed   int     files whose <Import> was rewritten
  OwnImportsFixed  int     the moved file's own imports rewritten
  AutoImported     bool    true for a by-location import (e.g. Directory.Build.props) whose inheritance scope changed
```

**Examples**

```powershell
path in every consumer
Move-MSBuildImport -Path ./Shared.props -Destination ./build/Shared.props -WhatIf

# Move into an existing folder (lands at ./build/Shared.props)
Move-MSBuildImport -Path ./Shared.props -Destination ./build

# A by-location import (Directory.Build.props): moving it changes inheritance scope - reported
Move-MSBuildImport -Path ./src/Directory.Build.props -Destination ./Directory.Build.props
```

---

### Move-PowerShell

Move a PowerShell item and reconcile references, routing by type to the right
specialist. The front door for PowerShell moves.

**Syntax**

```powershell
Move-PowerShell [-Path] <string> -Destination <string> [-RepoRoot <string>] [-Force] [-NoJournal] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Dispatches a PowerShell item to the right specialist by type (see Output for the routing):
the script specialist fixes dot-source/call references (AST-based), the module specialist
reconciles the manifest. `-WhatIf`/`-Confirm`/`-Verbose` propagate to the specialist; `-Force` is
forwarded, and `-RepoRoot` is forwarded to the script specialist (the module specialist has
no RepoRoot).

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`‑Path`</small> | <small>String</small> | <small>true</small> | <small>true (ByValue, ByPropertyName)</small> | <small>The PowerShell item to move: a .ps1 script, a .psd1 manifest, or a module folder. Accepts pipeline input.</small> |
| <small>`‑Destination`</small> | <small>String</small> | <small>true</small> | <small>false</small> | <small>New path - passed through to the specialist.</small> |
| <small>`‑RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>Repository root scanned for referencing scripts. Defaults to the enclosing git repository root. Forwarded to the script specialist only (the module specialist has no RepoRoot).</small> |
| <small>`‑Force`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.</small> |
| <small>`‑NoJournal`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Skip recording this move in the undo journal for this call (forwarded to the specialist), even when journaling is enabled.</small> |
| <small>`‑WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`‑Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

**Output**

```text
.ps1                   ->  Move-PowerShellScript  ->  DotnetMove.ScriptMoveResult
.psd1  module folder   ->  Move-PowerShellModule  ->  DotnetMove.PSModuleMoveResult
```

These share a common shape (Engine, Source, Destination, Performed, SkippedCount) and each adds its own fields; they are plain pscustomobjects with no shared base type. See [Output types](#output-types).

**Examples**

```powershell
# A .ps1 routes to the script mover (fixes dot-source/call references)
Move-PowerShell -Path ./lib/helpers.ps1 -Destination ./shared/helpers.ps1 -WhatIf

# A module folder (or its .psd1) routes to the module mover (reconciles the manifest)
Move-PowerShell -Path ./tools/Mayo -Destination ./modules/Mayo

# Destination is an existing folder -> the script lands at ./shared/helpers.ps1
Move-PowerShell -Path ./lib/helpers.ps1 -Destination ./shared
```

---

### Move-PowerShellModule

Move a PowerShell module folder and reconcile its manifest, delegating manifest
edits to Update-ModuleManifest rather than hand-editing the .psd1.

**Syntax**

```powershell
Move-PowerShellModule [-ModulePath] <string> -Destination <string> [-Force] [-NoJournal] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Moves a module directory (git mv when tracked), then rewrites RootModule,
NestedModules and FileList in the .psd1 via Update-ModuleManifest so relative
references stay valid. Validates the result with Test-ModuleManifest.

Limits (warned, not fixed): dot-sourced relative paths inside .psm1/.ps1 files,
and any path computed at runtime, cannot be reconciled automatically.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`‑ModulePath`</small> | <small>String</small> | <small>true</small> | <small>true (ByValue, ByPropertyName)</small> | <small>Path to the module folder, or directly to its .psd1 manifest.</small> |
| <small>`‑Destination`</small> | <small>String</small> | <small>true</small> | <small>false</small> | <small>Where to move the module folder, following `git mv` rules: an existing directory means move into it (keeping the name); otherwise it is the module's new folder path. Errors if it exists.</small> |
| <small>`‑Force`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.</small> |
| <small>`‑NoJournal`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Skip recording this move in the undo journal for this call, even when journaling is enabled (Undo-DotnetMove will not see this move).</small> |
| <small>`‑WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`‑Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

**Output**

Returns a single [DotnetMove.PSModuleMoveResult](#dotnetmovepsmodulemoveresult).

```text
DotnetMove.PSModuleMoveResult
  Engine        string
  Source        string
  Destination   string
  Performed     bool    false under -WhatIf
  SkippedCount  int
  Manifest      string  the manifest file name
```

**Examples**

```powershell
# Preview; reconciles RootModule/NestedModules/FileList via Update-ModuleManifest
Move-PowerShellModule -ModulePath ./tools/Mayo -Destination ./modules/Mayo -WhatIf

# Move it for real
Move-PowerShellModule -ModulePath ./tools/Mayo -Destination ./modules/Mayo

# Point at the .psd1 instead of the folder - same result
Move-PowerShellModule -ModulePath ./tools/Mayo/Mayo.psd1 -Destination ./modules/Mayo
```

---

### Move-PowerShellScript

Move a standalone .ps1 script and fix the relative paths in scripts that dot-source or
call it (and the moved script's own dot-source/call paths).

**Syntax**

```powershell
Move-PowerShellScript [-Path] <string> -Destination <string> [-RepoRoot <string>] [-Force] [-NoJournal] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Finds references via the PowerShell AST: dot-source (`. path`) and call (`& path`)
invocations whose path is a literal string or a `$PSScriptRoot`-based string resolving to
the moved script. It rewrites those relative paths with precise, BOM-preserving edits,
preserving the original style (`$PSScriptRoot`-prefixed or .\-relative).

HEURISTIC LIMIT: only literal and `$PSScriptRoot`-based string paths are resolved and
rewritten. A path that is a string containing other variables (e.g. "`$dir`\x.ps1") whose
leaf matches the moved script is reported as a possible dynamic reference to verify by
hand. A path built entirely from an expression (e.g. Join-Path ...) is not a string node
and cannot be detected at all - grep to be sure. Treat the result as "fixed what could
be proven," not "guaranteed complete."

git is used when available (else confirmed plain-move fallback via `-Force`). `-WhatIf`
supported; dotnet not required.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`‑Path`</small> | <small>String</small> | <small>true</small> | <small>true (ByValue, ByPropertyName)</small> | <small>The .ps1 to move. Accepts pipeline input.</small> |
| <small>`‑Destination`</small> | <small>String</small> | <small>true</small> | <small>false</small> | <small>New file path (or a folder, in which case the script keeps its name).</small> |
| <small>`‑RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>Root to scan for referencing scripts. Defaults to the enclosing git repository root.</small> |
| <small>`‑Force`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.</small> |
| <small>`‑NoJournal`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Skip recording this move in the undo journal for this call, even when journaling is enabled (Undo-DotnetMove will not see this move).</small> |
| <small>`‑WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`‑Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

**Output**

Returns a single [DotnetMove.ScriptMoveResult](#dotnetmovescriptmoveresult).

```text
DotnetMove.ScriptMoveResult
  Engine            string
  Source            string
  Destination       string
  Performed         bool    false under -WhatIf
  SkippedCount      int
  ReferencersFixed  int     scripts whose path to the moved file was rewritten
  OwnRefsFixed      int     the moved script's own paths rewritten
  UnresolvedRefs    int     count of possible dynamic references to verify, not a list
```

**Examples**

```powershell
# Preview; rewrites dot-source/call paths in referencing scripts and the script's own refs
Move-PowerShellScript -Path ./lib/helpers.ps1 -Destination ./shared/helpers.ps1 -WhatIf

# Move it for real
Move-PowerShellScript -Path ./lib/helpers.ps1 -Destination ./shared/helpers.ps1

# Limit the scan for referencing scripts to a specific root
Move-PowerShellScript -Path ./lib/helpers.ps1 -Destination ./shared/helpers.ps1 -RepoRoot ./lib
```

---

### Move-Solution

Move a solution file (.sln/.slnx) and rebase the relative project paths it stores, so
every project it references still resolves from the solution's new location.

**Syntax**

```powershell
Move-Solution [-Path] <string> -Destination <string> [-Force] [-NoJournal] [-WhatIf] [-Confirm] [<CommonParameters>]
```

A solution stores each project as a path relative to the solution file. Moving the
solution changes that base directory, so every entry must be recomputed. The dotnet
CLI has no "rebase" command, so this rewrites the stored paths with precise,
formatting- and BOM-preserving edits (it replaces the exact path token captured from
the file - .slnx &lt;Project Path="..."&gt; or the .sln project line - not a blind regex),
keeping each format's separator convention (/ for .slnx, \ for .sln). Project-to-project
references are unaffected by a solution move and are left alone.

git is used when available (else confirmed plain-move fallback via `-Force`). `-WhatIf`
supported. dotnet is not required.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`‑Path`</small> | <small>String</small> | <small>true</small> | <small>true (ByValue, ByPropertyName)</small> | <small>The .sln/.slnx file to move. Accepts pipeline input.</small> |
| <small>`‑Destination`</small> | <small>String</small> | <small>true</small> | <small>false</small> | <small>New file path (or a folder, in which case the solution keeps its name).</small> |
| <small>`‑Force`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.</small> |
| <small>`‑NoJournal`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Skip recording this move in the undo journal for this call, even when journaling is enabled (Undo-DotnetMove will not see this move).</small> |
| <small>`‑WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`‑Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

**Output**

Returns a single [DotnetMove.SolutionMoveResult](#dotnetmovesolutionmoveresult).

```text
DotnetMove.SolutionMoveResult
  Engine           string
  Source           string
  Destination      string
  Performed        bool    false under -WhatIf
  SkippedCount     int
  ProjectsRebased  int     stored paths rewritten
```

**Examples**

```powershell
# Preview moving a solution and rebasing the project paths it stores
Move-Solution -Path ./Demo.slnx -Destination ./build/Demo.slnx -WhatIf

# Destination is an existing folder -> lands at ./build/Demo.slnx
Move-Solution -Path ./Demo.slnx -Destination ./build

# Works the same for .sln
Move-Solution -Path ./Demo.sln -Destination ./build/Demo.sln
```

---

### Register-DotnetMvGitAlias

Opt-in: register a `git dotnetmv` alias pointing at DotnetMove's forwarder. Sets a single
reversible git-config line - it never edits PATH or installs anything.

**Syntax**

```powershell
Register-DotnetMvGitAlias [[-Scope] <string>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Adds `alias.dotnetmv = !pwsh -NoProfile -File <forwarder>` to git config so
`git dotnetmv <src> <dst>` works. "dotnet" is the .NET-platform umbrella: the verb
branches by target type to the right engine - the .NET project model
(csproj/sln/props), Unity (.meta/.asmdef), PowerShell (.ps1/.psd1), or native C++
(.vcxproj). Scope is your choice (repository-local or global). Undo with
Unregister-DotnetMvGitAlias. Use `-WhatIf` to see the exact `git config` command.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`‑Scope`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>'Local' (this repository, default) or 'Global' (~/.gitconfig).</small> |
| <small>`‑WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`‑Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

**Output**

Returns a single [DotnetMove.GitAlias](#dotnetmovegitalias).

```text
DotnetMove.GitAlias
  Alias      string
  Scope      string
  Forwarder  string
  Command    string  the git config command that was/would be run
```

**Examples**

```powershell
# Preview the exact git config command (changes nothing)
Register-DotnetMvGitAlias -Scope Global -WhatIf

# Register for this repository only (default scope is Local)
Register-DotnetMvGitAlias

# Register globally, in ~/.gitconfig
Register-DotnetMvGitAlias -Scope Global
```

---

### Repair-SolutionReferences

Scan a repository for broken solution membership and dangling ProjectReferences and repair them
by re-pointing each entry at the project's new location.

**Syntax**

```powershell
Repair-SolutionReferences [[-RepoRoot] <string>] [-Fix] [-Prune] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Finds solution entries and &lt;ProjectReference&gt;s that point at a project file which no longer
exists at the recorded path (usually because a project was moved or renamed without
reconciling). Read-only by default: it returns one object per problem, each tagged with a
Resolution of Relocatable, Missing, or Ambiguous.

With `-Fix` it repairs every Relocatable entry: it searches the repository for a project file of the
same name and re-points the entry at it through the dotnet CLI (remove the stale path, add
the found one). When one project of that name exists it is used directly; when several do,
the one that keeps the most of the original path's trailing folders is chosen, since a moved
project usually keeps its own folder name. Entries it cannot resolve are left untouched and
reported, Missing (no such project anywhere) or Ambiguous (several equally-good candidates).

With `-Prune` it removes the Missing entries, the genuinely deleted ones, through the dotnet
CLI. `-Prune` never touches Relocatable or Ambiguous entries. `-Fix` and `-Prune` can be combined.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`‑RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>true (ByValue, ByPropertyName)</small> | <small>Root to scan. Defaults to the enclosing git repository root of the current directory.</small> |
| <small>`‑Fix`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Re-point each dangling entry at the moved project when its new location is unambiguous. Honors `-WhatIf`.</small> |
| <small>`‑Prune`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Remove entries whose project cannot be found anywhere in the repository. Honors `-WhatIf`.</small> |
| <small>`‑WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`‑Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

**Output**

Returns zero or more [DotnetMove.RepairResult](#dotnetmoverepairresult), collected as an array (`$null` when none).
One per dangling entry.

```text
DotnetMove.RepairResult
  Kind        string
  Resolution  string
  Missing     string
  NewPath     string
  Container   string
  MissingAbs  string
  Candidates  string[]  same-named project files found, used to resolve NewPath
```

**Examples**

```powershell
# Report dangling entries only - read-only (each tagged Relocatable, Missing, or Ambiguous)
Repair-SolutionReferences -RepoRoot .

# Re-point relocatable entries at the project's new location (relocates; never deletes)
Repair-SolutionReferences -RepoRoot . -Fix

# Also remove entries whose project is gone for good - preview the whole thing first
Repair-SolutionReferences -RepoRoot . -Fix -Prune -WhatIf
```

---

### Resolve-MoveEngine

Classify a path to the reconciliation engine that should move it: dotnet, native,
unity, ps-script, ps-module, or unknown. Used by the `git dotnetmv` forwarder and
available for introspection.

**Syntax**

```powershell
Resolve-MoveEngine [-Path] <string> [<CommonParameters>]
```

Classification is by target type (extension + location + .meta pairing), not by content
beyond a folder's project/manifest scan. The path need not exist (extension-based cases
classify regardless); folder cases require the directory.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`‑Path`</small> | <small>String</small> | <small>true</small> | <small>true (ByValue, ByPropertyName)</small> | <small>The item to classify. Accepts pipeline input.</small> |

**Output**

```text
.vcxproj                                            ->  native
.asmdef  .asmref  *.meta  (or under Assets/)        ->  unity
.ps1                                                ->  ps-script
.psd1                                               ->  ps-module
.csproj .fsproj .vbproj .sln .slnx .props .targets  ->  dotnet
folder containing a .NET project                    ->  dotnet
folder containing a .psd1                           ->  ps-module
anything else                                       ->  unknown
```

**Examples**

```powershell
# A managed project classifies as 'dotnet'
Resolve-MoveEngine ./src/Tarragon/Tarragon.csproj

# Anything under Assets/ or paired with a .meta is 'unity'
Resolve-MoveEngine ./Assets/Art/logo.png

# A .ps1 is 'ps-script'; a module folder or .psd1 is 'ps-module'
Resolve-MoveEngine ./tools/build.ps1

# A .vcxproj is 'native'; an unrecognized path is 'unknown'
Resolve-MoveEngine ./Aleppo/Aleppo.vcxproj
```

---

### Set-DotnetMoveJournal

Turn the move journal on or off, per repository (default) or for every repository (`-Global`).

**Syntax**

```powershell
Set-DotnetMoveJournal [-Enabled] <bool> [[-RepoRoot] <string>] [-Global] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Journaling is on by default. This cmdlet writes the git setting that the precedence stack
reads (git config dotnetmove.journal), so the choice persists across sessions and rides along
with the repository's git config - no environment variable to remember. Local config (the
default here) wins over global, matching the resolution order in Test-MoveJournalEnabled.

With `-Global` it writes the user's global git config, switching the default for every
repository on the machine in one place. Requires git; with no git, set `$env`:DOTNETMOVE_JOURNAL
instead.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`‑Enabled`</small> | <small>Boolean</small> | <small>true</small> | <small>false</small> | <small>`$true` to journal moves (the default behavior), `$false` to stop journaling.</small> |
| <small>`‑Global`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Write the user's global git config instead of the repository's local config.</small> |
| <small>`‑RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>Repository whose local config to write. Defaults to the enclosing git repository root. Ignored with `-Global`.</small> |
| <small>`‑WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`‑Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

**Output**

None.

**Examples**

```powershell
# Stop journaling in this repository only
Set-DotnetMoveJournal -Enabled $false

# Turn it back on
Set-DotnetMoveJournal -Enabled $true

# Turn journaling off for every repository on the machine
Set-DotnetMoveJournal -Enabled $false -Global
```

---

### Sync-Solution

Resolve solution-membership divergence by adding each project to the solutions that are
missing it, so every solution in the repository lists the same projects.

**Syntax**

```powershell
Sync-Solution [[-RepoRoot] <string>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

The companion to Test-SolutionConsistency, which only reports divergence. This makes
membership uniform: for every project present in at least one solution but absent from
others, it adds the project to the solutions missing it, delegating to `dotnet sln add`
(never hand-editing the .sln/.slnx). It only adds; it never removes, so a project in no
solution is left alone (use Get-SolutionInventory to find those).

Uniform membership is the assumption. If a solution is intentionally a subset, do not run
this against the whole repository; preview with `-WhatIf` first and add specific projects by hand.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`‑RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>true (ByValue, ByPropertyName)</small> | <small>Root to scan. Accepts pipeline input. Defaults to the enclosing git repository root. Nested git worktrees are skipped.</small> |
| <small>`‑WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`‑Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

**Output**

Returns zero or more [DotnetMove.SyncResult](#dotnetmovesyncresult), collected as an array (`$null` when none).
One per project added.

```text
DotnetMove.SyncResult
  Solution  string  repo-relative
  Added     string  repo-relative project path
```

**Examples**

```powershell
# Preview which projects would be added to which solutions to make membership uniform
Sync-Solution -RepoRoot . -WhatIf

# Add each divergent project to the solutions missing it (only adds, never removes)
Sync-Solution -RepoRoot .
```

---

### Test-DotnetMoveUpdate

Check GitHub for a newer DotnetMove release and report whether the installed version is
behind. On-demand and read-only: it never updates anything itself.

**Syntax**

```powershell
Test-DotnetMoveUpdate [[-Repository] <string>] [<CommonParameters>]
```

DotnetMove does not update automatically, however it is installed (PowerShell Gallery,
installer, or a clone). This is the pull-based check: it GETs the latest GitHub release
and compares its tag (the "available" version) against the installed module's ModuleVersion
(the "installed" version). It prints what to do when behind, but performs no update - an
agent or user runs it when they want to know.

Needs network access to api.github.com. Honors `-ErrorAction` if the request fails (offline,
rate-limited, or no releases yet).

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`‑Repository`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>owner/name of the GitHub repository to check. Defaults to the project repository.</small> |

**Output**

Returns a single [DotnetMove.Update](#dotnetmoveupdate).
None (writes a non-terminating error) when the release cannot be fetched.

```text
DotnetMove.Update
  Installed        version
  Latest           version?  $null if the tag could not be parsed
  Tag              string
  UpdateAvailable  bool
  Url              string
```

**Examples**

```powershell
# Compare the installed module to the latest GitHub release
Test-DotnetMoveUpdate

# Check a fork or a different repository (owner/name)
Test-DotnetMoveUpdate -Repository myfork/dotnet-move
```

---

### Test-SolutionConsistency

Report projects whose membership diverges across the solution files in a repository
(present in some solutions but absent from others).

**Syntax**

```powershell
Test-SolutionConsistency [[-RepoRoot] <string>] [-Strict] [<CommonParameters>]
```

When a repository carries more than one solution (e.g. a classic .sln alongside a .slnx),
they can drift out of sync so the same project is listed in one but not the other.
This emits one object per divergent project and surfaces it through the standard streams
so behavior follows invocation: by default it writes a Warning per divergent project;
`-Strict` escalates each to a non-terminating error (honoring `-ErrorAction`); `-Debug` adds the
full membership matrix of every solution and its projects.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`‑RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>true (ByValue, ByPropertyName)</small> | <small>Root to scan. Accepts pipeline input (path string, or any object with a FullName/Path property such as Get-Item output). Defaults to the enclosing git repository root.</small> |
| <small>`‑Strict`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Escalate divergences from warnings to non-terminating errors.</small> |

**Output**

Returns zero or more [DotnetMove.ConsistencyResult](#dotnetmoveconsistencyresult), collected as an array (`$null` when none).
One per divergent project.

```text
DotnetMove.ConsistencyResult
  Project     string
  PresentIn   string[]  solution paths that list it
  AbsentFrom  string[]  solution paths that do not
```

**Examples**

```powershell
# Report projects whose membership diverges across solutions (warnings)
Test-SolutionConsistency -RepoRoot .

# Add the full solution/project membership matrix
Test-SolutionConsistency -RepoRoot . -Debug

# Escalate divergence to non-terminating errors (e.g. to gate CI)
Test-SolutionConsistency -RepoRoot . -Strict

# Check several repositories from the pipeline
Get-Item ./repoA, ./repoB | Test-SolutionConsistency -Strict
```

---

### Undo-DotnetMove

Reverse a previous DotnetMove move, using the journal at the repository root.

**Syntax**

```powershell
Undo-DotnetMove [-RepoRoot <string>] [-Id <string>] [-WhatIf] [-Confirm] [<CommonParameters>]

Undo-DotnetMove -All [-RepoRoot <string>] [-Force] [-WhatIf] [-Confirm] [<CommonParameters>]

Undo-DotnetMove [-RepoRoot <string>] [-List] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Each move is recorded in the journal (under the git dir, .git/dotnetmove/journal.jsonl, or a
temp fallback with no git) with its inverse: the same mover run with source and destination
swapped. Undo-DotnetMove replays that inverse, re-reconciling the solutions, references, and
GUIDs from the CURRENT state (more robust than restoring a stale snapshot). By default it
undoes the most recent move and pops it from the journal, so calling again walks further back
(LIFO); `-Id` targets a specific entry and `-List` shows the journal.

The reversing move is not itself journaled, so undo walks the history back rather than
ping-ponging. Journaling must have been on when the original move ran (it is on by default;
opt out per repository with git config dotnetmove.journal false, or with
`$env`:DOTNETMOVE_JOURNAL). Undoing an entry that is not the most recent can conflict with
moves made after it, so prefer undoing in reverse order.

`-All` reverses every journaled move (newest first) in one operation. Because that walks back
the entire history at once it is high-impact: it prompts for a yes/no confirmation that is not
silenced by `-Confirm`:`$false`; pass `-Force` to bypass the prompt (for automation) or `-WhatIf` to
preview each reversal without making changes.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`‑RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>Repository whose journal to use. Defaults to the enclosing git repository root.</small> |
| <small>`‑Id`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>Undo the entry with this journal id instead of the most recent.</small> |
| <small>`‑All`</small> | <small>SwitchParameter</small> | <small>true</small> | <small>false</small> | <small>Reverse every journaled move, newest first. High-impact: prompts for confirmation (use `-Force` to bypass, `-WhatIf` to preview).</small> |
| <small>`‑Force`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>With `-All`, bypass the confirmation prompt. Ignored without `-All`.</small> |
| <small>`‑List`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>List the journal (oldest first) and return without undoing anything.</small> |
| <small>`‑WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`‑Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

**Output**

Without `-List`, the move-result object from the reversing move (its type matches the original
mover). With `-List`, the journal entries. Nothing when the journal is empty.

**Examples**

```powershell
# See what can be undone
Undo-DotnetMove -List

# Preview undoing the most recent move
Undo-DotnetMove -WhatIf

# Undo the most recent move
Undo-DotnetMove

# Undo a specific entry by id
Undo-DotnetMove -Id a1b2c3d4

# Reverse every journaled move (prompts; -Force to skip the prompt)
Undo-DotnetMove -All
```

---

### Unregister-DotnetMvGitAlias

Remove the `git dotnetmv` alias registered by Register-DotnetMvGitAlias.

**Syntax**

```powershell
Unregister-DotnetMvGitAlias [[-Scope] <string>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`‑Scope`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>'Local' (this repository, default) or 'Global'.</small> |
| <small>`‑WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`‑Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

**Output**

None.

**Examples**

```powershell
# Remove the alias for this repository (default scope is Local)
Unregister-DotnetMvGitAlias

# Remove the global alias from ~/.gitconfig
Unregister-DotnetMvGitAlias -Scope Global
```

---

### Update-DotnetMove

Update an installed DotnetMove to the latest GitHub release, in place. The one-command
update for non-clone installs.

**Syntax**

```powershell
Update-DotnetMove [[-Repository] <string>] [-Force] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Checks GitHub for a newer release (via Test-DotnetMoveUpdate) and, if the installed version
is behind, runs the release's install.ps1 to overwrite the modules on your module path. No
git, no clone. Does nothing when already current unless `-Force`. Honors `-WhatIf`/`-Confirm`.

After it runs, reload the module in the current session with `Import-Module DotnetMove -Force`.
Needs network access to GitHub. For Gallery installs, `Update-Module DotnetMove` is the
simpler path; this command updates installer/clone installs in place from the GitHub release.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`‑Force`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Reinstall the latest release even if the installed version is already current.</small> |
| <small>`‑Repository`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>owner/name of the GitHub repository. Defaults to the project repository.</small> |
| <small>`‑WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`‑Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

**Output**

Returns a single [DotnetMove.Update](#dotnetmoveupdate).
The record from Test-DotnetMoveUpdate, so the decision is inspectable. Nothing on a failed check.

```text
DotnetMove.Update
  Installed        version
  Latest           version?  $null if the tag could not be parsed
  Tag              string
  UpdateAvailable  bool
  Url              string
```

**Examples**

```powershell
# Update to the latest release if the installed copy is behind
Update-DotnetMove

# Report what it would do without downloading or installing
Update-DotnetMove -WhatIf

# Reinstall the latest even if already up to date
Update-DotnetMove -Force
```

---

### Move-NativeProject

Move a native / C++/CLI project (.vcxproj). Windows-only. Does the parts the
dotnet CLI can delegate (solution membership, the move itself) and reports the
native path-bearing settings it cannot reconcile so they are never silently broken.

**Syntax**

```powershell
Move-NativeProject [-Project] <string> -Destination <string> [-RepoRoot <string>] [-Force] [-NoJournal] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Native projects link through MSBuild settings the dotnet CLI does not touch:
AdditionalIncludeDirectories / AdditionalLibraryDirectories / AdditionalDependencies,
&lt;Import&gt; of shared .props/.targets, `$(SolutionDir)`-relative OutDir, and the paired
.vcxproj.filters. C++/CLI is Windows-only, so this cmdlet refuses to run elsewhere.

It will: update .sln/.slnx membership via 'dotnet sln' (which understands .vcxproj),
move the folder (git mv when tracked), move the paired .vcxproj.filters alongside,
and then emit a report of every relative/SolutionDir-relative native setting that a
human (or a future native engine) must verify. It deliberately does not rewrite those
MSBuild paths yet - surfacing them beats silently mis-editing them.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`‑Project`</small> | <small>String</small> | <small>true</small> | <small>true (ByValue, ByPropertyName)</small> | <small>Path to the .vcxproj. Accepts pipeline input.</small> |
| <small>`‑Destination`</small> | <small>String</small> | <small>true</small> | <small>false</small> | <small>Where to move the project folder, following `git mv` rules: an existing directory means move into it (keeping the name); otherwise it is the new folder path. Errors if it exists.</small> |
| <small>`‑RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>Root to scan for solutions. Defaults to the enclosing git repository root.</small> |
| <small>`‑Force`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.</small> |
| <small>`‑NoJournal`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Skip recording this move in the undo journal for this call, even when journaling is enabled (Undo-DotnetMove will not see this move).</small> |
| <small>`‑WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`‑Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

**Output**

Returns a single [DotnetMove.NativeMoveResult](#dotnetmovenativemoveresult).

```text
DotnetMove.NativeMoveResult
  Engine                string
  Source                string
  Destination           string
  Performed             bool      false under -WhatIf
  SkippedCount          int
  HadFilters            bool      a paired .vcxproj.filters moved too
  Solutions             string[]  solution names updated
  UnreconciledSettings  object[]  one per native path setting to verify by hand; each has the setting name and value
```

**Examples**

```powershell
# Preview; reports the native path settings it cannot reconcile (verify by hand after)
Move-NativeProject -Project ./Aleppo/Aleppo.vcxproj -Destination ./native/Aleppo -WhatIf

# Move it (also moves the paired .vcxproj.filters)
Move-NativeProject -Project ./Aleppo/Aleppo.vcxproj -Destination ./native/Aleppo

# Move into an existing folder (lands at ./native/Aleppo)
Move-NativeProject -Project ./Aleppo/Aleppo.vcxproj -Destination ./native
```

---

### Move-UnityAsset

Move a Unity asset or folder while keeping its paired .meta file(s), so the GUIDs
that scene/prefab/asmdef references depend on survive the move.

**Syntax**

```powershell
Move-UnityAsset [-AssetPath] <string> -Destination <string> [-RepoRoot <string>] [-Force] [-NoJournal] [-WhatIf] [-Confirm] [<CommonParameters>]
```

In Unity every asset and folder has a sibling '&lt;name&gt;.meta' carrying a stable GUID.
References (in scenes, prefabs, and asmdef "references" entries of the form
"GUID:...") resolve by that GUID, not by path. If you move files on disk without
their .meta, Unity regenerates fresh GUIDs and every reference to them breaks.

This cmdlet moves the asset (git mv when tracked) together with its own .meta; for a
folder, the descendant .meta files travel inside it and the folder's sibling .meta is
moved too. asmdef references are by name/GUID (not path), so they do not need editing
- when moving an .asmdef this reports who references it, for your awareness only.

Cross-platform and target-agnostic: asmdef includePlatforms/excludePlatforms (iOS,
Android, etc.) are plain fields untouched by a move, so mobile layouts are preserved.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`‑AssetPath`</small> | <small>String</small> | <small>true</small> | <small>true (ByValue, ByPropertyName)</small> | <small>Asset file or folder to move (under Assets/ or a package). Accepts pipeline input.</small> |
| <small>`‑Destination`</small> | <small>String</small> | <small>true</small> | <small>false</small> | <small>Where to move the asset/folder, following `git mv` rules: an existing directory means move into it (keeping the name); otherwise it is the new path. Errors if it exists.</small> |
| <small>`‑RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>Root to scan for asmdef referencers. Defaults to the enclosing git repository root.</small> |
| <small>`‑Force`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.</small> |
| <small>`‑NoJournal`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Skip recording this move in the undo journal for this call, even when journaling is enabled (Undo-DotnetMove will not see this move).</small> |
| <small>`‑WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`‑Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

**Output**

Returns a single [DotnetMove.UnityMoveResult](#dotnetmoveunitymoveresult).

```text
DotnetMove.UnityMoveResult
  Engine        string
  Source        string
  Destination   string
  Performed     bool      false under -WhatIf
  SkippedCount  int
  MetaMoved     bool      the paired .meta moved too
  IsAsmdef      bool      the moved asset is an .asmdef
  ReferencedBy  string[]  asmdefs that reference a moved .asmdef; informational, refs are by name/GUID and survive
```

**Examples**

```powershell
# Preview; moves the asset/folder together with its .meta so GUIDs survive
Move-UnityAsset -AssetPath ./Assets/Plugins/Tarragon -Destination ./Assets/Lib/Tarragon -WhatIf

# Move it for real
Move-UnityAsset -AssetPath ./Assets/Plugins/Tarragon -Destination ./Assets/Lib/Tarragon

# Destination is an existing folder -> lands at ./Assets/Lib/Tarragon
Move-UnityAsset -AssetPath ./Assets/Plugins/Tarragon -Destination ./Assets/Lib
```

---

### Test-UnityMetaIntegrity

Report Unity .meta integrity problems under a root: assets missing a .meta, and
orphan .meta files whose asset is gone. These are the Unity analog of dangling
references - both lead to broken/regenerated GUIDs.

**Syntax**

```powershell
Test-UnityMetaIntegrity [[-Root] <string>] [-Strict] [<CommonParameters>]
```

Walks the tree and pairs every asset (file or folder) with its '&lt;name&gt;.meta'.
Emits one object per problem and surfaces it through the standard streams so behavior
follows invocation: by default it writes a Warning per problem; `-Strict` escalates each to
a non-terminating error (honoring `-ErrorAction`). Objects are always emitted so results are
capturable/filterable.

Ignores Unity-hidden entries (names starting with '.', folders ending with '~')
and the Library/Temp/obj caches.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`‑Root`</small> | <small>String</small> | <small>false</small> | <small>true (ByValue, ByPropertyName)</small> | <small>Folder to scan (typically an 'Assets' folder). Accepts pipeline input. Defaults to the current directory.</small> |
| <small>`‑Strict`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Escalate problems from warnings to non-terminating errors.</small> |

**Output**

Returns zero or more [DotnetMove.MetaIntegrity](#dotnetmovemetaintegrity), collected as an array (`$null` when none).
One per problem.

```text
DotnetMove.MetaIntegrity
  Kind  string  MissingMeta | OrphanMeta
  Path  string
```

**Examples**

```powershell
Test-UnityMetaIntegrity -Root ./Assets -Strict
```

Reports MissingMeta and OrphanMeta under Assets, one non-terminating error each.

## Output types

Each type below is one `pscustomobject` with the fields shown. A command may return a single one or several (and some types are also used as a field on another); whether a given command returns one or a collection is stated in that command's Output. In a field, `type[]` is array-valued, `type?` may be `$null`, and a `DotnetMove.*` field is itself one of these types.

| <small>Type</small> | <small>Represents</small> |
|:---|:---|
| <small>[DotnetMove.Capability](#dotnetmovecapability)</small> | <small>DotnetMove's resolved external-tool capabilities and platform - the 'what can I do here' probe.</small> |
| <small>[DotnetMove.ConsistencyResult](#dotnetmoveconsistencyresult)</small> | <small>One project whose solution membership diverges across the repo.</small> |
| <small>[DotnetMove.GitAlias](#dotnetmovegitalias)</small> | <small>The git dotnetmv alias registration (or what would be registered).</small> |
| <small>[DotnetMove.ImportMoveResult](#dotnetmoveimportmoveresult)</small> | <small>Result of moving a shared MSBuild .props/.targets file and fixing its importers.</small> |
| <small>[DotnetMove.MetaIntegrity](#dotnetmovemetaintegrity)</small> | <small>One Unity .meta integrity problem: an asset missing a .meta, or an orphan .meta.</small> |
| <small>[DotnetMove.MoveResult](#dotnetmovemoveresult)</small> | <small>Result of moving a .NET project folder and reconciling solutions and project references.</small> |
| <small>[DotnetMove.NativeMoveResult](#dotnetmovenativemoveresult)</small> | <small>Result of moving a native / C++/CLI project (.vcxproj).</small> |
| <small>[DotnetMove.PathReference](#dotnetmovepathreference)</small> | <small>One build/CI/hook/container line that hardcodes a moved path and that no first-party tool reconciles.</small> |
| <small>[DotnetMove.PSModuleMoveResult](#dotnetmovepsmodulemoveresult)</small> | <small>Result of moving a PowerShell module folder and reconciling its manifest.</small> |
| <small>[DotnetMove.RepairResult](#dotnetmoverepairresult)</small> | <small>One dangling solution-membership or ProjectReference entry that was (or would be) repaired.</small> |
| <small>[DotnetMove.ScriptMoveResult](#dotnetmovescriptmoveresult)</small> | <small>Result of moving a standalone .ps1 and fixing dot-source/call paths.</small> |
| <small>[DotnetMove.SolutionItem](#dotnetmovesolutionitem)</small> | <small>One entry in the full contents of a solution (or a project on disk that no solution references).</small> |
| <small>[DotnetMove.SolutionMoveResult](#dotnetmovesolutionmoveresult)</small> | <small>Result of moving a solution file and rebasing the relative project paths it stores.</small> |
| <small>[DotnetMove.SyncResult](#dotnetmovesyncresult)</small> | <small>One project added to a solution that was missing it, to resolve membership divergence.</small> |
| <small>[DotnetMove.ToolInfo](#dotnetmovetoolinfo)</small> | <small>Presence and version of one external tool (git or dotnet).</small> |
| <small>[DotnetMove.TreeMoveResult](#dotnetmovetreemoveresult)</small> | <small>Result of moving a folder of one or more .NET projects in one operation.</small> |
| <small>[DotnetMove.UnityMoveResult](#dotnetmoveunitymoveresult)</small> | <small>Result of moving a Unity asset/folder while keeping its paired .meta file(s).</small> |
| <small>[DotnetMove.Update](#dotnetmoveupdate)</small> | <small>Whether the installed DotnetMove is behind the latest GitHub release.</small> |

### DotnetMove.Capability

<small>[ [Get-DotnetMoveCapability](#get-dotnetmovecapability) ]</small>

DotnetMove's resolved external-tool capabilities and platform - the 'what can I do here' probe.

```text
DotnetMove.Capability
  Platform            string
  PSEdition           string
  DotnetSupportsSlnx  bool
  Git                 DotnetMove.ToolInfo
  Dotnet              DotnetMove.ToolInfo
```

### DotnetMove.ConsistencyResult

<small>[ [Test-SolutionConsistency](#test-solutionconsistency) ]</small>

One project whose solution membership diverges across the repo.

```text
DotnetMove.ConsistencyResult
  Project     string
  PresentIn   string[]  solution paths that list it
  AbsentFrom  string[]  solution paths that do not
```

### DotnetMove.GitAlias

<small>[ [Register-DotnetMvGitAlias](#register-dotnetmvgitalias) ]</small>

The git dotnetmv alias registration (or what would be registered).

```text
DotnetMove.GitAlias
  Alias      string
  Scope      string
  Forwarder  string
  Command    string  the git config command that was/would be run
```

### DotnetMove.ImportMoveResult

<small>[ [Move-Dotnet](#move-dotnet) | [Move-DotnetFile](#move-dotnetfile) | [Move-MSBuildImport](#move-msbuildimport) ]</small>

Result of moving a shared MSBuild .props/.targets file and fixing its importers.

```text
DotnetMove.ImportMoveResult
  Engine           string
  Source           string
  Destination      string
  Performed        bool    false under -WhatIf
  SkippedCount     int
  ImportersFixed   int     files whose <Import> was rewritten
  OwnImportsFixed  int     the moved file's own imports rewritten
  AutoImported     bool    true for a by-location import (e.g. Directory.Build.props) whose inheritance scope changed
```

### DotnetMove.MetaIntegrity

<small>[ [Test-UnityMetaIntegrity](#test-unitymetaintegrity) ]</small>

One Unity .meta integrity problem: an asset missing a .meta, or an orphan .meta.

```text
DotnetMove.MetaIntegrity
  Kind  string  MissingMeta | OrphanMeta
  Path  string
```

### DotnetMove.MoveResult

<small>[ [Move-Dotnet](#move-dotnet) | [Move-DotnetFile](#move-dotnetfile) | [Move-DotnetProject](#move-dotnetproject) ]</small>

Result of moving a .NET project folder and reconciling solutions and project references.

```text
DotnetMove.MoveResult
  Engine         string
  Source         string
  Destination    string
  Performed      bool      false under -WhatIf
  SkippedCount   int
  ConsumerCount  int       external references repointed
  OwnRefCount    int       the moved project's own references rebased
  Solutions      string[]  solution names updated
  Built          bool?     $null with -NoBuild
```

### DotnetMove.NativeMoveResult

<small>[ [Move-Dotnet](#move-dotnet) | [Move-NativeProject](#move-nativeproject) ]</small>

Result of moving a native / C++/CLI project (.vcxproj).

```text
DotnetMove.NativeMoveResult
  Engine                string
  Source                string
  Destination           string
  Performed             bool      false under -WhatIf
  SkippedCount          int
  HadFilters            bool      a paired .vcxproj.filters moved too
  Solutions             string[]  solution names updated
  UnreconciledSettings  object[]  one per native path setting to verify by hand; each has the setting name and value
```

### DotnetMove.PathReference

<small>[ [Find-PathReference](#find-pathreference) ]</small>

One build/CI/hook/container line that hardcodes a moved path and that no first-party tool reconciles.

```text
DotnetMove.PathReference
  File        string  repo-relative file containing the line
  Line        int     1-based line number
  Confidence  string  High | Low
  Text        string  the matching line
```

### DotnetMove.PSModuleMoveResult

<small>[ [Move-Dotnet](#move-dotnet) | [Move-PowerShell](#move-powershell) | [Move-PowerShellModule](#move-powershellmodule) ]</small>

Result of moving a PowerShell module folder and reconciling its manifest.

```text
DotnetMove.PSModuleMoveResult
  Engine        string
  Source        string
  Destination   string
  Performed     bool    false under -WhatIf
  SkippedCount  int
  Manifest      string  the manifest file name
```

### DotnetMove.RepairResult

<small>[ [Repair-SolutionReferences](#repair-solutionreferences) ]</small>

One dangling solution-membership or ProjectReference entry that was (or would be) repaired.

```text
DotnetMove.RepairResult
  Kind        string
  Resolution  string
  Missing     string
  NewPath     string
  Container   string
  MissingAbs  string
  Candidates  string[]  same-named project files found, used to resolve NewPath
```

### DotnetMove.ScriptMoveResult

<small>[ [Move-Dotnet](#move-dotnet) | [Move-PowerShell](#move-powershell) | [Move-PowerShellScript](#move-powershellscript) ]</small>

Result of moving a standalone .ps1 and fixing dot-source/call paths.

```text
DotnetMove.ScriptMoveResult
  Engine            string
  Source            string
  Destination       string
  Performed         bool    false under -WhatIf
  SkippedCount      int
  ReferencersFixed  int     scripts whose path to the moved file was rewritten
  OwnRefsFixed      int     the moved script's own paths rewritten
  UnresolvedRefs    int     count of possible dynamic references to verify, not a list
```

### DotnetMove.SolutionItem

<small>[ [Get-SolutionInventory](#get-solutioninventory) ]</small>

One entry in the full contents of a solution (or a project on disk that no solution references).

```text
DotnetMove.SolutionItem
  Solution  string                       repo-relative, or '(none)' for an unreferenced project
  Kind      DotnetMove.SolutionItemKind  enum: Project | SolutionFolder | SolutionItem | UnreferencedProject
  Type      string                       project extension without the dot, else empty
  Name      string
  Path      string                       as stored in the solution, or repo-relative
```

### DotnetMove.SolutionMoveResult

<small>[ [Move-Dotnet](#move-dotnet) | [Move-DotnetFile](#move-dotnetfile) | [Move-Solution](#move-solution) ]</small>

Result of moving a solution file and rebasing the relative project paths it stores.

```text
DotnetMove.SolutionMoveResult
  Engine           string
  Source           string
  Destination      string
  Performed        bool    false under -WhatIf
  SkippedCount     int
  ProjectsRebased  int     stored paths rewritten
```

### DotnetMove.SyncResult

<small>[ [Sync-Solution](#sync-solution) ]</small>

One project added to a solution that was missing it, to resolve membership divergence.

```text
DotnetMove.SyncResult
  Solution  string  repo-relative
  Added     string  repo-relative project path
```

### DotnetMove.ToolInfo

<small>[ [DotnetMove.Capability](#dotnetmovecapability) ]</small>

Presence and version of one external tool (git or dotnet).

```text
DotnetMove.ToolInfo
  Present  bool    found on PATH
  Version  string
  Path     string
```

### DotnetMove.TreeMoveResult

<small>[ [Move-Dotnet](#move-dotnet) | [Move-DotnetFolder](#move-dotnetfolder) | [Move-DotnetProjectTree](#move-dotnetprojecttree) ]</small>

Result of moving a folder of one or more .NET projects in one operation.

```text
DotnetMove.TreeMoveResult
  Engine         string
  Source         string
  Destination    string
  Performed      bool    false under -WhatIf
  SkippedCount   int
  ProjectsMoved  int
  ConsumerCount  int     external references repointed
  Built          bool?   $null with -NoBuild
```

### DotnetMove.UnityMoveResult

<small>[ [Move-Dotnet](#move-dotnet) | [Move-UnityAsset](#move-unityasset) ]</small>

Result of moving a Unity asset/folder while keeping its paired .meta file(s).

```text
DotnetMove.UnityMoveResult
  Engine        string
  Source        string
  Destination   string
  Performed     bool      false under -WhatIf
  SkippedCount  int
  MetaMoved     bool      the paired .meta moved too
  IsAsmdef      bool      the moved asset is an .asmdef
  ReferencedBy  string[]  asmdefs that reference a moved .asmdef; informational, refs are by name/GUID and survive
```

### DotnetMove.Update

<small>[ [Test-DotnetMoveUpdate](#test-dotnetmoveupdate) | [Update-DotnetMove](#update-dotnetmove) ]</small>

Whether the installed DotnetMove is behind the latest GitHub release.

```text
DotnetMove.Update
  Installed        version
  Latest           version?  $null if the tag could not be parsed
  Tag              string
  UpdateAvailable  bool
  Url              string
```

<!-- END GENERATED REFERENCE -->
