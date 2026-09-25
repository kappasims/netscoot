---
name: restructure-dotnet
description: Use when moving, relocating, or restructuring managed .NET projects, or repairing their solutions: moving a .csproj/.fsproj/.vbproj folder, reorganizing solution layout, extracting a project into its own assembly, syncing solution membership, or fixing dangling solution entries and project references. Triggers on "move this project," "restructure," "reorganize the solution," "extract into its own folder/assembly," "sync the solutions," "fix dangling solution references," "prune missing projects." Do not hand-edit .sln/.slnx/.csproj. For PowerShell modules/scripts use restructure-powershell, for Unity assets use restructure-unity, and for native C++/.vcxproj use restructure-native.
---

# Restructuring managed .NET repositories (cross-platform)

Purpose (full overview: the [netscoot README](https://github.com/kappasims/netscoot)): a move that
fixes what it would otherwise break. Where dragging a project in Visual Studio reconciles the
`.sln`/`.slnx` and the `<ProjectReference>`s, netscoot does the same from the command line. It uses
first-party tooling where one exists (`dotnet sln`, `dotnet reference`, `git mv`) and exact path
edits where none does (a solution's stored paths, `<Import>` paths). You never hand-edit `.sln`,
`.slnx`, or `.csproj`/`.fsproj`/`.vbproj`, because hand-typed paths and GUIDs drift.

Cross-platform: PowerShell 7 on Windows/Linux/macOS, or Windows PowerShell 5.1. It needs the dotnet
CLI, and git is optional (without it, a move falls back to a plain `Move-Item`). Use the installed
module (`Import-Module Netscoot`). Never auto-install: if it or a prerequisite (git, dotnet) is
missing, give the user the install command and let them run it. For native C++ (`.vcxproj`,
Windows-only) see `restructure-native` (`Move-DotnetProject` refuses `.vcxproj`). For PowerShell
modules or scripts see `restructure-powershell`, and for Unity assets see `restructure-unity`.

## Running a real move from an agent

Every mover, `Sync-NetscootSolution` and `Repair-NetscootSolutionReferences -Fix/-Prune` asks for confirmation,
and an agent's shell is non-interactive, so a real run without `-Confirm:$false` fails. Preview with
`-WhatIf`, get the user's go-ahead, then run the same command with `-Confirm:$false`.

## Analyze/audit first (read-only)

To understand a repository before touching it, use these. Do not parse solution/project files by
hand.

- `Test-NetscootSolutionConsistency` - projects whose membership diverges across solutions that share
  projects. `-Debug` shows the full solution/project matrix under `pwsh`. Windows PowerShell 5.1
  prompts on every debug line, so set `$DebugPreference = 'Continue'` there instead.
- `Get-NetscootSolutionInventory` - the full contents of every solution: projects of any type (including
  non-CLI ones like `.pssproj`), solution folders, and solution items, plus managed and native
  projects on disk that no solution references. Goes beyond `dotnet sln list`, which only lists
  CLI-buildable projects.
- `Repair-NetscootSolutionReferences` (no flags) - report dangling solution entries / `<ProjectReference>`s.
- `Find-NetscootPathReference` - build/CI/hook scripts that hardcode a path no move reconciles.
- `Resolve-MoveEngine` - which engine a given path classifies to.
- `Get-NetscootCapability` - whether git and dotnet are present, plus the platform.
- `Test-EditorSolutionGuard` - after consolidating to a single `.slnx`, checks that VS Code's C#
  Dev Kit will not silently re-mint a legacy `.sln` next to it (inspects `.vscode/settings.json`
  and `.gitignore`, and `-Strict` makes it CI-failing). Run it whenever you migrate `.sln` -> `.slnx`.

`Repair-NetscootSolutionReferences` and `Sync-NetscootSolution` need the dotnet CLI. The others only read files.

To resolve a divergence that `Test-NetscootSolutionConsistency` reports, run `Sync-NetscootSolution`. It adds each
managed project to the solutions missing it, within each group of solutions that share projects
(preview with `-WhatIf`). You can also add it by hand with `dotnet sln <solution> add <project>`.
These are the right tools when the task is "audit" or "sync the solutions," not only when moving.

## Moving a .NET project

```powershell
Import-Module Netscoot
# Always dry-run first:
Move-DotnetProject -Project ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon -WhatIf
# Then, after the user agrees:
Move-DotnetProject -Project ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon -Confirm:$false
```

This reconciles: solution membership (`dotnet sln add/remove`, works on `.sln` and `.slnx`),
consumer `<ProjectReference>`s, and the project's own references, then runs `dotnet build`
(skip it with `-NoBuild`). If reconciliation fails, the move rolls back. A failed build only warns.

`-Destination` follows `git mv` rules: an **existing** directory means move into it keeping the
folder's name (`-Destination ./libs` puts the project at `./libs/Tarragon`). Otherwise it is the
project's new folder path, a rename (`-Destination ./libs/Tarragon`).

## Other move operations (folders, solutions, imports)

`Move-DotnetProject` handles a single project. The rest of the .NET move surface:

- `Move-DotnetProjectTree` - move a FOLDER of one or more `.csproj` (and their subfolders) as a
  group. Fixes external `<ProjectReference>`s into the moved set and leaves internal sibling refs
  alone. Use this when reorganizing layout, not a single project. A `.vcxproj` inside the folder
  moves too, but its references are not updated (the move warns).
- `Move-Solution` - move the `.sln` / `.slnx` file itself and rebase every project and solution
  item path it stores. The dotnet CLI has no "rebase", so this rewrites those paths in place.
- `Move-MSBuildImport` - move a shared `.props` / `.targets` and fix every `<Import>` that points
  at it (and the file's own outgoing imports). It treats `Directory.Build.props` /
  `Directory.Packages.props` as by-location imports: it warns about inheritance changes and does
  not try to "fix" them.
- `Move-DotnetFile` / `Move-DotnetFolder` - dispatchers that route by extension/content. Use these
  when you have a `.NET` file or folder and want netscoot to pick the right specialist
  (`Move-DotnetProject` for `.csproj`, `Move-MSBuildImport` for `.props`, etc.). Same -WhatIf and
  result-object shape as the specialists.
- `Invoke-Netscoot` - the top-level cross-engine dispatcher. Routes a file/folder to the
  right engine (.NET / PowerShell / Unity / native) by extension and context. Use it when the
  caller doesn't know or care which engine handles the input. Alias: `Scoot`.

Every mover supports `-WhatIf` (preview) and `-Verbose` (full plan: solutions edited, references
repointed). Run `Move-X -WhatIf -Verbose` before a real move on anything non-trivial.

## Inspecting and repairing (no move)

These work on an existing repository without moving anything. Inspect first, then repair if needed.

```powershell
Get-NetscootSolutionInventory     -RepositoryRoot .          # full contents of every solution + projects in none
Test-NetscootSolutionConsistency  -RepositoryRoot .          # projects whose solution membership diverges
Sync-NetscootSolution             -RepositoryRoot . -WhatIf  # resolve divergence: add each project where it is missing
Repair-NetscootSolutionReferences -RepositoryRoot .          # report dangling entries (relocatable / missing / ambiguous)
Repair-NetscootSolutionReferences -RepositoryRoot . -Fix     # re-point dangling entries at the project's new location
Repair-NetscootSolutionReferences -RepositoryRoot . -Prune   # remove entries whose project is gone for good
Find-NetscootPathReference -Path ./src/Tarragon/Tarragon.csproj  # build/CI/hook scripts that hardcode the path (report-only)
```

`-Fix` relocates and never deletes. Removal is only `-Prune`, and only for entries whose project
cannot be found anywhere. A relocated `.vcxproj` is reported for the user to re-point in Visual
Studio. `Sync-NetscootSolution` only adds membership and never removes. All honor `-WhatIf`, and the
changing forms need `-Confirm:$false` when run from an agent.

## If you must do it without the module

Use the raw CLI, never a text editor:

- `dotnet sln <sln> remove <oldProj>` → move dir → `dotnet sln <sln> add <newProj>`
- `dotnet remove <consumer> reference <proj>` → `dotnet add <consumer> reference <proj>`
- `dotnet sln migrate` converts `.sln` → `.slnx`

## Known limits (warn the user, do not silently "fix")

- `Directory.Build.props/.targets` and `Directory.Packages.props` (Central Package Management)
  inheritance changes when folder depth changes. A move detects and warns, and cannot fix it.
- Hardcoded project paths in CI YAML / scripts.

## Undoing a move

Every move is journaled (on by default) to a per-user data directory outside the working tree, so
git never tracks it and you can reverse a move later, even in a new session, with `Undo-Netscoot`.
It replays the inverse (source and destination swapped), re-reconciling from the current state.

```powershell
Undo-Netscoot -List     # what can be undone
Undo-Netscoot -WhatIf   # preview reversing the most recent move
Undo-Netscoot           # reverse the most recent move (call again to walk back)
```

`Repair-NetscootJournal` reports moves a crash interrupted (read-only by default). `-Rollback`
restores such a move's files and moves it back, and `-Discard` forgets it and keeps the working
tree. Both prompt, so pass `-Force` from an agent. Opt out of journaling per repository with
`Set-NetscootJournal -Enabled $false` (`-Global` for all). See the
[README](https://github.com/kappasims/netscoot).

## The `git netscoot` verb (optional, ask first)

The same routing is also an opt-in git verb: `git netscoot <src> <dst> [--whatif]`. It needs a
one-time alias that `Register-NetscootGitAlias` writes to git config (this repository by default,
`-Scope Global` for the user). The alias runs `pwsh`, so it needs PowerShell 7 on PATH. If you
suggest it or want to use it, prompt the user first and let them register it. Do not edit their git
config for them. Never auto-install anything (git, the dotnet SDK, or these modules). If a
prerequisite is missing, tell the user the install command and let them run it.

## Staying current

netscoot does not auto-update. Check with `Test-NetscootUpdate`, which compares the installed module
to the latest GitHub release on the update channel (stable unless
`Set-NetscootUpdateChannel -Channel Beta` opted into betas). Update a Gallery install with `Update-Module Netscoot`, an installer
install with `Update-Netscoot`, and a dev clone with `git pull` then `./build.ps1 -Task Install`. A
SessionStart hook running `Test-NetscootUpdate -Auto` can remind automatically. It checks only when
the update policy is Enabled, and never updates. Ask the user before adding it, since it edits their
settings.json.
