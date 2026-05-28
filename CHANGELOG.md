# Changelog

All notable changes to netscoot are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `Invoke-Netscoot -WhatIf -Verbose` (and `Move-DotnetFile`/`Move-DotnetFolder`/`Move-PowerShell`
  routed the same way) now actually emit the planned reconciliation under `-Verbose` - the solutions
  to update, consumers to repoint, and references to rebase. In 2.3.0 the dispatch chain only
  forwarded `-WhatIf` and `-Confirm`, not `-Verbose`/`-Debug`, so the verbose plan emitted by the
  inner mover silently disappeared and only the engine-routing trace remained. Direct invocation
  (`Move-DotnetProject -WhatIf -Verbose ...`) was always fine.

### Changed

- Internal helpers module renamed from `Netscoot.Shared` to `NetscootShared` (no dot). The
  literal-dot wildcard `Get-Command -Module Netscoot.*` now returns exactly the 30 public cmdlets
  (the four `Netscoot.X` engines) and never the 54 internal helpers; previously it included them
  too because `Netscoot.Shared` matched the wildcard. Use `Get-Command -Module NetscootShared`
  to opt-in to the plumbing. Caveat: `Get-Command -Module Netscoot*` (no literal dot) still
  matches `NetscootShared` because `*` matches the missing dot - that's a wildcard quirk, not a
  bug, and the canonical query for the public surface is the literal-dot form.

## [2.3.0] - 2026-05-28

### Fixed

- `Test-SolutionConsistency` now reports a `.pssproj` (PowerShell project file) that diverges across
  solutions. Previously the comparison filter only matched `.csproj` / `.fsproj` / `.vbproj` / `.vcxproj`,
  so a `.pssproj` listed in one solution but not another silently read as "all solutions agree" even
  though `Get-SolutionInventory` clearly showed the divergence.
- The PowerShell Gallery listing now lists `Get-NetscootUpdatePolicy`, `Set-NetscootUpdatePolicy`,
  and `Repair-NetscootJournal` by name. These commands shipped in 2.2.0 and worked at runtime, but
  were absent from the umbrella manifest, so a Gallery search by cmdlet name didn't surface Netscoot.
- `Remove-Module Netscoot` now also unloads the nested engines (`Netscoot.Core`, `Netscoot.Unity`,
  `Netscoot.Native`, `Netscoot.Shared`). Previously they were left resident, since the umbrella
  loaded them globally, leaving the session in a half-removed state.

### Changed

- The move commands now narrate their full plan under `-Verbose`: the solutions they would edit, the
  consumer projects they would repoint, the references they would rebase, and (for native projects)
  the path settings they cannot reconcile. `Move-X -WhatIf -Verbose` now previews every reconciliation
  instead of summarizing as counts.

### Added

- New `netscoot-analyze` skill: cross-engine trigger surface for the analyzer cmdlets
  (`Get-SolutionInventory`, `Test-SolutionConsistency`, `Find-PathReference`,
  `Repair-SolutionReferences`, `Resolve-MoveEngine`, `Get-NetscootCapability`). AI agents now route
  questions like "is the rename done?" / "where else does this appear?" / "what would break if I
  moved X?" to Netscoot's structured output instead of ad-hoc text search.
- New `netscoot-manage` skill: trigger surface for the admin / config cmdlets that change
  netscoot's own behavior (`Get/Set-NetscootUpdatePolicy`, `Set-NetscootJournal`,
  `Clear-NetscootJournal`, `Unregister-NetscootGitAlias`). Distinct use case from moves;
  agents now route "stop netscoot auto-updating," "wipe my undo history," "remove the git verb"
  to this skill instead of the move-focused `restructure-*` skills.
- `restructure-dotnet` skill body now documents the full .NET-side move surface (the dispatcher
  movers `Invoke-Netscoot`, `Move-DotnetFile`, `Move-DotnetFolder`, the multi-project
  `Move-DotnetProjectTree`, the file movers `Move-Solution` and `Move-MSBuildImport`). Previously
  only `Move-DotnetProject` was named, so an agent that activated the skill could miss the
  right cmdlet for the move at hand.
