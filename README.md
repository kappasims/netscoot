# ![netscoot icon: a robot moving a nested item up a project tree](docs/icon-title.svg) Netscoot

[![PowerShell Gallery][gallery-badge]][gallery]
[![Downloads][downloads-badge]][gallery]
[![CI][ci-badge]][ci]
[![License][license-badge]][license]

A safer way for your agent to restructure .NET, PowerShell, Unity, and native C++ projects. Instead of
the agent hand-editing solution and project files, netscoot uses each format's own tooling where one
exists and otherwise changes only the paths. A move that fails is rolled back on a best-effort basis.
Its analysis commands (solution consistency, dangling and hardcoded references) and repair commands
(solution sync, broken references, interrupted moves) also work on their own.

A moved .NET project keeps its solution membership and project references. A moved PowerShell script
or module keeps the paths that load it, a Unity asset keeps its `.meta` GUID, and a native C++ project
keeps its solution entry and references, with a report of the build settings netscoot cannot safely
rewrite.

```powershell
# moves the project and updates the solution and references (rolls back if that fails)
Invoke-Netscoot -Path ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon

# the same move via the git verb; --whatif previews it first
git netscoot src/Tarragon/Tarragon.csproj libs/Tarragon --whatif
```

For AI agents, the repository ships a Claude Code plugin whose skills run these commands, triggering
on phrases like "move this project". The plugin carries the module, so it needs no separate install
(see [Usage](#usage)).

**How moves edit files.** Path changes go through the tool that owns the format where one works
(`dotnet sln` / `dotnet reference` for managed projects, `git mv`). Where none does, such as native
`.vcxproj` entries, `<Import>` paths and script references, netscoot rewrites only the path text in
place and keeps every GUID, platform mapping, line of formatting and file encoding. When a
reconciliation step fails, netscoot rolls the move back on a best-effort basis. A failed verifying
build only warns. Path-reference detection is report-only.

## Project philosophy

What netscoot optimizes for, in order:

1. **Accurate functionality.** Path changes delegate to first-party tooling (`dotnet sln`,
   `git mv`) wherever it works, and otherwise change only the path text. A move that breaks
   references is worse than no move.
2. **Reliability.** Write-ahead journal, in-operation rollback, structured `-WhatIf` previews, and
   CI gates against drift on both the Gallery-listed surface and the agent-discovery
   (`src/skills/`) surface.
3. **A conservative public shape.** Only what callers need ships as a public cmdlet. Internal
   helpers stay internal (see CONTRIBUTING for the convention). Result-type shapes are documented
   and gated.
4. **Documentation.** The [command reference](docs/reference.md) is generated from comment-based
   help, so it cannot drift from the cmdlets. CHANGELOG and CONTRIBUTING carry the operational and
   contributor contracts.

Raw performance and pattern/coding-consistency refactors are not priorities of their own. They get
addressed when they collide with the four above, or when there is concrete user-facing pain to
point at, not for their own sake.

## Setup

### Requirements

- PowerShell 7.2+ (Windows, Linux, macOS), or Windows PowerShell 5.1.
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
right engine, or you can call an engine command directly (they are listed under [Moving](#moving)).

```powershell
Import-Module Netscoot   # all engines (native is loaded on Windows only)

# The dispatcher takes any supported type:
Invoke-Netscoot -Path ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon -WhatIf
Invoke-Netscoot -Path ./build/helpers.ps1 -Destination ./shared/helpers.ps1
Invoke-Netscoot -Path ./Assets/Plugins/Tarragon -Destination ./Assets/Lib/Tarragon

# Or call an engine command directly:
Move-DotnetProject -Project ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon
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
```

Flags: `--whatif` (preview), `--force` (plain `Move-Item` fallback without asking when git is not
installed), `--nobuild` (skip the .NET build step). Unity and native engines are loaded on demand.
The alias runs `pwsh`, so it needs PowerShell 7 on PATH.

For AI agents, four Claude Code skills (`src/skills/`), one per engine, trigger on natural
language and run the commands above:

| Skill | Triggers on |
| :--- | :--- |
| `restructure-dotnet` | moving a `.csproj/.fsproj/.vbproj`, reorganizing a solution |
| `restructure-powershell` | moving a `.ps1` script or a PowerShell module |
| `restructure-unity` | moving a Unity asset, folder, or `.asmdef` |
| `restructure-native` | moving a native C++ `.vcxproj` (Windows) |

An analysis skill, `netscoot-analyze` (inventory, consistency and reference checks), and a management
skill, `netscoot-manage` (update policy, journal and git alias), round out the set. Install them as a
Claude Code plugin, which brings its own copy of the module, so no separate install is needed. In a
terminal session:

```text
/plugin marketplace add kappasims/netscoot
/plugin install netscoot@netscoot
```

In the desktop app, add the marketplace from a terminal first
(`claude plugin marketplace add kappasims/netscoot`), then install netscoot from
**+ > Plugins > Add plugin**.

Claude Code updates plugins from marketplaces outside Anthropic's own only when you turn that on, so
turn it on once: in `/plugin`, open the **Marketplaces** tab, select netscoot, and choose
**Enable auto-update**. To update by hand, run this in a shell:

```bash
claude plugin update netscoot@netscoot
```

An update applies to new sessions, and to a running terminal session after `/reload-plugins`. The
desktop app reads the same settings, so its next session loads the new version. The plugin version is
the netscoot release it carries.

### Moving

Every move recomputes the stored paths after the files move, delegating each change to the tool
that owns the format. The commands, most general first (full per-parameter docs in the
[command reference](docs/reference.md#command-reference)):

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
   fails, netscoot rolls the move back on a best-effort basis.
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

over the old identifier (the moved file's old path, a renamed type, an old DLL name in build
scripts), from the repository root. The default scan skips source files, so add `-AllFiles` when the
identifier can appear in code. Each row it returns is a reference the move machinery does not touch
(build scripts, CI YAML, git hooks, container files), with a warning that these are not
auto-reconciled. Fix them by hand and re-run. A zero-row result with no warning is the all-clear.
The `netscoot-analyze` skill runs the same check when an agent is asked whether a rename is done.

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

### Updating

The module never updates itself. For Gallery installs, `Update-Module Netscoot` is the one-liner.
Otherwise `Test-NetscootUpdate` checks GitHub for a newer release and `Update-Netscoot` (or
re-running the installer) applies it in place.

The Claude Code plugin carries its own copy of the module, from the same release as its skills, and
the skills load that copy. So a plugin update, by hand or automatic (see [Usage](#usage) for turning
automatic updates on), updates the skills and the code together, and Claude never runs skills against
an older module. The plugin does not need the module installed, and it leaves an installed module
alone.

> Updating from a release before 2.6.1: the in-box `Test-NetscootUpdate` / `Update-Netscoot` cannot
> fetch the fix, since the broken endpoint they shipped with is exactly what 2.6.1 repairs. Update
> once by the path you installed from - `Update-Module Netscoot` (Gallery) or re-run `install.ps1`
> (installer) - then the in-box updater works again.

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
the same states fleet-wide through Group Policy / Intune (see
[Environment variables](#environment-variables)). The `-Auto` check is meant for a SessionStart hook
you configure.

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
  tooling where one exists and path-text-only edits otherwise (see "How moves edit files" at the top).
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

A machine-wide `NETSCOOT_AUTOUPDATE` of `false` blocks `Update-Netscoot` for every user and cannot be
overridden. The full journaling precedence is under
[Turning the journal off](#turning-the-journal-off).

## Privacy policy

netscoot collects no personal data and sends no telemetry. It runs on your machine, and what it writes
stays there, as [Footprint](#footprint) lists: the module files, the undo journal in your per-user data
directory, and the temporary snapshots each move removes when it finishes.

It uses the network only when you run `Test-NetscootUpdate`, `Update-Netscoot` or the installer. They make
unauthenticated requests to `api.github.com` and `github.com` for the latest release and its source
archive, and send no credentials or data of yours. GitHub's privacy statement covers those requests.

The Claude Code plugin runs the same module on your machine. What you send to Claude while using it is
covered by Anthropic's privacy policy.

Contributing / building from source: see [CONTRIBUTING.md](CONTRIBUTING.md).

## Reference

Every command's syntax, parameters, output and examples are in the
[command reference](docs/reference.md#command-reference), and the objects the commands return are in
[output types](docs/reference.md#output-types). Both are generated from the cmdlets' help, which
`Get-Help <command> -Full` shows in a session.

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
