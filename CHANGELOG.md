# Changelog

All notable changes to netscoot are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `Move-Solution` results carry `ItemsRebased`, the number of solution item paths rewritten.

### Fixed

- Path rewrites keep each file's encoding. A UTF-16 file (the Windows PowerShell 5.1 `Out-File`
  default) stays UTF-16, and legacy code-page text is no longer garbled.
- Moving `.\helpers.ps1` no longer rewrites a `..\helpers.ps1` reference in the same file.
- `Move-Solution` rebases solution items and every project type, such as `.sqlproj` and `.wixproj`.
  Before, only `.csproj`, `.fsproj`, `.vbproj`, `.vcxproj` and `.pssproj` entries moved with it.
- `Repair-NetscootSolutionReferences` finds a moved `.vcxproj` instead of classifying it Missing, so
  `-Prune` no longer removes its solution entry. `-Fix` reports it for Visual Studio.
- `Sync-NetscootSolution` only syncs solutions that share projects, the groups `Test-NetscootSolutionConsistency`
  compares, so a standalone solution no longer receives another solution's projects. It adds only
  managed projects and reports a missing `.vcxproj` or `.pssproj`.
- `Test-NetscootSolutionConsistency` no longer requires the dotnet CLI.
- `Undo-Netscoot` finds a move made with a narrower `-RepositoryRoot`, which was journaled under
  that folder instead of the git repository root.
- `Repair-NetscootJournal -ClearOrphanSnapshots` keeps snapshots that another repository's
  interrupted move needs, and any snapshot less than an hour old.
- `Invoke-Netscoot -NoBuild` (and `git netscoot --nobuild`) works for a `.vcxproj`, and
  `-RepositoryRoot` reaches the Unity engine.
- `Move-DotnetProjectTree` reports `Built = false` when any project fails to build, not only the
  last one, and warns about a `.vcxproj` it moves without updating.
- `Resolve-MoveEngine` routes a path under `Assets/` or `Packages/` to Unity only inside a Unity
  project, so a NuGet `packages/` folder or a web `assets/` folder no longer goes to the Unity mover.
- `Test-UnityMetaIntegrity` skips files inside Unity-hidden folders such as `Samples~`.
- `Test-EditorSolutionGuard` no longer calls a consolidation durable when there is no
  `.vscode/settings.json` to confirm it.
- `Get-NetscootCapability` reports `.slnx` support from SDK 9.0.200, where `dotnet sln` gained it.
- `Test-NetscootUpdate` returns a `Netscoot.Update` record, and its update hint fits Gallery and
  installer installs.
- Update policy handling is more consistent.
- `Unregister-NetscootGitAlias` reports its own error under Windows PowerShell 5.1.

## [3.0.0-beta5] - 2026-09-25

No module changes from 3.0.0-beta4.

## [3.0.0-beta4] - 2026-09-25

### Fixed

- `Move-UnityAsset` gives each new parent folder it creates under `Assets/` (or inside a package) a
  folder `.meta`, staged with the move. Before, Unity generated those on import with a different
  GUID on every machine, and `Test-UnityMetaIntegrity` flagged them right after the move.
  `Undo-Netscoot` removes those folders and their `.meta` files again if nothing else was added.

## [3.0.0-beta3] - 2026-09-25

### Fixed

- `Move-NativeProject` now works for a project that is in a solution. It rewrites the project's path
  in each `.sln`/`.slnx` entry and in every `ProjectReference` to it, native or managed, and rebases
  its own `ProjectReference`s, keeping GUIDs, platform mappings and solution folders. It no longer
  needs the dotnet CLI, which cannot load a real `.vcxproj`. Include paths in other projects that
  point into the moved folder are reported.
- `Move-PowerShellModule` updates scripts that load the module by path (`Import-Module`,
  `using module`) and rebases the module's own paths to files outside it. It no longer rewrites the
  manifest, which reformatted it and could drop an explicit `VariablesToExport`.
