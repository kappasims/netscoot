---
name: restructure-dotnet
description: Use when moving, relocating, or restructuring managed .NET projects: moving a .csproj/.fsproj/.vbproj folder, reorganizing solution layout, or extracting a project into its own assembly. Triggers on "move this project," "restructure," "reorganize the solution," "extract into its own folder/assembly." Do not hand-edit .sln/.slnx/.csproj. For PowerShell modules/scripts use restructure-powershell; for native C++/.vcxproj use restructure-native.
---

# Restructuring managed .NET repositories (cross-platform)

Purpose (full overview: the [netscoot README](https://github.com/kappasims/netscoot)): a move that
fixes what it would otherwise break. Where dragging a project in Visual Studio reconciles the
`.sln`/`.slnx`, the `<ProjectReference>`s, and the GUID wiring, netscoot does the same from the
command line - delegating every path/GUID change to first-party tooling (`dotnet sln`,
`dotnet reference`, `git mv`), never hand-editing `.sln`, `.slnx`, or `.csproj`/`.fsproj`/`.vbproj`
(hand-typed paths and GUIDs drift).

Cross-platform: PowerShell 7 on Windows/Linux/macOS, needing only the dotnet CLI and git. Use the
installed module (`Import-Module Netscoot`); never auto-install - if it or a prerequisite (git,
dotnet) is missing, give the user the install command and let them run it. For native C++
(`.vcxproj`, Windows-only) see `restructure-native` (`Move-DotnetProject` refuses `.vcxproj`); for
PowerShell modules or scripts see `restructure-powershell`.

## Analyze/audit first (read-only)

To understand a repository before touching it, use these; do not parse solution/project files by hand:

- `Test-SolutionConsistency` - projects whose membership diverges across solutions (`-Debug` for
  the full solution/project matrix).
- `Get-SolutionInventory` - the full contents of every solution: projects of any type (including
  non-CLI ones like `.pssproj`), solution folders, and solution items, plus projects on disk that
  no solution references. Goes beyond `dotnet sln list`, which only lists CLI-buildable projects.
- `Repair-SolutionReferences` (no flags) - report dangling solution entries / `<ProjectReference>`s.
- `Find-PathReference` - build/CI/hook scripts that hardcode a path no move reconciles.
- `Resolve-MoveEngine` - which engine a given path classifies to.
- `Get-NetscootCapability` - whether git and dotnet are present, plus the platform.
- `Test-EditorSolutionGuard` - after consolidating to a single `.slnx`, checks that VS Code's C#
  Dev Kit will not silently re-mint a legacy `.sln` next to it (inspects `.vscode/settings.json`
  and `.gitignore`; `-Strict` makes it CI-failing). Run it whenever you migrate `.sln` -> `.slnx`.

To resolve a divergence that `Test-SolutionConsistency` reports, run `Sync-Solution` (it adds each
project to the solutions missing it; preview with `-WhatIf`), or add it by hand with
`dotnet sln <solution> add <project>`. These are the right tools when the task is "audit" or
"sync the solutions," not only when moving.

## Moving a .NET project

```powershell
Import-Module Netscoot
# Always dry-run first:
Move-DotnetProject -Project ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon -WhatIf
# Then for real:
Move-DotnetProject -Project ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon
```

This reconciles: solution membership (`dotnet sln add/remove`, works on `.sln` and `.slnx`),
consumer `<ProjectReference>`s, and the project's own references, then runs `dotnet build`
(skip it with `-NoBuild`).

`-Destination` follows `git mv` rules: an **existing** directory means move into it keeping the
folder's name (`-Destination ./libs` puts the project at `./libs/Tarragon`); otherwise it is the
project's new folder path, a rename (`-Destination ./libs/Tarragon`).

## Other move operations (folders, solutions, imports)

`Move-DotnetProject` handles a single project; the rest of the .NET move surface:

- `Move-DotnetProjectTree` - move a FOLDER of one or more `.csproj` (and their subfolders) as a
  group. Fixes external `<ProjectReference>`s into the moved set; leaves internal sibling refs
  alone. Use this when reorganizing layout, not a single project.
- `Move-Solution` - move the `.sln` / `.slnx` file itself and rebase the relative project paths
  it stores. The dotnet CLI has no native "rebase" so this rewrites those paths in place.
- `Move-MSBuildImport` - move a shared `.props` / `.targets` and fix every `<Import>` that points
  at it (and the file's own outgoing imports). Treats `Directory.Build.props` / `Directory.Packages.props`
  as by-location imports: warns about inheritance changes, doesn't try to "fix" them.
- `Move-DotnetFile` / `Move-DotnetFolder` - dispatchers that route by extension/content. Use these
  when you have a `.NET` file or folder and want netscoot to pick the right specialist
  (`Move-DotnetProject` for `.csproj`, `Move-MSBuildImport` for `.props`, etc.). Same -WhatIf and
  result-object shape as the specialists.
- `Invoke-Netscoot` - the top-level cross-engine dispatcher. Routes a file/folder to the
  right engine (.NET / PowerShell / Unity / native) by extension and context. Use it when the
  caller doesn't know or care which engine handles the input. Alias: `scoot`.

Every mover supports `-WhatIf` (preview) and `-Verbose` (full plan: solutions edited, references
repointed, GUIDs touched). Run `Move-X -WhatIf -Verbose` before a real move on anything
non-trivial.

## Inspecting and repairing (no move)

These work on an existing repository without moving anything. Inspect first, then repair if needed.

```powershell
Get-SolutionInventory     -RepositoryRoot .          # full contents of every solution + projects in none
Test-SolutionConsistency  -RepositoryRoot .          # projects whose solution membership diverges
Sync-Solution             -RepositoryRoot . -WhatIf  # resolve divergence: add each project where it is missing
Repair-SolutionReferences -RepositoryRoot .          # report dangling entries (relocatable / missing / ambiguous)
Repair-SolutionReferences -RepositoryRoot . -Fix     # re-point dangling entries at the project's new location
Repair-SolutionReferences -RepositoryRoot . -Prune   # remove entries whose project is gone for good
Find-PathReference -Path ./src/Tarragon/Tarragon.csproj  # build/CI/hook scripts that hardcode the path (report-only)
```

`-Fix` relocates; it does not delete. Removal is only `-Prune`, and only for entries whose
project cannot be found anywhere. `Sync-Solution` only adds membership, never removes. All honor
`-WhatIf`.

## If you must do it without the module

Use the raw CLI, never a text editor:

- `dotnet sln <sln> remove <oldProj>` → move dir → `dotnet sln <sln> add <newProj>`
- `dotnet remove <consumer> reference <proj>` → `dotnet add <consumer> reference <proj>`
- `dotnet sln migrate` converts `.sln` → `.slnx`

## Known limits (warn the user; do not silently "fix")

- `Directory.Build.props/.targets` and `Directory.Packages.props` (Central Package Management)
  inheritance changes when folder depth changes (a move detects and warns; it cannot fix it).
- Hardcoded project paths in CI YAML / scripts.

## Undoing a move

Every move is journaled (on by default) to a per-user data directory outside the working tree
(LocalAppData on Windows, ~/Library/Application Support on macOS, ~/.local/share on Linux), so git
never tracks it and you can reverse a move later - even in a new session - with `Undo-Netscoot`. It
replays the inverse (source and destination swapped), re-reconciling from the current state.

```powershell
Undo-Netscoot -List     # what can be undone
Undo-Netscoot -WhatIf   # preview reversing the most recent move
Undo-Netscoot           # reverse the most recent move (call again to walk back)
```

A move interrupted by a crash is recoverable with `Repair-NetscootJournal`. Opt out per repository
with `Set-NetscootJournal -Enabled $false` (`-Global` for all). See the
[README](https://github.com/kappasims/netscoot).

## The `git netscoot` verb (optional; ask first)

The same routing is also an opt-in git verb: `git netscoot <src> <dst> [--whatif]`. It needs a
one-time alias that `Register-NetscootGitAlias` writes to the user's git config. If you suggest
it or want to use it, prompt the user first and let them register it; do not edit their git
config for them. Never auto-install anything (git, the dotnet SDK, or these modules): if a
prerequisite is missing, tell the user the install command and let them run it.

## Staying current

netscoot does not auto-update. Check with `Test-NetscootUpdate` (compares the installed module to
the latest GitHub release); update in place with `Update-Netscoot`, or from a dev clone with
`git pull` then `./build.ps1 -Task Install`. (Updating from a release before 2.6.1 needs a one-time
manual `Update-Module Netscoot` or installer re-run - those shipped a broken update endpoint; the
in-box updater works from 2.6.1 on.) A SessionStart hook running `Test-NetscootUpdate -Auto` can
remind automatically (gated to the update policy, never updates); ask the user before adding it,
since it edits their settings.json.
