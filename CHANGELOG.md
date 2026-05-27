# Changelog

All notable changes to netscoot are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.1.0] - 2026-05-28

### Added

- `Repair-NetscootJournal`: detect and recover moves interrupted mid-operation. Read-only report by
  default; `-Rollback` reverses a half-applied move, `-Discard` forgets it, with snapshot and orphan
  cleanup.
- Write-ahead (WAL) move journal: each move and its journal write are a single atomic step, so an
  interrupted move is detected on the next run rather than leaving silent inconsistency.
- PowerShell Gallery discovery tags and CI/license badges.
- A markdownlint CI gate enforcing Markdown conformance across the repository.

### Changed

- Journal reads are linear with size-capped compaction (previously slower as the journal grew).
- Hot-path regexes are precompiled.
- Generated command reference reflowed to satisfy markdownlint (no content change).

### Fixed

- Security: `Update-Netscoot -Force` no longer overrides an administrator (machine-scope) Disabled
  update policy. It still overrides a Disabled you set for yourself (process or user scope).
- Windows PowerShell 5.1: `.Count` on a scalar in `Repair-NetscootJournal` under StrictMode.

## [2.0.0] - 2026-05-27

Rebranded from DotnetMove to netscoot; first release under the new name. Highlights: a single
PowerShell Gallery package (umbrella + engines), the Enabled/Manual/Disabled update policy with
`Get-NetscootUpdatePolicy`/`Set-NetscootUpdatePolicy` and `Test-NetscootUpdate -Auto`, the per-user
move journal, default table views, and the public `RepoRoot` parameter renamed to `RepositoryRoot`.
See the release notes for the full pull-request list.

DotnetMove 1.x history predates the rename; see the legacy DotnetMove releases.

[Unreleased]: https://github.com/kappasims/netscoot/compare/v2.1.0...HEAD
[2.1.0]: https://github.com/kappasims/netscoot/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/kappasims/netscoot/releases/tag/v2.0.0
