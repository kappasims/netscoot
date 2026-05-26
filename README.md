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
PowerShell modules, Unity `.meta` GUIDs, native C++ link paths.

For AI agents, the repo ships Claude Code skills that run these commands, triggering on phrases
like "move this project" (see [Skills](#skills)).

## Contents

- For users: [Requirements](#requirements), [Install](#install), [Quick start](#quick-start), [Moving](#moving), [Inspecting](#inspecting), [Repairing](#repairing), [PowerShell usage](#powershell-usage), [git usage](#git-usage), [Skills](#skills)
- For developers: [Build, test, install, docs](#build-test-install-docs), [Modules](#modules), [Layout](#layout)
- [Reference](#reference): every command, grouped by namespace

## For users

### Requirements

- PowerShell 7+ (Windows, Linux, macOS), or Windows PowerShell 5.1.
- The .NET SDK (`dotnet`) on PATH for .NET project moves; .NET 10 for `.slnx` solutions. Moving
  PowerShell or Unity files does not need it.
- git is optional; with it, moves use `git mv` and keep history, and without it `-Force` does a
  plain move.

Run `Get-DotnetMoveCapability` to see which of these (git, dotnet) the current machine has, plus
the platform and whether `.slnx` is supported.

### Install

Not on the PowerShell Gallery yet, so install from a clone. The install task copies the modules
onto your CurrentUser module path; after it you import by name and never reference the clone
again.

```powershell
git clone https://github.com/kappasims/dotnet-move
./dotnet-move/build.ps1 -Task Install     # copies to your module path (PS7 or 5.1)
Import-Module DotnetMove                   # all engines, by name

Register-DotnetMvGitAlias -Scope Global    # optional: enable `git dotnetmv` (one git-config line)
```

To work on DotnetMove itself, import straight from the clone instead of installing:
`Import-Module ./src/DotnetMove.Core/DotnetMove.Core.psd1`.

### Quick start

```powershell
# Dry-run any move with -WhatIf, then run it for real:
Move-Dotnet -Path ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon -WhatIf
Move-Dotnet -Path ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon

# Same move through the git verb:
git dotnetmv src/Tarragon/Tarragon.csproj libs/Tarragon --whatif
git dotnetmv src/Tarragon/Tarragon.csproj libs/Tarragon
```

`Move-Dotnet` detects what you passed and routes to the right engine.

### Moving

A move recomputes every stored path after the files have moved and delegates each change to the
tool that owns the format. The move commands, most general first; all are callable directly, with
full per-parameter docs in the [Reference](#reference) (generated;
`./build.ps1 -Task Docs` or `Get-Help <command> -Full`).

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

It is not entirely hands-off where native projects are involved off Windows. When you move a
shared `.props`/`.targets`, `Move-MSBuildImport` also rewrites the `<Import>` path in any native
`.vcxproj` that consumes it, on every OS. That is a best-effort, path-only update; a `.vcxproj`'s
native link settings are never reconciled off Windows, which stays `Move-NativeProject`'s
Windows-only job.

A `Move-DotnetProject` run, step by step (paths recomputed after the move, never typed by hand):

1. Enumerate the solutions that contain the project, its consumers, and its own references.
2. Remove references and solution membership while the old paths still resolve.
3. Move the directory (`git mv` if tracked, otherwise `Move-Item`).
4. Re-add membership and references so the CLI computes fresh paths.
5. Run `dotnet build` and report.

Every move supports `-WhatIf` and `-Confirm`. `-Force` falls back to a plain move when git is
unavailable (no history preserved).

### Inspecting

DotnetMove can be used purely to inspect a repo. These commands are read-only and change nothing.

| Command | Reports |
|---|---|
| `Test-SolutionConsistency` | projects with divergent solution membership across solutions |
| `Get-SolutionInventory` | full solution contents (projects of any type, folders, items) and projects in no solution |
| `Find-PathReference` | path references in build/CI/hook scripts that no move reconciles |
| `Test-UnityMetaIntegrity` | missing or orphan Unity `.meta` |
| `Resolve-MoveEngine` | which engine a given path classifies to |
| `Get-DotnetMoveCapability` | whether git and dotnet are present, plus the platform |
| `Test-DotnetMoveUpdate` | whether a newer DotnetMove release is available on GitHub |

`Get-SolutionInventory` reads `.sln`/`.slnx` directly (not just `dotnet sln list`), so it surfaces
non-CLI project types (e.g. `.pssproj`), solution folders, solution items, and any project on disk
that no solution references.

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

Flags: `--whatif` (preview), `--force` (plain move when git is unavailable), `--nobuild` (skip the
.NET build step). Unity and native engines are loaded on demand.

### Skills

For AI coding agents, the repo ships four Claude Code skills under `.claude/skills/`, one per
engine. They trigger on natural language and run the commands above:

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
```

`Install` copies the modules and their `Shared` sibling (the modules dot-source `..\Shared`), so
once that path is on `$env:PSModulePath` you can `Import-Module DotnetMove` by name (the umbrella
surfaces every engine's commands at once; native only on Windows).

CI (`.github/workflows/ci.yml`) runs the suite on ubuntu-latest and windows-latest under
PowerShell 7, plus a Windows PowerShell 5.1 job, so the cross-platform and dual-edition guarantees
are enforced on every push.

### Modules

Split by platform so the cross-platform core never ships native, Windows-only code:

- `DotnetMove.Core`: cross-platform (PowerShell 7 and Windows PowerShell 5.1). The .NET and
  PowerShell engines, the `Move-Dotnet` dispatcher, and the utilities. Depends only on the dotnet
  CLI and git.
- `DotnetMove.Unity`: cross-platform (`RequiredModules = DotnetMove.Core`). The Unity engine.
- `DotnetMove.Native`: Windows only (`RequiredModules = DotnetMove.Core`). The native C++ engine.
- `DotnetMove`: umbrella that imports every available engine in one `Import-Module`.

### Layout

```
build.ps1                Test / Analyze / Install / Docs tasks
.github/workflows/ci.yml CI: PS7 on Linux + Windows, and Windows PowerShell 5.1
src/Shared/Common/       cross-cutting helpers (Platform/Paths/Git/Plan/Capability), all modules
src/Shared/Dotnet/       .NET/MSBuild helpers (Dotnet/Solutions/Projects), Core + Native only
src/DotnetMove/          umbrella module (loads every available engine)
src/DotnetMove.Core/     cross-platform module; Private/ = helpers, Public/ = cmdlets
src/DotnetMove.Native/   Windows-only native module (Private/ + Public/; loads Common + Dotnet)
src/DotnetMove.Unity/    cross-platform Unity module (Private/ + Public/; loads Common only)
tests/                   Pester tests + fixtures
.claude/skills/          restructure-dotnet / -powershell / -unity / -native
```

## Reference

<!-- BEGIN GENERATED REFERENCE -->
<!-- Regenerate with ./build.ps1 -Task Docs. Generated from the cmdlets' comment-based help in src/; do not hand-edit between these markers. -->

**.NET and PowerShell**

| Command | What it does |
|---|---|
| [Find-PathReference](#find-pathreference) | Find references to a path in non-canonical, path-hardcoding files (build/CI/hook/ container scripts) that no first-party tool reconciles. |
| [Get-DotnetMoveCapability](#get-dotnetmovecapability) | Resolve DotnetMove's external-tool capabilities (git, dotnet) and platform. |
| [Get-SolutionInventory](#get-solutioninventory) | List the full contents of every solution in a repo - projects of any type, solution folders, and solution items - plus on-disk projects that no solution references. |
| [Move-Dotnet](#move-dotnet) | Move any supported item and reconcile references, routing by detected type to the right per-namespace front door. |
| [Move-DotnetFile](#move-dotnetfile) | Move a single managed .NET file and reconcile references, routing by extension to the right specialist. |
| [Move-DotnetFolder](#move-dotnetfolder) | Move a folder of managed .NET projects, reconciling references. |
| [Move-DotnetProject](#move-dotnetproject) | Move a .NET project folder and reconcile every solution and project reference that points at it, delegating all path/GUID changes to the dotnet CLI. |
| [Move-DotnetProjectTree](#move-dotnetprojecttree) | Move a folder that contains one or more managed .NET projects, reconciling solution membership and every external project reference in one operation. |
| [Move-MSBuildImport](#move-msbuildimport) | Move a shared MSBuild .props/.targets file and fix every project (or other props/targets) that imports it via &lt;Import Project="..."&gt;. |
| [Move-PowerShell](#move-powershell) | Move a PowerShell item and reconcile references, routing by type to the right specialist. |
| [Move-PowerShellModule](#move-powershellmodule) | Move a PowerShell module folder and reconcile its manifest, delegating manifest edits to Update-ModuleManifest rather than hand-editing the .psd1. |
| [Move-PowerShellScript](#move-powershellscript) | Move a standalone .ps1 script and fix the relative paths in scripts that dot-source or call it (and the moved script's own dot-source/call paths). |
| [Move-Solution](#move-solution) | Move a solution file (.sln/.slnx) and rebase the relative project paths it stores, so every project it references still resolves from the solution's new location. |
| [Register-DotnetMvGitAlias](#register-dotnetmvgitalias) | Opt-in: register a `git dotnetmv` alias pointing at DotnetMove's forwarder. |
| [Repair-SolutionReferences](#repair-solutionreferences) | Scan a repo for broken solution membership and dangling ProjectReferences and repair them by re-pointing each entry at the project's new location. |
| [Resolve-MoveEngine](#resolve-moveengine) | Classify a path to the reconciliation engine that should move it: dotnet, native, unity, ps-script, ps-module, or unknown. |
| [Sync-Solution](#sync-solution) | Resolve solution-membership divergence by adding each project to the solutions that are missing it, so every solution in the repo lists the same projects. |
| [Test-DotnetMoveUpdate](#test-dotnetmoveupdate) | Check GitHub for a newer DotnetMove release and report whether the installed version is behind. |
| [Test-SolutionConsistency](#test-solutionconsistency) | Report projects whose membership diverges across the solution files in a repo (present in some solutions but absent from others). |
| [Unregister-DotnetMvGitAlias](#unregister-dotnetmvgitalias) | Remove the `git dotnetmv` alias registered by Register-DotnetMvGitAlias. |

**native C++ (Windows)**

| Command | What it does |
|---|---|
| [Move-NativeProject](#move-nativeproject) | Move a native / C++/CLI project (.vcxproj). |

**Unity**

| Command | What it does |
|---|---|
| [Move-UnityAsset](#move-unityasset) | Move a Unity asset or folder while keeping its paired .meta file(s), so the GUIDs that scene/prefab/asmdef references depend on survive the move. |
| [Test-UnityMetaIntegrity](#test-unitymetaintegrity) | Report Unity .meta integrity problems under a root: assets missing a .meta, and orphan .meta files whose asset is gone. |

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

| Name | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `Path` | String | true | true (ByValue, ByPropertyName) | The item being/that was moved. Accepts pipeline input. |
| `RepoRoot` | String | false | false | Root to scan. Defaults to the enclosing git repo root. |
| `AdditionalGlob` | String[] | false | false | Extra repo-relative globs to include in the candidate set (e.g. 'deploy/*.sh'). |

**Output**

pscustomobject with File, Line, Confidence (High|Low), Text.

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
target), and git is optional (without it, moves fall back to a plain move with no history
preserved).

**Output**

DotnetMove.Capability with Platform, PSEdition, Git, Dotnet, and DotnetSupportsSlnx.

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

| Name | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `RepoRoot` | String | false | true (ByValue, ByPropertyName) | Root to scan. Accepts pipeline input (path string, or any object with a FullName/Path property). Defaults to the enclosing git repo root. Nested git worktrees are skipped. |

**Output**

One pscustomobject per item with Solution (repo-relative, or '(none)'), Kind
(Project | SolutionFolder | SolutionItem | UnreferencedProject), Type (project extension
without the dot, else empty), Name, and Path (as stored in the solution, or repo-relative).

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

Classifies the target with Resolve-MoveEngine, then dispatches to the namespace front
door, which performs the appropriate file/folder move:
  - managed .NET (.csproj/.fsproj/.vbproj/.sln/.slnx/.props/.targets, or a folder of
    them) -&gt; Move-DotnetFile / Move-DotnetFolder
  - PowerShell (.ps1/.psd1/module folder) -&gt; Move-PowerShell
  - Unity (under Assets/Packages, .meta-paired, .asmdef/.asmref) -&gt; Move-UnityAsset
    (loads DotnetMove.Unity on demand)
  - native C++ (.vcxproj) -&gt; Move-NativeProject (loads DotnetMove.Native on demand)

"dotnet" here is the .NET-platform umbrella (CLR/CoreCLR), not just the dotnet CLI - the
verb spans every engine. Each engine's behavior lives in its own cmdlet; this only routes.
-WhatIf/-Confirm/-Verbose propagate; -Force/-RepoRoot/-NoBuild are forwarded where the
target's engine accepts them.

**Parameters**

| Name | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `Path` | String | true | true (ByValue, ByPropertyName) | The item to move (file or folder). Accepts pipeline input. |
| `Destination` | String | true | false | New path - passed through to the engine. |
| `RepoRoot` | String | false | false | Repo root the engine scans for references. Defaults to the enclosing git repo root. Not used by the Unity engine. |
| `NoBuild` | SwitchParameter | false | false | Skip the verifying 'dotnet build'. Only the .NET engine builds; ignored by the others. |
| `Force` | SwitchParameter | false | false | Proceed with a plain file move when git is unavailable instead of aborting. A plain move does not preserve git history. Forwarded to the engine. |
| `WhatIf` | SwitchParameter | false | false |  |
| `Confirm` | SwitchParameter | false | false |  |

**Output**

The move-result object from the engine it routes to (see that engine's command for its shape).

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

Dispatches by extension: .csproj/.fsproj/.vbproj to Move-DotnetProject, .sln/.slnx to
Move-Solution, and .props/.targets to Move-MSBuildImport.
Native (.vcxproj), PowerShell (.ps1/.psd1) and Unity assets are deliberately not
handled here - use Move-NativeProject / Move-PowerShellScript / Move-PowerShellModule /
Move-UnityAsset. -WhatIf/-Confirm/-Verbose propagate to the specialist; -Force and
-RepoRoot/-NoBuild are forwarded where the specialist accepts them.

**Parameters**

| Name | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `Path` | String | true | true (ByValue, ByPropertyName) | The .NET file to move. Accepts pipeline input. |
| `Destination` | String | true | false | New path (file or folder) - passed through to the specialist. |
| `RepoRoot` | String | false | false | Repo root the specialist scans for references. Defaults to the enclosing git repo root. |
| `NoBuild` | SwitchParameter | false | false | Skip the verifying 'dotnet build' (forwarded to the project/import specialist). |
| `Force` | SwitchParameter | false | false | Proceed with a plain file move when git is unavailable instead of aborting. A plain move does not preserve git history. |
| `WhatIf` | SwitchParameter | false | false |  |
| `Confirm` | SwitchParameter | false | false |  |

**Output**

The result object from the .NET specialist it routes to (see Move-DotnetProject, Move-Solution, or Move-MSBuildImport for its shape).

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

| Name | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `Path` | String | true | true (ByValue, ByPropertyName) | The folder to move. Accepts pipeline input. |
| `Destination` | String | true | false | New folder path. |
| `RepoRoot` | String | false | false | Repo root scanned for references. Defaults to the enclosing git repo root. |
| `NoBuild` | SwitchParameter | false | false | Skip the verifying 'dotnet build' (forwarded to Move-DotnetProjectTree). |
| `Force` | SwitchParameter | false | false | Proceed with a plain file move when git is unavailable instead of aborting. A plain move does not preserve git history. |
| `WhatIf` | SwitchParameter | false | false |  |
| `Confirm` | SwitchParameter | false | false |  |

**Output**

DotnetMove.TreeMoveResult with Engine, Source, Destination, Performed, SkippedCount, ProjectsMoved, ConsumerCount, and Built.

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

| Name | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `Project` | String | true | true (ByValue, ByPropertyName) | Path to the project file (.csproj/.fsproj/.vbproj). Accepts pipeline input - pipe a path string or any object with a FullName/Path property (e.g. Get-Item output). |
| `Destination` | String | true | false | New folder for the project. The project file and its sibling contents move here. |
| `RepoRoot` | String | false | false | Root to scan for solutions/consumers. Defaults to the enclosing git repo root. |
| `Strict` | SwitchParameter | false | false | Escalate solution-divergence warnings to non-terminating errors. |
| `NoBuild` | SwitchParameter | false | false | Skip the verifying 'dotnet build' at the end. |
| `Force` | SwitchParameter | false | false | Proceed with a plain file move when git is unavailable instead of aborting. A plain move does not preserve git history. |
| `WhatIf` | SwitchParameter | false | false |  |
| `Confirm` | SwitchParameter | false | false |  |

**Output**

DotnetMove.MoveResult with Engine, Source, Destination, Performed, SkippedCount, Solutions, ConsumerCount, OwnRefCount, and Built.

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

| Name | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `Path` | String | true | true (ByValue, ByPropertyName) | The folder to move. Accepts pipeline input. |
| `Destination` | String | true | false | The new folder path. |
| `RepoRoot` | String | false | false | Root to scan. Defaults to the enclosing git repo root. |
| `NoBuild` | SwitchParameter | false | false | Skip the verifying build of the moved projects. |
| `Force` | SwitchParameter | false | false | Proceed with a plain file move when git is unavailable instead of aborting. A plain move does not preserve git history. |
| `WhatIf` | SwitchParameter | false | false |  |
| `Confirm` | SwitchParameter | false | false |  |

**Output**

DotnetMove.TreeMoveResult with Engine, Source, Destination, Performed, SkippedCount, ProjectsMoved, ConsumerCount, and Built.

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

| Name | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `Path` | String | true | true (ByValue, ByPropertyName) | The .props/.targets file to move. Accepts pipeline input. |
| `Destination` | String | true | false | New file path (or a folder, in which case the file keeps its name). |
| `RepoRoot` | String | false | false | Root to scan for importers. Defaults to the enclosing git repo root. |
| `Force` | SwitchParameter | false | false | Proceed with a plain file move when git is unavailable instead of aborting. A plain move does not preserve git history. |
| `WhatIf` | SwitchParameter | false | false |  |
| `Confirm` | SwitchParameter | false | false |  |

**Output**

DotnetMove.ImportMoveResult with Engine, Source, Destination, Performed, SkippedCount, ImportersFixed, OwnImportsFixed, and AutoImported.

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

Dispatches by target type:
  - a .ps1 -&gt; Move-PowerShellScript (fixes dot-source/call references, AST-based)
  - a .psd1 or module folder -&gt; Move-PowerShellModule (reconciles the manifest)
-WhatIf/-Confirm/-Verbose propagate to the specialist; -Force is forwarded, and
-RepoRoot is forwarded to the script specialist (the module specialist has no RepoRoot).

**Parameters**

| Name | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `Path` | String | true | true (ByValue, ByPropertyName) | The PowerShell item to move: a .ps1 script, a .psd1 manifest, or a module folder. Accepts pipeline input. |
| `Destination` | String | true | false | New path - passed through to the specialist. |
| `RepoRoot` | String | false | false | Repo root scanned for referencing scripts. Defaults to the enclosing git repo root. Forwarded to the script specialist only (the module specialist has no RepoRoot). |
| `Force` | SwitchParameter | false | false | Proceed with a plain file move when git is unavailable instead of aborting. A plain move does not preserve git history. |
| `WhatIf` | SwitchParameter | false | false |  |
| `Confirm` | SwitchParameter | false | false |  |

**Output**

DotnetMove.ScriptMoveResult (.ps1) or DotnetMove.ModuleMoveResult (module); see Move-PowerShellScript / Move-PowerShellModule for the shape.

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

| Name | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `ModulePath` | String | true | true (ByValue, ByPropertyName) | Path to the module folder, or directly to its .psd1 manifest. |
| `Destination` | String | true | false | New module folder. |
| `Force` | SwitchParameter | false | false | Proceed with a plain file move when git is unavailable instead of aborting. A plain move does not preserve git history. |
| `WhatIf` | SwitchParameter | false | false |  |
| `Confirm` | SwitchParameter | false | false |  |

**Output**

DotnetMove.ModuleMoveResult with Engine, Source, Destination, Performed, SkippedCount, and Manifest.

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

| Name | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `Path` | String | true | true (ByValue, ByPropertyName) | The .ps1 to move. Accepts pipeline input. |
| `Destination` | String | true | false | New file path (or a folder, in which case the script keeps its name). |
| `RepoRoot` | String | false | false | Root to scan for referencing scripts. Defaults to the enclosing git repo root. |
| `Force` | SwitchParameter | false | false | Proceed with a plain file move when git is unavailable instead of aborting. A plain move does not preserve git history. |
| `WhatIf` | SwitchParameter | false | false |  |
| `Confirm` | SwitchParameter | false | false |  |

**Output**

DotnetMove.ScriptMoveResult with Engine, Source, Destination, Performed, SkippedCount, ReferencersFixed, OwnRefsFixed, and UnresolvedRefs.

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

| Name | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `Path` | String | true | true (ByValue, ByPropertyName) | The .sln/.slnx file to move. Accepts pipeline input. |
| `Destination` | String | true | false | New file path (or a folder, in which case the solution keeps its name). |
| `Force` | SwitchParameter | false | false | Proceed with a plain file move when git is unavailable instead of aborting. A plain move does not preserve git history. |
| `WhatIf` | SwitchParameter | false | false |  |
| `Confirm` | SwitchParameter | false | false |  |

**Output**

DotnetMove.SolutionMoveResult with Engine, Source, Destination, Performed, SkippedCount, and ProjectsRebased.

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

| Name | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `Scope` | String | false | false | 'Local' (this repo, default) or 'Global' (~/.gitconfig). |
| `WhatIf` | SwitchParameter | false | false |  |
| `Confirm` | SwitchParameter | false | false |  |

**Output**

DotnetMove.GitAlias with Alias, Scope, Forwarder, and the git config Command.

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

| Name | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `RepoRoot` | String | false | true (ByValue, ByPropertyName) | Root to scan. Defaults to the enclosing git repo root of the current directory. |
| `Fix` | SwitchParameter | false | false | Re-point each dangling entry at the moved project when its new location is unambiguous. Honors -WhatIf. |
| `Prune` | SwitchParameter | false | false | Remove entries whose project cannot be found anywhere in the repo. Honors -WhatIf. |
| `WhatIf` | SwitchParameter | false | false |  |
| `Confirm` | SwitchParameter | false | false |  |

**Output**

One pscustomobject per dangling entry with Kind, Resolution, Missing, NewPath, and Container.

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

| Name | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `Path` | String | true | true (ByValue, ByPropertyName) | The item to classify. Accepts pipeline input. |

**Output**

[string] one of: dotnet, native, unity, ps-script, ps-module, unknown.

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

| Name | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `RepoRoot` | String | false | true (ByValue, ByPropertyName) | Root to scan. Accepts pipeline input. Defaults to the enclosing git repo root. Nested git worktrees are skipped. |
| `WhatIf` | SwitchParameter | false | false |  |
| `Confirm` | SwitchParameter | false | false |  |

**Output**

One pscustomobject per addition with Solution (repo-relative) and Added (repo-relative
project path).

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

| Name | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `Repository` | String | false | false | owner/name of the GitHub repository to check. Defaults to the project repository. |

**Output**

A pscustomobject with Installed (version), Latest (version), Tag, UpdateAvailable (bool),
and Url.

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

| Name | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `RepoRoot` | String | false | true (ByValue, ByPropertyName) | Root to scan. Accepts pipeline input (path string, or any object with a FullName/Path property such as Get-Item output). Defaults to the enclosing git repo root. |
| `Strict` | SwitchParameter | false | false | Escalate divergences from warnings to non-terminating errors. |

**Output**

One pscustomobject per divergent project with Project, PresentIn, and AbsentFrom.

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

| Name | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `Scope` | String | false | false | 'Local' (this repo, default) or 'Global'. |
| `WhatIf` | SwitchParameter | false | false |  |
| `Confirm` | SwitchParameter | false | false |  |

**Output**

None.

**Examples**

```powershell
Unregister-DotnetMvGitAlias -Scope Global
```

Removes the global git dotnetmv alias.

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

| Name | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `Project` | String | true | true (ByValue, ByPropertyName) | Path to the .vcxproj. Accepts pipeline input. |
| `Destination` | String | true | false | New folder for the project. |
| `RepoRoot` | String | false | false | Root to scan for solutions. Defaults to the enclosing git repo root. |
| `Force` | SwitchParameter | false | false | Proceed with a plain file move when git is unavailable instead of aborting. A plain move does not preserve git history. |
| `WhatIf` | SwitchParameter | false | false |  |
| `Confirm` | SwitchParameter | false | false |  |

**Output**

DotnetMove.NativeMoveResult with Engine, Source, Destination, Performed, SkippedCount, Solutions, UnreconciledSettings, and HadFilters.

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

| Name | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `AssetPath` | String | true | true (ByValue, ByPropertyName) | Asset file or folder to move (under Assets/ or a package). Accepts pipeline input. |
| `Destination` | String | true | false | New path for the asset/folder. |
| `RepoRoot` | String | false | false | Root to scan for asmdef referencers. Defaults to the enclosing git repo root. |
| `Force` | SwitchParameter | false | false | Proceed with a plain file move when git is unavailable instead of aborting. A plain move does not preserve git history. |
| `WhatIf` | SwitchParameter | false | false |  |
| `Confirm` | SwitchParameter | false | false |  |

**Output**

DotnetMove.UnityMoveResult with Engine, Source, Destination, Performed, SkippedCount, MetaMoved, IsAsmdef, and ReferencedBy.

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

| Name | Type | Required | Pipeline | Description |
|---|---|---|---|---|
| `Root` | String | false | true (ByValue, ByPropertyName) | Folder to scan (typically an 'Assets' folder). Accepts pipeline input. Defaults to the current directory. |
| `Strict` | SwitchParameter | false | false | Escalate problems from warnings to non-terminating errors. |

**Output**

pscustomobject with Kind (MissingMeta | OrphanMeta) and Path.

**Examples**

```powershell
Test-UnityMetaIntegrity -Root ./Assets -Strict
```

Reports MissingMeta and OrphanMeta under Assets, one non-terminating error each.

<!-- END GENERATED REFERENCE -->