- README's Inspecting section now documents `Find-PathReference -Path <old-id>` as the canonical
  post-refactor sanity check, with the warning string Netscoot emits as the agent-readable
  all-clear signal.
- New CI gate `tests/SkillCoverage.Tests.ps1`: asserts every cmdlet in the umbrella manifest's
  `FunctionsToExport` appears in at least one `.claude/skills/*/SKILL.md`. Catches the same
  declared-vs-delivered drift on the agent surface that `UmbrellaSurface.Tests.ps1` catches on
  the Gallery surface. Closes a real gap: at audit time 10 of the 30 exported cmdlets had no
  skill mention, so AI agents using netscoot in this repository couldn't discover them through
  the skill system.

## [2.2.0] - 2026-05-28

### Changed

- Read and analysis commands (project/solution moves, `Get-SolutionInventory`, `Repair-SolutionReferences`,
  and the consistency/sync checks) now parse the repository once per invocation instead of re-scanning it
  for each project. Large repositories see multi-times-faster moves and inventories, with the gap widening
  as the project count grows.
- Commands that take a path or repository root from the pipeline now accept a path string or a file/directory
  item (`Get-Item` / `Get-ChildItem`); piping any other kind of object reports a clear input error instead
  of binding an unexpected property. This makes one consistent pipeline contract across the module.
- Move results now have a default table view (engine, performed, source, destination), so a pipeline of
  moves renders as a table like the other result types instead of a long list.

### Fixed

- Move result objects now expose their properties in a stable, documented order; the engine-specific
  fields were previously emitted in an unpredictable order.

## [2.1.1] - 2026-05-28

### Fixed

- `Move-DotnetProject` aborted under Windows PowerShell 5.1 (StrictMode) when a repository project
  had a single non-literal or conditional `ProjectReference`. PowerShell 7 was unaffected.

## [2.1.0] - 2026-05-28

### Added

- `Repair-NetscootJournal`: detect and recover moves interrupted mid-operation. Read-only report by
  default; `-Rollback` reverses a half-applied move, `-Discard` forgets it, with snapshot and orphan
  cleanup.
- Write-ahead (WAL) move journal: each move and its journal write are a single atomic step, so an
  interrupted move is detected on the next run rather than leaving silent inconsistency.
- PowerShell Gallery discovery tags and CI/license badges.

### Changed

- Journal reads are linear with size-capped compaction (previously slower as the journal grew).
- Hot-path regexes are precompiled.

### Fixed

- Hardened update-policy enforcement for administrator (machine-scope) settings.
- Windows PowerShell 5.1 compatibility fixes.

## [2.0.0] - 2026-05-27

Rebranded from DotnetMove to netscoot; first release under the new name. Highlights: a single
PowerShell Gallery package (umbrella + engines), the Enabled/Manual/Disabled update policy with
`Get-NetscootUpdatePolicy`/`Set-NetscootUpdatePolicy` and `Test-NetscootUpdate -Auto`, the per-user
move journal, default table views, and the public `RepoRoot` parameter renamed to `RepositoryRoot`.
See the release notes for the full pull-request list.

DotnetMove 1.x history predates the rename; see the legacy DotnetMove releases.

[Unreleased]: https://github.com/kappasims/netscoot/compare/v2.3.0...HEAD
[2.3.0]: https://github.com/kappasims/netscoot/compare/v2.2.0...v2.3.0
[2.2.0]: https://github.com/kappasims/netscoot/compare/v2.1.1...v2.2.0
[2.1.1]: https://github.com/kappasims/netscoot/compare/v2.1.0...v2.1.1
[2.1.0]: https://github.com/kappasims/netscoot/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/kappasims/netscoot/releases/tag/v2.0.0
