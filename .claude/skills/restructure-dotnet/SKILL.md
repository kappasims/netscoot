---
name: restructure-dotnet
description: Use when moving, relocating, or restructuring managed .NET projects: moving a .csproj/.fsproj/.vbproj folder, reorganizing solution layout, or extracting a project into its own assembly. Triggers on "move this project", "restructure", "reorganize the solution", "extract into its own folder/assembly". Do not hand-edit .sln/.slnx/.csproj. For PowerShell modules/scripts use restructure-powershell; for native C++/.vcxproj use restructure-native.
---

# Restructuring managed .NET repositories (cross-platform)

Purpose (full overview: the [netscoot README](https://github.com/kappasims/netscoot)): a move
that fixes what it would otherwise break. Dragging a project in Visual Studio reconciles the
`.sln`/`.slnx`, the `<ProjectReference>`s that point at it, and the GUID wiring; netscoot does the
same from the command line, everywhere Visual Studio is not, delegating every path/GUID change to
first-party tooling rather than hand-editing files.

These cmdlets are **cross-platform** (PowerShell 7 on Windows/Linux/macOS); they rely only
on the dotnet CLI and git. For native C++ (`.vcxproj`), which is Windows-only, see the
`restructure-native` skill (`Move-DotnetProject` deliberately refuses `.vcxproj`). For moving
PowerShell modules/scripts, see the `restructure-powershell` skill.

**Rule: never hand-edit `.sln`, `.slnx`, or `.csproj`/`.fsproj`/`.vbproj` to move things.**
Relative paths and solution GUIDs drift out of sync when typed by hand. Delegate every
path/GUID change to first-party tooling.

Use the installed `netscoot` module (`Import-Module Netscoot`). If it is not installed, point
the user to the project's install steps and let them run them; never auto-install.

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
- `Get-ScootCapability` - whether git and dotnet are present, plus the platform.

To resolve a divergence that `Test-SolutionConsistency` reports, run `Sync-Solution` (it adds each
project to the solutions missing it; preview with `-WhatIf`), or add it by hand with
`dotnet sln <solution> add <project>`. These are the right tools when the task is "audit" or
"sync the solutions", not only when moving.

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
project's new folder path, a rename (`-Destination ./libs/Tarragon`). It errors if the resulting
folder already exists, so it never silently overwrites or double-nests.

## Inspecting and repairing (no move)

These work on an existing repository without moving anything. Inspect first, then repair if needed.

```powershell
Get-SolutionInventory     -RepoRoot .          # full contents of every solution + projects in none
Test-SolutionConsistency  -RepoRoot .          # projects whose solution membership diverges
Sync-Solution             -RepoRoot . -WhatIf  # resolve divergence: add each project where it is missing
Repair-SolutionReferences -RepoRoot .          # report dangling entries (relocatable / missing / ambiguous)
Repair-SolutionReferences -RepoRoot . -Fix     # re-point dangling entries at the project's new location
Repair-SolutionReferences -RepoRoot . -Prune   # remove entries whose project is gone for good
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

Every move is journaled to a per-user data directory (LocalAppData on Windows, ~/Library/Application Support on macOS, ~/.local/share on Linux), so you can reverse it later -
even in a new session - with `Undo-Scoot`. It replays the inverse (the same move with source
and destination swapped), re-reconciling from the current state.

```powershell
Undo-Scoot -List     # what can be undone
Undo-Scoot -WhatIf   # preview reversing the most recent move
Undo-Scoot           # reverse the most recent move (call again to walk back)
```

Journaling is on by default and stays out of the working tree (it lives inside `.git/`, so git never tracks it).
Opt out per repository with `Set-ScootJournal -Enabled $false` (or `-Global` for all repositories). See the [README](https://github.com/kappasims/netscoot).

## The `git netscoot` verb (optional; ask first)

The same routing is also an opt-in git verb: `git netscoot <src> <dst> [--whatif]`. It needs a
one-time alias that `Register-ScootGitAlias` writes to the user's git config. If you suggest
it or want to use it, prompt the user first and let them register it; do not edit their git
config for them. Never auto-install anything (git, the dotnet SDK, or these modules): if a
prerequisite is missing, tell the user the install command and let them run it.

## Staying current

netscoot does not auto-update; cutting a release changes nothing on an installed machine until
you update. Check with `Test-ScootUpdate` (it compares the installed module to the latest
GitHub release). Update in place with `Update-Scoot` (no git), or re-run the installer:
`irm https://raw.githubusercontent.com/kappasims/netscoot/master/install.ps1 | iex`. From a dev
clone instead, `git pull` then `./build.ps1 -Task Install`. For automatic reminders, consider a
Claude Code SessionStart hook that runs `Test-ScootUpdate -EnableAutoUpdate` (gated: it checks only when `$env:NETSCOOT_AUTOUPDATE` is truthy, and never updates); ask the user before adding it,
since it edits their settings.json.