- `Move-PowerShellScript` keeps the `/` or `\` style of the paths it rewrites, rebases the moved
  script's own `Import-Module` and `using module` paths, and reports other strings that name the
  moved script, such as a `Join-Path` argument.
- Every move command now returns the repository to its original state when a move fails partway.
  Previously `Move-NativeProject`, `Move-MSBuildImport`, `Move-PowerShellScript`,
  `Move-PowerShellModule`, `Move-Solution` and `Move-UnityAsset` could leave files at the destination
  and references half-updated while reporting that the move had been rolled back.
- Moving a .NET project keeps it in its solution folder. It was re-added under a virtual folder that
  mirrored its new physical path, so a deep move created empty intermediate folders and a project
  grouped under a solution folder lost that grouping.
- The reminder `Move-PowerShellModule` prints about dot-sourced paths shows the literal
  `$PSScriptRoot` text again, instead of an absolute path.

### Changed

- The deprecated aliases for the five renamed cmdlets (`Get-SolutionInventory`, `Sync-Solution`,
  `Find-PathReference`, `Test-SolutionConsistency`, `Repair-SolutionReferences`) now warn that they
  will be removed in 4.0.

## [3.0.0-beta2] - 2026-07-21

### Fixed

- `Move-DotnetProject`: a relative `-Destination` now resolves against the current location rather
  than the process's original working directory, so a move run after `cd`-ing into a repository
  lands where you expect (matching `-Project`).
- `Move-DotnetProject` no longer leaks the post-move `dotnet build` output into its result, so the
  returned `Netscoot.MoveResult` is a clean single object again.

## [3.0.0-beta1] - 2026-06-26

Opt-in prerelease for stress-testing. `Install-Module Netscoot` stays on 2.6.x. Opt in with
`-AllowPrerelease` (module) or the `3.0-beta` plugin branch (see [BETA.md](BETA.md)).

### Added

- A **beta update channel**: `Set-NetscootUpdateChannel Beta` (and `Get-NetscootUpdateChannel`) opts
  the in-product updater into prerelease releases. `Test-NetscootUpdate` and `Update-Netscoot` are now
  prerelease-aware. On the Beta channel they track newer beta builds and the stable release by
  SemVer precedence, and the default Stable channel only ever offers non-prerelease releases.

### Changed

- **BREAKING (3.0):** five public cmdlets gained the `Netscoot` brand noun so their names no longer
  collide with generic verbs in a shared session: `Get-SolutionInventory` ->
  `Get-NetscootSolutionInventory`, `Sync-Solution` -> `Sync-NetscootSolution`, `Find-PathReference`
  -> `Find-NetscootPathReference`, `Test-SolutionConsistency` -> `Test-NetscootSolutionConsistency`,
  `Repair-SolutionReferences` -> `Repair-NetscootSolutionReferences`. The old names continue to work
  as deprecated aliases that emit a warning on use and are removed in 4.0. Update scripts to the new
  names.
- **BREAKING (3.0):** move, inventory and analysis results are now real .NET types
  (`Netscoot.MoveResult`, `Netscoot.ConsistencyResult`, and the rest) instead of a `pscustomobject`
  stamped with a `PSTypeName`. Property access, formatting, and `$x.PSTypeNames[0]` checks are
  unchanged. Only code that tested `-is [pscustomobject]` is affected. Journal entries, the
  update-check record and the capability tool records stay `pscustomobject`.
- `Clear-NetscootJournal` now prompts before wiping a repository's undo journal
  (`ConfirmImpact = 'High'`, matching `Repair-NetscootJournal`). Pass `-Confirm:$false` to suppress.

## [2.6.3] - 2026-06-26

### Changed

- Maintenance release. Documentation and AI-agent skill updates only - no change to the shipped
  module or any cmdlet behavior. The released package is functionally identical to 2.6.2.

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
  `/repos/<owner>/<name>`. The broken check shipped in earlier versions, so update once by the path
  you installed from (`Update-Module Netscoot`, `git pull` then `./build.ps1 -Task Install`, or
  re-running `install.ps1`) to land this fix.
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
  solutions that share at least one project are compared with each other. A `.sln`/`.slnx` mirror
  pair that genuinely drifts is still reported.
- `Find-PathReference` no longer throws when `-RepositoryRoot` is omitted and `-Path` points at an
  already-moved (now nonexistent) path - the canonical "sweep the old identifier after a rename"
  use case. The repository root is derived from the current directory, not from the search path.

## [2.5.0] - 2026-05-29

No user-visible changes.

## [2.4.0] - 2026-05-29

### Changed

- `Repair-SolutionReferences -Fix` / `-Prune` and `Sync-Solution` now prompt by default
  (`ConfirmImpact = 'High'`), matching `Move-Solution` and `Move-MSBuildImport`, which mutate
  the same kind of file. Pass `-Confirm:$false` to suppress the prompt. The report-only path (no
  `-Fix` / `-Prune`) is unaffected. Callers that relied on the previous no-prompt default
  need to start passing `-Confirm:$false` explicitly.
- `Undo-Netscoot -Id` and `Repair-NetscootJournal -Id` now validate the id format at
  parameter bind (`^[a-zA-Z0-9]{8}$`). A typo (wrong length, stray whitespace, punctuation)
  now fails at the call site instead of at the journal-lookup error.

### Added

- `Undo-Netscoot` and `Unregister-NetscootGitAlias` now declare their output types via
  `[OutputType()]`. Undo-Netscoot returns the nine move-result / journal-entry types it
  produces depending on parameters. Unregister-NetscootGitAlias returns nothing (`[void]`).
  `Get-Command` and tab completion see the declared types.

## [2.3.2] - 2026-05-29

### Added

- Comment-based help `.LINK` cross-references for the natural cmdlet pairs and the
  analysis clusters (update policy, journal, solution analysis). `Get-Help` shows them
  under RELATED LINKS.

### Changed

- `Move-PowerShellModule` reports its input errors as structured non-terminating errors, like the
  other movers. Callers using `-ErrorAction Stop` see the same outcome as before.
- The dispatch-chain trace under `-Verbose` now reads uniformly across all layers: the outer
  dispatcher names the target cmdlet the same way the inner dispatchers do.

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

- Internal helpers module renamed from `Netscoot.Shared` to `NetscootShared` (no dot), so the
  wildcard `Get-Command -Module Netscoot.*` no longer matches the internal helpers. Use
  `Get-Command -Module NetscootShared` to opt in to the plumbing.

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

## [2.2.0] - 2026-05-28

### Changed

- Read and analysis commands (project/solution moves, `Get-SolutionInventory`, `Repair-SolutionReferences`,
  and the consistency/sync checks) now parse the repository once per invocation instead of re-scanning it
  for each project. Large repositories see multi-times-faster moves and inventories, with the gap widening
  as the project count grows.
- Commands that take a path or repository root from the pipeline now accept a path string or a file/directory
  item (`Get-Item` / `Get-ChildItem`). Piping any other kind of object reports a clear input error
  instead of binding an unexpected property. This makes one consistent pipeline contract across the
  module.
- Move results now have a default table view (engine, performed, source, destination), so a pipeline of
  moves renders as a table like the other result types instead of a long list.

### Fixed

- Move result objects now expose their properties in a stable, documented order. The engine-specific
  fields were previously emitted in an unpredictable order.

## [2.1.1] - 2026-05-28

### Fixed

- `Move-DotnetProject` aborted under Windows PowerShell 5.1 (StrictMode) when a repository project
  had a single non-literal or conditional `ProjectReference`. PowerShell 7 was unaffected.

## [2.1.0] - 2026-05-28

### Added

- `Repair-NetscootJournal`: detect and recover moves interrupted mid-operation. It reports only by
  default. `-Rollback` reverses a half-applied move and `-Discard` forgets it, with snapshot and
  orphan cleanup.
- Write-ahead (WAL) move journal: each move and its journal write are a single atomic step, so an
  interrupted move is detected on the next run rather than leaving silent inconsistency.

### Changed

- Journal reads are linear with size-capped compaction (previously slower as the journal grew).

### Fixed

- Hardened update-policy enforcement for administrator (machine-scope) settings.
- Windows PowerShell 5.1 compatibility fixes.

## [2.0.0] - 2026-05-27

Rebranded from DotnetMove to netscoot, the first release under the new name. Highlights: a single
PowerShell Gallery package (umbrella + engines), the Enabled/Manual/Disabled update policy with
`Get-NetscootUpdatePolicy`/`Set-NetscootUpdatePolicy` and `Test-NetscootUpdate -Auto`, the per-user
move journal, default table views, and the public `RepoRoot` parameter renamed to `RepositoryRoot`.
See the release notes for the full pull-request list.

DotnetMove 1.x history predates the rename. See the legacy DotnetMove releases.

[Unreleased]: https://github.com/kappasims/netscoot/compare/v3.0.0-beta5...HEAD
[3.0.0-beta5]: https://github.com/kappasims/netscoot/compare/v3.0.0-beta4...v3.0.0-beta5
[3.0.0-beta4]: https://github.com/kappasims/netscoot/compare/v3.0.0-beta3...v3.0.0-beta4
[3.0.0-beta3]: https://github.com/kappasims/netscoot/compare/v3.0.0-beta2...v3.0.0-beta3
[3.0.0-beta2]: https://github.com/kappasims/netscoot/compare/v3.0.0-beta1...v3.0.0-beta2
[3.0.0-beta1]: https://github.com/kappasims/netscoot/compare/v2.6.3...v3.0.0-beta1
[2.6.3]: https://github.com/kappasims/netscoot/compare/v2.6.2...v2.6.3
[2.6.2]: https://github.com/kappasims/netscoot/compare/v2.6.1...v2.6.2
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
