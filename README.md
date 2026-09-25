# Netscoot

[![PowerShell Gallery][gallery-badge]][gallery]
[![Downloads][downloads-badge]][gallery]
[![CI][ci-badge]][ci]
[![License][license-badge]][license]

netscoot moves .NET projects without breaking what depends on them: it updates their solution
membership and project references. It also moves PowerShell scripts and modules (updating the paths
that load them), Unity assets (keeping their `.meta` GUIDs), and native C++ projects (updating their
solution entries and references, and reporting the build settings it cannot safely rewrite). It runs
from the command line, so it works in any editor, in CI, on Linux and macOS, and for AI agents.

```powershell
# moves the project and updates the solution and references (rolls back if that fails)
Invoke-Netscoot -Path ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon

# the same move via the git verb; --whatif previews it first
git netscoot src/Tarragon/Tarragon.csproj libs/Tarragon --whatif
```

For AI agents, the repository ships Claude Code skills that run these commands, triggering on phrases
like "move this project" (see [Usage](#usage)).

**How moves edit files.** Path changes go through the tool that owns the format where one works
(`dotnet sln` / `dotnet reference` for managed projects, `git mv`). Where none does, such as native
`.vcxproj` entries, `<Import>` paths and script references, netscoot rewrites only the path text in
place and keeps every GUID, platform mapping, line of formatting and file encoding. A move rolls
back to the original state if any reconciliation step fails. A failed verifying build only warns.
Path-reference detection is report-only.

## Project philosophy

What netscoot optimizes for, in order:

1. **Accurate functionality.** Path changes delegate to first-party tooling (`dotnet sln`,
   `git mv`) wherever it works, and otherwise change only the path text. A move that breaks
   references is worse than no move.
2. **Reliability.** Write-ahead journal, in-operation rollback, structured `-WhatIf` previews, and
   CI gates against drift on both the Gallery-listed surface and the agent-discovery
   (`.claude/skills/`) surface.
3. **A conservative public shape.** Only what callers need ships as a public cmdlet. Internal
   helpers stay internal (see CONTRIBUTING for the convention). Result-type shapes are documented
   and gated.
4. **Documentation.** The Command reference is generated from comment-based help, so it cannot
   drift from the cmdlets. CHANGELOG and CONTRIBUTING carry the operational and contributor
   contracts.

Raw performance and pattern/coding-consistency refactors are not priorities of their own. They get
addressed when they collide with the four above, or when there is concrete user-facing pain to
point at, not for their own sake.

## Setup

### Requirements

- PowerShell 7+ (Windows, Linux, macOS), or Windows PowerShell 5.1.
- The .NET SDK (`dotnet`) on PATH for .NET project moves, and SDK 9.0.200 or later for `.slnx`
  solutions. Moving PowerShell or Unity files does not need it.
- git is optional. With it, moves use `git mv` and keep history. Without it, a move asks before
  falling back to a plain `Move-Item` (no history), and `-Force` skips the question.
  `Get-NetscootCapability` reports what the machine has.

### Install

Install from the [PowerShell Gallery](https://www.powershellgallery.com/packages/Netscoot) (the
single bundled package, all engines), then load it:

```powershell
Install-Module Netscoot -Scope CurrentUser     # PowerShellGet (Windows PowerShell 5.1+ / PowerShell 7)
Install-PSResource Netscoot                     # PSResourceGet (the newer installer, PowerShell 7.4+)
Import-Module Netscoot                          # load all engines, by name
```

If you cannot reach the Gallery or need to pin a release, install from a
[GitHub release](https://github.com/kappasims/netscoot/releases) with `install.ps1` instead. It copies
the module folders onto your module path. Download it, read it, then run it:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/kappasims/netscoot/master/install.ps1 -OutFile install.ps1
./install.ps1                    # the latest release, or -Version 2.6.6 to pin one
```

To update an installed copy, see [Updating](#updating).

netscoot keeps a per-user undo journal so you can reverse a move later (on by default). To install or
run with it off, see [Turning the journal off](#turning-the-journal-off).

## Usage

netscoot exposes the same moves through three front ends. The PowerShell module is the core: after
`Import-Module Netscoot`, the `Invoke-Netscoot` dispatcher routes any supported file or folder to the
right engine, or you can call an engine command (`Move-DotnetProject`, `Move-Solution`,
`Move-PowerShell`, and so on) directly.

```powershell
Import-Module Netscoot   # all engines (native is loaded on Windows only)

# Top-level dispatcher, for any supported type:
Invoke-Netscoot -Path ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon -WhatIf
Invoke-Netscoot -Path ./build/helpers.ps1 -Destination ./shared/helpers.ps1
Invoke-Netscoot -Path ./Assets/Plugins/Tarragon -Destination ./Assets/Lib/Tarragon

# Or call an engine command directly:
Move-DotnetProject     -Project ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon
Move-DotnetProjectTree -Path ./src/Group -Destination ./libs/Group
Move-Solution          -Path ./Demo.slnx -Destination ./build/Demo.slnx
Move-MSBuildImport     -Path ./Shared.props -Destination ./build/Shared.props
Move-PowerShell        -Path ./tools/Mayo -Destination ./modules/Mayo
Move-NativeProject     -Project ./Aleppo/Aleppo.vcxproj -Destination ./native/Aleppo   # Windows

# Validate without moving:
Repair-SolutionReferences -RepositoryRoot . -Fix -WhatIf
Test-SolutionConsistency  -RepositoryRoot .
```

An opt-in alias gives `git netscoot`, a single verb that forwards to `Invoke-Netscoot`. It sets one
reversible git-config line and does not edit PATH or install anything.

```powershell
Register-NetscootGitAlias -Scope Local -WhatIf   # preview the change
Register-NetscootGitAlias -Scope Local           # set it
Unregister-NetscootGitAlias -Scope Local         # undo
```

```sh
git netscoot src/Tarragon/Tarragon.csproj libs/Tarragon --whatif   # dry run
git netscoot src/Tarragon/Tarragon.csproj libs/Tarragon            # do it (like git mv, no prompt)
git netscoot Assets/Plugins/Tarragon Assets/Lib/Tarragon      # routes to the Unity engine
git netscoot Aleppo/Aleppo.vcxproj native/Aleppo          # routes to the native engine (Windows)
```

Flags: `--whatif` (preview), `--force` (plain `Move-Item` fallback without asking when git is not
installed), `--nobuild` (skip the .NET build step). Unity and native engines are loaded on demand.
The alias runs `pwsh`, so it needs PowerShell 7 on PATH.

For AI agents, four Claude Code skills (`.claude/skills/`), one per engine, trigger on natural
language and run the commands above:

| Skill | Triggers on |
| :--- | :--- |
| `restructure-dotnet` | moving a `.csproj/.fsproj/.vbproj`, reorganizing a solution |
| `restructure-powershell` | moving a `.ps1` script or a PowerShell module |
| `restructure-unity` | moving a Unity asset, folder, or `.asmdef` |
| `restructure-native` | moving a native C++ `.vcxproj` (Windows) |

An analysis skill, `netscoot-analyze` (inventory, consistency and reference checks), and a management
skill, `netscoot-manage` (update policy, journal and git alias), round out the set. Install them as a
Claude Code plugin:

```text
/plugin marketplace add kappasims/netscoot
/plugin install netscoot@netscoot
```

To take newer skill versions, run `claude plugin update netscoot@netscoot` in a shell, or open
`/plugin` in a session and choose Update now on the Installed tab. The plugin is versioned
independently of the PowerShell module, so skill fixes ship without a module release.

### Moving

Every move recomputes the stored paths after the files move, delegating each change to the tool
that owns the format. The commands, most general first (full per-parameter docs in the
[Reference](#reference)):

Level 1, one command for anything:

| Command | Moves |
| :--- | :--- |
| `Invoke-Netscoot` | any supported file or folder, routed by its detected type |

Level 2, the everyday movers, one per engine. The .NET and PowerShell movers route a file or folder to
the right specialist below.

| Command | Moves |
| :--- | :--- |
| `Move-DotnetFile` | a .NET file: `.csproj`/`.fsproj`/`.vbproj`, `.sln`/`.slnx`, `.props`/`.targets` |
| `Move-DotnetFolder` | a folder of .NET projects |
| `Move-PowerShell` | a `.ps1`, a `.psd1`, or a module folder |
| `Move-UnityAsset` | a Unity asset or folder (with its `.meta`) |
| `Move-NativeProject` | a native C++ `.vcxproj` (Windows) |

Level 3, specialists, when you want one specific reconciliation:

| Command | Moves | Reconciles via |
| :--- | :--- | :--- |
| `Move-DotnetProject` | one .NET project | `dotnet sln add/remove`, `dotnet add/remove reference` |
| `Move-DotnetProjectTree` | many projects under a folder | same, for every cross-boundary reference |
| `Move-Solution` | a solution (`.sln`/`.slnx`) | rebases the stored project paths |
| `Move-MSBuildImport` | a shared `.props`/`.targets` | fixes `<Import>` paths in consumers |
| `Move-PowerShellScript` | a `.ps1` | rewrites dot-source/call/`Import-Module` references from the AST |
| `Move-PowerShellModule` | a module folder | rewrites `Import-Module`/dot-source paths into and out of the module (manifest untouched) |

`Move-UnityAsset` moves the asset together with its `.meta`, so the GUIDs scenes and prefabs
reference are preserved (nothing to rewrite), and gives any new parent folder its own `.meta`.
`Directory.Build.props/.targets` and `Directory.Packages.props` (Central Package Management)
inheritance is the one thing no move can fix, because it changes with folder depth. The move
detects when the nearest inherited file changes and reports it.

Moving a shared `.props`/`.targets` also fixes the `<Import>` path in any consuming `.vcxproj` on
every OS (path-only). A `.vcxproj`'s native link settings are never rewritten: `Move-NativeProject`
(Windows) reports them for you to verify. A `Move-DotnetProject` run, step by step:

1. Enumerate the solutions, consumers, and own references of the project.
2. Remove references and solution membership while the old paths still resolve.
3. Move the directory (`git mv` if tracked, else `Move-Item`).
4. Re-add membership and references so the CLI recomputes fresh paths. If any step up to here
   fails, the move rolls back to the original state.
5. Build and report. A failed build warns, and the move stays.

Every move supports `-WhatIf` and `-Confirm`. `-Force` skips the question before the no-git fallback.

### Repairing

It can also fix a repository whose solution entries or `<ProjectReference>`s were left dangling by a
move done outside netscoot, without moving anything itself. `Repair-SolutionReferences` finds
entries pointing at a project that no longer exists at the recorded path and reports each as
relocatable, missing, or ambiguous (read-only by default).

| Flag | Does |
| :--- | :--- |
| (none) | report the dangling entries and whether each can be repaired |
| `-Fix` | re-point each relocatable entry at the project's new location |
| `-Prune` | remove entries whose project is gone for good |

To resolve the membership divergence that `Test-SolutionConsistency` reports, `Sync-Solution` adds
each managed project to the solutions missing it (via `dotnet sln add`), within each group of
solutions that share projects. It only adds and never removes. Preview with `-WhatIf` first.

### Inspecting

netscoot can be used purely to inspect a repository. These commands are read-only and change nothing.

| Command | Reports |
| :--- | :--- |
| `Test-SolutionConsistency` | projects with divergent solution membership across solutions |
| `Get-SolutionInventory` | full solution contents beyond `dotnet sln list` (non-CLI types like `.pssproj`, folders, items) + projects in no solution |
| `Find-PathReference` | path references in build/CI/hook scripts that no move reconciles |
| `Test-UnityMetaIntegrity` | missing or orphan Unity `.meta` |
| `Resolve-MoveEngine` | which engine a given path classifies to |
| `Get-NetscootCapability` | whether git and dotnet are present, plus the platform |
| `Test-NetscootUpdate` | whether a newer netscoot release is available on GitHub |

Each returns objects, so results are filterable and scriptable, and print as a table by default.

#### Canonical post-refactor sanity check

When a refactor, rename, or move appears done, run

```powershell
Find-PathReference -Path <old identifier or path>
```

over the OLD identifier (the moved file's old path, a renamed type, an old DLL name in build
scripts), from the repository root. The default scan skips source files, so add `-AllFiles` when the
identifier can appear in code. The output is structured (`File`, `Line`, `Confidence`, `Text`) and
the cmdlet emits the warning *"These are not auto-reconciled - review and fix them by hand."* Treat
that warning as the agent-readable signal that some references survive in places the move machinery
does not touch: build scripts, CI YAML, git hooks, container files, documentation snippets. Use this
BEFORE declaring a rename complete. If it returns rows, fix them by hand and re-run. A zero-row
result with no warning is the all-clear.

This is the idiomatic "did I miss anything" pattern. It is what `netscoot-analyze` routes to when
an AI agent is asked "is the rename done" / "any stragglers" / "where else does X appear" / "what
would break." Prefer it over an ad-hoc `Grep`: `Find-PathReference` knows which file kinds are
candidates, applies a confidence rating, and excludes paths the move machinery already reconciled.

<details>
<summary>Sample output</summary>

```text
PS> Test-SolutionConsistency
Project            PresentIn         AbsentFrom
-------            ---------         ----------
src/Lib/Lib.csproj App.sln, Api.sln  Tools.sln

PS> Get-SolutionInventory
Name          Kind                Type   Solution Path
----          ----                ----   -------- ----
Lib.csproj    Project             csproj App.sln  src/Lib/Lib.csproj
build         SolutionFolder             App.sln
Legacy.csproj UnreferencedProject csproj (none)   tools/Legacy/Legacy.csproj

PS> Find-PathReference -Path ./src/Lib/Lib.csproj
File                     Line Confidence Text
----                     ---- ---------- ----
.github/workflows/ci.yml   31 High       dotnet build src/Lib/Lib.csproj
build.ps1                  12 Low        $proj = 'Lib.csproj'

PS> Test-UnityMetaIntegrity ./Assets
Kind        Path
----        ----
MissingMeta /repo/Assets/Art/logo.png
OrphanMeta  /repo/Assets/Old/gone.cs.meta
```

</details>

### Undoing

Every move is recorded in a per-user journal (one file per repository), so you can reverse it later,
even from a fresh session. `Undo-Netscoot` replays the recorded inverse (the same move with source and
destination swapped), re-reconciling from the current state rather than restoring a stale snapshot.
Pick what to reverse: `-Last` (the default, the most recent move), `-Id <id>` (one specific move),
`-After <time>` (every move recorded since a time), or `-All` (everything). `-List` shows what is
available.

A successful undo removes that entry from the journal, and the reversing move is not itself recorded,
so repeated `-Last` calls walk the history backwards rather than toggling one move on and off. The
bulk modes reverse newest-first, so each step re-reconciles after the moves that followed it are gone.

Undo applies to the move commands. `Sync-Solution` and `Repair-SolutionReferences` are not journaled,
so preview either with `-WhatIf` first.

```powershell
Undo-Netscoot -List                       # what can be undone (oldest first)
Undo-Netscoot -WhatIf                      # preview reversing the most recent move
Undo-Netscoot                              # reverse the most recent move, and call again to walk back further
Undo-Netscoot -Id a1b2c3d4                 # reverse one specific move (its id from -List)
Undo-Netscoot -After (Get-Date).AddHours(-1)   # reverse everything from the last hour, newest first
Undo-Netscoot -All                         # reverse every move, newest first
```

`-List` returns the entries (tagged `Netscoot.JournalEntry`), which print as a table:

```text
Id       When             Command            Source             Destination
--       ----             -------            ------             -----------
a1b2c3d4 2026-05-27 14:02 Move-DotnetProject /repo/src/Tarragon /repo/libs/Tarragon
9f3e1c77 2026-05-27 14:05 Move-Solution      /repo/Demo.slnx    /repo/build/Demo.slnx
```

`-All` and `-After` walk back several moves at once, so they prompt for a yes/no confirmation that
`-Confirm:$false` does not silence. Pass `-Force` to bypass it (for automation) or `-WhatIf` to list
the reversals first.

Journaling is **on by default**. To turn it off (any install method, the PowerShell Gallery
included), see [Turning the journal off](#turning-the-journal-off).

### Updating

Nothing updates automatically. For Gallery installs, `Update-Module Netscoot` is the one-liner.
Otherwise `Test-NetscootUpdate` checks GitHub for a newer release and `Update-Netscoot` (or
re-running the installer) applies it in place. The Claude Code skills update separately through the
plugin: `claude plugin update netscoot@netscoot` in a shell, or Update now on the Installed tab of
`/plugin`. In a clone, `git pull` refreshes them in place.

> Updating from a release before 2.6.1: the in-box `Test-NetscootUpdate` / `Update-Netscoot` cannot
> fetch the fix, since the broken endpoint they shipped with is exactly what 2.6.1 repairs. Update
> once by the path you installed from - `Update-Module Netscoot` (Gallery), `git pull` then
> `./build.ps1 -Task Install` (clone), or re-run `install.ps1` (installer) - then the in-box updater
> works again.

A single policy governs automatic behavior, set with `Set-NetscootUpdatePolicy` (or read with
`Get-NetscootUpdatePolicy`):

| State | Automatic check (`Test-NetscootUpdate -Auto`) | `Update-Netscoot` |
| :--- | :--- | :--- |
| `Enabled` | runs | allowed |
| `Manual` (default) | no-op | allowed (when you run it) |
| `Disabled` | no-op | refused (`-Force` overrides a Disabled you set yourself, not an admin one) |

```powershell
Set-NetscootUpdatePolicy -State Enabled              # opt in: Test-NetscootUpdate -Auto now checks
Set-NetscootUpdatePolicy -State Disabled -Scope Machine   # block updates for every user (elevated)
Get-NetscootUpdatePolicy                             # show the effective state and where it came from
```

The policy is stored in the `NETSCOOT_AUTOUPDATE` environment variable, so an administrator can set
the same states fleet-wide through Group Policy / Intune (truthy = Enabled, falsy = Disabled). A
manual `Update-Netscoot` you run yourself works unless the policy is Disabled. The automatic `-Auto`
check, for example from a SessionStart hook you configure, stays silent unless the policy is
Enabled. `-Force` overrides a Disabled you set for yourself, but never one an administrator set.

## How the journal works

The journal lives in a per-user data directory (`%LOCALAPPDATA%\netscoot` on Windows,
`~/Library/Application Support/netscoot` on macOS, `$XDG_DATA_HOME/netscoot` or
`~/.local/share/netscoot` on Linux), one file per git repository. So git never tracks it, `git clean`
cannot remove it, and your `.gitignore` is left untouched. Set `$env:NETSCOOT_JOURNAL_HOME` to
relocate the store (for example a roaming or managed path).

On disk each entry is one JSON line recording the reversing invocation (the mover and the swapped
splat that `Undo-Netscoot` replays), with absolute paths:

```json
{"v":2,"id":"a1b2c3d4","timestamp":"2026-05-27T14:02:11Z","status":"committed","command":"Move-DotnetProject","engine":"dotnet","source":"/repo/src/Tarragon","destination":"/repo/libs/Tarragon","undo":{"Command":"Move-DotnetProject","Params":{"Project":"/repo/libs/Tarragon/Tarragon.csproj","Destination":"/repo/src/Tarragon"}},"snapshot":"","backup":[]}
```

Each move is written ahead of time: a `pending` record before it runs, then a `committed` record
after, so a move interrupted by a crash is detectable (and recoverable with `Repair-NetscootJournal`).
Writes are append-only. The journal prunes only when it outgrows a 1 MB cap. It then drops entries
older than 180 days and, oldest first, anything beyond the cap, always keeping the newest move.

It is safe to delete at any time (`Clear-NetscootJournal`). Each entry is schema-versioned, so a
newer netscoot reads an older journal, and an older netscoot ignores (never misreads) entries written
by a newer one.

### Turning the journal off

The journal is **on by default** because undo is broadly useful, but it is fully opt-out. Turn it off
if you would rather netscoot keep no out-of-tree per-user state (privacy or a clean machine), on
ephemeral or CI agents where you will never undo, or in a locked-down/managed environment. It is a
git/env setting, not an install option, so the same controls work no matter how you installed -
**including the PowerShell Gallery**:

```powershell
# From the Gallery (or any install): turn it off for every repository on the machine
Install-Module Netscoot -Scope CurrentUser
Set-NetscootJournal -Enabled $false -Global

Set-NetscootJournal -Enabled $false      # just this repository
$env:NETSCOOT_JOURNAL = 0                 # this session only (or fleet-wide via Group Policy / Intune)
./install.ps1 -NoJournal                  # GitHub-release installer: sets the global git setting (or the env var without git)
Clear-NetscootJournal                     # also discard an existing journal
```

The enabled state resolves in this order, first match wins: an internal suppression flag (set by
`Undo-Netscoot` around its own reverse move) → the `NETSCOOT_JOURNAL` env var (`off`/`0`/`false`, or
`on`/`1`/`true`) → `git config netscoot.journal` (local wins over global, the durable per-repository
setting) → on. The env var trumps git config so an admin can force the choice fleet-wide. The git
setting is the persistent per-repository default. Installing with `-NoJournal` writes the global git
setting, or the env var when git is missing, and updates never flip it back on.

## Footprint

Everything netscoot writes, and where:

- **Installing** copies the module folders to your CurrentUser PowerShell module path (already on
  `$env:PSModulePath`), or an `-InstallPath` you choose. Installing and updating download the release
  zip to the system temp dir. They and the update check (`Test-NetscootUpdate`) are the only actions
  that touch the network (`github.com` / `api.github.com`).
- **A move** edits the target repository's solution/project files to reconcile it, through first-party
  tooling where one exists and path-text-only edits otherwise (see [How moves edit files](#netscoot)).
  It writes a per-repository undo journal to the per-user data directory (out of the working tree, so
  `git status` stays clean, see [How the journal works](#how-the-journal-works)). It also snapshots
  the files it edits to the system temp dir for rollback, removed when the move finishes. See
  [Turning the journal off](#turning-the-journal-off) to opt out of the journal.
- **Only when you ask:** `Register-NetscootGitAlias` adds one `alias.netscoot` line to your git
  config. `install.ps1 -NoJournal` or `Set-NetscootJournal` turns the journal off, and
  `Clear-NetscootJournal` deletes a repository's journal. `Set-NetscootUpdatePolicy` sets the
  `NETSCOOT_AUTOUPDATE` environment variable, persisted for your user or the machine on Windows.

Nothing else under your home or AppData is touched: it never edits `PATH`, never auto-installs git or
the .NET SDK, and sends no telemetry.

### Environment variables

Each variable below is unset by default and is an opt-in control.

<details>
<summary>Environment variables</summary>

| Variable | Values | Effect |
| :--- | :--- | :--- |
| `NETSCOOT_JOURNAL` | `off`/`0`/`false`, or `on`/`1`/`true` | Turns the undo journal off or on. Trumps `git config netscoot.journal`, so an admin can force it either way fleet-wide. |
| `NETSCOOT_JOURNAL_HOME` | a directory | Relocates the journal store away from the per-user data dir above (point it at a roaming or managed path). |
| `NETSCOOT_AUTOUPDATE` | `true` / `false` | Backs the update policy (see [Updating](#updating)): truthy = Enabled, falsy = Disabled, unset = Manual. Prefer `Set-NetscootUpdatePolicy`, and set this directly for Group Policy / Intune. |
| `NETSCOOT_JOURNAL_SUPPRESS` | internal | Set by `Undo-Netscoot` around its own reverse move so the undo is not itself journaled. Not meant to be set by hand. |

</details>

The full journaling precedence and how to turn it off live under
[How the journal works](#how-the-journal-works).

> [!NOTE]
> **For sysadmins.** Both controls are fleet-settable. Set `NETSCOOT_AUTOUPDATE` machine-wide via
> Group Policy / Intune to force the update policy: `false` = Disabled, which blocks
> `Update-Netscoot` for every user and cannot be overridden, and `true` = Enabled (see
> [Updating](#updating)). Journaling is a git setting (`git config [--global] netscoot.journal`)
> that the `NETSCOOT_JOURNAL` env var overrides fleet-wide (see
> [Turning the journal off](#turning-the-journal-off)).

Contributing / building from source: see [CONTRIBUTING.md](CONTRIBUTING.md).

## Reference

<!-- BEGIN GENERATED REFERENCE -->
<!-- Regenerate with ./build.ps1 -Task Docs. Generated from the cmdlets' comment-based
help in src/; do not hand-edit between these markers. -->

### Command reference

#### Move

Relocate a project, folder, file, module, or asset and reconcile what the move would otherwise break.

| Command | What it does |
| :--- | :--- |
| [Invoke-Netscoot](#invoke-netscoot) | Move any supported item and reconcile references, routing by detected type to the right per-namespace front door. |
| [Move-DotnetProject](#move-dotnetproject) | Move a .NET project folder and reconcile every solution and project reference that points at it, delegating all path/GUID changes to the dotnet CLI. |
| [Move-DotnetProjectTree](#move-dotnetprojecttree) | Move a folder that contains one or more managed .NET projects, reconciling solution membership and every external project reference in one operation. |
| [Move-DotnetFile](#move-dotnetfile) | Move a single managed .NET file and reconcile references, routing by extension to the right specialist. |
| [Move-DotnetFolder](#move-dotnetfolder) | Move a folder of managed .NET projects, reconciling references. |
| [Move-MSBuildImport](#move-msbuildimport) | Move a shared MSBuild `.props/.targets` file and fix every project (or other props/targets) that imports it via `<Import Project="...">`. |
| [Move-Solution](#move-solution) | Move a solution file (`.sln/.slnx`) and rebase the relative project paths it stores, so every project it references still resolves from the solution's new location. |
| [Move-PowerShell](#move-powershell) | Move a PowerShell item and reconcile references, routing by type to the right specialist. |
| [Move-PowerShellScript](#move-powershellscript) | Move a standalone `.ps1` script and fix the relative paths in scripts that dot-source or call it (and the moved script's own dot-source/call paths). |
| [Move-PowerShellModule](#move-powershellmodule) | Move a PowerShell module folder and update the script paths that reference it or that it uses. |
| [Move-NativeProject](#move-nativeproject) | Move a native or C++/CLI project (`.vcxproj`), update the solutions and projects that reference it, and report the native path-bearing settings it does not rewrite so they are never silently broken. |
| [Move-UnityAsset](#move-unityasset) | Move a Unity asset or folder while keeping its paired `.meta` file(s), so the GUIDs that scene/prefab/asmdef references depend on survive the move. |

#### Inspect

Read-only audits. These change nothing.

| Command | What it does |
| :--- | :--- |
| [Resolve-MoveEngine](#resolve-moveengine) | Classify a path to the reconciliation engine that should move it: dotnet, native, unity, ps-script, ps-module, or unknown. |
| [Get-NetscootCapability](#get-netscootcapability) | Resolve Netscoot's external-tool capabilities (git, dotnet) and platform. |
| [Test-SolutionConsistency](#test-solutionconsistency) | Report projects whose membership diverges across the solution files in a repository (present in some solutions but absent from others). |
| [Get-SolutionInventory](#get-solutioninventory) | List the full contents of every solution in a repository (projects of any type, solution folders, and solution items), plus on-disk managed and native projects that no solution references. |
| [Find-PathReference](#find-pathreference) | Find references to a path in non-canonical, path-hardcoding files (build/CI/hook/ container scripts) that no first-party tool reconciles. |
| [Test-UnityMetaIntegrity](#test-unitymetaintegrity) | Report Unity `.meta` integrity problems under a root: Assets missing a `.meta`, and orphan `.meta` files whose asset is gone. |
| [Test-EditorSolutionGuard](#test-editorsolutionguard) | Check that a repository's editor configuration will keep a `.slnx` consolidation durable - i.e. |

#### Manage

Reconcile a repository, undo moves, and control the journal.

##### Reconcile

| Command | What it does |
| :--- | :--- |
| [Repair-SolutionReferences](#repair-solutionreferences) | Scan a repository for broken solution membership and dangling ProjectReferences and repair them by re-pointing each entry at the project's new location. |
| [Sync-Solution](#sync-solution) | Resolve solution-membership divergence by adding each project to the solutions that are missing it, within each group of solutions that share projects. |

##### Undo & journal

| Command | What it does |
| :--- | :--- |
| [Undo-Netscoot](#undo-netscoot) | Reverse previous netscoot moves from the per-user journal. |
| [Repair-NetscootJournal](#repair-netscootjournal) | Report and recover moves the journal recorded as started but never finished (interrupted by a crash), and clear orphaned recovery snapshots. |
| [Set-NetscootJournal](#set-netscootjournal) | Turn the move journal on or off, per repository (default) or for every repository (`-Global`). |
| [Clear-NetscootJournal](#clear-netscootjournal) | Delete a repository's move journal, discarding its undo history. |

#### Install & environment

Manage the installation itself and wire up the git integration.

##### Stay current

| Command | What it does |
| :--- | :--- |
| [Test-NetscootUpdate](#test-netscootupdate) | Check GitHub for a newer netscoot release and report whether the installed version is behind. |
| [Update-Netscoot](#update-netscoot) | Update an installed netscoot to the latest GitHub release, in place. |

##### Update policy

| Command | What it does |
| :--- | :--- |
| [Get-NetscootUpdatePolicy](#get-netscootupdatepolicy) | Report the effective auto-update policy and where it was resolved from. |
| [Set-NetscootUpdatePolicy](#set-netscootupdatepolicy) | Set netscoot's auto-update policy to Enabled, Disabled, or Manual. |

##### Git verb

| Command | What it does |
| :--- | :--- |
| [Register-NetscootGitAlias](#register-netscootgitalias) | Opt-in: register a `git netscoot` alias pointing at Netscoot's forwarder. |
| [Unregister-NetscootGitAlias](#unregister-netscootgitalias) | Remove the `git netscoot` alias registered by [Register-NetscootGitAlias](#register-netscootgitalias). |

---

#### Clear-NetscootJournal

Delete a repository's move journal, discarding its undo history.

##### Syntax

```powershell
Clear-NetscootJournal [[-RepositoryRoot] <string>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Removes this repository's journal file from the per-user store (LocalAppData on Windows, ~/Library/Application Support
on macOS, `$XDG_DATA_HOME` or ~/.local/share on Linux, or the folder `NETSCOOT_JOURNAL_HOME` names). The journal prunes
itself when it outgrows its size cap (dropping entries older than the age cap, then the oldest past the size cap), so
this is rarely needed. Use it to wipe the undo history outright. After clearing, [Undo-Netscoot](#undo-netscoot) has
nothing to reverse until the next move. It does not change whether journaling is on.
[Set-NetscootJournal](#set-netscootjournal) does that.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑RepositoryRoot` | String | false | false | Repository whose journal to delete. Defaults to the enclosing git repository root. |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

None.

##### Examples

```powershell
# Discard the undo history for this repository
Clear-NetscootJournal

# Preview without deleting
Clear-NetscootJournal -WhatIf
```

##### Related

[ [Set-NetscootJournal](#set-netscootjournal) | [Undo-Netscoot](#undo-netscoot) |
[Repair-NetscootJournal](#repair-netscootjournal) ]

[Back to Command reference](#command-reference)

---

#### Find-PathReference

Find references to a path in non-canonical, path-hardcoding files (build/CI/hook/ container scripts) that no first-party
tool reconciles. Report-only.

##### Syntax

```powershell
Find-PathReference [-Path] <string> [-RepositoryRoot <string>] [-AdditionalGlob <string[]>] [-AllFiles] [<CommonParameters>]
```

Moving a project/folder breaks any path hardcoded in `build.ps1`, CI YAML, git hooks, tools scripts,
Makefile/Dockerfile, etc. - and unlike `.sln/.csproj/.psd1` there is no tool that understands their schema, so they
cannot be safely auto-rewritten (a blind regex could corrupt logic). This detects the class of such files (by location +
name, not a hardcoded filename list) and reports lines that reference the given path, so you (or an agent) can fix them
deliberately. It never edits anything. Two confidence tiers: High when the item's repository-relative path appears (e.g.
'`lib/Tarragon.csproj`' or 'lib\\`Tarragon.csproj`'), Low when only the bare leaf name appears (e.g.
'`Tarragon.csproj`'), which is likely but not certain. By default it scans only the class of non-canonical,
path-hardcoding files (the ones no first-party tool reconciles), which keeps the result focused and avoids flagging the
project's own source. Pass `-AllFiles` to instead search EVERY text file under the repository (caches, vendored dirs,
and binary files excluded) - the "look literally everywhere" mode for when a reference may live in an ordinary source
file the default classifier skips (e.g. a build script in a non-standard directory). Both modes are report-only and
never edit. Run it before a move (to see what will break) or after (searching the old path).

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Path` | String | true | true (ByValue) | The path whose references to find (typically a recently moved item). Accepts pipeline input: a path string, or a file/directory item from Get-Item / Get-ChildItem. |
| `‑RepositoryRoot` | String | false | false | Root to scan. Defaults to the enclosing git repository root of the current directory, not of `-Path`, which may no longer exist. |
| `‑AdditionalGlob` | String[] | false | false | Extra repository-relative globs to include in the candidate set (e.g. 'deploy/*.sh'). |
| `‑AllFiles` | SwitchParameter | false | false | Search every text file under the repository instead of only the build/CI/hook/container file class. Caches/vendored dirs (.git, bin, obj, node_modules, ...) and binary file kinds are still excluded. Broader and noisier, but catches references in ordinary source files the default scan deliberately skips. |

##### Output

Returns zero or more [Netscoot.PathReference](#netscootpathreference), collected as an array (`$null` when none).
One per matching line.

```text
Netscoot.PathReference
  File        string  # repository-relative file containing the line
  Line        int     # 1-based line number
  Confidence  string  # High | Low
  Text        string  # the matching line
```

##### Examples

```powershell
# Build/CI/hook lines that hardcode the path (report-only)
Find-PathReference -Path ./lib/Tarragon.csproj

# Scan the old path after a move to find what still points at it
Find-PathReference -Path ./libs/Tarragon/Tarragon.csproj

# Widen the candidate set with extra repository-relative globs
Find-PathReference -Path ./lib/Tarragon.csproj -AdditionalGlob 'deploy/*.sh','*.psake.ps1'

# Search EVERY text file (not just build/CI/hook files) for the reference
Find-PathReference -Path ./lib/Tarragon.csproj -AllFiles
```

[Back to Command reference](#command-reference)

---

#### Get-NetscootCapability

Resolve Netscoot's external-tool capabilities (git, dotnet) and platform. This is the canonical "what can I do here"
probe - netscoot does not auto-install anything.

##### Syntax

```powershell
Get-NetscootCapability [<CommonParameters>]
```

PowerShell has no manifest mechanism to declare external-CLI prerequisites, so this is a runtime probe via Get-Command.
dotnet is required for .NET project moves (the delegation target). git is optional. Without it, a move asks before
falling back to a plain PowerShell `Move-Item`, which preserves no history, and `-Force` skips the question.

##### Output

Returns a single [Netscoot.Capability](#netscootcapability).

```text
Netscoot.Capability
  Platform            string
  PSEdition           string
  DotnetSupportsSlnx  bool
  Git                 Netscoot.ToolInfo
                        Present  bool    # found on PATH
                        Version  string
                        Path     string
  Dotnet              Netscoot.ToolInfo
                        Present  bool    # found on PATH
                        Version  string
                        Path     string
```

##### Examples

```powershell
# Probe machine capabilities (returns an object with Platform, PSEdition, Git, Dotnet, DotnetSupportsSlnx)
Get-NetscootCapability
```

[Back to Command reference](#command-reference)

---

#### Get-NetscootUpdatePolicy

Report the effective auto-update policy and where it was resolved from.

##### Syntax

```powershell
Get-NetscootUpdatePolicy [<CommonParameters>]
```

netscoot's update behavior is governed by one policy with three states: Enabled automatic checks run
([Test-NetscootUpdate](#test-netscootupdate) `-Auto`), and [Update-Netscoot](#update-netscoot) is allowed. Manual
(default) no automatic check runs, but a [Update-Netscoot](#update-netscoot) you invoke yourself works. Disabled
automatic checks do nothing, and [Update-Netscoot](#update-netscoot) refuses (`-Force` overrides). The policy is stored
in the `NETSCOOT_AUTOUPDATE` environment variable, so it can be set with
[Set-NetscootUpdatePolicy](#set-netscootupdatepolicy) or pushed by an administrator (Group Policy / Intune / a profile).
An administrator's machine-wide Disabled always applies. Otherwise the value resolves in precedence order: the current
process, then (on Windows) the user environment, then the machine environment. A truthy value (`1`/`true`/`on`) is
Enabled, a falsy one (`0`/`false`/`off`) is Disabled, and absent or unrecognized is Manual.

##### Output

Returns a single [Netscoot.UpdatePolicy](#netscootupdatepolicy).

```text
Netscoot.UpdatePolicy
  State   string  # Enabled | Disabled | Manual
  Source  string  # Process | User | Machine | Default
  Value   string  # the raw NETSCOOT_AUTOUPDATE value, or $null
```

##### Examples

```powershell
# See the current policy and where it came from
Get-NetscootUpdatePolicy
```

##### Related

[ [Set-NetscootUpdatePolicy](#set-netscootupdatepolicy) | [Test-NetscootUpdate](#test-netscootupdate) |
[Update-Netscoot](#update-netscoot) ]

[Back to Command reference](#command-reference)

---

#### Get-SolutionInventory

List the full contents of every solution in a repository (projects of any type, solution folders, and solution items),
plus on-disk managed and native projects that no solution references.

##### Syntax

```powershell
Get-SolutionInventory [[-RepositoryRoot] <string>] [<CommonParameters>]
```

Where [Test-SolutionConsistency](#test-solutionconsistency) compares membership and
[Repair-SolutionReferences](#repair-solutionreferences) finds dangling entries, this gives the complete picture without
reading the files by hand. It parses each `.sln/.slnx` directly (not via `dotnet sln list`, which only returns
CLI-buildable projects), so it also surfaces non-CLI project types (e.g. .pssproj), solution folders, and loose solution
items. It then compares against the managed and native (vcxproj) projects on disk and flags any that are in no solution
at all. An unreferenced PowerShell project (pssproj) is not flagged. Read-only: One record per item, so you can group,
filter, or format it however you like.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑RepositoryRoot` | String | false | true (ByValue) | Root to scan. Accepts pipeline input: a path string, or a file/directory item from Get-Item / Get-ChildItem. Defaults to the enclosing git repository root. Nested git worktrees are skipped. |

##### Output

Returns zero or more [Netscoot.SolutionItem](#netscootsolutionitem), collected as an array.
One per item.

```text
Netscoot.SolutionItem
  Solution  string                     # repository-relative, or '(none)' for an unreferenced project
  Kind      Netscoot.SolutionItemKind  # enum: Project | SolutionFolder | SolutionItem | UnreferencedProject
  Type      string                     # project extension without the dot, else empty
  Name      string
  Path      string                     # as stored in the solution, or repository-relative
```

##### Examples

```powershell
# Everything across all solutions, plus projects in none
Get-SolutionInventory -RepositoryRoot . | Format-Table -AutoSize

# Only the projects on disk that no solution references
Get-SolutionInventory | Where-Object Kind -eq 'UnreferencedProject'

# Only loose solution items (e.g. a README in a solution folder)
Get-SolutionInventory | Where-Object Kind -eq 'SolutionItem'

# Kind is the [Netscoot.SolutionItemKind] enum, so this also works
Get-SolutionInventory | Where-Object Kind -eq ([Netscoot.SolutionItemKind]::UnreferencedProject)
```

##### Related

[ [Test-SolutionConsistency](#test-solutionconsistency) | [Sync-Solution](#sync-solution) |
[Repair-SolutionReferences](#repair-solutionreferences) ]

[Back to Command reference](#command-reference)

---

#### Invoke-Netscoot

Move any supported item and reconcile references, routing by detected type to the right per-namespace front door. The
single top-level entry point (the `git netscoot` alias calls this).

##### Syntax

```powershell
Invoke-Netscoot [-Path] <string> -Destination <string> [-RepositoryRoot <string>] [-NoBuild] [-Force] [-NoJournal] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Classifies the target with [Resolve-MoveEngine](#resolve-moveengine), then dispatches to the namespace front door that
performs the appropriate file/folder move (see Output for the routing). It loads Netscoot.Unity or Netscoot.Native on
demand for a Unity or native C++ target. "dotnet" here is the .NET-platform umbrella (CLR/CoreCLR), not just the dotnet
CLI - the verb spans every engine. Each engine's behavior lives in its own cmdlet, and this only routes.
`-WhatIf`/`-Confirm`/`-Verbose` propagate, and `-Force`/`-RepositoryRoot`/`-NoBuild` are forwarded where the target's
engine accepts them.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Path` | String | true | true (ByValue) | The item to move (file or folder). Accepts a path string or a Get-ChildItem/Get-Item item from the pipeline, and rejects other object types. |
| `‑Destination` | String | true | false | New path (file or folder), following `git mv` rules, and passed through to the engine. |
| `‑RepositoryRoot` | String | false | false | Repository root the engine scans for references. Defaults to the enclosing git repository root. Not used for a PowerShell module folder. |
| `‑NoBuild` | SwitchParameter | false | false | Skip the verifying 'dotnet build'. Only the .NET engine builds, and the others ignore it. |
| `‑Force` | SwitchParameter | false | false | When git is not installed, move with a plain PowerShell `Move-Item` without asking first. Without `-Force` it asks before falling back. The plain move does not preserve git history. Forwarded to the engine. |
| `‑NoJournal` | SwitchParameter | false | false | Skip recording this move in the undo journal for this call (forwarded to the engine), even when journaling is enabled. |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

```text
.csproj  .fsproj  .vbproj  ->  Netscoot.MoveResult
folder of .NET projects    ->  Netscoot.TreeMoveResult
.sln  .slnx                ->  Netscoot.SolutionMoveResult
.props  .targets           ->  Netscoot.ImportMoveResult
.ps1                       ->  Netscoot.ScriptMoveResult
.psd1  module folder       ->  Netscoot.PSModuleMoveResult
.vcxproj                   ->  Netscoot.NativeMoveResult
Unity asset or folder      ->  Netscoot.UnityMoveResult
```

These share a common shape (Engine, Source, Destination, Performed, SkippedCount) and each adds its own fields, with no
shared base type. See [Output types](#output-types).

##### Examples

```powershell
# Preview any move - detects the engine, changes nothing
Invoke-Netscoot -Path ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon -WhatIf

# Rename: ./libs/Tarragon does not exist yet, so src/Tarragon becomes libs/Tarragon
Invoke-Netscoot -Path ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon

# Move into an existing folder: ./libs exists, so it lands at ./libs/Tarragon
Invoke-Netscoot -Path ./src/Tarragon/Tarragon.csproj -Destination ./libs

# Any supported type routes through the same call (here a PowerShell module folder)
Invoke-Netscoot -Path ./tools/Mayo -Destination ./modules/Mayo

# git not installed? -Force falls back to a plain Move-Item without asking (history not preserved)
Invoke-Netscoot -Path ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon -Force
```

[Back to Command reference](#command-reference)

---

#### Move-DotnetFile

Move a single managed .NET file and reconcile references, routing by extension to the right specialist. The front door
for file moves in the .NET family.

##### Syntax

```powershell
Move-DotnetFile [-Path] <string> -Destination <string> [-RepositoryRoot <string>] [-NoBuild] [-Force] [-NoJournal] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Dispatches a managed .NET file to the right specialist by extension (see Output for the routing). Native (`.vcxproj`),
PowerShell (`.ps1/.psd1`) and Unity assets are deliberately not handled here - use
[Move-NativeProject](#move-nativeproject) / [Move-PowerShellScript](#move-powershellscript) /
[Move-PowerShellModule](#move-powershellmodule) / [Move-UnityAsset](#move-unityasset). `-WhatIf`/`-Confirm`/`-Verbose`
propagate to the specialist, and `-Force` and `-RepositoryRoot`/`-NoBuild` are forwarded where the specialist accepts
them.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Path` | String | true | true (ByValue) | The .NET file to move. Accepts a path string or a Get-ChildItem/Get-Item item from the pipeline, and rejects other object types. |
| `‑Destination` | String | true | false | New path (file or folder), following `git mv` rules, passed through to the specialist. For a project file, Destination is the project's new folder, and the whole folder moves. |
| `‑RepositoryRoot` | String | false | false | Repository root the specialist scans for references. Defaults to the enclosing git repository root. Not used for a solution file. |
| `‑NoBuild` | SwitchParameter | false | false | Skip the verifying 'dotnet build' (forwarded to [Move-DotnetProject](#move-dotnetproject)). |
| `‑Force` | SwitchParameter | false | false | When git is not installed, move with a plain PowerShell `Move-Item` without asking first. Without `-Force` it asks before falling back. The plain move does not preserve git history. |
| `‑NoJournal` | SwitchParameter | false | false | Skip recording this move in the undo journal for this call (forwarded to the specialist), even when journaling is enabled. |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

```text
.csproj  .fsproj  .vbproj  ->  Move-DotnetProject   ->  Netscoot.MoveResult
.sln  .slnx                ->  Move-Solution        ->  Netscoot.SolutionMoveResult
.props  .targets           ->  Move-MSBuildImport   ->  Netscoot.ImportMoveResult
```

These share a common shape (Engine, Source, Destination, Performed, SkippedCount) and each adds its own fields, with no
shared base type. See [Output types](#output-types).

##### Examples

```powershell
# A project file routes to Move-DotnetProject
Move-DotnetFile -Path ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon

# A solution routes to Move-Solution (rebases stored project paths)
Move-DotnetFile -Path ./Demo.slnx -Destination ./build/Demo.slnx

# A shared import routes to Move-MSBuildImport (fixes <Import> in consumers)
Move-DotnetFile -Path ./Shared.props -Destination ./build/Shared.props
```

[Back to Command reference](#command-reference)

---

#### Move-DotnetFolder

Move a folder of managed .NET projects, reconciling references. The front door for folder moves in the .NET family, it
delegates to [Move-DotnetProjectTree](#move-dotnetprojecttree) (which handles a single project or many).

##### Syntax

```powershell
Move-DotnetFolder [-Path] <string> -Destination <string> [-RepositoryRoot <string>] [-NoBuild] [-Force] [-NoJournal] [-WhatIf] [-Confirm] [<CommonParameters>]
```

A folder move always goes through [Move-DotnetProjectTree](#move-dotnetprojecttree): It treats every managed project
under the folder as one co-moving set and reconciles only the references that cross the folder boundary (internal
references ride along unchanged). If the folder contains no managed projects, that specialist reports it. A `.vcxproj`
in the folder moves with it without its references being updated, and the move warns. `-WhatIf`/`-Confirm`/`-Verbose`
propagate, and `-Force`/`-RepositoryRoot`/`-NoBuild` are forwarded.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Path` | String | true | true (ByValue) | The folder to move. Accepts a path string or a Get-ChildItem/Get-Item item from the pipeline, and rejects other object types. |
| `‑Destination` | String | true | false | New folder path, following `git mv` rules (an existing directory means move into it, otherwise it is the new path), and passed through to [Move-DotnetProjectTree](#move-dotnetprojecttree). |
| `‑RepositoryRoot` | String | false | false | Repository root scanned for references. Defaults to the enclosing git repository root. |
| `‑NoBuild` | SwitchParameter | false | false | Skip the verifying 'dotnet build' (forwarded to [Move-DotnetProjectTree](#move-dotnetprojecttree)). |
| `‑Force` | SwitchParameter | false | false | When git is not installed, move with a plain PowerShell `Move-Item` without asking first. Without `-Force` it asks before falling back. The plain move does not preserve git history. |
| `‑NoJournal` | SwitchParameter | false | false | Skip recording this move in the undo journal for this call (forwarded to the specialist), even when journaling is enabled. |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

Returns a single [Netscoot.TreeMoveResult](#netscoottreemoveresult).
From [Move-DotnetProjectTree](#move-dotnetprojecttree).

```text
Netscoot.TreeMoveResult
  Engine         string
  Source         string  # absolute path
  Destination    string  # absolute path
  Performed      bool    # false under -WhatIf
  SkippedCount   int
  ProjectsMoved  int
  ConsumerCount  int     # external references repointed
  Built          bool?   # $null with -NoBuild
```

##### Examples

```powershell
# Preview moving a folder of .NET projects (delegates to the tree mover)
Move-DotnetFolder -Path ./src/Group -Destination ./libs/Group -WhatIf

# Move into an existing folder (lands at ./libs/Group)
Move-DotnetFolder -Path ./src/Group -Destination ./libs
```

[Back to Command reference](#command-reference)

---

#### Move-DotnetProject

Move a .NET project folder and reconcile every solution and project reference that points at it, delegating all
path/GUID changes to the dotnet CLI.

##### Syntax

```powershell
Move-DotnetProject [-Project] <string> -Destination <string> [-RepositoryRoot <string>] [-Strict] [-NoBuild] [-Force] [-NoJournal] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Enumerates the solutions that include the project, the projects that reference it, and the project's own references.
Removes those links while the old paths still resolve, moves the directory (git mv when tracked), then re-adds every
link so the dotnet CLI recomputes fresh relative paths. The solution and project XML (the `.sln/.slnx` and the
`.csproj`) is never hand-edited. Because the CLI re-creates each solution entry, a `.sln` entry gets a new project GUID
unless the project sets `<ProjectGuid>`. The entry's solution folder is restored. Diagnostics follow invocation:
`-Verbose` narrates the plan, `-Debug` emits the full solution-membership matrix, and divergence (the project living in
some but not all of the repository's solutions) is surfaced as a Warning (or, with `-Strict`, a non- terminating error
honoring `-ErrorAction`).

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Project` | String | true | true (ByValue) | Path to the project file (`.csproj/.fsproj/.vbproj`). Accepts a path string or a Get-ChildItem/Get-Item item from the pipeline, and rejects other object types. |
| `‑Destination` | String | true | false | Where to move the project folder, following `git mv` rules. If Destination is an existing directory, the folder moves into it (keeping its name, e.g. './libs' -&gt; './libs/Tarragon'). Otherwise Destination is the project's new folder path (a rename, './libs/Tarragon'). The project file and its sibling contents move as one. |
| `‑RepositoryRoot` | String | false | false | Root to scan for solutions/consumers. Defaults to the enclosing git repository root. |
| `‑Strict` | SwitchParameter | false | false | Escalate solution-divergence warnings to non-terminating errors. |
| `‑NoBuild` | SwitchParameter | false | false | Skip the verifying 'dotnet build' at the end. |
| `‑Force` | SwitchParameter | false | false | When git is not installed, move with a plain PowerShell `Move-Item` without asking first. Without `-Force` it asks before falling back. The plain move does not preserve git history. |
| `‑NoJournal` | SwitchParameter | false | false | Skip recording this move in the undo journal for this call, even when journaling is enabled ([Undo-Netscoot](#undo-netscoot) will not see this move). |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

Returns a single [Netscoot.MoveResult](#netscootmoveresult).

```text
Netscoot.MoveResult
  Engine         string
  Source         string    # absolute path
  Destination    string    # absolute path
  Performed      bool      # false under -WhatIf
  SkippedCount   int
  Solutions      string[]  # solution names updated
  ConsumerCount  int       # external references repointed
  OwnRefCount    int       # the moved project's own references rebased
  Built          bool?     # $null with -NoBuild
```

##### Examples

```powershell
# Preview the move and emit the plan object, changing nothing
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

[Back to Command reference](#command-reference)

---

#### Move-DotnetProjectTree

Move a folder that contains one or more managed .NET projects, reconciling solution membership and every external
project reference in one operation. This is the bulk "restructure" case (e.g. wrapping several projects into a new
parent folder).

##### Syntax

```powershell
Move-DotnetProjectTree [-Path] <string> -Destination <string> [-RepositoryRoot <string>] [-NoBuild] [-Force] [-NoJournal] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Enumerates the managed projects (`.csproj/.fsproj/.vbproj`) under the folder and treats them as a single co-moving set.
It reconciles only what crosses the folder boundary: solution membership for each moved project (dotnet sln remove/add),
external consumers (projects outside the folder that reference one inside), and the moved projects' own references to
projects outside the folder. References between two co-moved projects are left untouched - their relative path is
unchanged because both move by the same delta. Everything is delegated to the dotnet CLI, and nothing is hand-edited. A
`.vcxproj` inside the folder moves with it, but its solution entries and references are not updated, and the move warns
about each one. As with [Move-DotnetProject](#move-dotnetproject), dotnet is required and git is used when available
(otherwise a plain move, confirmed first or forced with `-Force`). It supports `-WhatIf`.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Path` | String | true | true (ByValue) | The folder to move. Accepts a path string or a Get-ChildItem/Get-Item item from the pipeline, and rejects other object types. |
| `‑Destination` | String | true | false | Where to move the folder, following `git mv` rules: An existing directory means move into it, keeping the name. Any other path is the folder's new path. |
| `‑RepositoryRoot` | String | false | false | Root to scan. Defaults to the enclosing git repository root. |
| `‑NoBuild` | SwitchParameter | false | false | Skip the verifying build of the moved projects. |
| `‑Force` | SwitchParameter | false | false | When git is not installed, move with a plain PowerShell `Move-Item` without asking first. Without `-Force` it asks before falling back. The plain move does not preserve git history. |
| `‑NoJournal` | SwitchParameter | false | false | Skip recording this move in the undo journal for this call, even when journaling is enabled ([Undo-Netscoot](#undo-netscoot) will not see this move). |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

Returns a single [Netscoot.TreeMoveResult](#netscoottreemoveresult).

```text
Netscoot.TreeMoveResult
  Engine         string
  Source         string  # absolute path
  Destination    string  # absolute path
  Performed      bool    # false under -WhatIf
  SkippedCount   int
  ProjectsMoved  int
  ConsumerCount  int     # external references repointed
  Built          bool?   # $null with -NoBuild
```

##### Examples

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

[Back to Command reference](#command-reference)

---

#### Move-MSBuildImport

Move a shared MSBuild `.props/.targets` file and fix every project (or other props/targets) that imports it via
`<Import Project="...">`.

##### Syntax

```powershell
Move-MSBuildImport [-Path] <string> -Destination <string> [-RepositoryRoot <string>] [-Force] [-NoJournal] [-WhatIf] [-Confirm] [<CommonParameters>]
```

There is no dotnet CLI for `<Import>`, so this reconciles the relative Import paths directly with text edits that keep
each file's formatting and encoding (it replaces the exact `Project="<value>"` token captured from the XML). It also
fixes the moved file's own outgoing `<Import>` paths, which break when its location changes. The
`$(MSBuildThisFileDirectory)` token is resolved and preserved. Other `$(...)` tokens in the moved file's own imports are
reported as unresolved rather than guessed. An importer that reaches the file through any token other than
`$(MSBuildThisFileDirectory)` is not detected. Note: `Directory.Build.props/.targets` (and `Directory.Packages.props`,
etc.) are imported by location, not an explicit `<Import>` - moving one changes inheritance scope, which cannot be
"fixed" by editing imports. For those this warns (like the inheritance check) and only fixes the file's own outgoing
imports. Importers may include native `.vcxproj` files. Their `<Import>` path is fixed on any OS (a best-effort,
path-only update). A `.vcxproj`'s native link settings are never rewritten, and
[Move-NativeProject](#move-nativeproject) (Windows) reports them when the project itself moves. dotnet is not required
here. git is used when available (otherwise a plain move, confirmed first or forced with `-Force`). Supports `-WhatIf`.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Path` | String | true | true (ByValue) | The `.props/.targets` file to move. Accepts a path string or a Get-ChildItem/Get-Item item from the pipeline, and rejects other object types. |
| `‑Destination` | String | true | false | New file path (or a folder, in which case the file keeps its name). |
| `‑RepositoryRoot` | String | false | false | Root to scan for importers. Defaults to the enclosing git repository root. |
| `‑Force` | SwitchParameter | false | false | When git is not installed, move with a plain PowerShell `Move-Item` without asking first. Without `-Force` it asks before falling back. The plain move does not preserve git history. |
| `‑NoJournal` | SwitchParameter | false | false | Skip recording this move in the undo journal for this call, even when journaling is enabled ([Undo-Netscoot](#undo-netscoot) will not see this move). |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

Returns a single [Netscoot.ImportMoveResult](#netscootimportmoveresult).

```text
Netscoot.ImportMoveResult
  Engine           string
  Source           string  # absolute path
  Destination      string  # absolute path
  Performed        bool    # false under -WhatIf
  SkippedCount     int
  ImportersFixed   int     # files whose <Import> was rewritten
  OwnImportsFixed  int     # the moved file's own imports rewritten
  AutoImported     bool    # true for a by-location import (e.g. Directory.Build.props) whose inheritance scope changed
```

##### Examples

```powershell
# Move a shared props/targets and fix every consumer's Import path
Move-MSBuildImport -Path ./Shared.props -Destination ./build/Shared.props -WhatIf

# Move into an existing folder (lands at ./build/Shared.props)
Move-MSBuildImport -Path ./Shared.props -Destination ./build

# A by-location import (Directory.Build.props): moving it changes inheritance scope - reported
Move-MSBuildImport -Path ./src/Directory.Build.props -Destination ./Directory.Build.props
```

[Back to Command reference](#command-reference)

---

#### Move-PowerShell

Move a PowerShell item and reconcile references, routing by type to the right specialist. The front door for PowerShell
moves.

##### Syntax

```powershell
Move-PowerShell [-Path] <string> -Destination <string> [-RepositoryRoot <string>] [-Force] [-NoJournal] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Dispatches a PowerShell item to the right specialist by type (see Output for the routing): the script specialist fixes
dot-source/call references (AST-based), the module specialist fixes the paths that load the module.
`-WhatIf`/`-Confirm`/`-Verbose` propagate to the specialist, `-Force` is forwarded, and `-RepositoryRoot` is forwarded
to the script specialist (the module specialist has no RepositoryRoot).

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Path` | String | true | true (ByValue) | The PowerShell item to move: a `.ps1` script, a `.psd1` manifest, or a module folder. Accepts a path string or a Get-ChildItem/Get-Item item from the pipeline, and rejects other object types. |
| `‑Destination` | String | true | false | New path (file or folder), following `git mv` rules, and passed through to the specialist. |
| `‑RepositoryRoot` | String | false | false | Repository root scanned for referencing scripts. Defaults to the enclosing git repository root. Forwarded to the script specialist only (the module specialist has no RepositoryRoot). |
| `‑Force` | SwitchParameter | false | false | When git is not installed, move with a plain PowerShell `Move-Item` without asking first. Without `-Force` it asks before falling back. The plain move does not preserve git history. |
| `‑NoJournal` | SwitchParameter | false | false | Skip recording this move in the undo journal for this call (forwarded to the specialist), even when journaling is enabled. |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

```text
.ps1                   ->  Move-PowerShellScript  ->  Netscoot.ScriptMoveResult
.psd1  module folder   ->  Move-PowerShellModule  ->  Netscoot.PSModuleMoveResult
```

These share a common shape (Engine, Source, Destination, Performed, SkippedCount) and each adds its own fields, with no
shared base type. See [Output types](#output-types).

##### Examples

```powershell
# A .ps1 routes to the script mover (fixes dot-source/call references)
Move-PowerShell -Path ./lib/helpers.ps1 -Destination ./shared/helpers.ps1 -WhatIf

# A module folder (or its .psd1) routes to the module mover (fixes the paths that load it)
Move-PowerShell -Path ./tools/Mayo -Destination ./modules/Mayo

# Destination is an existing folder -> the script lands at ./shared/helpers.ps1
Move-PowerShell -Path ./lib/helpers.ps1 -Destination ./shared
```

[Back to Command reference](#command-reference)

---

#### Move-PowerShellModule

Move a PowerShell module folder and update the script paths that reference it or that
it uses.

##### Syntax

```powershell
Move-PowerShellModule [-ModulePath] <string> -Destination <string> [-Force] [-NoJournal] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Moves a module directory (git mv when tracked). Scripts elsewhere that import the module by path (Import-Module,
`using module`) or dot-source one of its files are repointed, and the module's own `.ps1/.psm1` paths to files outside
it are rebased, with the same encoding-preserving edits as [Move-PowerShellScript](#move-powershellscript). The
manifest's entries are module-relative, so the `.psd1` is left unchanged and only validated with Test-ModuleManifest.
Limits (warned, not fixed): a path built from variables is reported as a possible dynamic reference. Any path computed
at runtime cannot be reconciled automatically.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑ModulePath` | String | true | true (ByValue) | Path to the module folder, or directly to its `.psd1` manifest. Accepts a path string or a Get-ChildItem/Get-Item item from the pipeline, and rejects other object types. |
| `‑Destination` | String | true | false | Where to move the module folder, following `git mv` rules: An existing directory means move into it, keeping the name. Any other path is the module's new folder path. |
| `‑Force` | SwitchParameter | false | false | When git is not installed, move with a plain PowerShell `Move-Item` without asking first. Without `-Force` it asks before falling back. The plain move does not preserve git history. |
| `‑NoJournal` | SwitchParameter | false | false | Skip recording this move in the undo journal for this call, even when journaling is enabled ([Undo-Netscoot](#undo-netscoot) will not see this move). |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

Returns a single [Netscoot.PSModuleMoveResult](#netscootpsmodulemoveresult).

```text
Netscoot.PSModuleMoveResult
  Engine        string
  Source        string  # absolute path
  Destination   string  # absolute path
  Performed     bool    # false under -WhatIf
  SkippedCount  int
  Manifest      string  # the manifest file name
```

##### Examples

```powershell
# Preview the callers and module paths it will update
Move-PowerShellModule -ModulePath ./tools/Mayo -Destination ./modules/Mayo -WhatIf

# Move it for real
Move-PowerShellModule -ModulePath ./tools/Mayo -Destination ./modules/Mayo

# Point at the .psd1 instead of the folder - same result
Move-PowerShellModule -ModulePath ./tools/Mayo/Mayo.psd1 -Destination ./modules/Mayo
```

[Back to Command reference](#command-reference)

---

#### Move-PowerShellScript

Move a standalone `.ps1` script and fix the relative paths in scripts that dot-source or call it (and the moved script's
own dot-source/call paths).

##### Syntax

```powershell
Move-PowerShellScript [-Path] <string> -Destination <string> [-RepositoryRoot <string>] [-Force] [-NoJournal] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Finds references via the PowerShell AST: dot-source (`. path`), call (`& path`) and Import-Module invocations whose path
is a literal string or a `$PSScriptRoot`-based string resolving to the moved script. A relative path is resolved against
the referencing script's own folder. It rewrites those paths as whole tokens, keeping each file's encoding and the
original style (`$PSScriptRoot`-prefixed or .\-relative, and the / or \ separator). The moved script's own dot-source,
call, Import-Module and `using module` paths are rebased too. HEURISTIC LIMIT: only literal and `$PSScriptRoot`-based
string paths are resolved and rewritten. A string built from other variables (e.g. one rooted at `$dir`), or a string
literal elsewhere in a script (e.g. a Join-Path argument), whose leaf matches the moved script is reported as a possible
dynamic reference to verify by hand. A path assembled with no string naming the script cannot be detected at all - grep
to be sure. Treat the result as "fixed what could be proven," not "guaranteed complete." git is used when available
(otherwise a plain move, confirmed first or forced with `-Force`). It supports `-WhatIf` and does not need dotnet.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Path` | String | true | true (ByValue) | The `.ps1` to move. Accepts a path string or a Get-ChildItem/Get-Item item from the pipeline, and rejects other object types. |
| `‑Destination` | String | true | false | New file path (or a folder, in which case the script keeps its name). |
| `‑RepositoryRoot` | String | false | false | Root to scan for referencing scripts. Defaults to the enclosing git repository root. |
| `‑Force` | SwitchParameter | false | false | When git is not installed, move with a plain PowerShell `Move-Item` without asking first. Without `-Force` it asks before falling back. The plain move does not preserve git history. |
| `‑NoJournal` | SwitchParameter | false | false | Skip recording this move in the undo journal for this call, even when journaling is enabled ([Undo-Netscoot](#undo-netscoot) will not see this move). |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

Returns a single [Netscoot.ScriptMoveResult](#netscootscriptmoveresult).

```text
Netscoot.ScriptMoveResult
  Engine            string
  Source            string  # absolute path
  Destination       string  # absolute path
  Performed         bool    # false under -WhatIf
  SkippedCount      int
  ReferencersFixed  int     # scripts whose path to the moved file was rewritten
  OwnRefsFixed      int     # the moved script's own paths rewritten
  UnresolvedRefs    int     # count of possible dynamic references to verify, not a list
```

##### Examples

```powershell
# Preview the rewrites of dot-source/call paths in referencing scripts and the script's own refs
Move-PowerShellScript -Path ./lib/helpers.ps1 -Destination ./shared/helpers.ps1 -WhatIf

# Move it for real
Move-PowerShellScript -Path ./lib/helpers.ps1 -Destination ./shared/helpers.ps1

# Limit the scan for referencing scripts to a specific root
Move-PowerShellScript -Path ./lib/helpers.ps1 -Destination ./shared/helpers.ps1 -RepositoryRoot ./lib
```

[Back to Command reference](#command-reference)

---

#### Move-Solution

Move a solution file (`.sln/.slnx`) and rebase the relative project paths it stores, so every project it references
still resolves from the solution's new location.

##### Syntax

```powershell
Move-Solution [-Path] <string> -Destination <string> [-Force] [-NoJournal] [-WhatIf] [-Confirm] [<CommonParameters>]
```

A solution stores each project, of any project type, and each solution item as a path relative to the solution file.
Moving the solution changes that base directory, so every stored path is recomputed. The dotnet CLI has no "rebase"
command, so this rewrites the stored paths in place, keeping the file's formatting and encoding. It replaces the exact
path token captured from the file (the `.slnx` `<Project Path="...">` or `<File Path="...">`, or the `.sln` project or
SolutionItems line), and keeps each format's separator convention (/ for `.slnx`, \ for `.sln`). A web site project
stored as a URL is left alone. Project-to-project references are unaffected by a solution move and are left alone. git
is used when available (else confirmed plain-move fallback via `-Force`). `-WhatIf` supported. dotnet is not required.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Path` | String | true | true (ByValue) | The `.sln/.slnx` file to move. Accepts a path string or a Get-ChildItem/Get-Item item from the pipeline, and rejects other object types. |
| `‑Destination` | String | true | false | New file path (or a folder, in which case the solution keeps its name). |
| `‑Force` | SwitchParameter | false | false | When git is not installed, move with a plain PowerShell `Move-Item` without asking first. Without `-Force` it asks before falling back. The plain move does not preserve git history. |
| `‑NoJournal` | SwitchParameter | false | false | Skip recording this move in the undo journal for this call, even when journaling is enabled ([Undo-Netscoot](#undo-netscoot) will not see this move). |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

Returns a single [Netscoot.SolutionMoveResult](#netscootsolutionmoveresult).

```text
Netscoot.SolutionMoveResult
  Engine           string
  Source           string  # absolute path
  Destination      string  # absolute path
  Performed        bool    # false under -WhatIf
  SkippedCount     int
  ProjectsRebased  int     # project paths rewritten
  ItemsRebased     int     # solution item paths rewritten
```

##### Examples

```powershell
# Preview moving a solution and rebasing the project paths it stores
Move-Solution -Path ./Demo.slnx -Destination ./build/Demo.slnx -WhatIf

# Destination is an existing folder -> lands at ./build/Demo.slnx
Move-Solution -Path ./Demo.slnx -Destination ./build

# Works the same for .sln
Move-Solution -Path ./Demo.sln -Destination ./build/Demo.sln
```

[Back to Command reference](#command-reference)

---

#### Register-NetscootGitAlias

Opt-in: register a `git netscoot` alias pointing at Netscoot's forwarder. Sets a single reversible git-config line - it
never edits PATH or installs anything.

##### Syntax

```powershell
Register-NetscootGitAlias [[-Scope] <string>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Adds `alias.netscoot = !pwsh -NoProfile -File <forwarder>` to git config so `git netscoot <src> <dst>` works. The
forwarder calls [Invoke-Netscoot](#invoke-netscoot), which routes by target type to the right engine: the .NET project
model (csproj/sln/props), Unity (`.meta`/.asmdef), PowerShell (`.ps1/.psd1`), or native C++ (`.vcxproj`). The alias runs
`pwsh`, so it needs PowerShell 7 on PATH. Scope is your choice (repository-local or global). Undo with
[Unregister-NetscootGitAlias](#unregister-netscootgitalias). The returned object's Command property holds the exact
`git config` command, and `-WhatIf` previews the change.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Scope` | String | false | false | 'Local' (this repository, default) or 'Global' (~/.gitconfig). |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

Returns a single [Netscoot.GitAlias](#netscootgitalias).

```text
Netscoot.GitAlias
  Alias      string
  Scope      string
  Forwarder  string
  Command    string  # the git config command that was/would be run
```

##### Examples

```powershell
# Preview the change (changes nothing)
Register-NetscootGitAlias -Scope Global -WhatIf

# Register for this repository only (default scope is Local)
Register-NetscootGitAlias

# Register globally, in ~/.gitconfig
Register-NetscootGitAlias -Scope Global
```

##### Related

[ [Unregister-NetscootGitAlias](#unregister-netscootgitalias) ]

[Back to Command reference](#command-reference)

---

#### Repair-NetscootJournal

Report and recover moves the journal recorded as started but never finished (interrupted by a crash), and clear orphaned
recovery snapshots.

##### Syntax

```powershell
Repair-NetscootJournal [-RepositoryRoot <string>] [-ClearOrphanSnapshots] [-WhatIf] [-Confirm] [<CommonParameters>]

Repair-NetscootJournal -Rollback [-RepositoryRoot <string>] [-Id <string>] [-Force] [-ClearOrphanSnapshots] [-WhatIf] [-Confirm] [<CommonParameters>]

Repair-NetscootJournal -Discard [-RepositoryRoot <string>] [-Id <string>] [-Force] [-ClearOrphanSnapshots] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Each move is written ahead: a `pending` record before it runs, a `committed`/`rolledback` record after. A move with a
`pending` record and no outcome was interrupted (the process died mid-move), so the working tree may be partway between
the old and new layout. Read-only by default: It lists the interrupted moves and changes nothing. Then choose an action
(both confine every path to the repository, and prompt unless `-Force`): `-Rollback` return the move to its pre-move
state - restore the edited files from the recovery snapshot, move the destination back to the source, and drop the
entry. `-Discard` accept the working tree as-is and just forget the interrupted entry (no file changes), removing its
snapshot. `-Id` limits the action to one entry (by its journal id). `-ClearOrphanSnapshots` deletes leftover
`netscoot_snap_*` recovery directories in the temp folder that no interrupted move in any repository's journal
references. Snapshots less than an hour old are kept.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑RepositoryRoot` | String | false | false | Repository whose journal to inspect, and the boundary every recovery is confined to. Defaults to the enclosing git repository root of the current directory. |
| `‑Rollback` | SwitchParameter | true | false | Roll each interrupted move back to its pre-move state (high-impact: prompts unless `-Force`). |
| `‑Discard` | SwitchParameter | true | false | Forget each interrupted move without touching the working tree (removes its snapshot). |
| `‑Id` | String | false | false | Act on only the interrupted move with this journal id. |
| `‑Force` | SwitchParameter | false | false | Skip the confirmation prompt of `-Rollback` or `-Discard` (for automation). |
| `‑ClearOrphanSnapshots` | SwitchParameter | false | false | Delete temp recovery snapshots (`netscoot_snap_*`) that no interrupted move references. It prompts once per snapshot. Add `-Confirm:$false` to skip the prompts. |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

Returns zero or more [Netscoot.JournalEntry](#netscootjournalentry), collected as an array.
The interrupted entries (report mode), or those acted on.

```text
Netscoot.JournalEntry
  id           string  # 8-character move id
  timestamp    string  # UTC ISO-8601, when the move ran
  status       string  # committed | pending | rolledback
  command      string  # the mover that ran
  engine       string  # dotnet | native | unity | powershell
  source       string
  destination  string
```

##### Examples

```powershell
# See what was interrupted (read-only)
Repair-NetscootJournal

# Roll everything interrupted back to its pre-move state
Repair-NetscootJournal -Rollback

# Forget one interrupted move, keeping the working tree as-is
Repair-NetscootJournal -Discard -Id a1b2c3d4

# Clean up leftover recovery snapshots
Repair-NetscootJournal -ClearOrphanSnapshots
```

##### Related

[ [Undo-Netscoot](#undo-netscoot) | [Set-NetscootJournal](#set-netscootjournal) |
[Clear-NetscootJournal](#clear-netscootjournal) ]

[Back to Command reference](#command-reference)

---

#### Repair-SolutionReferences

Scan a repository for broken solution membership and dangling ProjectReferences and repair them by re-pointing each
entry at the project's new location.

##### Syntax

```powershell
Repair-SolutionReferences [[-RepositoryRoot] <string>] [-Fix] [-Prune] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Finds solution entries and `<ProjectReference>`s that point at a project file which no longer exists at the recorded
path (usually because a project was moved or renamed without reconciling). Read-only by default: It returns one object
per problem, each tagged with a Resolution of Relocatable, Missing, or Ambiguous. With `-Fix` it repairs every
Relocatable entry: It searches the repository for a project file of the same name and re-points the entry at it through
the dotnet CLI (remove the stale path, add the found one). When one project of that name exists it is used directly.
When several do, the one that keeps the most of the original path's trailing folders is chosen, since a moved project
usually keeps its own folder name. Entries it cannot resolve are left untouched and reported, Missing (no such project
anywhere) or Ambiguous (several equally-good candidates). A relocatable `.vcxproj` is reported with its new location but
not re-pointed, because the dotnet CLI cannot load a native project. Re-point it in Visual Studio. With `-Prune` it
removes the Missing entries, the genuinely deleted ones, through the dotnet CLI. `-Prune` never touches Relocatable or
Ambiguous entries. `-Fix` and `-Prune` can be combined.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑RepositoryRoot` | String | false | true (ByValue) | Root to scan. Accepts pipeline input: a path string, or a directory item from Get-Item. Defaults to the enclosing git repository root of the current directory. |
| `‑Fix` | SwitchParameter | false | false | Re-point each dangling entry at the moved project when its new location is unambiguous. Honors `-WhatIf`. |
| `‑Prune` | SwitchParameter | false | false | Remove entries whose project cannot be found anywhere in the repository. Honors `-WhatIf`. |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

Returns zero or more [Netscoot.RepairResult](#netscootrepairresult), collected as an array (`$null` when none).
One per dangling entry.

```text
Netscoot.RepairResult
  Kind        string
  Resolution  string
  Missing     string
  NewPath     string
  Container   string
  MissingAbs  string
  Candidates  string[]  # same-named project files found, used to resolve NewPath
```

##### Examples

```powershell
# Report dangling entries only - read-only (each tagged Relocatable, Missing, or Ambiguous)
Repair-SolutionReferences -RepositoryRoot .

# Re-point relocatable entries at the project's new location (relocates, never deletes)
Repair-SolutionReferences -RepositoryRoot . -Fix

# Also remove entries whose project is gone for good - preview the whole thing first
Repair-SolutionReferences -RepositoryRoot . -Fix -Prune -WhatIf
```

##### Related

[ [Get-SolutionInventory](#get-solutioninventory) | [Test-SolutionConsistency](#test-solutionconsistency) |
[Sync-Solution](#sync-solution) | [Find-PathReference](#find-pathreference) ]

[Back to Command reference](#command-reference)

---

#### Resolve-MoveEngine

Classify a path to the reconciliation engine that should move it: dotnet, native, unity, ps-script, ps-module, or
unknown. Used by [Invoke-Netscoot](#invoke-netscoot) (and so `git netscoot`) and available for introspection.

##### Syntax

```powershell
Resolve-MoveEngine [-Path] <string> [<CommonParameters>]
```

Classification is by target type (extension + location + `.meta` pairing), not by content beyond a folder's
project/manifest scan. A path is unity when it is an .asmdef/.asmref, has a sibling `.meta`, or sits under the Assets/
or Packages/ folder of a Unity project (one with ProjectSettings/ beside it). A folder is dotnet when a managed project
is anywhere under it, and ps-module when a `.psd1` is directly in it. The path need not exist (extension-based cases
classify regardless). Folder cases require the directory.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Path` | String | true | true (ByValue) | The item to classify. Accepts pipeline input: a path string, or a file/directory item from Get-Item / Get-ChildItem. |

##### Output

```text
.vcxproj                                            ->  native
.asmdef  .asmref  a file with a sibling .meta       ->  unity
under a Unity project's Assets/ or Packages/        ->  unity
.ps1                                                ->  ps-script
.psd1                                               ->  ps-module
.csproj .fsproj .vbproj .sln .slnx .props .targets  ->  dotnet
folder with a .NET project anywhere under it        ->  dotnet
folder with a .psd1 directly in it                  ->  ps-module
anything else                                       ->  unknown
```

##### Examples

```powershell
# A managed project classifies as 'dotnet'
Resolve-MoveEngine ./src/Tarragon/Tarragon.csproj

# Anything under a Unity project's Assets/ or Packages/, or paired with a .meta, is 'unity'
Resolve-MoveEngine ./Assets/Art/logo.png

# A .ps1 is 'ps-script', and a module folder or .psd1 is 'ps-module'
Resolve-MoveEngine ./tools/build.ps1

# A .vcxproj is 'native', and an unrecognized path is 'unknown'
Resolve-MoveEngine ./Aleppo/Aleppo.vcxproj
```

[Back to Command reference](#command-reference)

---

#### Set-NetscootJournal

Turn the move journal on or off, per repository (default) or for every repository (`-Global`).

##### Syntax

```powershell
Set-NetscootJournal [-Enabled] <bool> [[-RepositoryRoot] <string>] [-Global] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Journaling is on by default. This cmdlet writes the git setting that the precedence stack reads (git config
netscoot.journal), so the choice persists across sessions and rides along with the repository's git config - no
environment variable to remember. Local config (the default here) wins over global. With `-Global` it writes the user's
global git config, switching the default for every repository on the machine in one place. Requires git. The
`NETSCOOT_JOURNAL` environment variable, when set, overrides this setting, so this cmdlet has no effect while it is set.
Without git, set that variable instead.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Enabled` | Boolean | true | false | `$true` to journal moves (the default behavior), `$false` to stop journaling. |
| `‑Global` | SwitchParameter | false | false | Write the user's global git config instead of the repository's local config. |
| `‑RepositoryRoot` | String | false | false | Repository whose local config to write. Defaults to the enclosing git repository root. Ignored with `-Global`. |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

None.

##### Examples

```powershell
# Stop journaling in this repository only
Set-NetscootJournal -Enabled $false

# Turn it back on
Set-NetscootJournal -Enabled $true

# Turn journaling off for every repository on the machine
Set-NetscootJournal -Enabled $false -Global
```

##### Related

[ [Clear-NetscootJournal](#clear-netscootjournal) | [Undo-Netscoot](#undo-netscoot) |
[Repair-NetscootJournal](#repair-netscootjournal) ]

[Back to Command reference](#command-reference)

---

#### Set-NetscootUpdatePolicy

Set netscoot's auto-update policy to Enabled, Disabled, or Manual.

##### Syntax

```powershell
Set-NetscootUpdatePolicy [-State] <string> [[-Scope] <string>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Writes the `NETSCOOT_AUTOUPDATE` environment variable that governs update behavior (see
[Get-NetscootUpdatePolicy](#get-netscootupdatepolicy) for the three states). The change always takes effect in the
current session, and the scope controls how far it persists: `-Scope` User (default) persists for the current user
(Windows). `-Scope` Machine persists for all users (Windows), and needs an elevated session. `-Scope` Process this
session only, with nothing persisted. On non-Windows, User/Machine cannot be persisted programmatically, so this sets
the session value and prints the line to add to your shell profile. An administrator can achieve the same fleet-wide by
pushing `NETSCOOT_AUTOUPDATE` through Group Policy / Intune. This cmdlet is the per-user equivalent.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑State` | String | true | false | Enabled, Disabled, or Manual. |
| `‑Scope` | String | false | false | How far to persist: User (default, Windows), Machine (Windows, elevated), or Process (this session only). |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

Returns a single [Netscoot.UpdatePolicy](#netscootupdatepolicy).
The resulting effective policy.

```text
Netscoot.UpdatePolicy
  State   string  # Enabled | Disabled | Manual
  Source  string  # Process | User | Machine | Default
  Value   string  # the raw NETSCOOT_AUTOUPDATE value, or $null
```

##### Examples

```powershell
# Opt in to automatic checks (Test-NetscootUpdate -Auto, e.g. from a SessionStart hook you configure)
Set-NetscootUpdatePolicy -State Enabled

# Block updates on this machine for every user (run elevated)
Set-NetscootUpdatePolicy -State Disabled -Scope Machine

# Back to the default: no auto-check, manual Update-Netscoot still works
Set-NetscootUpdatePolicy -State Manual
```

##### Related

[ [Get-NetscootUpdatePolicy](#get-netscootupdatepolicy) | [Test-NetscootUpdate](#test-netscootupdate) |
[Update-Netscoot](#update-netscoot) ]

[Back to Command reference](#command-reference)

---

#### Sync-Solution

Resolve solution-membership divergence by adding each project to the solutions that are missing it, within each group of
solutions that share projects.

##### Syntax

```powershell
Sync-Solution [[-RepositoryRoot] <string>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

The companion to [Test-SolutionConsistency](#test-solutionconsistency), which only reports divergence. It works on the
same groups: solutions that share at least one project, such as a `.sln` and its `.slnx` mirror. A solution that shares
no project with another is left alone. Within a group, every managed project present in one solution but absent from
another is added where it is missing, through `dotnet sln add`. The dotnet CLI cannot load a `.vcxproj` or .pssproj, so
a missing one is reported as a warning to add in Visual Studio. It only adds and never removes, so a project in no
solution is left alone (use [Get-SolutionInventory](#get-solutioninventory) to find those). Uniform membership within a
group is the assumption. If a solution is intentionally a subset of another it shares projects with, preview with
`-WhatIf` first and add specific projects by hand.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑RepositoryRoot` | String | false | true (ByValue) | Root to scan. Accepts pipeline input: a path string, or a file/directory item from Get-Item / Get-ChildItem. Defaults to the enclosing git repository root. Nested git worktrees are skipped. |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

Returns zero or more [Netscoot.SyncResult](#netscootsyncresult), collected as an array (`$null` when none).
One per project added to a solution.

```text
Netscoot.SyncResult
  Solution  string  # repository-relative
  Added     string  # repository-relative project path
```

##### Examples

```powershell
# Preview which projects would be added to which solutions to make membership uniform
Sync-Solution -RepositoryRoot . -WhatIf

# Add each divergent project to the solutions missing it (only adds, never removes)
Sync-Solution -RepositoryRoot .
```

##### Related

[ [Get-SolutionInventory](#get-solutioninventory) | [Test-SolutionConsistency](#test-solutionconsistency) |
[Repair-SolutionReferences](#repair-solutionreferences) ]

[Back to Command reference](#command-reference)

---

#### Test-EditorSolutionGuard

Check that a repository's editor configuration will keep a `.slnx` consolidation durable - i.e. that VS Code's C# Dev
Kit will not silently re-mint a legacy `.sln` next to it.

##### Syntax

```powershell
Test-EditorSolutionGuard [[-RepositoryRoot] <string>] [-Strict] [<CommonParameters>]
```

Consolidating to a single `.slnx` is not durable on its own. VS Code's C# Dev Kit AUTO-GENERATES a legacy `.sln` next to
a `.slnx` on folder open unless 'dotnet.automaticallyCreateSolutionInWorkspace' is false, so a regenerated `.sln`
reappears and drifts (the exact stale-duplicate that [Test-SolutionConsistency](#test-solutionconsistency) detects after
the fact). When at least one `.slnx` exists in the repository, this inspects the repository-root editor config and
reports whether the guards that keep the consolidation durable are in place: AutoCreateGuard .vscode/settings.json must
set 'dotnet.automaticallyCreateSolutionInWorkspace' to false (else Dev Kit re-mints the `.sln`). DefaultSolution
'dotnet.defaultSolution' should point at a real, existing solution (ideally the `.slnx`). Missing, or pointing at a
deleted/nonexistent file, means Dev Kit chooses which solution loads - possibly a stray `.sln`. GitignoreGuard
.gitignore should ignore *`.sln` so a regenerated one cannot be committed. Read-only: it never edits settings,
.gitignore, or any solution. It emits one result object per check and surfaces findings through the standard streams so
behavior follows invocation. By default it writes a Warning for each failed guard, and `-Strict` escalates each
Warning-level finding to a non-terminating error (honoring `-ErrorAction`). Info-level findings (e.g. a missing
.gitignore guard) are emitted as objects and shown under `-Verbose`, never as warnings. A repository with no
.vscode/settings.json is an Info finding, since it may not use VS Code at all, so `-Strict` does not fail on it. This is
editor-specific (VS Code C# Dev Kit) because that is what governs solution drift in practice. The checks only run when
the repository actually contains a `.slnx`.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑RepositoryRoot` | String | false | true (ByValue) | Root to inspect. Accepts pipeline input: a path string, or a file/directory item from Get-Item / Get-ChildItem. Defaults to the enclosing git repository root. |
| `‑Strict` | SwitchParameter | false | false | Escalate each Warning-level guard finding to a non-terminating error (for CI gating). |

##### Output

Returns zero or more [Netscoot.EditorSolutionGuard](#netscooteditorsolutionguard), collected as an array.
One per check performed.

```text
Netscoot.EditorSolutionGuard
  Check     string  # AutoCreateGuard | DefaultSolution | GitignoreGuard
  Severity  string  # OK | Info | Warning
  Detail    string  # what was found and how to fix it
```

##### Examples

```powershell
# Check the current repository's editor guards
Test-EditorSolutionGuard

# Gate CI on the consolidation being durable
Test-EditorSolutionGuard -RepositoryRoot . -Strict

# Inspect a specific repository from the pipeline
Get-Item ./repo | Test-EditorSolutionGuard
```

##### Related

[ [Test-SolutionConsistency](#test-solutionconsistency) | [Get-SolutionInventory](#get-solutioninventory) ]

[Back to Command reference](#command-reference)

---

#### Test-NetscootUpdate

Check GitHub for a newer netscoot release and report whether the installed version is behind. On-demand and read-only:
it never updates anything itself.

##### Syntax

```powershell
Test-NetscootUpdate [[-Repository] <string>] [-Auto] [<CommonParameters>]
```

netscoot does not update automatically, however it is installed (PowerShell Gallery, installer, or a clone). This is the
pull-based check: It GETs the latest GitHub release and compares its tag (the "available" version) against the installed
module's ModuleVersion (the "installed" version). It prints what to do when behind, but performs no update - an agent or
user runs it when they want to know. Needs network access to api.github.com. Honors `-ErrorAction` if the request fails
(offline, rate-limited, or no releases yet). A plain Test-NetscootUpdate always checks. `-Auto` is the
automation/SessionStart entry point: It runs the check only when the update policy is Enabled (see
[Set-NetscootUpdatePolicy](#set-netscootupdatepolicy)), and is a silent no-op otherwise. So a hook can call it
unconditionally, and nothing happens until the policy is opted in. An administrator can disable it fleet-wide. Either
way it never updates - it only reports.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Repository` | String | false | false | The GitHub repository to check, in `owner/name` form. Defaults to the project repository. |
| `‑Auto` | SwitchParameter | false | false | Run as the automatic check (for a SessionStart hook or other automation): proceed only when the update policy is Enabled, otherwise do nothing. Still read-only - it never updates. |

##### Output

Returns a single [Netscoot.Update](#netscootupdate).
None (writes a non-terminating error) when the release cannot be fetched, and nothing at all when `-Auto` is set but the
update policy is not Enabled.

```text
Netscoot.Update
  Installed        version   # a [version], e.g. 2.1.0 (compares numerically)
  Latest           version?  # a [version], $null if the tag could not be parsed
  Tag              string
  UpdateAvailable  bool
  Url              string
```

##### Examples

```powershell
# Compare the installed module to the latest GitHub release
Test-NetscootUpdate

# Check a fork or a different repository (owner/name)
Test-NetscootUpdate -Repository myfork/netscoot

# SessionStart hook: checks only when the update policy is Enabled
Test-NetscootUpdate -Auto
```

##### Related

[ [Update-Netscoot](#update-netscoot) | [Get-NetscootUpdatePolicy](#get-netscootupdatepolicy) |
[Set-NetscootUpdatePolicy](#set-netscootupdatepolicy) ]

[Back to Command reference](#command-reference)

---

#### Test-SolutionConsistency

Report projects whose membership diverges across the solution files in a repository (present in some solutions but
absent from others).

##### Syntax

```powershell
Test-SolutionConsistency [[-RepositoryRoot] <string>] [-Strict] [<CommonParameters>]
```

When a repository carries more than one solution (e.g. a classic `.sln` alongside a `.slnx`), they can drift out of sync
so the same project is listed in one but not the other. Only solutions that already share at least one project are
compared with each other: a repository may carry intentionally-separate solutions (a standalone client, a submodule's
own solution) that were never meant to list the same projects, and those are not flagged against one another. This emits
one object per divergent project and surfaces it through the standard streams so behavior follows invocation. By default
it writes a Warning per divergent project, and `-Strict` escalates each to a non-terminating error (honoring
`-ErrorAction`). `-Debug` adds the full membership matrix of every solution and its projects. It only reads the solution
files, so the dotnet CLI is not required.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑RepositoryRoot` | String | false | true (ByValue) | Root to scan. Accepts pipeline input: a path string, or a file/directory item from Get-Item / Get-ChildItem. Defaults to the enclosing git repository root. |
| `‑Strict` | SwitchParameter | false | false | Escalate divergences from warnings to non-terminating errors. |

##### Output

Returns zero or more [Netscoot.ConsistencyResult](#netscootconsistencyresult), collected as an array (`$null` when
none).
One per divergent project.

```text
Netscoot.ConsistencyResult
  Project     string
  PresentIn   string[]  # solution paths that list it
  AbsentFrom  string[]  # solution paths that do not
```

##### Examples

```powershell
# Report projects whose membership diverges across solutions (warnings)
Test-SolutionConsistency -RepositoryRoot .

# Add the full solution/project membership matrix
Test-SolutionConsistency -RepositoryRoot . -Debug

# Escalate divergence to non-terminating errors (e.g. to gate CI)
Test-SolutionConsistency -RepositoryRoot . -Strict

# Check several repositories from the pipeline
Get-Item ./repoA, ./repoB | Test-SolutionConsistency -Strict
```

##### Related

[ [Get-SolutionInventory](#get-solutioninventory) | [Sync-Solution](#sync-solution) |
[Repair-SolutionReferences](#repair-solutionreferences) ]

[Back to Command reference](#command-reference)

---

#### Undo-Netscoot

Reverse previous netscoot moves from the per-user journal.

##### Syntax

```powershell
Undo-Netscoot [-RepositoryRoot <string>] [-Last] [-WhatIf] [-Confirm] [<CommonParameters>]

Undo-Netscoot -Id <string> [-RepositoryRoot <string>] [-WhatIf] [-Confirm] [<CommonParameters>]

Undo-Netscoot -After <datetime> [-RepositoryRoot <string>] [-Force] [-WhatIf] [-Confirm] [<CommonParameters>]

Undo-Netscoot -All [-RepositoryRoot <string>] [-Force] [-WhatIf] [-Confirm] [<CommonParameters>]

Undo-Netscoot -List [-RepositoryRoot <string>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Every move is journaled with its inverse: the same mover, source and destination swapped. Undo-Netscoot replays that
inverse, reconciling from the current state rather than restoring a stale snapshot. The reversing move is not itself
journaled, so repeated calls walk back through history instead of toggling the last move. Pick what to reverse (mutually
exclusive): `-Last` (default) the most recent move. Call again to walk further back. `-Id` one specific move, by its
journal id (see `-List`). `-After` every move after a given time, newest first. `-All` every recorded move, newest
first. `-List` prints the journal and changes nothing. Because each reversal reconciles from the current state, undoing
an older move (with `-Id`) while later moves still depend on its old location can leave references dangling. When that
is possible, a read-only sweep of solution membership and ProjectReferences runs afterward and reports dangling entries,
with the command to fix them. Other engines' references are not swept. `-All` and `-After` reverse many moves at once,
so they prompt for a confirmation that `-Confirm:$false` does not silence. `-Force` bypasses it, and `-WhatIf` lists the
reversals without running them. Journaling must have been on when the moves ran. It is on by default, and the opt-outs
are the `NETSCOOT_JOURNAL` environment variable and git config netscoot.journal false.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑RepositoryRoot` | String | false | false | Repository whose journal to use, and the boundary every reversal is confined to. Defaults to the enclosing git repository root of the current directory. |
| `‑Last` | SwitchParameter | false | false | Reverse only the most recent move (the default). |
| `‑Id` | String | true | false | Reverse one specific move, identified by its journal id (the 8-character id from `-List`). If it is not the most recent move, a read-only sweep afterward reports any solution entries and ProjectReferences the out-of-order reversal left dangling. |
| `‑After` | DateTime | true | false | Reverse every move recorded strictly after this time, newest first. The time need not match any recorded entry. |
| `‑All` | SwitchParameter | true | false | Reverse every recorded move, newest first. |
| `‑Force` | SwitchParameter | false | false | With `-All` or `-After`, bypass the confirmation prompt. |
| `‑List` | SwitchParameter | true | false | List the journal (oldest first) and return without undoing anything. |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

The move-result object(s) from the reversing move(s), of the same type as the original mover's. With `-List`, the
journal entries. When there is nothing to undo, nothing is returned and a non-terminating error says why (an empty
journal, journaling off, or no moves after `-After`).

- [Netscoot.MoveResult](#netscootmoveresult)
- [Netscoot.TreeMoveResult](#netscoottreemoveresult)
- [Netscoot.SolutionMoveResult](#netscootsolutionmoveresult)
- [Netscoot.ImportMoveResult](#netscootimportmoveresult)
- [Netscoot.ScriptMoveResult](#netscootscriptmoveresult)
- [Netscoot.PSModuleMoveResult](#netscootpsmodulemoveresult)
- [Netscoot.NativeMoveResult](#netscootnativemoveresult)
- [Netscoot.UnityMoveResult](#netscootunitymoveresult)
- [Netscoot.JournalEntry](#netscootjournalentry)

These result types are heterogeneous - they share no common fields. See [Output types](#output-types).

##### Examples

```powershell
# See what can be undone
Undo-Netscoot -List

# Reverse the most recent move (default), and call again to walk back
Undo-Netscoot

# Reverse one specific move by its journal id (from -List)
Undo-Netscoot -Id a1b2c3d4

# Preview reversing the most recent move
Undo-Netscoot -WhatIf

# Reverse everything recorded in the last hour (prompts)
Undo-Netscoot -After (Get-Date).AddHours(-1)

# Reverse every recorded move (prompts, and -Force skips the prompt)
Undo-Netscoot -All
```

##### Related

[ [Repair-NetscootJournal](#repair-netscootjournal) | [Set-NetscootJournal](#set-netscootjournal) |
[Clear-NetscootJournal](#clear-netscootjournal) ]

[Back to Command reference](#command-reference)

---

#### Unregister-NetscootGitAlias

Remove the `git netscoot` alias registered by [Register-NetscootGitAlias](#register-netscootgitalias).

##### Syntax

```powershell
Unregister-NetscootGitAlias [[-Scope] <string>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Scope` | String | false | false | 'Local' (this repository, default) or 'Global'. |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

None.

##### Examples

```powershell
# Remove the alias for this repository (default scope is Local)
Unregister-NetscootGitAlias

# Remove the global alias from ~/.gitconfig
Unregister-NetscootGitAlias -Scope Global
```

##### Related

[ [Register-NetscootGitAlias](#register-netscootgitalias) ]

[Back to Command reference](#command-reference)

---

#### Update-Netscoot

Update an installed netscoot to the latest GitHub release, in place. The one-command
update for non-clone installs.

##### Syntax

```powershell
Update-Netscoot [[-Repository] <string>] [-Force] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Checks GitHub for a newer release (via [Test-NetscootUpdate](#test-netscootupdate)) and, if the installed version is
behind, runs the release's `install.ps1` to overwrite the modules on your module path. No git, no clone. Does nothing
when already current unless `-Force`. Honors `-WhatIf`/`-Confirm`. After it runs, reload the module in the current
session with `Import-Module Netscoot -Force`. Needs network access to GitHub. For Gallery installs, use
`Update-Module Netscoot` instead. This command updates installer/clone installs in place from the GitHub release, and
replaces a Gallery install's folder with an installer copy. When the update policy is Disabled (see
[Set-NetscootUpdatePolicy](#set-netscootupdatepolicy)), this refuses to update. `-Force` overrides a policy you set for
yourself, never one an administrator set.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Force` | SwitchParameter | false | false | Reinstall the latest release even if already current, and override a Disabled update policy that you set for yourself. |
| `‑Repository` | String | false | false | The GitHub repository to install from, in `owner/name` form. Defaults to the project repository. |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

Returns a single [Netscoot.Update](#netscootupdate).
The record from [Test-NetscootUpdate](#test-netscootupdate), so the decision is inspectable. Nothing when the update
policy blocks the update or the check fails.

```text
Netscoot.Update
  Installed        version   # a [version], e.g. 2.1.0 (compares numerically)
  Latest           version?  # a [version], $null if the tag could not be parsed
  Tag              string
  UpdateAvailable  bool
  Url              string
```

##### Examples

```powershell
# Update to the latest release if the installed copy is behind
Update-Netscoot

# Report what it would do without downloading or installing
Update-Netscoot -WhatIf

# Reinstall the latest even if already up to date
Update-Netscoot -Force
```

##### Related

[ [Test-NetscootUpdate](#test-netscootupdate) | [Get-NetscootUpdatePolicy](#get-netscootupdatepolicy) |
[Set-NetscootUpdatePolicy](#set-netscootupdatepolicy) ]

[Back to Command reference](#command-reference)

---

#### Move-NativeProject

Move a native or C++/CLI project (`.vcxproj`), update the solutions and projects that reference it, and report the
native path-bearing settings it does not rewrite so they are never silently broken. Windows-only.

##### Syntax

```powershell
Move-NativeProject [-Project] <string> -Destination <string> [-RepositoryRoot <string>] [-Force] [-NoJournal] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Native projects link through MSBuild settings that a move can break: AdditionalIncludeDirectories /
AdditionalLibraryDirectories / AdditionalDependencies, `<Import>` of shared `.props/.targets`, `$(SolutionDir)`-relative
OutDir, and the paired vcxproj.filters file. C++/CLI is Windows-only, so this cmdlet refuses to run elsewhere. It will:
move the folder (git mv when tracked) with its paired `.vcxproj`.filters; rewrite the project's path in each
`.sln/.slnx` entry, in every ProjectReference to it (native or managed consumers) and in its own ProjectReferences,
keeping GUIDs, platform mappings and solution folders as they are; and report native settings for a human to verify:
every relative or SolutionDir-relative setting in the moved project (returned as UnreconciledSettings), and every
parent-relative (..) setting in another project that points into its folder (written as warnings). It does not rewrite
those MSBuild settings. The dotnet CLI is not used: it cannot load a `.vcxproj` outside Visual Studio's MSBuild.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Project` | String | true | true (ByValue) | Path to the `.vcxproj`. Accepts a path string or a Get-ChildItem/Get-Item item from the pipeline, and rejects other object types. |
| `‑Destination` | String | true | false | Where to move the project folder, following `git mv` rules: An existing directory means move into it, keeping the name. Any other path is the new folder path. |
| `‑RepositoryRoot` | String | false | false | Root to scan for solutions. Defaults to the enclosing git repository root. |
| `‑Force` | SwitchParameter | false | false | When git is not installed, move with a plain PowerShell `Move-Item` without asking first. Without `-Force` it asks before falling back. The plain move does not preserve git history. |
| `‑NoJournal` | SwitchParameter | false | false | Skip recording this move in the undo journal for this call, even when journaling is enabled ([Undo-Netscoot](#undo-netscoot) will not see this move). |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

Returns a single [Netscoot.NativeMoveResult](#netscootnativemoveresult).

```text
Netscoot.NativeMoveResult
  Engine                string
  Source                string                    # absolute path
  Destination           string                    # absolute path
  Performed             bool                      # false under -WhatIf
  SkippedCount          int
  Solutions             string[]                  # solution names updated
  UnreconciledSettings  Netscoot.NativeSetting[]  # native path settings to verify by hand
                          Kind   string  # e.g. AdditionalIncludeDirectories, OutDir, Import
                          Value  string  # the stored path expression to verify by hand
  HadFilters            bool                      # a paired .vcxproj.filters moved too
```

##### Examples

```powershell
# Preview, including the native path settings it cannot reconcile (verify by hand after)
Move-NativeProject -Project ./Aleppo/Aleppo.vcxproj -Destination ./native/Aleppo -WhatIf

# Move it (also moves the paired .vcxproj.filters)
Move-NativeProject -Project ./Aleppo/Aleppo.vcxproj -Destination ./native/Aleppo

# Move into an existing folder (lands at ./native/Aleppo)
Move-NativeProject -Project ./Aleppo/Aleppo.vcxproj -Destination ./native
```

[Back to Command reference](#command-reference)

---

#### Move-UnityAsset

Move a Unity asset or folder while keeping its paired `.meta` file(s), so the GUIDs that scene/prefab/asmdef references
depend on survive the move.

##### Syntax

```powershell
Move-UnityAsset [-AssetPath] <string> -Destination <string> [-RepositoryRoot <string>] [-Force] [-NoJournal] [-FoldersToPrune <string[]>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

In Unity every asset and folder has a sibling `<name>.meta` carrying a stable GUID. References (in scenes, prefabs, and
asmdef "references" entries of the form "GUID:...") resolve by that GUID, not by path. If you move files on disk without
their `.meta`, Unity regenerates fresh GUIDs and every reference to them breaks. This cmdlet moves the asset (git mv
when tracked) together with its own `.meta`. For a folder, the descendant `.meta` files travel inside it and the
folder's sibling `.meta` is moved too. asmdef references are by name/GUID (not path), so they do not need editing. When
moving an .asmdef this reports who references it, for your awareness only. When the destination needs new parent
folders, each one under Assets/ (or inside a package) gets a folder `.meta` with a fresh GUID, staged with the move, so
it is committed once instead of being generated differently on every machine. [Undo-Netscoot](#undo-netscoot) moves the
asset back and removes those folders and their `.meta` files again, if they are empty. Cross-platform and
target-agnostic: asmdef includePlatforms/excludePlatforms (iOS, Android, etc.) are plain fields untouched by a move, so
mobile layouts are preserved.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑AssetPath` | String | true | true (ByValue) | Asset file or folder to move (under Assets/ or a package). Accepts a path string or a Get-ChildItem/Get-Item item from the pipeline, and rejects other object types. |
| `‑Destination` | String | true | false | Where to move the asset/folder, following `git mv` rules: An existing directory means move into it, keeping the name. Any other path is the new path. |
| `‑RepositoryRoot` | String | false | false | Root to scan for asmdef referencers. Defaults to the enclosing git repository root. |
| `‑Force` | SwitchParameter | false | false | When git is not installed, move with a plain PowerShell `Move-Item` without asking first. Without `-Force` it asks before falling back. The plain move does not preserve git history. |
| `‑NoJournal` | SwitchParameter | false | false | Skip recording this move in the undo journal for this call, even when journaling is enabled ([Undo-Netscoot](#undo-netscoot) will not see this move). |
| `‑FoldersToPrune` | String[] | false | false | Set by [Undo-Netscoot](#undo-netscoot): the folders an earlier move created above AssetPath. After this move, each one that is empty is removed with its folder `.meta`. |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

Returns a single [Netscoot.UnityMoveResult](#netscootunitymoveresult).

```text
Netscoot.UnityMoveResult
  Engine        string
  Source        string    # absolute path
  Destination   string    # absolute path
  Performed     bool      # false under -WhatIf
  SkippedCount  int
  MetaMoved     bool      # the paired .meta moved too
  IsAsmdef      bool      # the moved asset is an .asmdef
  ReferencedBy  string[]  # asmdefs that reference a moved .asmdef (informational, since refs are by name or GUID and survive)
```

##### Examples

```powershell
# Preview moving the asset/folder together with its .meta so GUIDs survive
Move-UnityAsset -AssetPath ./Assets/Plugins/Tarragon -Destination ./Assets/Lib/Tarragon -WhatIf

# Move it for real
Move-UnityAsset -AssetPath ./Assets/Plugins/Tarragon -Destination ./Assets/Lib/Tarragon

# Destination is an existing folder -> lands at ./Assets/Lib/Tarragon
Move-UnityAsset -AssetPath ./Assets/Plugins/Tarragon -Destination ./Assets/Lib
```

[Back to Command reference](#command-reference)

---

#### Test-UnityMetaIntegrity

Report Unity `.meta` integrity problems under a root: Assets missing a `.meta`, and orphan `.meta` files whose asset is
gone. These are the Unity analog of dangling references - both lead to broken/regenerated GUIDs.

##### Syntax

```powershell
Test-UnityMetaIntegrity [[-Root] <string>] [-Strict] [<CommonParameters>]
```

Walks the tree and pairs every asset (file or folder) with its `<name>.meta`. Emits one object per problem and surfaces
it through the standard streams so behavior follows invocation. By default it writes a Warning per problem, and
`-Strict` escalates each to a non-terminating error (honoring `-ErrorAction`). Objects are always emitted so results are
capturable/filterable. Ignores Unity-hidden entries (names starting with '.', folders ending with '~') and everything
inside them, and the Library/Temp/obj caches.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Root` | String | false | true (ByValue) | Folder to scan (typically an 'Assets' folder). Accepts pipeline input: a path string, or a file/directory item from Get-Item / Get-ChildItem. Defaults to the current directory. |
| `‑Strict` | SwitchParameter | false | false | Escalate problems from warnings to non-terminating errors. |

##### Output

Returns zero or more [Netscoot.MetaIntegrity](#netscootmetaintegrity), collected as an array (`$null` when none).
One per problem.

```text
Netscoot.MetaIntegrity
  Kind  string  # MissingMeta | OrphanMeta
  Path  string
```

##### Examples

```powershell
# Report MissingMeta and OrphanMeta under Assets as warnings
Test-UnityMetaIntegrity -Root ./Assets

# Same scan, but escalate each problem to a non-terminating error (e.g. to gate CI)
Test-UnityMetaIntegrity -Root ./Assets -Strict

# Run from the pipeline
Get-Item ./Assets | Test-UnityMetaIntegrity
```

[Back to Command reference](#command-reference)

---

### Output types

Each type below is one object with the fields shown. A command may return a single one or several, and some types are
also used as a field on another. Whether a given command returns one or a collection is stated in that command's Output.
In a field, `type[]` is array-valued, `type?` may be `$null`, and a `Netscoot.*` field is itself one of these types.

| Type | Represents |
| :--- | :--- |
| [Netscoot.Capability](#netscootcapability) | Netscoot's resolved external-tool capabilities and platform - the 'what can I do here' probe. |
| [Netscoot.ConsistencyResult](#netscootconsistencyresult) | One project whose solution membership diverges across the repository. |
| [Netscoot.EditorSolutionGuard](#netscooteditorsolutionguard) | One editor-config check that governs whether a `.slnx` consolidation stays durable (VS Code C# Dev Kit). |
| [Netscoot.GitAlias](#netscootgitalias) | The git netscoot alias registration (or what would be registered). |
| [Netscoot.ImportMoveResult](#netscootimportmoveresult) | Result of moving a shared MSBuild `.props/.targets` file and fixing its importers. |
| [Netscoot.JournalEntry](#netscootjournalentry) | One move in the undo journal: a completed (committed) move, or a pending one interrupted by a crash. |
| [Netscoot.MetaIntegrity](#netscootmetaintegrity) | One Unity `.meta` integrity problem: An asset missing a `.meta`, or an orphan `.meta`. |
| [Netscoot.MoveResult](#netscootmoveresult) | Result of moving a .NET project folder and reconciling solutions and project references. |
| [Netscoot.NativeMoveResult](#netscootnativemoveresult) | Result of moving a native / C++/CLI project (`.vcxproj`). |
| [Netscoot.NativeSetting](#netscootnativesetting) | One path-bearing MSBuild setting in a moved `.vcxproj` that the move reports for manual verification. |
| [Netscoot.PathReference](#netscootpathreference) | One build/CI/hook/container line that hardcodes a moved path and that no first-party tool reconciles. |
| [Netscoot.PSModuleMoveResult](#netscootpsmodulemoveresult) | Result of moving a PowerShell module folder and fixing the paths that load it. |
| [Netscoot.RepairResult](#netscootrepairresult) | One dangling solution-membership or ProjectReference entry that was (or would be) repaired. |
| [Netscoot.ScriptMoveResult](#netscootscriptmoveresult) | Result of moving a standalone `.ps1` and fixing dot-source/call paths. |
| [Netscoot.SolutionItem](#netscootsolutionitem) | One entry in the full contents of a solution (or a project on disk that no solution references). |
| [Netscoot.SolutionMoveResult](#netscootsolutionmoveresult) | Result of moving a solution file and rebasing the relative project paths it stores. |
| [Netscoot.SyncResult](#netscootsyncresult) | One project added to a solution that was missing it, to resolve membership divergence. |
| [Netscoot.ToolInfo](#netscoottoolinfo) | Presence and version of one external tool (git or dotnet). |
| [Netscoot.TreeMoveResult](#netscoottreemoveresult) | Result of moving a folder of one or more .NET projects in one operation. |
| [Netscoot.UnityMoveResult](#netscootunitymoveresult) | Result of moving a Unity asset/folder while keeping its paired `.meta` file(s). |
| [Netscoot.Update](#netscootupdate) | Whether the installed Netscoot is behind the latest GitHub release. |
| [Netscoot.UpdatePolicy](#netscootupdatepolicy) | The effective auto-update policy and where it was resolved from. |

---

#### Netscoot.Capability

[ [Get-NetscootCapability](#get-netscootcapability) ]

Netscoot's resolved external-tool capabilities and platform - the 'what can I do here' probe.

```text
Netscoot.Capability
  Platform            string
  PSEdition           string
  DotnetSupportsSlnx  bool
  Git                 Netscoot.ToolInfo
                        Present  bool    # found on PATH
                        Version  string
                        Path     string
  Dotnet              Netscoot.ToolInfo
                        Present  bool    # found on PATH
                        Version  string
                        Path     string
```

[Back to Output types](#output-types)

---

#### Netscoot.ConsistencyResult

[ [Test-SolutionConsistency](#test-solutionconsistency) ]

One project whose solution membership diverges across the repository.

```text
Netscoot.ConsistencyResult
  Project     string
  PresentIn   string[]  # solution paths that list it
  AbsentFrom  string[]  # solution paths that do not
```

[Back to Output types](#output-types)

---

#### Netscoot.EditorSolutionGuard

[ [Test-EditorSolutionGuard](#test-editorsolutionguard) ]

One editor-config check that governs whether a `.slnx` consolidation stays durable (VS Code C# Dev Kit).

```text
Netscoot.EditorSolutionGuard
  Check     string  # AutoCreateGuard | DefaultSolution | GitignoreGuard
  Severity  string  # OK | Info | Warning
  Detail    string  # what was found and how to fix it
```

[Back to Output types](#output-types)

---

#### Netscoot.GitAlias

[ [Register-NetscootGitAlias](#register-netscootgitalias) ]

The git netscoot alias registration (or what would be registered).

```text
Netscoot.GitAlias
  Alias      string
  Scope      string
  Forwarder  string
  Command    string  # the git config command that was/would be run
```

[Back to Output types](#output-types)

---

#### Netscoot.ImportMoveResult

[ [Invoke-Netscoot](#invoke-netscoot) | [Move-DotnetFile](#move-dotnetfile) | [Move-MSBuildImport](#move-msbuildimport)
| [Undo-Netscoot](#undo-netscoot) ]

Result of moving a shared MSBuild `.props/.targets` file and fixing its importers.

```text
Netscoot.ImportMoveResult
  Engine           string
  Source           string  # absolute path
  Destination      string  # absolute path
  Performed        bool    # false under -WhatIf
  SkippedCount     int
  ImportersFixed   int     # files whose <Import> was rewritten
  OwnImportsFixed  int     # the moved file's own imports rewritten
  AutoImported     bool    # true for a by-location import (e.g. Directory.Build.props) whose inheritance scope changed
```

[Back to Output types](#output-types)

---

#### Netscoot.JournalEntry

[ [Repair-NetscootJournal](#repair-netscootjournal) | [Undo-Netscoot](#undo-netscoot) ]

One move in the undo journal: a completed (committed) move, or a pending one interrupted by a crash.

```text
Netscoot.JournalEntry
  id           string  # 8-character move id
  timestamp    string  # UTC ISO-8601, when the move ran
  status       string  # committed | pending | rolledback
  command      string  # the mover that ran
  engine       string  # dotnet | native | unity | powershell
  source       string
  destination  string
```

[Back to Output types](#output-types)

---

#### Netscoot.MetaIntegrity

[ [Test-UnityMetaIntegrity](#test-unitymetaintegrity) ]

One Unity `.meta` integrity problem: An asset missing a `.meta`, or an orphan `.meta`.

```text
Netscoot.MetaIntegrity
  Kind  string  # MissingMeta | OrphanMeta
  Path  string
```

[Back to Output types](#output-types)

---

#### Netscoot.MoveResult

[ [Invoke-Netscoot](#invoke-netscoot) | [Move-DotnetFile](#move-dotnetfile) | [Move-DotnetProject](#move-dotnetproject)
| [Undo-Netscoot](#undo-netscoot) ]

Result of moving a .NET project folder and reconciling solutions and project references.

```text
Netscoot.MoveResult
  Engine         string
  Source         string    # absolute path
  Destination    string    # absolute path
  Performed      bool      # false under -WhatIf
  SkippedCount   int
  Solutions      string[]  # solution names updated
  ConsumerCount  int       # external references repointed
  OwnRefCount    int       # the moved project's own references rebased
  Built          bool?     # $null with -NoBuild
```

[Back to Output types](#output-types)

---

#### Netscoot.NativeMoveResult

[ [Invoke-Netscoot](#invoke-netscoot) | [Move-NativeProject](#move-nativeproject) | [Undo-Netscoot](#undo-netscoot) ]

Result of moving a native / C++/CLI project (`.vcxproj`).

```text
Netscoot.NativeMoveResult
  Engine                string
  Source                string                    # absolute path
  Destination           string                    # absolute path
  Performed             bool                      # false under -WhatIf
  SkippedCount          int
  Solutions             string[]                  # solution names updated
  UnreconciledSettings  Netscoot.NativeSetting[]  # native path settings to verify by hand
                          Kind   string  # e.g. AdditionalIncludeDirectories, OutDir, Import
                          Value  string  # the stored path expression to verify by hand
  HadFilters            bool                      # a paired .vcxproj.filters moved too
```

[Back to Output types](#output-types)

---

#### Netscoot.NativeSetting

[ [Netscoot.NativeMoveResult](#netscootnativemoveresult) ]

One path-bearing MSBuild setting in a moved `.vcxproj` that the move reports for manual verification.

```text
Netscoot.NativeSetting
  Kind   string  # e.g. AdditionalIncludeDirectories, OutDir, Import
  Value  string  # the stored path expression to verify by hand
```

[Back to Output types](#output-types)

---

#### Netscoot.PathReference

[ [Find-PathReference](#find-pathreference) ]

One build/CI/hook/container line that hardcodes a moved path and that no first-party tool reconciles.

```text
Netscoot.PathReference
  File        string  # repository-relative file containing the line
  Line        int     # 1-based line number
  Confidence  string  # High | Low
  Text        string  # the matching line
```

[Back to Output types](#output-types)

---

#### Netscoot.PSModuleMoveResult

[ [Invoke-Netscoot](#invoke-netscoot) | [Move-PowerShell](#move-powershell) |
[Move-PowerShellModule](#move-powershellmodule) | [Undo-Netscoot](#undo-netscoot) ]

Result of moving a PowerShell module folder and fixing the paths that load it.

```text
Netscoot.PSModuleMoveResult
  Engine        string
  Source        string  # absolute path
  Destination   string  # absolute path
  Performed     bool    # false under -WhatIf
  SkippedCount  int
  Manifest      string  # the manifest file name
```

[Back to Output types](#output-types)

---

#### Netscoot.RepairResult

[ [Repair-SolutionReferences](#repair-solutionreferences) ]

One dangling solution-membership or ProjectReference entry that was (or would be) repaired.

```text
Netscoot.RepairResult
  Kind        string
  Resolution  string
  Missing     string
  NewPath     string
  Container   string
  MissingAbs  string
  Candidates  string[]  # same-named project files found, used to resolve NewPath
```

[Back to Output types](#output-types)

---

#### Netscoot.ScriptMoveResult

[ [Invoke-Netscoot](#invoke-netscoot) | [Move-PowerShell](#move-powershell) |
[Move-PowerShellScript](#move-powershellscript) | [Undo-Netscoot](#undo-netscoot) ]

Result of moving a standalone `.ps1` and fixing dot-source/call paths.

```text
Netscoot.ScriptMoveResult
  Engine            string
  Source            string  # absolute path
  Destination       string  # absolute path
  Performed         bool    # false under -WhatIf
  SkippedCount      int
  ReferencersFixed  int     # scripts whose path to the moved file was rewritten
  OwnRefsFixed      int     # the moved script's own paths rewritten
  UnresolvedRefs    int     # count of possible dynamic references to verify, not a list
```

[Back to Output types](#output-types)

---

#### Netscoot.SolutionItem

[ [Get-SolutionInventory](#get-solutioninventory) ]

One entry in the full contents of a solution (or a project on disk that no solution references).

```text
Netscoot.SolutionItem
  Solution  string                     # repository-relative, or '(none)' for an unreferenced project
  Kind      Netscoot.SolutionItemKind  # enum: Project | SolutionFolder | SolutionItem | UnreferencedProject
  Type      string                     # project extension without the dot, else empty
  Name      string
  Path      string                     # as stored in the solution, or repository-relative
```

[Back to Output types](#output-types)

---

#### Netscoot.SolutionMoveResult

[ [Invoke-Netscoot](#invoke-netscoot) | [Move-DotnetFile](#move-dotnetfile) | [Move-Solution](#move-solution) |
[Undo-Netscoot](#undo-netscoot) ]

Result of moving a solution file and rebasing the relative project paths it stores.

```text
Netscoot.SolutionMoveResult
  Engine           string
  Source           string  # absolute path
  Destination      string  # absolute path
  Performed        bool    # false under -WhatIf
  SkippedCount     int
  ProjectsRebased  int     # project paths rewritten
  ItemsRebased     int     # solution item paths rewritten
```

[Back to Output types](#output-types)

---

#### Netscoot.SyncResult

[ [Sync-Solution](#sync-solution) ]

One project added to a solution that was missing it, to resolve membership divergence.

```text
Netscoot.SyncResult
  Solution  string  # repository-relative
  Added     string  # repository-relative project path
```

[Back to Output types](#output-types)

---

#### Netscoot.ToolInfo

[ [Netscoot.Capability](#netscootcapability) ]

Presence and version of one external tool (git or dotnet).

```text
Netscoot.ToolInfo
  Present  bool    # found on PATH
  Version  string
  Path     string
```

[Back to Output types](#output-types)

---

#### Netscoot.TreeMoveResult

[ [Invoke-Netscoot](#invoke-netscoot) | [Move-DotnetFolder](#move-dotnetfolder) |
[Move-DotnetProjectTree](#move-dotnetprojecttree) | [Undo-Netscoot](#undo-netscoot) ]

Result of moving a folder of one or more .NET projects in one operation.

```text
Netscoot.TreeMoveResult
  Engine         string
  Source         string  # absolute path
  Destination    string  # absolute path
  Performed      bool    # false under -WhatIf
  SkippedCount   int
  ProjectsMoved  int
  ConsumerCount  int     # external references repointed
  Built          bool?   # $null with -NoBuild
```

[Back to Output types](#output-types)

---

#### Netscoot.UnityMoveResult

[ [Invoke-Netscoot](#invoke-netscoot) | [Move-UnityAsset](#move-unityasset) | [Undo-Netscoot](#undo-netscoot) ]

Result of moving a Unity asset/folder while keeping its paired `.meta` file(s).

```text
Netscoot.UnityMoveResult
  Engine        string
  Source        string    # absolute path
  Destination   string    # absolute path
  Performed     bool      # false under -WhatIf
  SkippedCount  int
  MetaMoved     bool      # the paired .meta moved too
  IsAsmdef      bool      # the moved asset is an .asmdef
  ReferencedBy  string[]  # asmdefs that reference a moved .asmdef (informational, since refs are by name or GUID and survive)
```

[Back to Output types](#output-types)

---

#### Netscoot.Update

[ [Test-NetscootUpdate](#test-netscootupdate) | [Update-Netscoot](#update-netscoot) ]

Whether the installed Netscoot is behind the latest GitHub release.

```text
Netscoot.Update
  Installed        version   # a [version], e.g. 2.1.0 (compares numerically)
  Latest           version?  # a [version], $null if the tag could not be parsed
  Tag              string
  UpdateAvailable  bool
  Url              string
```

[Back to Output types](#output-types)

---

#### Netscoot.UpdatePolicy

[ [Get-NetscootUpdatePolicy](#get-netscootupdatepolicy) | [Set-NetscootUpdatePolicy](#set-netscootupdatepolicy) ]

The effective auto-update policy and where it was resolved from.

```text
Netscoot.UpdatePolicy
  State   string  # Enabled | Disabled | Manual
  Source  string  # Process | User | Machine | Default
  Value   string  # the raw NETSCOOT_AUTOUPDATE value, or $null
```

[Back to Output types](#output-types)

---

<!-- END GENERATED REFERENCE -->

netscoot is an independent, community-maintained project, not affiliated with, sponsored by, or
endorsed by Microsoft. ".NET," "dotnet," and related marks are trademarks of Microsoft Corporation,
used here only to describe the projects and tooling netscoot works with.

[gallery]: https://www.powershellgallery.com/packages/Netscoot
[gallery-badge]: https://img.shields.io/powershellgallery/v/Netscoot?logo=powershell&label=PowerShell%20Gallery
[downloads-badge]: https://img.shields.io/powershellgallery/dt/Netscoot?label=downloads
[ci]: https://github.com/kappasims/netscoot/actions/workflows/ci.yml
[ci-badge]: https://github.com/kappasims/netscoot/actions/workflows/ci.yml/badge.svg?branch=develop
[license]: https://github.com/kappasims/netscoot/blob/master/LICENSE
[license-badge]: https://img.shields.io/github/license/kappasims/netscoot?cacheSeconds=300
