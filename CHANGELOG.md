# Changelog

All notable changes to netscoot are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **BREAKING (3.0):** five public cmdlets gained the `Netscoot` brand noun so their names no longer
  collide with generic verbs in a shared session: `Get-SolutionInventory` ->
  `Get-NetscootSolutionInventory`, `Sync-Solution` -> `Sync-NetscootSolution`, `Find-PathReference`
  -> `Find-NetscootPathReference`, `Test-SolutionConsistency` -> `Test-NetscootSolutionConsistency`,
  `Repair-SolutionReferences` -> `Repair-NetscootSolutionReferences`. The old names continue to work
  as deprecated aliases that emit a warning on use and will be removed in a later release; update
  scripts to the new names.

## [2.6.2] - 2026-06-26

### Changed

- Maintenance release. Internal build and CI tooling only - no change to the shipped module or any
  cmdlet behavior. The released package is functionally identical to 2.6.1.

## [2.6.1] - 2026-06-26

### Fixed

- `Test-NetscootUpdate`, `Update-Netscoot`, and `install.ps1` now reach the correct GitHub release
  endpoint. They queried `/repositories/<owner>/<name>`, which is the numeric-repo-id path and 404s
  for an `owner/name` string, so every update check failed with a generic "could not get the latest
  release" and the installer's latest-version path could not resolve a release. Now uses
  `/repos/<owner>/<name>`. (Note: the broken check shipped in earlier versions, so a self-update
  from one of those still needs a one-time manual `Install-Module Netscoot` to land this fix.)
- The umbrella `Netscoot` module now owns its cmdlets. It loaded each engine globally, so the 31
  public cmdlets were owned by the engine modules: `Get-Command -Module Netscoot` returned nothing
  and `(Get-Module Netscoot).ExportedCommands` was empty (and `Test-ModuleManifest` warned that the
  manifest exported functions the root module did not define) - even though every cmdlet resolved
  and ran. The engines are now imported nested and their functions re-exported from the umbrella,
  so `Get-Command -Module Netscoot` lists all 31, `ExportedCommands` is populated, and
  `Get-Command <cmdlet>` reports `Netscoot` as the source. The Windows-only native engine stays
  conditional and runtime behavior is unchanged.

## [2.6.0] - 2026-06-26

### Added

- `Test-EditorSolutionGuard`: a read-only check that reports whether a repository's VS Code editor
  configuration will keep a `.slnx` consolidation durable - that is, whether the C# Dev Kit will
  silently regenerate a legacy `.sln` next to it (the source of a whole class of stale-duplicate
  solution drift). It inspects `.vscode/settings.json`
  (`dotnet.automaticallyCreateSolutionInWorkspace`, `dotnet.defaultSolution`) and `.gitignore`,
  warning when a guard is missing or misconfigured. `-Strict` escalates findings to errors for CI.
- `Find-PathReference -AllFiles`: search every text file under the repository instead of only the
  build/CI/hook/container file class. Caches/vendored dirs and binary files stay excluded. Use it
  for the thorough "look everywhere" sweep when a hardcoded path may live in an ordinary source
  file the default (focused) scan deliberately skips. The default behavior is unchanged.

### Fixed

