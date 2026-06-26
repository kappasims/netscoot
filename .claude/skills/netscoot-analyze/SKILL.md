---
name: netscoot-analyze
description: Use to analyze a repository's solution/project state and to verify that a refactor is complete. Read-only inventory, consistency, and reference detection across .NET, PowerShell, Unity, and native projects. Triggers on "what projects are in this solution," "list all projects," "are the sln and slnx in sync," "is the solution consistent," "do the solutions agree on membership," "find dangling references," "any orphaned projects," "broken solution refs," "what's in this solution," "any unreferenced projects," "find references to <path>," "where else does <X> appear," "what would break if I moved <X>," "did I miss any references after the rename," "is the rename/refactor complete," "check for stragglers," "any non-canonical references," "what engine moves <file>," "can netscoot handle this file," "does this env have what netscoot needs," "why does my .sln keep coming back," "will my .slnx consolidation stick," "is VS Code regenerating a .sln," "check the editor solution guards." For actually moving/restructuring, use restructure-dotnet / restructure-powershell / restructure-unity / restructure-native instead.
---

# Netscoot: analysis and post-refactor sanity (cross-engine, read-only)

Purpose (full overview: the [netscoot README](https://github.com/kappasims/netscoot)): structured
answers to "what's in this repository," "is this rename actually done," "where else does X
appear," "what would break if I moved Y" without ad-hoc Grep/Read over `.sln`/`.slnx`/`.csproj`.

Every cmdlet here is **read-only**: nothing is moved, no file is rewritten. The actual moves belong
to the project-type-specific skills (`restructure-dotnet`, `restructure-powershell`,
`restructure-unity`, `restructure-native`).

## Map a question to the right cmdlet

| Question | Cmdlet |
| --- | --- |
| What projects are in this solution? Any orphans? Solution folders or solution items? | `Get-NetscootSolutionInventory` |
| Are `.sln` and `.slnx` in sync? Do solutions agree on membership? | `Test-NetscootSolutionConsistency` |
| Any dangling solution entries or broken `<ProjectReference>`s? | `Repair-NetscootSolutionReferences` (no flags is report-only) |
| Where else does this path/file appear in build scripts, CI, hooks, container files? | `Find-NetscootPathReference -Path <old-id-or-path>` |
| Did I miss any references after the rename? Is the refactor complete? | `Find-NetscootPathReference -Path <old-id-or-path>` (see the canonical pattern below) |
| What engine would move this file? Can netscoot handle it? | `Resolve-MoveEngine -Path <file>` |
| Does this environment have what netscoot needs? | `Get-NetscootCapability` |
| Will my `.slnx` consolidation stay durable, or will VS Code re-create a `.sln`? | `Test-EditorSolutionGuard` |

Output is structured (`pscustomobject` with `PSTypeName='Netscoot.<Kind>'`), so the agent can
filter and assert on rows rather than parsing text. Default Format.ps1xml table views are tuned
for the common columns; the full record is always there for `Select-Object`.

## Canonical post-refactor sanity check

When a refactor, rename, or move appears done, run

```powershell
Find-NetscootPathReference -Path <old identifier or path>
```

over the OLD identifier (a moved file's old path, a renamed type, a removed namespace, an old DLL
name in build scripts). The output is structured (`File`, `Line`, `Confidence`, `Text`) and the
cmdlet emits the warning *"These are not auto-reconciled - review and fix them by hand."* That is
the agent-readable signal that references survive in places the move machinery does not touch:
build scripts, CI YAML, git hooks, container files, documentation snippets. Use it BEFORE declaring
a rename "complete." If it returns rows, fix them by hand and re-run; a zero-row result with no
warning is the all-clear.

This is the canonical "did I miss anything" pattern - do not substitute an ad-hoc `Grep`.
`Find-NetscootPathReference` already knows which file kinds are candidates, applies a confidence
rating, and excludes paths the move machinery already reconciled. By default it scans only the
non-canonical automation file class (build/CI/hooks/containers); add `-AllFiles` to search every
text file under the repository (caches/vendored dirs and binaries still excluded) for the thorough
"search literally everywhere" pass when the default returns nothing but you suspect a reference
survives.

## Use the installed module

`Import-Module Netscoot` if available. If it is not installed, point the user at the
[install steps](https://github.com/kappasims/netscoot) and let them run them; never auto-install.

## Cross-engine, not engine-specific

These cmdlets work across all four engine families. For the actual MOVES, route by project type:

- `restructure-dotnet` for `.csproj`/`.fsproj`/`.vbproj` and solutions.
- `restructure-powershell` for `.ps1` scripts and PowerShell modules.
- `restructure-unity` for Unity assets, asmdefs, and `.meta` pairs.
- `restructure-native` for `.vcxproj` (Windows-only).

The analyzers here intentionally do NOT decide between those routes; that is `Resolve-MoveEngine`'s
job (use it explicitly when the answer matters).
