# Changelog

All notable changes to netscoot are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Read and analysis commands (project/solution moves, `Get-SolutionInventory`, `Repair-SolutionReferences`,
  and the consistency/sync checks) now parse the repository once per invocation instead of re-scanning it
  for each project. Large repositories see multi-times-faster moves and inventories, with the gap widening
  as the project count grows.
- Commands that take a path or repository root from the pipeline now accept a path string or a file/directory
  item (`Get-Item` / `Get-ChildItem`); piping any other kind of object reports a clear input error instead
  of binding an unexpected property. This makes one consistent pipeline contract across the module.

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

[Unreleased]: https://github.com/kappasims/netscoot/compare/v2.1.1...HEAD
[2.1.1]: https://github.com/kappasims/netscoot/compare/v2.1.0...v2.1.1
[2.1.0]: https://github.com/kappasims/netscoot/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/kappasims/netscoot/releases/tag/v2.0.0
