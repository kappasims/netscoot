# DotnetMove

Move and restructure .NET projects from the command line without breaking their references.

```powershell
# fixes the .sln, references, and GUIDs
Move-Dotnet -Path ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon

# the same reference-fixing move (not a plain git mv), exposed as a git verb; --whatif previews it
git dotnetmv src/Tarragon/Tarragon.csproj libs/Tarragon --whatif
```

Visual Studio reconciles a moved project for you. DotnetMove does it everywhere Visual Studio
is not (AI agents, VS Code, Rider, CLI, CI, Linux and macOS), and for what it never did:
PowerShell modules, Unity `.meta` GUIDs, Native C++ link paths.

For AI agents, the repo ships Claude Code skills that run these commands, triggering on phrases
like "move this project" (see [Skills](#skills)).

## Contents

- For users: [Requirements](#requirements), [Install](#install), [Updating](#updating), [Moving](#moving), [Inspecting](#inspecting), [Repairing](#repairing), [PowerShell usage](#powershell-usage), [git usage](#git-usage), [Skills](#skills)
- For developers: [Build, test, install, docs](#build-test-install-docs), [Modules](#modules), [Layout](#layout)
- [Reference](#reference): every command, grouped by namespace
- [Type reference](#type-reference): the output types the commands return

## For users

### Requirements

- PowerShell 7+ (Windows, Linux, macOS), or Windows PowerShell 5.1.
- The .NET SDK (`dotnet`) on PATH for .NET project moves; .NET 10 for `.slnx` solutions. Moving
  PowerShell or Unity files does not need it.
- git is optional: with it, moves use `git mv` (history kept); without it, `-Force` does a plain
  `Move-Item` (no history). `Get-DotnetMoveCapability` reports what the machine has.

### Install

Not on the PowerShell Gallery yet, so install with the hosted installer (no git or clone): it
downloads the latest release and copies the modules onto your CurrentUser module path.

```powershell
irm https://raw.githubusercontent.com/kappasims/dotnet-move/master/install.ps1 | iex
Import-Module DotnetMove                   # all engines, by name

Register-DotnetMvGitAlias -Scope Global    # optional: enable `git dotnetmv` (one git-config line)
```

To work on DotnetMove itself, install from a clone instead, or import directly:

```powershell
./build.ps1 -Task Install                          # copy this clone's modules to your module path
Import-Module ./src/DotnetMove.Core/DotnetMove.Core.psd1   # or import straight from the clone
```

### Updating

Nothing updates automatically. `Test-DotnetMoveUpdate` checks GitHub for a newer release;
`Update-DotnetMove` (or re-running the installer) applies it in place. The Claude Code skills are
separate files: refresh them with `git pull` in a clone, or re-sync `.claude/skills` if installed
globally. (Once on the PowerShell Gallery, `Update-Module DotnetMove` replaces this.)

### Moving

Every move recomputes the stored paths after the files move, delegating each change to the tool
that owns the format. The commands, most general first (full per-parameter docs in the
[Reference](#reference)):

Level 1, one command for anything:

| Command | Moves |
|---|---|
| `Move-Dotnet` | any supported file or folder; detects the type and routes |

Level 2, the everyday movers: hand them a file or a folder and they route to the right specialist.

| Command | Moves |
|---|---|
| `Move-DotnetFile` | a .NET file: `.csproj`/`.fsproj`/`.vbproj`, `.sln`/`.slnx`, `.props`/`.targets` |
| `Move-DotnetFolder` | a folder of .NET projects |
| `Move-PowerShell` | a `.ps1`, a `.psd1`, or a module folder |
| `Move-UnityAsset` | a Unity asset or folder (with its `.meta`) |
| `Move-NativeProject` | a native C++ `.vcxproj` (Windows) |

Level 3, specialists, when you want one specific reconciliation:

| Command | Moves | Reconciles via |
|---|---|---|
| `Move-DotnetProject` | one .NET project | `dotnet sln add/remove`, `dotnet add/remove reference` |
| `Move-DotnetProjectTree` | many projects under a folder | same, for every cross-boundary reference |
| `Move-Solution` | a solution (`.sln`/`.slnx`) | rebases the stored project paths |
| `Move-MSBuildImport` | a shared `.props`/`.targets` | fixes `<Import>` paths in consumers |
| `Move-PowerShellScript` | a `.ps1` | rewrites dot-source/call references from the AST |
| `Move-PowerShellModule` | a module folder | `Update-ModuleManifest` (`RootModule`/`NestedModules`/`FileList`) |

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

### Inspecting

DotnetMove can be used purely to inspect a repo. These commands are read-only and change nothing.

| Command | Reports |
|---|---|
| `Test-SolutionConsistency` | projects with divergent solution membership across solutions |
| `Get-SolutionInventory` | full solution contents beyond `dotnet sln list` (non-CLI types like `.pssproj`, folders, items) + projects in no solution |
| `Find-PathReference` | path references in build/CI/hook scripts that no move reconciles |
| `Test-UnityMetaIntegrity` | missing or orphan Unity `.meta` |
| `Resolve-MoveEngine` | which engine a given path classifies to |
| `Get-DotnetMoveCapability` | whether git and dotnet are present, plus the platform |
| `Test-DotnetMoveUpdate` | whether a newer DotnetMove release is available on GitHub |

### Repairing

It can also fix a repo whose solution entries or `<ProjectReference>`s were left dangling by a
move done outside DotnetMove, without moving anything itself. `Repair-SolutionReferences` finds
entries pointing at a project that no longer exists at the recorded path and reports each as
relocatable, missing, or ambiguous (read-only by default).

| Flag | Does |
|---|---|
| (none) | report the dangling entries and whether each can be repaired |
| `-Fix` | re-point each relocatable entry at the project's new location |
| `-Prune` | remove entries whose project is gone for good |

To resolve the membership divergence that `Test-SolutionConsistency` reports, `Sync-Solution` adds
each project to the solutions missing it (via `dotnet sln add`), making membership uniform. It only
adds, never removes; preview with `-WhatIf` first.

### PowerShell usage

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

### git usage

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

### Skills

Four Claude Code skills (`.claude/skills/`), one per engine, trigger on natural language and run
the commands above:

| Skill | Triggers on |
|---|---|
| `restructure-dotnet` | moving a `.csproj/.fsproj/.vbproj`, reorganizing a solution |
| `restructure-powershell` | moving a `.ps1` script or a PowerShell module |
| `restructure-unity` | moving a Unity asset, folder, or `.asmdef` |
| `restructure-native` | moving a native C++ `.vcxproj` (Windows) |

## For developers

### Build, test, install, docs

```powershell
./build.ps1                          # run the Pester suite (imports all modules first); CI-friendly exit code
./build.ps1 -Task Analyze            # PSScriptAnalyzer over src/ (skipped if not installed)
./build.ps1 -Task Install            # copy modules + Shared into the per-user PowerShell module path
./build.ps1 -Task Install -InstallPath D:\Modules
./build.ps1 -Task Docs               # regenerate the README Command reference section from the cmdlets' help
./build.ps1 -Task Release -Version 1.2.0           # stamp ModuleVersion in every manifest; gate on analyze + tests
./build.ps1 -Task Release -Version 1.2.0 -Publish  # also commit, tag vX.Y.Z, push, and create the GitHub release
./build.ps1 -Task Publish                          # stage + validate the single bundled package (dry run)
./build.ps1 -Task Publish -ApiKey <key>            # publish that one DotnetMove package to the PowerShell Gallery
```

`Install` copies the modules and their `Shared` sibling (the modules dot-source `..\Shared`), so
once that path is on `$env:PSModulePath` you can `Import-Module DotnetMove` by name (the umbrella
surfaces every engine's commands at once; native only on Windows).

Per-push CI (`.github/workflows/ci.yml`) runs the suite on windows-latest (PowerShell 7) and
Windows PowerShell 5.1, plus lint. Linux and macOS are on-demand (`platforms.yml`, via
`tools/Invoke-PlatformCI.ps1`) - run them before a release.

Contract: moves never hand-**write** solution/project files; every path/GUID change goes through
first-party tooling (`dotnet sln`/`reference`, `git mv`, `Update-ModuleManifest`). The only
hand-written exceptions are formats no CLI reconciles, solution stored paths, `<Import>` paths, and
script dot-source paths, via the BOM-preserving `Set-Raw*` helpers; reads parse files directly only
where no first-party reader suffices. `tests/FirstPartyDrift.Tests.ps1` locks this write surface down.

### Modules

Split by platform so the cross-platform core never ships native, Windows-only code:

- `DotnetMove.Shared`: cross-platform support module of path/git/MSBuild/solution helpers that the
  engines require. Not used directly.
- `DotnetMove.Core`: cross-platform (PowerShell 7 and Windows PowerShell 5.1). The .NET and
  PowerShell engines, the `Move-Dotnet` dispatcher, and the utilities.
- `DotnetMove.Unity`: cross-platform Unity engine.
- `DotnetMove.Native`: Windows-only native C++ engine.
- `DotnetMove`: umbrella that imports every available engine in one `Import-Module`.

Each engine declares `RequiredModules = DotnetMove.Shared`.

### Layout

```
build.ps1                Test / Analyze / Install / Docs / Release tasks
.github/workflows/      ci.yml (push: Windows + PS 5.1 + lint); platforms.yml (on-demand: Linux + macOS)
src/DotnetMove.Shared/   shared helpers module (Common/ + Dotnet/); the engines require it
src/DotnetMove/          umbrella module (loads every available engine)
src/DotnetMove.Core/     cross-platform module; Private/ = helpers, Public/ = cmdlets
src/DotnetMove.Native/   Windows-only native module (RequiredModules: DotnetMove.Shared)
src/DotnetMove.Unity/    cross-platform Unity module (RequiredModules: DotnetMove.Shared)
tests/                   Pester tests + fixtures
.claude/skills/          restructure-dotnet / -powershell / -unity / -native
```

## Reference

<!-- BEGIN GENERATED REFERENCE -->
<!-- Regenerate with ./build.ps1 -Task Docs. Generated from the cmdlets' comment-based help in src/; do not hand-edit between these markers. -->

**.NET and PowerShell**

| <small>Command</small> | <small>What it does</small> |
|:---|:---|
| <small>[Find-PathReference](#find-pathreference)</small> | <small>Find references to a path in non-canonical, path-hardcoding files (build/CI/hook/ container scripts) that no first-party tool reconciles.</small> |
| <small>[Get-DotnetMoveCapability](#get-dotnetmovecapability)</small> | <small>Resolve DotnetMove's external-tool capabilities (git, dotnet) and platform.</small> |
| <small>[Get-SolutionInventory](#get-solutioninventory)</small> | <small>List the full contents of every solution in a repo - projects of any type, solution folders, and solution items - plus on-disk projects that no solution references.</small> |
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
| <small>[Repair-SolutionReferences](#repair-solutionreferences)</small> | <small>Scan a repo for broken solution membership and dangling ProjectReferences and repair them by re-pointing each entry at the project's new location.</small> |
| <small>[Resolve-MoveEngine](#resolve-moveengine)</small> | <small>Classify a path to the reconciliation engine that should move it: dotnet, native, unity, ps-script, ps-module, or unknown.</small> |
| <small>[Sync-Solution](#sync-solution)</small> | <small>Resolve solution-membership divergence by adding each project to the solutions that are missing it, so every solution in the repo lists the same projects.</small> |
| <small>[Test-DotnetMoveUpdate](#test-dotnetmoveupdate)</small> | <small>Check GitHub for a newer DotnetMove release and report whether the installed version is behind.</small> |
| <small>[Test-SolutionConsistency](#test-solutionconsistency)</small> | <small>Report projects whose membership diverges across the solution files in a repo (present in some solutions but absent from others).</small> |
| <small>[Unregister-DotnetMvGitAlias](#unregister-dotnetmvgitalias)</small> | <small>Remove the `git dotnetmv` alias registered by Register-DotnetMvGitAlias.</small> |
| <small>[Update-DotnetMove](#update-dotnetmove)</small> | <small>Update an installed DotnetMove to the latest GitHub release, in place.</small> |

**native C++ (Windows)**

| <small>Command</small> | <small>What it does</small> |
|:---|:---|
| <small>[Move-NativeProject](#move-nativeproject)</small> | <small>Move a native / C++/CLI project (.vcxproj).</small> |

**Unity**

| <small>Command</small> | <small>What it does</small> |
|:---|:---|
| <small>[Move-UnityAsset](#move-unityasset)</small> | <small>Move a Unity asset or folder while keeping its paired .meta file(s), so the GUIDs that scene/prefab/asmdef references depend on survive the move.</small> |
| <small>[Test-UnityMetaIntegrity](#test-unitymetaintegrity)</small> | <small>Report Unity .meta integrity problems under a root: assets missing a .meta, and orphan .meta files whose asset is gone.</small> |

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

Two confidence tiers: High when the item's repo-relative path appears (e.g.
'lib/Tarragon.csproj' or 'lib\Tarragon.csproj'), Low when only the bare leaf name appears (e.g.
'Tarragon.csproj'), which is likely but not certain.

Run it before a move (to see what will break) or after (searching the old path).

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`-Path`</small> | <small>String</small> | <small>true</small> | <small>true (ByValue, ByPropertyName)</small> | <small>The item being/that was moved. Accepts pipeline input.</small> |
| <small>`-RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>Root to scan. Defaults to the enclosing git repo root.</small> |
| <small>`-AdditionalGlob`</small> | <small>String[]</small> | <small>false</small> | <small>false</small> | <small>Extra repo-relative globs to include in the candidate set (e.g. 'deploy/*.sh').</small> |

**Output**

Returns zero or more [DotnetMove.PathReference](#dotnetmovepathreference), collected as an array (`$null` when none).
One per matching line.

```text
DotnetMove.PathReference[]
  File        string  repo-relative file containing the line
  Line        int     1-based line number
  Confidence  string  High | Low
  Text        string  the matching line
```

**Examples**

```powershell
Find-PathReference -Path ./lib/Tarragon.csproj
```

Lists the build/CI/hook lines that hardcode lib/Tarragon.csproj so you can fix them by hand.

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

### Get-SolutionInventory

List the full contents of every solution in a repo - projects of any type, solution
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
| <small>`-RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>true (ByValue, ByPropertyName)</small> | <small>Root to scan. Accepts pipeline input (path string, or any object with a FullName/Path property). Defaults to the enclosing git repo root. Nested git worktrees are skipped.</small> |

**Output**

Returns zero or more [DotnetMove.SolutionItem](#dotnetmovesolutionitem), collected as an array.
One per item.

```text
DotnetMove.SolutionItem[]
  Solution  string  repo-relative, or '(none)' for an unreferenced project
  Kind      string  Project | SolutionFolder | SolutionItem | UnreferencedProject
  Type      string  project extension without the dot, else empty
  Name      string
  Path      string  as stored in the solution, or repo-relative
```

**Examples**

```powershell
Get-SolutionInventory -RepoRoot . | Format-Table -AutoSize
```

Shows every project, folder, and item across all solutions, and any unreferenced project.

```powershell
Get-SolutionInventory | Where-Object Kind -eq 'UnreferencedProject'
```

Lists only the projects on disk that no solution includes.

### Move-Dotnet

Move any supported item and reconcile references, routing by detected type to the right
per-namespace front door. The single top-level entry point (the `git dotnetmv` alias
calls this).

**Syntax**

```powershell
Move-Dotnet [-Path] <string> -Destination <string> [-RepoRoot <string>] [-NoBuild] [-Force] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Classifies the target with Resolve-MoveEngine, then dispatches to the namespace front door
that performs the appropriate file/folder move (see Output for the routing). The Unity and
native C++ front doors load DotnetMove.Unity / DotnetMove.Native on demand.

"dotnet" here is the .NET-platform umbrella (CLR/CoreCLR), not just the dotnet CLI - the
verb spans every engine. Each engine's behavior lives in its own cmdlet; this only routes.
-WhatIf/-Confirm/-Verbose propagate; -Force/-RepoRoot/-NoBuild are forwarded where the
target's engine accepts them.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`-Path`</small> | <small>String</small> | <small>true</small> | <small>true (ByValue, ByPropertyName)</small> | <small>The item to move (file or folder). Accepts pipeline input.</small> |
| <small>`-Destination`</small> | <small>String</small> | <small>true</small> | <small>false</small> | <small>New path - passed through to the engine.</small> |
| <small>`-RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>Repo root the engine scans for references. Defaults to the enclosing git repo root. Not used by the Unity engine.</small> |
| <small>`-NoBuild`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Skip the verifying 'dotnet build'. Only the .NET engine builds; ignored by the others.</small> |
| <small>`-Force`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history. Forwarded to the engine.</small> |
| <small>`-WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`-Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

**Output**

```text
managed .NET file        ->  Move-DotnetFile
folder of .NET projects  ->  Move-DotnetFolder
.ps1  .psd1  module      ->  Move-PowerShell
.vcxproj                 ->  Move-NativeProject
Unity asset  .meta       ->  Move-UnityAsset
```

These share a common shape (Engine, Source, Destination, Performed, SkippedCount) and each adds its own fields; they are plain pscustomobjects with no shared base type. See [Type reference](#type-reference).

**Examples**

```powershell
Move-Dotnet -Path ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon -WhatIf
```

Detects the .NET engine and previews moving Tarragon into libs/; nothing changes.

### Move-DotnetFile

Move a single managed .NET file and reconcile references, routing by extension to the
right specialist. The front door for file moves in the .NET family.

**Syntax**

```powershell
Move-DotnetFile [-Path] <string> -Destination <string> [-RepoRoot <string>] [-NoBuild] [-Force] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Dispatches a managed .NET file to the right specialist by extension (see Output for the
routing). Native (.vcxproj), PowerShell (.ps1/.psd1) and Unity assets are deliberately not
handled here - use Move-NativeProject / Move-PowerShellScript / Move-PowerShellModule /
Move-UnityAsset. -WhatIf/-Confirm/-Verbose propagate to the specialist; -Force and
-RepoRoot/-NoBuild are forwarded where the specialist accepts them.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`-Path`</small> | <small>String</small> | <small>true</small> | <small>true (ByValue, ByPropertyName)</small> | <small>The .NET file to move. Accepts pipeline input.</small> |
| <small>`-Destination`</small> | <small>String</small> | <small>true</small> | <small>false</small> | <small>New path (file or folder) - passed through to the specialist.</small> |
| <small>`-RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>Repo root the specialist scans for references. Defaults to the enclosing git repo root.</small> |
| <small>`-NoBuild`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Skip the verifying 'dotnet build' (forwarded to the project/import specialist).</small> |
| <small>`-Force`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.</small> |
| <small>`-WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`-Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

**Output**

```text
.csproj  .fsproj  .vbproj  ->  Move-DotnetProject   ->  DotnetMove.MoveResult
.sln  .slnx                ->  Move-Solution        ->  DotnetMove.SolutionMoveResult
.props  .targets           ->  Move-MSBuildImport   ->  DotnetMove.ImportMoveResult
```

These share a common shape (Engine, Source, Destination, Performed, SkippedCount) and each adds its own fields; they are plain pscustomobjects with no shared base type. See [Type reference](#type-reference).

**Examples**

```powershell
Move-DotnetFile -Path ./Demo.slnx -Destination ./build/Demo.slnx
```

Routes the .slnx to Move-Solution and rebases its stored project paths.

### Move-DotnetFolder

Move a folder of managed .NET projects, reconciling references. The front door for
folder moves in the .NET family; delegates to Move-DotnetProjectTree (which handles a
single project or many).

**Syntax**

```powershell
Move-DotnetFolder [-Path] <string> -Destination <string> [-RepoRoot <string>] [-NoBuild] [-Force] [-WhatIf] [-Confirm] [<CommonParameters>]
```

A folder move always goes through Move-DotnetProjectTree: it treats every managed
project under the folder as one co-moving set and reconciles only the references that
cross the folder boundary (internal references ride along unchanged). If the folder
contains no managed projects, that specialist reports it. -WhatIf/-Confirm/-Verbose
propagate; -Force/-RepoRoot/-NoBuild are forwarded.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`-Path`</small> | <small>String</small> | <small>true</small> | <small>true (ByValue, ByPropertyName)</small> | <small>The folder to move. Accepts pipeline input.</small> |
| <small>`-Destination`</small> | <small>String</small> | <small>true</small> | <small>false</small> | <small>New folder path.</small> |
| <small>`-RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>Repo root scanned for references. Defaults to the enclosing git repo root.</small> |
| <small>`-NoBuild`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Skip the verifying 'dotnet build' (forwarded to Move-DotnetProjectTree).</small> |
| <small>`-Force`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.</small> |
| <small>`-WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`-Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

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
Move-DotnetFolder -Path ./src/Group -Destination ./libs/Group -WhatIf
```

Previews moving the src/Group folder of projects via the tree mover.

### Move-DotnetProject

Move a .NET project folder and reconcile every solution and project reference
that points at it, delegating all path/GUID changes to the dotnet CLI.

**Syntax**

```powershell
Move-DotnetProject [-Project] <string> -Destination <string> [-RepoRoot <string>] [-Strict] [-NoBuild] [-Force] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Enumerates the solutions that include the project, the projects that reference it,
and the project's own references. Removes those links while the old paths still
resolve, moves the directory (git mv when tracked), then re-adds every link so the
dotnet CLI recomputes fresh relative paths and preserves GUIDs. The solution and
project XML (.sln/.slnx, .csproj) is never hand-edited.

Diagnostics follow invocation: -Verbose narrates the plan, -Debug emits the full
solution-membership matrix, and divergence (the project living in some but not all
of the repo's solutions) is surfaced as a Warning (or, with -Strict, a non-
terminating error honoring -ErrorAction).

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`-Project`</small> | <small>String</small> | <small>true</small> | <small>true (ByValue, ByPropertyName)</small> | <small>Path to the project file (.csproj/.fsproj/.vbproj). Accepts pipeline input - pipe a path string or any object with a FullName/Path property (e.g. Get-Item output).</small> |
| <small>`-Destination`</small> | <small>String</small> | <small>true</small> | <small>false</small> | <small>New folder for the project. The project file and its sibling contents move here.</small> |
| <small>`-RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>Root to scan for solutions/consumers. Defaults to the enclosing git repo root.</small> |
| <small>`-Strict`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Escalate solution-divergence warnings to non-terminating errors.</small> |
| <small>`-NoBuild`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Skip the verifying 'dotnet build' at the end.</small> |
| <small>`-Force`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.</small> |
| <small>`-WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`-Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

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
Move-DotnetProject -Project ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon -WhatIf
```

Previews the move and emits the plan object; nothing is changed.

```powershell
Get-Item ./src/Tarragon/Tarragon.csproj | Move-DotnetProject -Destination ./libs/Tarragon
```

Same move, taking the project from the pipeline.

### Move-DotnetProjectTree

Move a folder that contains one or more managed .NET projects, reconciling solution
membership and every external project reference in one operation. This is the bulk
"restructure" case (e.g. wrapping several projects into a new parent folder).

**Syntax**

```powershell
Move-DotnetProjectTree [-Path] <string> -Destination <string> [-RepoRoot <string>] [-NoBuild] [-Force] [-WhatIf] [-Confirm] [<CommonParameters>]
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
confirmed plain-move fallback via -Force / ShouldContinue); supports -WhatIf.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`-Path`</small> | <small>String</small> | <small>true</small> | <small>true (ByValue, ByPropertyName)</small> | <small>The folder to move. Accepts pipeline input.</small> |
| <small>`-Destination`</small> | <small>String</small> | <small>true</small> | <small>false</small> | <small>The new folder path.</small> |
| <small>`-RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>Root to scan. Defaults to the enclosing git repo root.</small> |
| <small>`-NoBuild`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Skip the verifying build of the moved projects.</small> |
| <small>`-Force`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.</small> |
| <small>`-WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`-Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

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
Move-DotnetProjectTree -Path ./src/Group -Destination ./libs/Group
```

Moves every project under src/Group as one set, reconciling only cross-boundary references.

### Move-MSBuildImport

Move a shared MSBuild .props/.targets file and fix every project (or other
props/targets) that imports it via &lt;Import Project="..."&gt;.

**Syntax**

```powershell
Move-MSBuildImport [-Path] <string> -Destination <string> [-RepoRoot <string>] [-Force] [-WhatIf] [-Confirm] [<CommonParameters>]
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
fallback via -Force). Supports -WhatIf.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`-Path`</small> | <small>String</small> | <small>true</small> | <small>true (ByValue, ByPropertyName)</small> | <small>The .props/.targets file to move. Accepts pipeline input.</small> |
| <small>`-Destination`</small> | <small>String</small> | <small>true</small> | <small>false</small> | <small>New file path (or a folder, in which case the file keeps its name).</small> |
| <small>`-RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>Root to scan for importers. Defaults to the enclosing git repo root.</small> |
| <small>`-Force`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.</small> |
| <small>`-WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`-Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

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
Move-MSBuildImport -Path ./Shared.props -Destination ./build/Shared.props
```

Moves the shared props and fixes the Import path in every project that consumes it.

### Move-PowerShell

Move a PowerShell item and reconcile references, routing by type to the right
specialist. The front door for PowerShell moves.

**Syntax**

```powershell
Move-PowerShell [-Path] <string> -Destination <string> [-RepoRoot <string>] [-Force] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Dispatches a PowerShell item to the right specialist by type (see Output for the routing):
the script specialist fixes dot-source/call references (AST-based), the module specialist
reconciles the manifest. -WhatIf/-Confirm/-Verbose propagate to the specialist; -Force is
forwarded, and -RepoRoot is forwarded to the script specialist (the module specialist has
no RepoRoot).

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`-Path`</small> | <small>String</small> | <small>true</small> | <small>true (ByValue, ByPropertyName)</small> | <small>The PowerShell item to move: a .ps1 script, a .psd1 manifest, or a module folder. Accepts pipeline input.</small> |
| <small>`-Destination`</small> | <small>String</small> | <small>true</small> | <small>false</small> | <small>New path - passed through to the specialist.</small> |
| <small>`-RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>Repo root scanned for referencing scripts. Defaults to the enclosing git repo root. Forwarded to the script specialist only (the module specialist has no RepoRoot).</small> |
| <small>`-Force`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.</small> |
| <small>`-WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`-Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

**Output**

```text
.ps1                   ->  Move-PowerShellScript  ->  DotnetMove.ScriptMoveResult
.psd1  module folder   ->  Move-PowerShellModule  ->  DotnetMove.ModuleMoveResult
```

These share a common shape (Engine, Source, Destination, Performed, SkippedCount) and each adds its own fields; they are plain pscustomobjects with no shared base type. See [Type reference](#type-reference).

**Examples**

```powershell
Move-PowerShell -Path ./tools/Mayo -Destination ./modules/Mayo -WhatIf
```

Detects a module folder and previews moving it, reconciling the .psd1 manifest.

### Move-PowerShellModule

Move a PowerShell module folder and reconcile its manifest, delegating manifest
edits to Update-ModuleManifest rather than hand-editing the .psd1.

**Syntax**

```powershell
Move-PowerShellModule [-ModulePath] <string> -Destination <string> [-Force] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Moves a module directory (git mv when tracked), then rewrites RootModule,
NestedModules and FileList in the .psd1 via Update-ModuleManifest so relative
references stay valid. Validates the result with Test-ModuleManifest.

Limits (warned, not fixed): dot-sourced relative paths inside .psm1/.ps1 files,
and any path computed at runtime, cannot be reconciled automatically.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`-ModulePath`</small> | <small>String</small> | <small>true</small> | <small>true (ByValue, ByPropertyName)</small> | <small>Path to the module folder, or directly to its .psd1 manifest.</small> |
| <small>`-Destination`</small> | <small>String</small> | <small>true</small> | <small>false</small> | <small>New module folder.</small> |
| <small>`-Force`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.</small> |
| <small>`-WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`-Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

**Output**

Returns a single [DotnetMove.ModuleMoveResult](#dotnetmovemodulemoveresult).

```text
DotnetMove.ModuleMoveResult
  Engine        string
  Source        string
  Destination   string
  Performed     bool    false under -WhatIf
  SkippedCount  int
  Manifest      string  the manifest file name
```

**Examples**

```powershell
Move-PowerShellModule -ModulePath ./tools/Mayo -Destination ./modules/Mayo
```

Moves the module and rewrites RootModule, NestedModules, and FileList in its .psd1.

### Move-PowerShellScript

Move a standalone .ps1 script and fix the relative paths in scripts that dot-source or
call it (and the moved script's own dot-source/call paths).

**Syntax**

```powershell
Move-PowerShellScript [-Path] <string> -Destination <string> [-RepoRoot <string>] [-Force] [-WhatIf] [-Confirm] [<CommonParameters>]
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

git is used when available (else confirmed plain-move fallback via -Force). -WhatIf
supported; dotnet not required.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`-Path`</small> | <small>String</small> | <small>true</small> | <small>true (ByValue, ByPropertyName)</small> | <small>The .ps1 to move. Accepts pipeline input.</small> |
| <small>`-Destination`</small> | <small>String</small> | <small>true</small> | <small>false</small> | <small>New file path (or a folder, in which case the script keeps its name).</small> |
| <small>`-RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>Root to scan for referencing scripts. Defaults to the enclosing git repo root.</small> |
| <small>`-Force`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.</small> |
| <small>`-WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`-Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

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
Move-PowerShellScript -Path ./lib/helpers.ps1 -Destination ./shared/helpers.ps1
```

Moves the script and rewrites the dot-source and call paths in scripts that reference it.

### Move-Solution

Move a solution file (.sln/.slnx) and rebase the relative project paths it stores, so
every project it references still resolves from the solution's new location.

**Syntax**

```powershell
Move-Solution [-Path] <string> -Destination <string> [-Force] [-WhatIf] [-Confirm] [<CommonParameters>]
```

A solution stores each project as a path relative to the solution file. Moving the
solution changes that base directory, so every entry must be recomputed. The dotnet
CLI has no "rebase" command, so this rewrites the stored paths with precise,
formatting- and BOM-preserving edits (it replaces the exact path token captured from
the file - .slnx &lt;Project Path="..."&gt; or the .sln project line - not a blind regex),
keeping each format's separator convention (/ for .slnx, \ for .sln). Project-to-project
references are unaffected by a solution move and are left alone.

git is used when available (else confirmed plain-move fallback via -Force). -WhatIf
supported. dotnet is not required.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`-Path`</small> | <small>String</small> | <small>true</small> | <small>true (ByValue, ByPropertyName)</small> | <small>The .sln/.slnx file to move. Accepts pipeline input.</small> |
| <small>`-Destination`</small> | <small>String</small> | <small>true</small> | <small>false</small> | <small>New file path (or a folder, in which case the solution keeps its name).</small> |
| <small>`-Force`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.</small> |
| <small>`-WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`-Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

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
Move-Solution -Path ./Demo.slnx -Destination ./build/Demo.slnx
```

Moves the solution and rebases each stored project path to resolve from build/.

### Register-DotnetMvGitAlias

Opt-in: register a `git dotnetmv` alias pointing at DotnetMove's forwarder. Sets a single
reversible git-config line - it never edits PATH or installs anything.

**Syntax**

```powershell
Register-DotnetMvGitAlias [[-Scope] <string>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Adds `alias.dotnetmv = !pwsh -NoProfile -File &lt;forwarder&gt;` to git config so
`git dotnetmv &lt;src&gt; &lt;dst&gt;` works. "dotnet" is the .NET-platform umbrella: the verb
branches by target type to the right engine - the .NET project model
(csproj/sln/props), Unity (.meta/.asmdef), PowerShell (.ps1/.psd1), or native C++
(.vcxproj). Scope is your choice (repo-local or global). Undo with
Unregister-DotnetMvGitAlias. Use -WhatIf to see the exact `git config` command.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`-Scope`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>'Local' (this repo, default) or 'Global' (~/.gitconfig).</small> |
| <small>`-WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`-Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

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
Register-DotnetMvGitAlias -Scope Global -WhatIf
```

Prints the exact git config command it would run, without changing anything.

### Repair-SolutionReferences

Scan a repo for broken solution membership and dangling ProjectReferences and repair them
by re-pointing each entry at the project's new location.

**Syntax**

```powershell
Repair-SolutionReferences [[-RepoRoot] <string>] [-Fix] [-Prune] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Finds solution entries and &lt;ProjectReference&gt;s that point at a project file which no longer
exists at the recorded path (usually because a project was moved or renamed without
reconciling). Read-only by default: it returns one object per problem, each tagged with a
Resolution of Relocatable, Missing, or Ambiguous.

With -Fix it repairs every Relocatable entry: it searches the repo for a project file of the
same name and re-points the entry at it through the dotnet CLI (remove the stale path, add
the found one). When one project of that name exists it is used directly; when several do,
the one that keeps the most of the original path's trailing folders is chosen, since a moved
project usually keeps its own folder name. Entries it cannot resolve are left untouched and
reported, Missing (no such project anywhere) or Ambiguous (several equally-good candidates).

With -Prune it removes the Missing entries, the genuinely deleted ones, through the dotnet
CLI. -Prune never touches Relocatable or Ambiguous entries. -Fix and -Prune can be combined.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`-RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>true (ByValue, ByPropertyName)</small> | <small>Root to scan. Defaults to the enclosing git repo root of the current directory.</small> |
| <small>`-Fix`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Re-point each dangling entry at the moved project when its new location is unambiguous. Honors -WhatIf.</small> |
| <small>`-Prune`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Remove entries whose project cannot be found anywhere in the repo. Honors -WhatIf.</small> |
| <small>`-WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`-Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

**Output**

Returns zero or more [DotnetMove.RepairResult](#dotnetmoverepairresult), collected as an array (`$null` when none).
One per dangling entry.

```text
DotnetMove.RepairResult[]
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
Repair-SolutionReferences -RepoRoot .
```

Reports dangling entries, each tagged Relocatable, Missing, or Ambiguous.

```powershell
Repair-SolutionReferences -RepoRoot . -Fix
```

Re-points every relocatable entry at the project's new location.

```powershell
Repair-SolutionReferences -RepoRoot . -Fix -Prune -WhatIf
```

Previews relocating the movable entries and removing the ones whose project is gone.

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
| <small>`-Path`</small> | <small>String</small> | <small>true</small> | <small>true (ByValue, ByPropertyName)</small> | <small>The item to classify. Accepts pipeline input.</small> |

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
dotnet
Resolve-MoveEngine ./Assets/Art/logo.png     # -> unity
```

### Sync-Solution

Resolve solution-membership divergence by adding each project to the solutions that are
missing it, so every solution in the repo lists the same projects.

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
this against the whole repo; preview with -WhatIf first and add specific projects by hand.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`-RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>true (ByValue, ByPropertyName)</small> | <small>Root to scan. Accepts pipeline input. Defaults to the enclosing git repo root. Nested git worktrees are skipped.</small> |
| <small>`-WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`-Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

**Output**

Returns zero or more [DotnetMove.SyncResult](#dotnetmovesyncresult), collected as an array (`$null` when none).
One per project added.

```text
DotnetMove.SyncResult[]
  Solution  string  repo-relative
  Added     string  repo-relative project path
```

**Examples**

```powershell
Sync-Solution -RepoRoot . -WhatIf
```

Previews which projects would be added to which solutions to make membership uniform.

```powershell
Sync-Solution -RepoRoot .
```

Adds every divergent project to the solutions missing it.

### Test-DotnetMoveUpdate

Check GitHub for a newer DotnetMove release and report whether the installed version is
behind. On-demand and read-only: it never updates anything itself.

**Syntax**

```powershell
Test-DotnetMoveUpdate [[-Repository] <string>] [<CommonParameters>]
```

DotnetMove is installed from a clone (not yet on the PowerShell Gallery), so there is no
automatic update channel. This is the pull-based check: it GETs the latest GitHub release
and compares its tag (the "available" version) against the installed module's ModuleVersion
(the "installed" version). It prints what to do when behind, but performs no update - an
agent or user runs it when they want to know.

Needs network access to api.github.com. Honors -ErrorAction if the request fails (offline,
rate-limited, or no releases yet).

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`-Repository`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>owner/name of the GitHub repository to check. Defaults to the project repository.</small> |

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
Test-DotnetMoveUpdate
```

Reports whether a newer release exists and, if so, how to update.

### Test-SolutionConsistency

Report projects whose membership diverges across the solution files in a repo
(present in some solutions but absent from others).

**Syntax**

```powershell
Test-SolutionConsistency [[-RepoRoot] <string>] [-Strict] [<CommonParameters>]
```

When a repo carries more than one solution (e.g. a classic .sln alongside a .slnx),
they can drift out of sync so the same project is listed in one but not the other.
This emits one object per divergent project and surfaces it through the standard streams
so behavior follows invocation: by default it writes a Warning per divergent project;
-Strict escalates each to a non-terminating error (honoring -ErrorAction); -Debug adds the
full membership matrix of every solution and its projects.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`-RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>true (ByValue, ByPropertyName)</small> | <small>Root to scan. Accepts pipeline input (path string, or any object with a FullName/Path property such as Get-Item output). Defaults to the enclosing git repo root.</small> |
| <small>`-Strict`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Escalate divergences from warnings to non-terminating errors.</small> |

**Output**

Returns zero or more [DotnetMove.ConsistencyResult](#dotnetmoveconsistencyresult), collected as an array (`$null` when none).
One per divergent project.

```text
DotnetMove.ConsistencyResult[]
  Project     string
  PresentIn   string[]  solution paths that list it
  AbsentFrom  string[]  solution paths that do not
```

**Examples**

```powershell
Test-SolutionConsistency -RepoRoot . -Debug
```

Reports divergent projects, and with -Debug the full membership matrix.

```powershell
Get-Item ./repoA, ./repoB | Test-SolutionConsistency -Strict
```

Checks several repos from the pipeline, raising a non-terminating error per divergence.

### Unregister-DotnetMvGitAlias

Remove the `git dotnetmv` alias registered by Register-DotnetMvGitAlias.

**Syntax**

```powershell
Unregister-DotnetMvGitAlias [[-Scope] <string>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`-Scope`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>'Local' (this repo, default) or 'Global'.</small> |
| <small>`-WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`-Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

**Output**

None.

**Examples**

```powershell
Unregister-DotnetMvGitAlias -Scope Global
```

Removes the global git dotnetmv alias.

### Update-DotnetMove

Update an installed DotnetMove to the latest GitHub release, in place. The one-command
update for non-clone installs.

**Syntax**

```powershell
Update-DotnetMove [[-Repository] <string>] [-Force] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Checks GitHub for a newer release (via Test-DotnetMoveUpdate) and, if the installed version
is behind, runs the release's install.ps1 to overwrite the modules on your module path. No
git, no clone. Does nothing when already current unless -Force. Honors -WhatIf/-Confirm.

After it runs, reload the module in the current session with `Import-Module DotnetMove -Force`.
Needs network access to GitHub. When the module ships on the PowerShell Gallery this is
superseded by `Update-Module DotnetMove`.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`-Force`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Reinstall the latest release even if the installed version is already current.</small> |
| <small>`-Repository`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>owner/name of the GitHub repository. Defaults to the project repository.</small> |
| <small>`-WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`-Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

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
Update-DotnetMove
```

Updates to the latest release if the installed copy is behind.

```powershell
Update-DotnetMove -WhatIf
```

Reports what it would do without downloading or installing.

### Move-NativeProject

Move a native / C++/CLI project (.vcxproj). Windows-only. Does the parts the
dotnet CLI can delegate (solution membership, the move itself) and reports the
native path-bearing settings it cannot reconcile so they are never silently broken.

**Syntax**

```powershell
Move-NativeProject [-Project] <string> -Destination <string> [-RepoRoot <string>] [-Force] [-WhatIf] [-Confirm] [<CommonParameters>]
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
| <small>`-Project`</small> | <small>String</small> | <small>true</small> | <small>true (ByValue, ByPropertyName)</small> | <small>Path to the .vcxproj. Accepts pipeline input.</small> |
| <small>`-Destination`</small> | <small>String</small> | <small>true</small> | <small>false</small> | <small>New folder for the project.</small> |
| <small>`-RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>Root to scan for solutions. Defaults to the enclosing git repo root.</small> |
| <small>`-Force`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.</small> |
| <small>`-WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`-Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

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
Move-NativeProject -Project ./Aleppo/Aleppo.vcxproj -Destination ./native/Aleppo -WhatIf
```

Previews the native move and reports the MSBuild path settings it cannot reconcile.

### Move-UnityAsset

Move a Unity asset or folder while keeping its paired .meta file(s), so the GUIDs
that scene/prefab/asmdef references depend on survive the move.

**Syntax**

```powershell
Move-UnityAsset [-AssetPath] <string> -Destination <string> [-RepoRoot <string>] [-Force] [-WhatIf] [-Confirm] [<CommonParameters>]
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
| <small>`-AssetPath`</small> | <small>String</small> | <small>true</small> | <small>true (ByValue, ByPropertyName)</small> | <small>Asset file or folder to move (under Assets/ or a package). Accepts pipeline input.</small> |
| <small>`-Destination`</small> | <small>String</small> | <small>true</small> | <small>false</small> | <small>New path for the asset/folder.</small> |
| <small>`-RepoRoot`</small> | <small>String</small> | <small>false</small> | <small>false</small> | <small>Root to scan for asmdef referencers. Defaults to the enclosing git repo root.</small> |
| <small>`-Force`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.</small> |
| <small>`-WhatIf`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Preview the operation and report what would change, without modifying anything.</small> |
| <small>`-Confirm`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Prompt for confirmation before each change.</small> |

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
Move-UnityAsset -AssetPath ./Assets/Plugins/Tarragon -Destination ./Assets/Lib/Tarragon -WhatIf
```

Previews moving the asset and its .meta together so GUID references survive.

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
follows invocation: by default it writes a Warning per problem; -Strict escalates each to
a non-terminating error (honoring -ErrorAction). Objects are always emitted so results are
capturable/filterable.

Ignores Unity-hidden entries (names starting with '.', folders ending with '~')
and the Library/Temp/obj caches.

**Parameters**

| <small>Name</small> | <small>Type</small> | <small>Required</small> | <small>Pipeline</small> | <small>Description</small> |
|:---|:---|:---|:---|:---|
| <small>`-Root`</small> | <small>String</small> | <small>false</small> | <small>true (ByValue, ByPropertyName)</small> | <small>Folder to scan (typically an 'Assets' folder). Accepts pipeline input. Defaults to the current directory.</small> |
| <small>`-Strict`</small> | <small>SwitchParameter</small> | <small>false</small> | <small>false</small> | <small>Escalate problems from warnings to non-terminating errors.</small> |

**Output**

Returns zero or more [DotnetMove.MetaIntegrity](#dotnetmovemetaintegrity), collected as an array (`$null` when none).
One per problem.

```text
DotnetMove.MetaIntegrity[]
  Kind  string  MissingMeta | OrphanMeta
  Path  string
```

**Examples**

```powershell
Test-UnityMetaIntegrity -Root ./Assets -Strict
```

Reports MissingMeta and OrphanMeta under Assets, one non-terminating error each.

## Type reference

The shapes the commands return. Each is a single `pscustomobject`; a trailing `[]` on the type line means a command emits zero or more of them (a collection, `$null` when empty) - the object itself is not an array. In a field, `type[]` is an array-valued field, `type?` may be `$null`, and a `DotnetMove.*` field is itself one of these types.

| <small>Type</small> | <small>Represents</small> |
|:---|:---|
| <small>[DotnetMove.Capability](#dotnetmovecapability)</small> | <small>DotnetMove's resolved external-tool capabilities and platform - the 'what can I do here' probe.</small> |
| <small>[DotnetMove.ConsistencyResult](#dotnetmoveconsistencyresult)</small> | <small>One project whose solution membership diverges across the repo.</small> |
| <small>[DotnetMove.GitAlias](#dotnetmovegitalias)</small> | <small>The git dotnetmv alias registration (or what would be registered).</small> |
| <small>[DotnetMove.ImportMoveResult](#dotnetmoveimportmoveresult)</small> | <small>Result of moving a shared MSBuild .props/.targets file and fixing its importers.</small> |
| <small>[DotnetMove.MetaIntegrity](#dotnetmovemetaintegrity)</small> | <small>One Unity .meta integrity problem: an asset missing a .meta, or an orphan .meta.</small> |
| <small>[DotnetMove.ModuleMoveResult](#dotnetmovemodulemoveresult)</small> | <small>Result of moving a PowerShell module folder and reconciling its manifest.</small> |
| <small>[DotnetMove.MoveResult](#dotnetmovemoveresult)</small> | <small>Result of moving a .NET project folder and reconciling solutions and project references.</small> |
| <small>[DotnetMove.NativeMoveResult](#dotnetmovenativemoveresult)</small> | <small>Result of moving a native / C++/CLI project (.vcxproj).</small> |
| <small>[DotnetMove.PathReference](#dotnetmovepathreference)</small> | <small>One build/CI/hook/container line that hardcodes a moved path and that no first-party tool reconciles.</small> |
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

(emitted by [Get-DotnetMoveCapability](#get-dotnetmovecapability))

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

(emitted by [Test-SolutionConsistency](#test-solutionconsistency))

One project whose solution membership diverges across the repo.

```text
DotnetMove.ConsistencyResult[]
  Project     string
  PresentIn   string[]  solution paths that list it
  AbsentFrom  string[]  solution paths that do not
```

### DotnetMove.GitAlias

(emitted by [Register-DotnetMvGitAlias](#register-dotnetmvgitalias))

The git dotnetmv alias registration (or what would be registered).

```text
DotnetMove.GitAlias
  Alias      string
  Scope      string
  Forwarder  string
  Command    string  the git config command that was/would be run
```

### DotnetMove.ImportMoveResult

(emitted by [Move-Dotnet](#move-dotnet), [Move-DotnetFile](#move-dotnetfile), [Move-MSBuildImport](#move-msbuildimport))

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

(emitted by [Test-UnityMetaIntegrity](#test-unitymetaintegrity))

One Unity .meta integrity problem: an asset missing a .meta, or an orphan .meta.

```text
DotnetMove.MetaIntegrity[]
  Kind  string  MissingMeta | OrphanMeta
  Path  string
```

### DotnetMove.ModuleMoveResult

(emitted by [Move-Dotnet](#move-dotnet), [Move-PowerShell](#move-powershell), [Move-PowerShellModule](#move-powershellmodule))

Result of moving a PowerShell module folder and reconciling its manifest.

```text
DotnetMove.ModuleMoveResult
  Engine        string
  Source        string
  Destination   string
  Performed     bool    false under -WhatIf
  SkippedCount  int
  Manifest      string  the manifest file name
```

### DotnetMove.MoveResult

(emitted by [Move-Dotnet](#move-dotnet), [Move-DotnetFile](#move-dotnetfile), [Move-DotnetProject](#move-dotnetproject))

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

(emitted by [Move-Dotnet](#move-dotnet), [Move-NativeProject](#move-nativeproject))

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

(emitted by [Find-PathReference](#find-pathreference))

One build/CI/hook/container line that hardcodes a moved path and that no first-party tool reconciles.

```text
DotnetMove.PathReference[]
  File        string  repo-relative file containing the line
  Line        int     1-based line number
  Confidence  string  High | Low
  Text        string  the matching line
```

### DotnetMove.RepairResult

(emitted by [Repair-SolutionReferences](#repair-solutionreferences))

One dangling solution-membership or ProjectReference entry that was (or would be) repaired.

```text
DotnetMove.RepairResult[]
  Kind        string
  Resolution  string
  Missing     string
  NewPath     string
  Container   string
  MissingAbs  string
  Candidates  string[]  same-named project files found, used to resolve NewPath
```

### DotnetMove.ScriptMoveResult

(emitted by [Move-Dotnet](#move-dotnet), [Move-PowerShell](#move-powershell), [Move-PowerShellScript](#move-powershellscript))

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

(emitted by [Get-SolutionInventory](#get-solutioninventory))

One entry in the full contents of a solution (or a project on disk that no solution references).

```text
DotnetMove.SolutionItem[]
  Solution  string  repo-relative, or '(none)' for an unreferenced project
  Kind      string  Project | SolutionFolder | SolutionItem | UnreferencedProject
  Type      string  project extension without the dot, else empty
  Name      string
  Path      string  as stored in the solution, or repo-relative
```

### DotnetMove.SolutionMoveResult

(emitted by [Move-Dotnet](#move-dotnet), [Move-DotnetFile](#move-dotnetfile), [Move-Solution](#move-solution))

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

(emitted by [Sync-Solution](#sync-solution))

One project added to a solution that was missing it, to resolve membership divergence.

```text
DotnetMove.SyncResult[]
  Solution  string  repo-relative
  Added     string  repo-relative project path
```

### DotnetMove.ToolInfo

(nested in [DotnetMove.Capability](#dotnetmovecapability))

Presence and version of one external tool (git or dotnet).

```text
DotnetMove.ToolInfo
  Present  bool    found on PATH
  Version  string
  Path     string
```

### DotnetMove.TreeMoveResult

(emitted by [Move-Dotnet](#move-dotnet), [Move-DotnetFolder](#move-dotnetfolder), [Move-DotnetProjectTree](#move-dotnetprojecttree))

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

(emitted by [Move-Dotnet](#move-dotnet), [Move-UnityAsset](#move-unityasset))

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

(emitted by [Test-DotnetMoveUpdate](#test-dotnetmoveupdate), [Update-DotnetMove](#update-dotnetmove))

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