- `Test-SolutionConsistency` no longer flags every project as "diverging" in a repository that holds
  multiple intentionally-separate solutions (a standalone client, a submodule's own solution). Only
  solutions that share at least one project are compared with each other; a `.sln`/`.slnx` mirror
  pair that genuinely drifts is still reported.
- `Find-PathReference` no longer throws when `-RepositoryRoot` is omitted and `-Path` points at an
  already-moved (now nonexistent) path - the canonical "sweep the old identifier after a rename"
  use case. The repository root is derived from the current directory, not from the search path.

## [2.5.0] - 2026-05-29

Internal test infrastructure release. No user-visible API or behavior changes from 2.4.0; the
regression baseline this introduces will make the upcoming v3 journal-layout migration safer.

### Added

- Three-tier regression test suite locking down the v2 move-journal contract:
  - `tests/JournalFormat.Tests.ps1` asserts the on-disk per-entry schema (11 fields,
    `id` is 8 lowercase hex, status is one of `pending`/`committed`/`rolledback`, paths
    are absolute, etc.).
  - Extensions to `tests/Journal.Tests.ps1` lock the WAL append-order ("successful move
    writes [pending, committed]"), the post-crash Repair-Rollback entry-removal contract,
    the closed status taxonomy, and the compaction-never-trims-pending safety invariant.
  - `tests/JournalSnapshot.Tests.ps1` locks the snapshot directory lifecycle - by path
    *semantics* (`$entry.snapshot` is the canonical reference), not by path *shape*,
    so a future relocation of snapshots into the journal partition dir still passes
    every assertion.

### Changed

- `tests/WorktreeExclusion.Tests.ps1` fixture now uses `Copy-FixtureTemplate`, so the
  4 dotnet sln/add calls in its setup run once per session instead of per `It` block.
  Trims a few seconds off whichever CI shard the file lands in.

## [2.4.0] - 2026-05-29

### Changed

- `Repair-SolutionReferences -Fix` / `-Prune` and `Sync-Solution` now prompt by default
  (`ConfirmImpact = 'High'`), matching `Move-Solution` and `Move-MSBuildImport`, which mutate
  the same kind of file. Pass `-Confirm:$false` to suppress; the report-only path (no
  `-Fix` / `-Prune`) is unaffected. Callers that relied on the previous no-prompt default
  need to start passing `-Confirm:$false` explicitly.
- `Undo-Netscoot -Id` and `Repair-NetscootJournal -Id` now validate the id format at
  parameter bind (`^[a-zA-Z0-9]{8}$`). A typo (wrong length, stray whitespace, punctuation)
  now fails at the call site instead of at the journal-lookup error.

### Added

- `Undo-Netscoot` and `Unregister-NetscootGitAlias` now declare their output types via
  `[OutputType()]`. Undo-Netscoot returns the nine move-result / journal-entry types it
  produces depending on parameters; Unregister-NetscootGitAlias returns nothing (`[void]`).
  The generated Command reference now renders an Output section for both, and `Get-Command`
  / tab-completion see the declared types.

### Fixed

- The Command reference's "These share a common shape" line on `Undo-Netscoot` is no
  longer misleading. The docs generator's field-name comparison was case-insensitive,
  which collapsed `Netscoot.JournalEntry.engine` with `Netscoot.MoveResult.Engine` and
  claimed both as shared. The line now correctly reports the types as heterogeneous when
  field casing differs, while move-result-only commands (`Invoke-Netscoot`,
  `Move-DotnetFile`) continue to show the correct common shape.

## [2.3.2] - 2026-05-29

### Added

- The generated Command reference now linkifies cmdlet mentions inside cmdlet help prose
  (e.g. a reference to `Get-NetscootUpdatePolicy` from another cmdlet's help renders as a
  link to that cmdlet's section). `Get-Help` is unchanged; this affects the README's
  Command reference only.
- Comment-based help `.LINK` cross-references for the natural cmdlet pairs and the
  analysis clusters (update policy, journal, solution analysis). `Get-Help` shows them
  under RELATED LINKS, and the README renders a compact "Related" line per cmdlet.

### Changed

- `Move-PowerShellModule` reports "missing .psd1 manifest" and "destination already exists"
  as structured non-terminating errors (FQEIDs `ManifestNotFound` and `DestinationExists`),
  matching every other mover in the family. Previously these were bare terminating throws;
  callers using `-ErrorAction Stop` see the same outcome.
- The dispatch-chain trace under `-Verbose` now reads uniformly across all layers - the
  outer dispatcher names the target cmdlet the same way the inner dispatchers do, instead
  of emitting a different shape at the top.

### Fixed

- Help-prose consistency pass across the 30 public cmdlets: tightened `.SYNOPSIS` first
  sentences (these drive the Command reference index blurbs), uniform `.PARAMETER` phrasing
  for pipeline input and `git mv`-rule destinations, and small grammar/casing fixes.

## [2.3.1] - 2026-05-29

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

[Unreleased]: https://github.com/kappasims/netscoot/compare/v2.6.1...HEAD
[2.6.1]: https://github.com/kappasims/netscoot/compare/v2.6.0...v2.6.1
[2.6.0]: https://github.com/kappasims/netscoot/compare/v2.5.0...v2.6.0
[2.5.0]: https://github.com/kappasims/netscoot/compare/v2.4.0...v2.5.0
[2.4.0]: https://github.com/kappasims/netscoot/compare/v2.3.2...v2.4.0
[2.3.2]: https://github.com/kappasims/netscoot/compare/v2.3.1...v2.3.2
[2.3.1]: https://github.com/kappasims/netscoot/compare/v2.3.0...v2.3.1
[2.3.0]: https://github.com/kappasims/netscoot/compare/v2.2.0...v2.3.0
[2.2.0]: https://github.com/kappasims/netscoot/compare/v2.1.1...v2.2.0
[2.1.1]: https://github.com/kappasims/netscoot/compare/v2.1.0...v2.1.1
[2.1.0]: https://github.com/kappasims/netscoot/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/kappasims/netscoot/releases/tag/v2.0.0
