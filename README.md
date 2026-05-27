# Netscoot

[![PowerShell Gallery][gallery-badge]][gallery]
[![Downloads][downloads-badge]][gallery]
[![CI][ci-badge]][ci]
[![License][license-badge]][license]

netscoot moves a project, module, or asset (.NET, PowerShell, Unity, or native C++) without breaking
what depends on it, and rolls back if anything fails. It reconciles what the move would otherwise
break: a .NET project's solution membership, references, and GUIDs; a PowerShell module's
manifest; a Unity asset's `.meta` GUIDs; a
native C++ project's solution membership (reporting the link settings it cannot safely rewrite).
Visual Studio does this for a .NET project when you drag it in the GUI, whereas netscoot does it from
the command line, everywhere Visual Studio is not: VS Code, Rider, CI, Linux, macOS, and AI agents.

```powershell
# moves the project and reconciles the .sln, references, and GUIDs (rolls back on failure)
Invoke-Netscoot -Path ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon

# the same move via the git verb; --whatif previews it first
git netscoot src/Tarragon/Tarragon.csproj libs/Tarragon --whatif
```

For AI agents, the repository ships Claude Code skills that run these commands, triggering on phrases
like "move this project" (see [Usage](#usage)).

**Guarantees.** Solution and project files are never hand-edited: every path and GUID change goes
through the tool that owns the format (`dotnet sln` / `dotnet reference`, `git mv`,
`Update-ModuleManifest`), with a targeted in-place rewrite only where no such tool exists. Every move
rolls back to the original state if any step fails, and path-reference detection is report-only.

## Setup

### Requirements

- PowerShell 7+ (Windows, Linux, macOS), or Windows PowerShell 5.1.
- The .NET SDK (`dotnet`) on PATH for .NET project moves; the .NET 9 SDK or later for `.slnx`
  solutions. Moving PowerShell or Unity files does not need it.
- git is optional: with it, moves use `git mv` (history kept); without it, `-Force` does a plain
  `Move-Item` (no history). `Get-NetscootCapability` reports what the machine has.

### Install

Install from the [PowerShell Gallery](https://www.powershellgallery.com/packages/Netscoot) (the
single bundled package, all engines), then load it:

```powershell
Install-Module Netscoot -Scope CurrentUser     # PowerShellGet (Windows PowerShell 5.1+ / PowerShell 7)
Install-PSResource Netscoot                     # PSResourceGet (the newer installer, PowerShell 7.4+)
Import-Module Netscoot                          # load all engines, by name
```

If you cannot reach the Gallery, want to read the installer first, or need to pin a release, install
from the [GitHub release](https://github.com/kappasims/netscoot/releases) instead (it copies the
module folders onto your module path). To update an installed copy, see [Updating](#updating).

## Usage

netscoot exposes the same moves through three front ends. The PowerShell module is the core: after
`Import-Module Netscoot`, the `Invoke-Netscoot` dispatcher routes any supported file or folder to the
right engine, or you can call an engine command (`Move-DotnetProject`, `Move-Solution`,
`Move-PowerShell`, and so on) directly.

```powershell
Import-Module Netscoot   # all engines (native is loaded on Windows only)

# Top-level dispatcher; works for any supported type:
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
Register-NetscootGitAlias -Scope Local -WhatIf   # preview the exact git config command
Register-NetscootGitAlias -Scope Local           # set it
Unregister-NetscootGitAlias -Scope Local         # undo
```

```sh
git netscoot src/Tarragon/Tarragon.csproj libs/Tarragon --whatif   # dry run
git netscoot src/Tarragon/Tarragon.csproj libs/Tarragon            # do it (like git mv, no prompt)
git netscoot Assets/Plugins/Tarragon Assets/Lib/Tarragon      # routes to the Unity engine
git netscoot Aleppo/Aleppo.vcxproj native/Aleppo          # routes to the native engine (Windows)
```

Flags: `--whatif` (preview), `--force` (plain `Move-Item` fallback when git is unavailable),
`--nobuild` (skip the .NET build step). Unity and native engines are loaded on demand.

For AI agents, four Claude Code skills (`.claude/skills/`), one per engine, trigger on natural
language and run the commands above:

| Skill | Triggers on |
| :--- | :--- |
| `restructure-dotnet` | moving a `.csproj/.fsproj/.vbproj`, reorganizing a solution |
| `restructure-powershell` | moving a `.ps1` script or a PowerShell module |
| `restructure-unity` | moving a Unity asset, folder, or `.asmdef` |
| `restructure-native` | moving a native C++ `.vcxproj` (Windows) |

### Moving

Every move recomputes the stored paths after the files move, delegating each change to the tool
that owns the format. The commands, most general first (full per-parameter docs in the
[Reference](#reference)):

Level 1, one command for anything:

| Command | Moves |
| :--- | :--- |
| `Invoke-Netscoot` | any supported file or folder; detects the type and routes |

Level 2, the everyday movers: Hand them a file or a folder and they route to the right specialist.

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
each project to the solutions missing it (via `dotnet sln add`), making membership uniform. It only
adds, never removes; preview with `-WhatIf` first.

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
MissingMeta Assets/Art/logo.png
OrphanMeta  Assets/Old/gone.cs.meta
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

Undo applies to the move commands. `Sync-Solution` and `Repair-SolutionReferences` are not journaled;
preview either with `-WhatIf` first if you want to (as with any command here, it is optional).

```powershell
Undo-Netscoot -List                       # what can be undone (oldest first)
Undo-Netscoot -WhatIf                      # preview reversing the most recent move
Undo-Netscoot                              # reverse the most recent move; call again to walk back further
Undo-Netscoot -Id a1b2c3d4                 # reverse one specific move (its id from -List)
Undo-Netscoot -After (Get-Date).AddHours(-1)   # reverse everything from the last hour, newest first
Undo-Netscoot -All                         # reverse every move, newest first
```

`-List` returns the entries (tagged `Netscoot.JournalEntry`), which print as a table:

```text
Id       When             Command            Source        Destination
--       ----             -------            ------        -----------
a1b2c3d4 2026-05-27 14:02 Move-DotnetProject src/Tarragon  libs/Tarragon
9f3e1c77 2026-05-27 14:05 Move-Solution      Demo.slnx     build/Demo.slnx
```

`-All` and `-After` walk back several moves at once, so they prompt for a yes/no confirmation that
`-Confirm:$false` does not silence; pass `-Force` to bypass it (for automation) or `-WhatIf` to list
the reversals first.

To opt out, turn it off per repository (or for every repository) with `Set-NetscootJournal`, which
writes the `netscoot.journal` git setting:

```powershell
Set-NetscootJournal -Enabled $false           # this repository only
Set-NetscootJournal -Enabled $false -Global    # every repository on the machine
Clear-NetscootJournal                          # also discard the existing undo history
```

The journal is **on by default**, and this opt-out works the same no matter how you installed
(PowerShell Gallery included) - it is a git/env setting, not an install option. (`install.ps1
-NoJournal` is just a shortcut that writes the global git setting for you during a GitHub-release
install.) For where it lives, the on-disk format, crash recovery, pruning, and the full opt-out
precedence, see [How the journal works](#how-the-journal-works).

### Updating

Nothing updates automatically. For Gallery installs, `Update-Module Netscoot` is the one-liner.
Otherwise `Test-NetscootUpdate` checks GitHub for a newer release and `Update-Netscoot` (or
re-running the installer) applies it in place. The Claude Code skills are separate files: Refresh
them with `git pull` in a clone, or re-sync `.claude/skills` if installed globally.

A single policy governs automatic behavior, set with `Set-NetscootUpdatePolicy` (or read with
`Get-NetscootUpdatePolicy`):

| State | Automatic check (`Test-NetscootUpdate -Auto`) | `Update-Netscoot` |
| :--- | :--- | :--- |
| `Enabled` | runs | allowed |
| `Manual` (default) | no-op | allowed (when you run it) |
| `Disabled` | no-op | refused (`-Force` overrides a Disabled you set yourself, not an admin one) |

```powershell
Set-NetscootUpdatePolicy -State Enabled              # opt in: a SessionStart hook's -Auto check now runs
Set-NetscootUpdatePolicy -State Disabled -Scope Machine   # block updates for every user (elevated)
Get-NetscootUpdatePolicy                             # show the effective state and where it came from
```

The policy is stored in the `NETSCOOT_AUTOUPDATE` environment variable, so an administrator can set
the same states fleet-wide through Group Policy / Intune (truthy = Enabled, falsy = Disabled). A
manual `Update-Netscoot` you run yourself works unless the policy is Disabled; the automatic `-Auto`
check stays silent unless the policy is Enabled. `-Force` overrides a Disabled you set for yourself,
but never one an administrator pushed machine-wide.

## How the journal works

The journal lives in a per-user data directory (`%LOCALAPPDATA%\netscoot` on Windows,
`~/Library/Application Support/netscoot` on macOS, `~/.local/share/netscoot` on Linux), one file per
repository, so git never tracks it (and `git clean` cannot remove it) and your `.gitignore` is left
untouched. Set `$env:NETSCOOT_JOURNAL_HOME` to relocate the store (for example a roaming or managed
path).

On disk each entry is one JSON line recording the reversing invocation (the mover and the swapped
splat that `Undo-Netscoot` replays):

```json
{"id":"a1b2c3d4","timestamp":"2026-05-27T14:02:11Z","command":"Move-DotnetProject","engine":"dotnet","source":"src/Tarragon","destination":"libs/Tarragon","undo":{"command":"Move-DotnetProject","params":{"Project":"libs/Tarragon/Tarragon.csproj","Destination":"src/Tarragon"}}}
```

Each move is written ahead of time: a `pending` record before it runs, then a `committed` record
after, so a move interrupted by a crash is detectable (and recoverable with `Repair-NetscootJournal`).
Writes are append-only; the journal prunes lazily, only once it outgrows its caps, dropping entries
older than 180 days and, oldest first, anything beyond a 1 MB cap, always keeping the newest move.

It is safe to delete at any time (`Clear-NetscootJournal`). Each entry is schema-versioned, so a
newer netscoot reads an older journal, and an older netscoot ignores (never misreads) entries written
by a newer one.

The enabled state resolves in this order, first match wins: an internal suppression flag (set by
`Undo-Netscoot` around its own reverse move) → the `NETSCOOT_JOURNAL` env var (`off`/`0`/`false`) →
`git config netscoot.journal` (local wins over global, the durable per-repository setting) → on. The
env var trumps git config so an admin can force the choice fleet-wide; the git setting is the
persistent per-repository default. Installing with `-NoJournal` writes the global git setting (see
[Install](#install)), and updates never flip it back on.

## Footprint

Everything netscoot writes, and where:

- **Installing** copies the module folders to your CurrentUser PowerShell module path (already on
  `$env:PSModulePath`), or an `-InstallPath` you choose. Installing and updating download the release
  zip to the system temp dir and are the only actions that touch the network (`github.com` /
  `api.github.com`).
- **A move** edits the target repository's solution/project files to reconcile it, through first-party
  tooling (see [Guarantees](#netscoot)). It writes a per-repository undo journal to the per-user
  data directory (`%LOCALAPPDATA%\netscoot`, `~/Library/Application Support/netscoot`, or
  `~/.local/share/netscoot`), kept out of the working tree so `git status` stays clean, and snapshots
  the files it edits to the system temp dir for rollback, removed when the move finishes. On by
  default; see [Undoing](#undoing) to opt out, or [How the journal works](#how-the-journal-works)
  to relocate it.
- **Only when you ask:** `Register-NetscootGitAlias` adds one `alias.netscoot` line to your git
  config; `install.ps1 -NoJournal` or `Set-NetscootJournal` turns the journal off, and
  `Clear-NetscootJournal` deletes a repository's journal.

Nothing else under your home or AppData is touched: it never edits `PATH`, never auto-installs git or
the .NET SDK, and sends no telemetry.

### Environment variables

netscoot reads no environment variables by default; each one below is an opt-in control.

<details>
<summary>Environment variables</summary>

| Variable | Values | Effect |
| :--- | :--- | :--- |
| `NETSCOOT_JOURNAL` | `off`/`0`/`false` | Turns the undo journal off. Trumps `git config netscoot.journal`, so an admin can force it on/off fleet-wide. |
| `NETSCOOT_JOURNAL_HOME` | a directory | Relocates the journal store away from the per-user data dir above (point it at a roaming or managed path). |
| `NETSCOOT_AUTOUPDATE` | `true` / `false` | Backs the update policy (see [Updating](#updating)): truthy = Enabled, falsy = Disabled, unset = Manual. Prefer `Set-NetscootUpdatePolicy`; set this directly for Group Policy / Intune. |
| `NETSCOOT_JOURNAL_SUPPRESS` | internal | Set by `Undo-Netscoot` around its own reverse move so the undo is not itself journaled. Not meant to be set by hand. |

</details>

The full journaling precedence and how to turn it off live under
[How the journal works](#how-the-journal-works).

> [!NOTE]
> **For sysadmins.** The update policy is Manual by default, so nothing checks or
> updates on its own; set `NETSCOOT_AUTOUPDATE` (Group Policy / Intune) to `false` to force Disabled
> fleet-wide or `true` for Enabled. A machine-scope Disabled blocks `Update-Netscoot` and `-Force`
> cannot override it. See [Updating](#updating). Journaling
> is controllable per repository or globally
> (`git config [--global] netscoot.journal`), and the `NETSCOOT_JOURNAL` env var trumps that setting
> so you can force the choice fleet-wide; the journal sits in the standard per-user data dir,
> relocatable via `NETSCOOT_JOURNAL_HOME`.

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
| [Move-PowerShellModule](#move-powershellmodule) | Move a PowerShell module folder and reconcile its manifest, delegating manifest edits to Update-ModuleManifest rather than hand-editing the `.psd1`. |
| [Move-NativeProject](#move-nativeproject) | Move a native / C++/CLI project (`.vcxproj`). |
| [Move-UnityAsset](#move-unityasset) | Move a Unity asset or folder while keeping its paired `.meta` file(s), so the GUIDs that scene/prefab/asmdef references depend on survive the move. |

#### Inspect

Read-only audits. These change nothing.

| Command | What it does |
| :--- | :--- |
| [Resolve-MoveEngine](#resolve-moveengine) | Classify a path to the reconciliation engine that should move it: dotnet, native, unity, ps-script, ps-module, or unknown. |
| [Get-NetscootCapability](#get-netscootcapability) | Resolve Netscoot's external-tool capabilities (git, dotnet) and platform. |
| [Test-SolutionConsistency](#test-solutionconsistency) | Report projects whose membership diverges across the solution files in a repository (present in some solutions but absent from others). |
| [Get-SolutionInventory](#get-solutioninventory) | List the full contents of every solution in a repository (projects of any type, solution folders, and solution items), plus on-disk projects that no solution references. |
| [Find-PathReference](#find-pathreference) | Find references to a path in non-canonical, path-hardcoding files (build/CI/hook/ container scripts) that no first-party tool reconciles. |
| [Test-UnityMetaIntegrity](#test-unitymetaintegrity) | Report Unity `.meta` integrity problems under a root: Assets missing a `.meta`, and orphan `.meta` files whose asset is gone. |

#### Manage

Reconcile a repository, undo moves, and control the journal.

##### Reconcile

| Command | What it does |
| :--- | :--- |
| [Repair-SolutionReferences](#repair-solutionreferences) | Scan a repository for broken solution membership and dangling ProjectReferences and repair them by re-pointing each entry at the project's new location. |
| [Sync-Solution](#sync-solution) | Resolve solution-membership divergence by adding each project to the solutions that are missing it, so every solution in the repository lists the same projects. |

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
| [Unregister-NetscootGitAlias](#unregister-netscootgitalias) | Remove the `git netscoot` alias registered by Register-NetscootGitAlias. |

---

#### Clear-NetscootJournal

Delete a repository's move journal, discarding its undo history.

##### Syntax

```powershell
Clear-NetscootJournal [[-RepositoryRoot] <string>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Removes this repository's journal file from the per-user store (LocalAppData on Windows, ~/Library/Application Support
on macOS, ~/.local/share on Linux). The journal prunes itself on every write (entries older than the age cap, then
oldest-first past the size cap), so this is rarely needed; use it to wipe the undo history outright. After clearing,
Undo-Netscoot has nothing to reverse until the next move. It does not change whether journaling is on - use
Set-NetscootJournal for that.

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

[Back to Command reference](#command-reference)

---

#### Find-PathReference

Find references to a path in non-canonical, path-hardcoding files (build/CI/hook/ container scripts) that no first-party
tool reconciles. report-only.

##### Syntax

```powershell
Find-PathReference [-Path] <string> [-RepositoryRoot <string>] [-AdditionalGlob <string[]>] [<CommonParameters>]
```

Moving a project/folder breaks any path hardcoded in `build.ps1`, CI YAML, git hooks, tools scripts,
Makefile/Dockerfile, etc. - and unlike `.sln/.csproj/.psd1` there is no tool that understands their schema, so they
cannot be safely auto-rewritten (a blind regex could corrupt logic). This detects the class of such files (by location +
name, not a hardcoded filename list) and reports lines that reference the given path, so you (or an agent) can fix them
deliberately. It never edits anything. Two confidence tiers: High when the item's repository-relative path appears (e.g.
'`lib/Tarragon.csproj`' or 'lib\\`Tarragon.csproj`'), Low when only the bare leaf name appears (e.g.
'`Tarragon.csproj`'), which is likely but not certain. Run it before a move (to see what will break) or after (searching
the old path).

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Path` | String | true | true (ByValue, ByPropertyName) | The item being/that was moved. Accepts pipeline input. |
| `‑RepositoryRoot` | String | false | false | Root to scan. Defaults to the enclosing git repository root. |
| `‑AdditionalGlob` | String[] | false | false | Extra repository-relative globs to include in the candidate set (e.g. 'deploy/*.sh'). |

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

PowerShell has no manifest mechanism to declare external-CLI prerequisites, so this is a runtime probe via Get-Command;
dotnet is required for .NET project moves (the delegation target), and git is optional (without it, moves fall back to a
plain move (PowerShell `Move-Item`) with no history preserved).

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
Get-NetscootCapability
```

Returns an object with Platform, PSEdition, Git, Dotnet, and DotnetSupportsSlnx.

[Back to Command reference](#command-reference)

---

#### Get-NetscootUpdatePolicy

Report the effective auto-update policy and where it was resolved from.

##### Syntax

```powershell
Get-NetscootUpdatePolicy [<CommonParameters>]
```

netscoot's update behavior is governed by one policy with three states: Enabled automatic checks run
(Test-NetscootUpdate `-Auto`), and Update-Netscoot is allowed. Manual (default) no automatic check runs, but a
Update-Netscoot you invoke yourself works. Disabled automatic checks do nothing, and Update-Netscoot refuses (`-Force`
overrides). The policy is stored in the `NETSCOOT_AUTOUPDATE` environment variable, so it can be set with
Set-NetscootUpdatePolicy or pushed by an administrator (Group Policy / Intune / a profile). This resolves the value in
precedence order: the current process, then (on Windows) the user environment, then the machine environment. A truthy
value (`1`/`true`/`on`) is Enabled, a falsy one (`0`/`false`/`off`) is Disabled, and absent or unrecognized is Manual.

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

[Back to Command reference](#command-reference)

---

#### Get-SolutionInventory

List the full contents of every solution in a repository (projects of any type, solution folders, and solution items),
plus on-disk projects that no solution references.

##### Syntax

```powershell
Get-SolutionInventory [[-RepositoryRoot] <string>] [<CommonParameters>]
```

Where Test-SolutionConsistency compares membership and Repair-SolutionReferences finds dangling entries, this gives the
complete picture without reading the files by hand. It parses each `.sln/.slnx` directly (not via `dotnet sln list`,
which only returns CLI-buildable projects), so it also surfaces non-CLI project types (e.g. .pssproj), solution folders,
and loose solution items. It then compares against the projects on disk and flags any that are in no solution at all.
Read-only: One record per item, so you can group, filter, or format it however you like.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑RepositoryRoot` | String | false | true (ByValue, ByPropertyName) | Root to scan. Accepts pipeline input (path string, or any object with a FullName/Path property). Defaults to the enclosing git repository root. Nested git worktrees are skipped. |

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

[Back to Command reference](#command-reference)

---

#### Invoke-Netscoot

Move any supported item and reconcile references, routing by detected type to the right per-namespace front door. The
single top-level entry point (the `git netscoot` alias calls this).

##### Syntax

```powershell
Invoke-Netscoot [-Path] <string> -Destination <string> [-RepositoryRoot <string>] [-NoBuild] [-Force] [-NoJournal] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Classifies the target with Resolve-MoveEngine, then dispatches to the namespace front door that performs the appropriate
file/folder move (see Output for the routing). The Unity and native C++ front doors load Netscoot.Unity /
Netscoot.Native on demand. "dotnet" here is the .NET-platform umbrella (CLR/CoreCLR), not just the dotnet CLI - the verb
spans every engine. Each engine's behavior lives in its own cmdlet; this only routes. `-WhatIf`/`-Confirm`/`-Verbose`
propagate; `-Force`/`-RepositoryRoot`/`-NoBuild` are forwarded where the target's engine accepts them.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Path` | String | true | true (ByValue) | The item to move (file or folder). Accepts pipeline input (a path string or a Get-ChildItem/Get-Item item; other object types are rejected). |
| `‑Destination` | String | true | false | New path - passed through to the engine. |
| `‑RepositoryRoot` | String | false | false | Repository root the engine scans for references. Defaults to the enclosing git repository root. Not used by the Unity engine. |
| `‑NoBuild` | SwitchParameter | false | false | Skip the verifying 'dotnet build'. Only the .NET engine builds; ignored by the others. |
| `‑Force` | SwitchParameter | false | false | Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history. Forwarded to the engine. |
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
Unity asset  .meta         ->  Netscoot.UnityMoveResult
```

These share a common shape (Engine, Source, Destination, Performed, SkippedCount) and each adds its own fields; they are
plain pscustomobjects with no shared base type. See [Output types](#output-types).

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

# No git in the repository? -Force falls back to a plain Move-Item (history not preserved)
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
PowerShell (`.ps1/.psd1`) and Unity assets are deliberately not handled here - use Move-NativeProject /
Move-PowerShellScript / Move-PowerShellModule / Move-UnityAsset. `-WhatIf`/`-Confirm`/`-Verbose` propagate to the
specialist; `-Force` and `-RepositoryRoot`/`-NoBuild` are forwarded where the specialist accepts them.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Path` | String | true | true (ByValue) | The .NET file to move. Accepts pipeline input (a path string or a Get-ChildItem/Get-Item item; other object types are rejected). |
| `‑Destination` | String | true | false | New path (file or folder) - passed through to the specialist. |
| `‑RepositoryRoot` | String | false | false | Repository root the specialist scans for references. Defaults to the enclosing git repository root. |
| `‑NoBuild` | SwitchParameter | false | false | Skip the verifying 'dotnet build' (forwarded to the project/import specialist). |
| `‑Force` | SwitchParameter | false | false | Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history. |
| `‑NoJournal` | SwitchParameter | false | false | Skip recording this move in the undo journal for this call (forwarded to the specialist), even when journaling is enabled. |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

```text
.csproj  .fsproj  .vbproj  ->  Move-DotnetProject   ->  Netscoot.MoveResult
.sln  .slnx                ->  Move-Solution        ->  Netscoot.SolutionMoveResult
.props  .targets           ->  Move-MSBuildImport   ->  Netscoot.ImportMoveResult
```

These share a common shape (Engine, Source, Destination, Performed, SkippedCount) and each adds its own fields; they are
plain pscustomobjects with no shared base type. See [Output types](#output-types).

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

Move a folder of managed .NET projects, reconciling references. The front door for folder moves in the .NET family;
delegates to Move-DotnetProjectTree (which handles a single project or many).

##### Syntax

```powershell
Move-DotnetFolder [-Path] <string> -Destination <string> [-RepositoryRoot <string>] [-NoBuild] [-Force] [-NoJournal] [-WhatIf] [-Confirm] [<CommonParameters>]
```

A folder move always goes through Move-DotnetProjectTree: It treats every managed project under the folder as one
co-moving set and reconciles only the references that cross the folder boundary (internal references ride along
unchanged). If the folder contains no managed projects, that specialist reports it. `-WhatIf`/`-Confirm`/`-Verbose`
propagate; `-Force`/`-RepositoryRoot`/`-NoBuild` are forwarded.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Path` | String | true | true (ByValue) | The folder to move. Accepts pipeline input (a path string or a Get-ChildItem/Get-Item item; other object types are rejected). |
| `‑Destination` | String | true | false | New folder path. |
| `‑RepositoryRoot` | String | false | false | Repository root scanned for references. Defaults to the enclosing git repository root. |
| `‑NoBuild` | SwitchParameter | false | false | Skip the verifying 'dotnet build' (forwarded to Move-DotnetProjectTree). |
| `‑Force` | SwitchParameter | false | false | Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history. |
| `‑NoJournal` | SwitchParameter | false | false | Skip recording this move in the undo journal for this call (forwarded to the specialist), even when journaling is enabled. |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

Returns a single [Netscoot.TreeMoveResult](#netscoottreemoveresult).
From Move-DotnetProjectTree.

```text
Netscoot.TreeMoveResult
  Engine         string
  Source         string
  Destination    string
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
link so the dotnet CLI recomputes fresh relative paths and preserves GUIDs. The solution and project XML (`.sln/.slnx`,
`.csproj`) is never hand-edited. Diagnostics follow invocation: `-Verbose` narrates the plan, `-Debug` emits the full
solution-membership matrix, and divergence (the project living in some but not all of the repository's solutions) is
surfaced as a Warning (or, with `-Strict`, a non- terminating error honoring `-ErrorAction`).

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Project` | String | true | true (ByValue) | Path to the project file (`.csproj/.fsproj/.vbproj`). Accepts pipeline input - pipe a path string or a Get-ChildItem/Get-Item item. Other object types are rejected. |
| `‑Destination` | String | true | false | Where to move the project folder, following `git mv` rules: if Destination is an existing directory the folder moves into it (keeping its name, e.g. './libs' -&gt; './libs/Tarragon'); otherwise Destination is the project's new folder path (a rename, './libs/Tarragon'). The project file and its sibling contents move as one. |
| `‑RepositoryRoot` | String | false | false | Root to scan for solutions/consumers. Defaults to the enclosing git repository root. |
| `‑Strict` | SwitchParameter | false | false | Escalate solution-divergence warnings to non-terminating errors. |
| `‑NoBuild` | SwitchParameter | false | false | Skip the verifying 'dotnet build' at the end. |
| `‑Force` | SwitchParameter | false | false | Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history. |
| `‑NoJournal` | SwitchParameter | false | false | Skip recording this move in the undo journal for this call, even when journaling is enabled (Undo-Netscoot will not see this move). |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

Returns a single [Netscoot.MoveResult](#netscootmoveresult).

```text
Netscoot.MoveResult
  Engine         string
  Source         string
  Destination    string
  Performed      bool      # false under -WhatIf
  SkippedCount   int
  ConsumerCount  int       # external references repointed
  OwnRefCount    int       # the moved project's own references rebased
  Solutions      string[]  # solution names updated
  Built          bool?     # $null with -NoBuild
```

##### Examples

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
unchanged because both move by the same delta. Everything is delegated to the dotnet CLI; nothing is hand-edited. Like
Move-DotnetProject: dotnet is required; git is used when available (else a confirmed plain-move fallback via `-Force` /
ShouldContinue); supports `-WhatIf`.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Path` | String | true | true (ByValue) | The folder to move. Accepts pipeline input (a path string or a Get-ChildItem/Get-Item item; other object types are rejected). |
| `‑Destination` | String | true | false | Where to move the folder, following `git mv` rules: An existing directory means move into it (keeping the name); otherwise it is the folder's new path. |
| `‑RepositoryRoot` | String | false | false | Root to scan. Defaults to the enclosing git repository root. |
| `‑NoBuild` | SwitchParameter | false | false | Skip the verifying build of the moved projects. |
| `‑Force` | SwitchParameter | false | false | Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history. |
| `‑NoJournal` | SwitchParameter | false | false | Skip recording this move in the undo journal for this call, even when journaling is enabled (Undo-Netscoot will not see this move). |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

Returns a single [Netscoot.TreeMoveResult](#netscoottreemoveresult).

```text
Netscoot.TreeMoveResult
  Engine         string
  Source         string
  Destination    string
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

There is no dotnet CLI for `<Import>`, so this reconciles the relative Import paths directly with precise, formatting-
and BOM-preserving text edits (it replaces the exact `Project="<value>"` token captured from the XML, not a blind
regex). It also fixes the moved file's own outgoing `<Import>` paths, which break when its location changes. The
`$(MSBuildThisFileDirectory)` token is resolved/preserved; other `$(...)` tokens are reported as unresolved rather than
guessed. Note: `Directory.Build.props/.targets` (and `Directory.Packages.props`, etc.) are imported by location, not an
explicit `<Import>` - moving one changes inheritance scope, which cannot be "fixed" by editing imports. For those this
warns (like the inheritance check) and only fixes the file's own outgoing imports. Importers may include native
`.vcxproj` files; their `<Import>` path is fixed on any OS (a best-effort, path-only update), but a `.vcxproj`'s native
link settings are never reconciled off Windows; that remains Move-NativeProject's Windows-only job. dotnet is not
required here; git is used when available (else confirmed plain-move fallback via `-Force`). Supports `-WhatIf`.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Path` | String | true | true (ByValue) | The `.props/.targets` file to move. Accepts pipeline input (a path string or a Get-ChildItem/Get-Item item; other object types are rejected). |
| `‑Destination` | String | true | false | New file path (or a folder, in which case the file keeps its name). |
| `‑RepositoryRoot` | String | false | false | Root to scan for importers. Defaults to the enclosing git repository root. |
| `‑Force` | SwitchParameter | false | false | Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history. |
| `‑NoJournal` | SwitchParameter | false | false | Skip recording this move in the undo journal for this call, even when journaling is enabled (Undo-Netscoot will not see this move). |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

Returns a single [Netscoot.ImportMoveResult](#netscootimportmoveresult).

```text
Netscoot.ImportMoveResult
  Engine           string
  Source           string
  Destination      string
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
dot-source/call references (AST-based), the module specialist reconciles the manifest. `-WhatIf`/`-Confirm`/`-Verbose`
propagate to the specialist; `-Force` is forwarded, and `-RepositoryRoot` is forwarded to the script specialist (the
module specialist has no RepositoryRoot).

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Path` | String | true | true (ByValue) | The PowerShell item to move: a `.ps1` script, a `.psd1` manifest, or a module folder. Accepts pipeline input (a path string or a Get-ChildItem/Get-Item item; other object types are rejected). |
| `‑Destination` | String | true | false | New path - passed through to the specialist. |
| `‑RepositoryRoot` | String | false | false | Repository root scanned for referencing scripts. Defaults to the enclosing git repository root. Forwarded to the script specialist only (the module specialist has no RepositoryRoot). |
| `‑Force` | SwitchParameter | false | false | Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history. |
| `‑NoJournal` | SwitchParameter | false | false | Skip recording this move in the undo journal for this call (forwarded to the specialist), even when journaling is enabled. |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

```text
.ps1                   ->  Move-PowerShellScript  ->  Netscoot.ScriptMoveResult
.psd1  module folder   ->  Move-PowerShellModule  ->  Netscoot.PSModuleMoveResult
```

These share a common shape (Engine, Source, Destination, Performed, SkippedCount) and each adds its own fields; they are
plain pscustomobjects with no shared base type. See [Output types](#output-types).

##### Examples

```powershell
# A .ps1 routes to the script mover (fixes dot-source/call references)
Move-PowerShell -Path ./lib/helpers.ps1 -Destination ./shared/helpers.ps1 -WhatIf

# A module folder (or its .psd1) routes to the module mover (reconciles the manifest)
Move-PowerShell -Path ./tools/Mayo -Destination ./modules/Mayo

# Destination is an existing folder -> the script lands at ./shared/helpers.ps1
Move-PowerShell -Path ./lib/helpers.ps1 -Destination ./shared
```

[Back to Command reference](#command-reference)

---

#### Move-PowerShellModule

Move a PowerShell module folder and reconcile its manifest, delegating manifest edits to Update-ModuleManifest rather
than hand-editing the `.psd1`.

##### Syntax

```powershell
Move-PowerShellModule [-ModulePath] <string> -Destination <string> [-Force] [-NoJournal] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Moves a module directory (git mv when tracked), then rewrites RootModule, NestedModules and FileList in the `.psd1` via
Update-ModuleManifest so relative references stay valid. Validates the result with Test-ModuleManifest. Limits (warned,
not fixed): Dot-sourced relative paths inside `.psm1/.ps1` files, and any path computed at runtime, cannot be reconciled
automatically.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑ModulePath` | String | true | true (ByValue) | Path to the module folder, or directly to its `.psd1` manifest. Accepts pipeline input (a path string or a Get-ChildItem/Get-Item item; other object types are rejected). |
| `‑Destination` | String | true | false | Where to move the module folder, following `git mv` rules: An existing directory means move into it (keeping the name); otherwise it is the module's new folder path. |
| `‑Force` | SwitchParameter | false | false | Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history. |
| `‑NoJournal` | SwitchParameter | false | false | Skip recording this move in the undo journal for this call, even when journaling is enabled (Undo-Netscoot will not see this move). |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

Returns a single [Netscoot.PSModuleMoveResult](#netscootpsmodulemoveresult).

```text
Netscoot.PSModuleMoveResult
  Engine        string
  Source        string
  Destination   string
  Performed     bool    # false under -WhatIf
  SkippedCount  int
  Manifest      string  # the manifest file name
```

##### Examples

```powershell
# Preview; reconciles RootModule/NestedModules/FileList via Update-ModuleManifest
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

Finds references via the PowerShell AST: dot-source (`. path`) and call (`& path`) invocations whose path is a literal
string or a `$PSScriptRoot`-based string resolving to the moved script. It rewrites those relative paths with precise,
BOM-preserving edits, preserving the original style (`$PSScriptRoot`-prefixed or .\-relative). HEURISTIC LIMIT: only
literal and `$PSScriptRoot`-based string paths are resolved and rewritten. A path that is a string built from other
variables (e.g. one rooted at `$dir`) whose leaf matches the moved script is reported as a possible dynamic reference to
verify by hand. A path built entirely from an expression (e.g. Join-Path ...) is not a string node and cannot be
detected at all - grep to be sure. Treat the result as "fixed what could be proven," not "guaranteed complete." git is
used when available (else confirmed plain-move fallback via `-Force`). `-WhatIf` supported; dotnet not required.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Path` | String | true | true (ByValue) | The `.ps1` to move. Accepts pipeline input (a path string or a Get-ChildItem/Get-Item item; other object types are rejected). |
| `‑Destination` | String | true | false | New file path (or a folder, in which case the script keeps its name). |
| `‑RepositoryRoot` | String | false | false | Root to scan for referencing scripts. Defaults to the enclosing git repository root. |
| `‑Force` | SwitchParameter | false | false | Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history. |
| `‑NoJournal` | SwitchParameter | false | false | Skip recording this move in the undo journal for this call, even when journaling is enabled (Undo-Netscoot will not see this move). |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

Returns a single [Netscoot.ScriptMoveResult](#netscootscriptmoveresult).

```text
Netscoot.ScriptMoveResult
  Engine            string
  Source            string
  Destination       string
  Performed         bool    # false under -WhatIf
  SkippedCount      int
  ReferencersFixed  int     # scripts whose path to the moved file was rewritten
  OwnRefsFixed      int     # the moved script's own paths rewritten
  UnresolvedRefs    int     # count of possible dynamic references to verify, not a list
```

##### Examples

```powershell
# Preview; rewrites dot-source/call paths in referencing scripts and the script's own refs
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

A solution stores each project as a path relative to the solution file. Moving the solution changes that base directory,
so every entry must be recomputed. The dotnet CLI has no "rebase" command, so this rewrites the stored paths with
precise, formatting- and BOM-preserving edits. It replaces the exact path token captured from the file (the `.slnx`
`<Project Path="...">` or the `.sln` project line), not a blind regex, and keeps each format's separator convention (/
for `.slnx`, \ for `.sln`). Project-to-project references are unaffected by a solution move and are left alone. git is
used when available (else confirmed plain-move fallback via `-Force`). `-WhatIf` supported. dotnet is not required.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Path` | String | true | true (ByValue) | The `.sln/.slnx` file to move. Accepts pipeline input (a path string or a Get-ChildItem/Get-Item item; other object types are rejected). |
| `‑Destination` | String | true | false | New file path (or a folder, in which case the solution keeps its name). |
| `‑Force` | SwitchParameter | false | false | Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history. |
| `‑NoJournal` | SwitchParameter | false | false | Skip recording this move in the undo journal for this call, even when journaling is enabled (Undo-Netscoot will not see this move). |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

Returns a single [Netscoot.SolutionMoveResult](#netscootsolutionmoveresult).

```text
Netscoot.SolutionMoveResult
  Engine           string
  Source           string
  Destination      string
  Performed        bool    # false under -WhatIf
  SkippedCount     int
  ProjectsRebased  int     # stored paths rewritten
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

Adds `alias.netscoot = !pwsh -NoProfile -File <forwarder>` to git config so `git netscoot <src> <dst>` works. "dotnet"
is the .NET-platform umbrella: The verb branches by target type to the right engine - the .NET project model
(csproj/sln/props), Unity (`.meta`/.asmdef), PowerShell (`.ps1/.psd1`), or native C++ (`.vcxproj`). Scope is your choice
(repository-local or global). Undo with Unregister-NetscootGitAlias. Use `-WhatIf` to see the exact `git config`
command.

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
# Preview the exact git config command (changes nothing)
Register-NetscootGitAlias -Scope Global -WhatIf

# Register for this repository only (default scope is Local)
Register-NetscootGitAlias

# Register globally, in ~/.gitconfig
Register-NetscootGitAlias -Scope Global
```

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
`netscoot_snap_*` recovery directories in the temp folder that no pending entry references.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑RepositoryRoot` | String | false | false | Repository whose journal to inspect, and the boundary every recovery is confined to. Defaults to the enclosing git repository root of the current directory. |
| `‑Rollback` | SwitchParameter | true | false | Roll each interrupted move back to its pre-move state (high-impact: prompts unless `-Force`). |
| `‑Discard` | SwitchParameter | true | false | Forget each interrupted move without touching the working tree (removes its snapshot). |
| `‑Id` | String | false | false | Act on only the interrupted move with this journal id. |
| `‑Force` | SwitchParameter | false | false | Skip the confirmation prompt (for automation). |
| `‑ClearOrphanSnapshots` | SwitchParameter | false | false | Delete temp recovery snapshots (`netscoot_snap_*`) that no pending entry references. |
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
the dotnet CLI (remove the stale path, add the found one). When one project of that name exists it is used directly;
when several do, the one that keeps the most of the original path's trailing folders is chosen, since a moved project
usually keeps its own folder name. Entries it cannot resolve are left untouched and reported, Missing (no such project
anywhere) or Ambiguous (several equally-good candidates). With `-Prune` it removes the Missing entries, the genuinely
deleted ones, through the dotnet CLI. `-Prune` never touches Relocatable or Ambiguous entries. `-Fix` and `-Prune` can
be combined.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑RepositoryRoot` | String | false | true (ByValue, ByPropertyName) | Root to scan. Defaults to the enclosing git repository root of the current directory. |
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

# Re-point relocatable entries at the project's new location (relocates; never deletes)
Repair-SolutionReferences -RepositoryRoot . -Fix

# Also remove entries whose project is gone for good - preview the whole thing first
Repair-SolutionReferences -RepositoryRoot . -Fix -Prune -WhatIf
```

[Back to Command reference](#command-reference)

---

#### Resolve-MoveEngine

Classify a path to the reconciliation engine that should move it: dotnet, native, unity, ps-script, ps-module, or
unknown. Used by the `git netscoot` forwarder and available for introspection.

##### Syntax

```powershell
Resolve-MoveEngine [-Path] <string> [<CommonParameters>]
```

Classification is by target type (extension + location + `.meta` pairing), not by content beyond a folder's
project/manifest scan. The path need not exist (extension-based cases classify regardless); folder cases require the
directory.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Path` | String | true | true (ByValue, ByPropertyName) | The item to classify. Accepts pipeline input. |

##### Output

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

##### Examples

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
environment variable to remember. Local config (the default here) wins over global, matching the resolution order in
Test-MoveJournalEnabled. With `-Global` it writes the user's global git config, switching the default for every
repository on the machine in one place. Requires git; with no git, set `$env:NETSCOOT_JOURNAL` instead.

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

[Back to Command reference](#command-reference)

---

#### Set-NetscootUpdatePolicy

Set netscoot's auto-update policy to Enabled, Disabled, or Manual.

##### Syntax

```powershell
Set-NetscootUpdatePolicy [-State] <string> [[-Scope] <string>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Writes the `NETSCOOT_AUTOUPDATE` environment variable that governs update behavior (see Get-NetscootUpdatePolicy for the
three states). The change always takes effect in the current session; the scope controls how far it persists: `-Scope`
User (default) persists for the current user (Windows). `-Scope` Machine persists for all users (Windows); needs an
elevated session. `-Scope` Process this session only; nothing is persisted. On non-Windows, User/Machine cannot be
persisted programmatically, so this sets the session value and prints the line to add to your shell profile. An
administrator can achieve the same fleet-wide by pushing `NETSCOOT_AUTOUPDATE` through Group Policy / Intune; this
cmdlet is the per-user equivalent.

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
# Opt in to automatic checks (the SessionStart hook will now run)
Set-NetscootUpdatePolicy -State Enabled

# Block updates on this machine for every user (run elevated)
Set-NetscootUpdatePolicy -State Disabled -Scope Machine

# Back to the default: no auto-check, manual Update-Netscoot still works
Set-NetscootUpdatePolicy -State Manual
```

[Back to Command reference](#command-reference)

---

#### Sync-Solution

Resolve solution-membership divergence by adding each project to the solutions that are missing it, so every solution in
the repository lists the same projects.

##### Syntax

```powershell
Sync-Solution [[-RepositoryRoot] <string>] [-WhatIf] [-Confirm] [<CommonParameters>]
```

The companion to Test-SolutionConsistency, which only reports divergence. This makes membership uniform: For every
project present in at least one solution but absent from others, it adds the project to the solutions missing it,
delegating to `dotnet sln add` (never hand-editing the `.sln/.slnx`). It only adds; it never removes, so a project in no
solution is left alone (use Get-SolutionInventory to find those). Uniform membership is the assumption. If a solution is
intentionally a subset, do not run this against the whole repository; preview with `-WhatIf` first and add specific
projects by hand.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑RepositoryRoot` | String | false | true (ByValue, ByPropertyName) | Root to scan. Accepts pipeline input. Defaults to the enclosing git repository root. Nested git worktrees are skipped. |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

Returns zero or more [Netscoot.SyncResult](#netscootsyncresult), collected as an array (`$null` when none).
One per project added.

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

[Back to Command reference](#command-reference)

---

#### Test-NetscootUpdate

Check GitHub for a newer netscoot release and report whether the installed version is behind. On-demand and read-only:
It never updates anything itself.

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
Set-NetscootUpdatePolicy), and is a silent no-op otherwise. So a hook can call it unconditionally; nothing happens until
the policy is opted in, and an administrator can disable it fleet-wide. Either way it never updates - it only reports.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Repository` | String | false | false | owner/name of the GitHub repository to check. Defaults to the project repository. |
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
so the same project is listed in one but not the other. This emits one object per divergent project and surfaces it
through the standard streams so behavior follows invocation: By default it writes a Warning per divergent project;
`-Strict` escalates each to a non-terminating error (honoring `-ErrorAction`); `-Debug` adds the full membership matrix
of every solution and its projects.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑RepositoryRoot` | String | false | true (ByValue, ByPropertyName) | Root to scan. Accepts pipeline input (path string, or any object with a FullName/Path property such as Get-Item output). Defaults to the enclosing git repository root. |
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
exclusive): `-Last` (default) the most recent move; call again to walk further back. `-Id` one specific move, by its
journal id (see `-List`). `-After` every move after a given time, newest first. `-All` every recorded move, newest
first. `-List` prints the journal and changes nothing. Because each reversal reconciles from the current state, undoing
an older move (with `-Id`) while later moves still depend on its old location can leave references dangling. When that
is possible, a read-only sweep runs afterward and reports anything broken, with the command to fix it. `-All` and
`-After` reverse many moves at once, so they prompt for a confirmation that `-Confirm`:`$false` does not silence;
`-Force` bypasses it, and `-WhatIf` lists the reversals without running them. Journaling must have been on when the
moves ran (it is by default; opt out with `$env:NETSCOOT_JOURNAL` or git config netscoot.journal false).

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑RepositoryRoot` | String | false | false | Repository whose journal to use, and the boundary every reversal is confined to. Defaults to the enclosing git repository root of the current directory. |
| `‑Last` | SwitchParameter | false | false | Reverse only the most recent move (the default). |
| `‑Id` | String | true | false | Reverse one specific move, identified by its journal id (the 8-character id from `-List`). If it is not the most recent move, a read-only sweep afterward reports any references the out-of-order reversal left dangling. |
| `‑After` | DateTime | true | false | Reverse every move recorded strictly after this time, newest first. The time need not match any recorded entry. |
| `‑All` | SwitchParameter | true | false | Reverse every recorded move, newest first. |
| `‑Force` | SwitchParameter | false | false | With `-All` or `-After`, bypass the confirmation prompt. |
| `‑List` | SwitchParameter | true | false | List the journal (oldest first) and return without undoing anything. |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

The move-result object(s) from the reversing move(s); their type matches the original mover. With `-List`, the journal
entries. Nothing when there is nothing to undo.

##### Examples

```powershell
# See what can be undone
Undo-Netscoot -List

# Reverse the most recent move (default); call again to walk back
Undo-Netscoot

# Reverse one specific move by its journal id (from -List)
Undo-Netscoot -Id a1b2c3d4

# Preview reversing the most recent move
Undo-Netscoot -WhatIf

# Reverse everything recorded in the last hour (prompts)
Undo-Netscoot -After (Get-Date).AddHours(-1)

# Reverse every recorded move (prompts; -Force to skip the prompt)
Undo-Netscoot -All
```

[Back to Command reference](#command-reference)

---

#### Unregister-NetscootGitAlias

Remove the `git netscoot` alias registered by Register-NetscootGitAlias.

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

[Back to Command reference](#command-reference)

---

#### Update-Netscoot

Update an installed netscoot to the latest GitHub release, in place. The one-command
update for non-clone installs.

##### Syntax

```powershell
Update-Netscoot [[-Repository] <string>] [-Force] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Checks GitHub for a newer release (via Test-NetscootUpdate) and, if the installed version is behind, runs the release's
`install.ps1` to overwrite the modules on your module path. No git, no clone. Does nothing when already current unless
`-Force`. Honors `-WhatIf`/`-Confirm`. After it runs, reload the module in the current session with
`Import-Module Netscoot -Force`. Needs network access to GitHub. For Gallery installs, `Update-Module Netscoot` is the
simpler path; this command updates installer/clone installs in place from the GitHub release. Policy kill-switch: when
the update policy is Disabled (see Set-NetscootUpdatePolicy), this refuses to update so machine state stays managed.
`-Force` overrides a Disabled you set for yourself (process or user scope), but NOT one an administrator pushed
machine-wide (Group Policy / Intune).

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Force` | SwitchParameter | false | false | Reinstall the latest release even if already current, and override a Disabled update policy that you set for yourself. A machine-scope (administrator) Disabled is never overridden. |
| `‑Repository` | String | false | false | owner/name of the GitHub repository. Defaults to the project repository. |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

Returns a single [Netscoot.Update](#netscootupdate).
The record from Test-NetscootUpdate, so the decision is inspectable. Nothing on a failed check.

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

[Back to Command reference](#command-reference)

---

#### Move-NativeProject

Move a native / C++/CLI project (`.vcxproj`). Windows-only. Does the parts the dotnet CLI can delegate (solution
membership, the move itself) and reports the native path-bearing settings it cannot reconcile so they are never silently
broken.

##### Syntax

```powershell
Move-NativeProject [-Project] <string> -Destination <string> [-RepositoryRoot <string>] [-Force] [-NoJournal] [-WhatIf] [-Confirm] [<CommonParameters>]
```

Native projects link through MSBuild settings the dotnet CLI does not touch: AdditionalIncludeDirectories /
AdditionalLibraryDirectories / AdditionalDependencies, `<Import>` of shared `.props/.targets`, `$(SolutionDir)`-relative
OutDir, and the paired `.vcxproj`.filters. C++/CLI is Windows-only, so this cmdlet refuses to run elsewhere. It will:
Update `.sln/.slnx` membership via 'dotnet sln' (which understands `.vcxproj`), move the folder (git mv when tracked),
move the paired `.vcxproj`.filters alongside, and then emit a report of every relative/SolutionDir-relative native
setting that a human (or a future native engine) must verify. It deliberately does not rewrite those MSBuild paths yet -
surfacing them beats silently mis-editing them.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Project` | String | true | true (ByValue) | Path to the `.vcxproj`. Accepts pipeline input (a path string or a Get-ChildItem/Get-Item item; other object types are rejected). |
| `‑Destination` | String | true | false | Where to move the project folder, following `git mv` rules: An existing directory means move into it (keeping the name); otherwise it is the new folder path. |
| `‑RepositoryRoot` | String | false | false | Root to scan for solutions. Defaults to the enclosing git repository root. |
| `‑Force` | SwitchParameter | false | false | Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history. |
| `‑NoJournal` | SwitchParameter | false | false | Skip recording this move in the undo journal for this call, even when journaling is enabled (Undo-Netscoot will not see this move). |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

Returns a single [Netscoot.NativeMoveResult](#netscootnativemoveresult).

```text
Netscoot.NativeMoveResult
  Engine                string
  Source                string
  Destination           string
  Performed             bool      # false under -WhatIf
  SkippedCount          int
  HadFilters            bool      # a paired .vcxproj.filters moved too
  Solutions             string[]  # solution names updated
  UnreconciledSettings  object[]  # one per native path setting to verify by hand; each has the setting name and value
```

##### Examples

```powershell
# Preview; reports the native path settings it cannot reconcile (verify by hand after)
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
Move-UnityAsset [-AssetPath] <string> -Destination <string> [-RepositoryRoot <string>] [-Force] [-NoJournal] [-WhatIf] [-Confirm] [<CommonParameters>]
```

In Unity every asset and folder has a sibling `<name>.meta` carrying a stable GUID. References (in scenes, prefabs, and
asmdef "references" entries of the form "GUID:...") resolve by that GUID, not by path. If you move files on disk without
their `.meta`, Unity regenerates fresh GUIDs and every reference to them breaks. This cmdlet moves the asset (git mv
when tracked) together with its own `.meta`; for a folder, the descendant `.meta` files travel inside it and the
folder's sibling `.meta` is moved too. asmdef references are by name/GUID (not path), so they do not need editing; when
moving an .asmdef this reports who references it, for your awareness only. Cross-platform and target-agnostic: asmdef
includePlatforms/excludePlatforms (iOS, Android, etc.) are plain fields untouched by a move, so mobile layouts are
preserved.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑AssetPath` | String | true | true (ByValue) | Asset file or folder to move (under Assets/ or a package). Accepts pipeline input (a path string or a Get-ChildItem/Get-Item item; other object types are rejected). |
| `‑Destination` | String | true | false | Where to move the asset/folder, following `git mv` rules: An existing directory means move into it (keeping the name); otherwise it is the new path. |
| `‑RepositoryRoot` | String | false | false | Root to scan for asmdef referencers. Defaults to the enclosing git repository root. |
| `‑Force` | SwitchParameter | false | false | Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history. |
| `‑NoJournal` | SwitchParameter | false | false | Skip recording this move in the undo journal for this call, even when journaling is enabled (Undo-Netscoot will not see this move). |
| `‑WhatIf` | SwitchParameter | false | false | Preview the operation and report what would change, without modifying anything. |
| `‑Confirm` | SwitchParameter | false | false | Prompt for confirmation before each change. |

##### Output

Returns a single [Netscoot.UnityMoveResult](#netscootunitymoveresult).

```text
Netscoot.UnityMoveResult
  Engine        string
  Source        string
  Destination   string
  Performed     bool      # false under -WhatIf
  SkippedCount  int
  MetaMoved     bool      # the paired .meta moved too
  IsAsmdef      bool      # the moved asset is an .asmdef
  ReferencedBy  string[]  # asmdefs that reference a moved .asmdef; informational, refs are by name/GUID and survive
```

##### Examples

```powershell
# Preview; moves the asset/folder together with its .meta so GUIDs survive
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
it through the standard streams so behavior follows invocation: By default it writes a Warning per problem; `-Strict`
escalates each to a non-terminating error (honoring `-ErrorAction`). Objects are always emitted so results are
capturable/filterable. Ignores Unity-hidden entries (names starting with '.', folders ending with '~') and the
Library/Temp/obj caches.

##### Parameters

| Name | Type | Required | Pipeline | Description |
| :--- | :--- | :--- | :--- | :--- |
| `‑Root` | String | false | true (ByValue, ByPropertyName) | Folder to scan (typically an 'Assets' folder). Accepts pipeline input. Defaults to the current directory. |
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
Test-UnityMetaIntegrity -Root ./Assets -Strict
```

Reports MissingMeta and OrphanMeta under Assets, one non-terminating error each.

[Back to Command reference](#command-reference)

### Output types

Each type below is one `pscustomobject` with the fields shown. A command may return a single one or several (and some
types are also used as a field on another); whether a given command returns one or a collection is stated in that
command's Output. In a field, `type[]` is array-valued, `type?` may be `$null`, and a `Netscoot.*` field is itself one
of these types.

| Type | Represents |
| :--- | :--- |
| [Netscoot.Capability](#netscootcapability) | Netscoot's resolved external-tool capabilities and platform - the 'what can I do here' probe. |
| [Netscoot.ConsistencyResult](#netscootconsistencyresult) | One project whose solution membership diverges across the repository. |
| [Netscoot.GitAlias](#netscootgitalias) | The git netscoot alias registration (or what would be registered). |
| [Netscoot.ImportMoveResult](#netscootimportmoveresult) | Result of moving a shared MSBuild `.props/.targets` file and fixing its importers. |
| [Netscoot.JournalEntry](#netscootjournalentry) | One move in the undo journal: a completed (committed) move, or a pending one interrupted by a crash. |
| [Netscoot.MetaIntegrity](#netscootmetaintegrity) | One Unity `.meta` integrity problem: An asset missing a `.meta`, or an orphan `.meta`. |
| [Netscoot.MoveResult](#netscootmoveresult) | Result of moving a .NET project folder and reconciling solutions and project references. |
| [Netscoot.NativeMoveResult](#netscootnativemoveresult) | Result of moving a native / C++/CLI project (`.vcxproj`). |
| [Netscoot.PathReference](#netscootpathreference) | One build/CI/hook/container line that hardcodes a moved path and that no first-party tool reconciles. |
| [Netscoot.PSModuleMoveResult](#netscootpsmodulemoveresult) | Result of moving a PowerShell module folder and reconciling its manifest. |
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

#### Netscoot.ImportMoveResult

[ [Invoke-Netscoot](#invoke-netscoot) | [Move-DotnetFile](#move-dotnetfile) | [Move-MSBuildImport](#move-msbuildimport)
]

Result of moving a shared MSBuild `.props/.targets` file and fixing its importers.

```text
Netscoot.ImportMoveResult
  Engine           string
  Source           string
  Destination      string
  Performed        bool    # false under -WhatIf
  SkippedCount     int
  ImportersFixed   int     # files whose <Import> was rewritten
  OwnImportsFixed  int     # the moved file's own imports rewritten
  AutoImported     bool    # true for a by-location import (e.g. Directory.Build.props) whose inheritance scope changed
```

[Back to Output types](#output-types)

#### Netscoot.JournalEntry

[ [Repair-NetscootJournal](#repair-netscootjournal) ]

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

#### Netscoot.MetaIntegrity

[ [Test-UnityMetaIntegrity](#test-unitymetaintegrity) ]

One Unity `.meta` integrity problem: An asset missing a `.meta`, or an orphan `.meta`.

```text
Netscoot.MetaIntegrity
  Kind  string  # MissingMeta | OrphanMeta
  Path  string
```

[Back to Output types](#output-types)

#### Netscoot.MoveResult

[ [Invoke-Netscoot](#invoke-netscoot) | [Move-DotnetFile](#move-dotnetfile) | [Move-DotnetProject](#move-dotnetproject)
]

Result of moving a .NET project folder and reconciling solutions and project references.

```text
Netscoot.MoveResult
  Engine         string
  Source         string
  Destination    string
  Performed      bool      # false under -WhatIf
  SkippedCount   int
  ConsumerCount  int       # external references repointed
  OwnRefCount    int       # the moved project's own references rebased
  Solutions      string[]  # solution names updated
  Built          bool?     # $null with -NoBuild
```

[Back to Output types](#output-types)

#### Netscoot.NativeMoveResult

[ [Invoke-Netscoot](#invoke-netscoot) | [Move-NativeProject](#move-nativeproject) ]

Result of moving a native / C++/CLI project (`.vcxproj`).

```text
Netscoot.NativeMoveResult
  Engine                string
  Source                string
  Destination           string
  Performed             bool      # false under -WhatIf
  SkippedCount          int
  HadFilters            bool      # a paired .vcxproj.filters moved too
  Solutions             string[]  # solution names updated
  UnreconciledSettings  object[]  # one per native path setting to verify by hand; each has the setting name and value
```

[Back to Output types](#output-types)

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

#### Netscoot.PSModuleMoveResult

[ [Invoke-Netscoot](#invoke-netscoot) | [Move-PowerShell](#move-powershell) |
[Move-PowerShellModule](#move-powershellmodule) ]

Result of moving a PowerShell module folder and reconciling its manifest.

```text
Netscoot.PSModuleMoveResult
  Engine        string
  Source        string
  Destination   string
  Performed     bool    # false under -WhatIf
  SkippedCount  int
  Manifest      string  # the manifest file name
```

[Back to Output types](#output-types)

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

#### Netscoot.ScriptMoveResult

[ [Invoke-Netscoot](#invoke-netscoot) | [Move-PowerShell](#move-powershell) |
[Move-PowerShellScript](#move-powershellscript) ]

Result of moving a standalone `.ps1` and fixing dot-source/call paths.

```text
Netscoot.ScriptMoveResult
  Engine            string
  Source            string
  Destination       string
  Performed         bool    # false under -WhatIf
  SkippedCount      int
  ReferencersFixed  int     # scripts whose path to the moved file was rewritten
  OwnRefsFixed      int     # the moved script's own paths rewritten
  UnresolvedRefs    int     # count of possible dynamic references to verify, not a list
```

[Back to Output types](#output-types)

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

#### Netscoot.SolutionMoveResult

[ [Invoke-Netscoot](#invoke-netscoot) | [Move-DotnetFile](#move-dotnetfile) | [Move-Solution](#move-solution) ]

Result of moving a solution file and rebasing the relative project paths it stores.

```text
Netscoot.SolutionMoveResult
  Engine           string
  Source           string
  Destination      string
  Performed        bool    # false under -WhatIf
  SkippedCount     int
  ProjectsRebased  int     # stored paths rewritten
```

[Back to Output types](#output-types)

#### Netscoot.SyncResult

[ [Sync-Solution](#sync-solution) ]

One project added to a solution that was missing it, to resolve membership divergence.

```text
Netscoot.SyncResult
  Solution  string  # repository-relative
  Added     string  # repository-relative project path
```

[Back to Output types](#output-types)

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

#### Netscoot.TreeMoveResult

[ [Invoke-Netscoot](#invoke-netscoot) | [Move-DotnetFolder](#move-dotnetfolder) |
[Move-DotnetProjectTree](#move-dotnetprojecttree) ]

Result of moving a folder of one or more .NET projects in one operation.

```text
Netscoot.TreeMoveResult
  Engine         string
  Source         string
  Destination    string
  Performed      bool    # false under -WhatIf
  SkippedCount   int
  ProjectsMoved  int
  ConsumerCount  int     # external references repointed
  Built          bool?   # $null with -NoBuild
```

[Back to Output types](#output-types)

#### Netscoot.UnityMoveResult

[ [Invoke-Netscoot](#invoke-netscoot) | [Move-UnityAsset](#move-unityasset) ]

Result of moving a Unity asset/folder while keeping its paired `.meta` file(s).

```text
Netscoot.UnityMoveResult
  Engine        string
  Source        string
  Destination   string
  Performed     bool      # false under -WhatIf
  SkippedCount  int
  MetaMoved     bool      # the paired .meta moved too
  IsAsmdef      bool      # the moved asset is an .asmdef
  ReferencedBy  string[]  # asmdefs that reference a moved .asmdef; informational, refs are by name/GUID and survive
```

[Back to Output types](#output-types)

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

<!-- END GENERATED REFERENCE -->

---

netscoot is an independent, community-maintained project, not affiliated with, sponsored by, or
endorsed by Microsoft. ".NET," "dotnet," and related marks are trademarks of Microsoft Corporation,
used here only to describe the projects and tooling netscoot works with.

[gallery]: https://www.powershellgallery.com/packages/Netscoot
[gallery-badge]: https://img.shields.io/powershellgallery/v/Netscoot?logo=powershell&label=PowerShell%20Gallery
[downloads-badge]: https://img.shields.io/powershellgallery/dt/Netscoot?label=downloads
[ci]: https://github.com/kappasims/netscoot/actions/workflows/ci.yml
[ci-badge]: https://github.com/kappasims/netscoot/actions/workflows/ci.yml/badge.svg?branch=develop
[license]: https://github.com/kappasims/netscoot/blob/master/LICENSE
[license-badge]: https://img.shields.io/github/license/kappasims/netscoot
