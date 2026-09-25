---
name: restructure-native
description: Use when moving or restructuring a native C++ or C++/CLI project (.vcxproj) in a Visual Studio solution on Windows. Triggers on moving a .vcxproj folder, relocating a native library, or restructuring a mixed managed+native solution. Windows-only. For pure managed .csproj/.fsproj/.vbproj use the restructure-dotnet skill instead.
---

# Restructuring native / C++ projects (.vcxproj), Windows only

Purpose (full overview: the [netscoot README](https://github.com/kappasims/netscoot)): a move
that reconciles what it can and reports the rest. netscoot moves the folder (with its paired
`.vcxproj.filters`), updates the solution entries and `ProjectReference`s that point at it, then
reports the relative or `$(SolutionDir)`-relative settings you must verify by hand rather than
silently editing them.

Native projects do not fit the dotnet-CLI delegation model that managed projects use. The dotnet
CLI cannot load a real `.vcxproj` outside Visual Studio's MSBuild. So netscoot rewrites the path in
each `.sln`/`.slnx` entry and each `ProjectReference` in place, keeping GUIDs, platform mappings and
solution folders. It does **not** rewrite how native projects link:

- `<AdditionalIncludeDirectories>` / `<AdditionalLibraryDirectories>` (often `..\` or `$(SolutionDir)`-relative)
- `<AdditionalDependencies>` (e.g. `Tarragon.lib`, resolved via the library dirs above)
- `<Import Project="..\shared\Tarragon.props" />` of shared `.props`/`.targets`
- `$(SolutionDir)`-relative `<OutDir>`/`<IntDir>` and PCH paths
- the paired `.vcxproj.filters`

C++/CLI is Windows-only (`<CLRSupport>`, `#pragma managed`, `<Windows.h>`), so this is gated.

Scope is `.vcxproj` (the MSBuild format, Visual Studio 2010 and later), covering both pure native
C++ and C++/CLI. The legacy `.vcproj` (pre-VS2010) is **not** supported. It predates MSBuild, so
nothing here can process it. Passing a `.vcproj` is rejected with a clear error. Convert it to
`.vcxproj` first (open it in VS 2010+).

## Analyze/audit first (read-only)

Before moving, inspect with the read-only surface instead of parsing `.sln`/`.vcxproj` by hand:
`Test-NetscootSolutionConsistency` (membership divergence across solutions, `-Debug` for the full matrix
under `pwsh`), `Get-NetscootSolutionInventory` (full solution contents: it surfaces `.vcxproj` and other
non-CLI project types that `dotnet sln list` omits, plus projects in no solution),
`Repair-NetscootSolutionReferences` (no flags, to report dangling entries), `Find-NetscootPathReference`, and
`Get-NetscootCapability`.

Do not use `Sync-NetscootSolution` or `dotnet sln <solution> add` for a `.vcxproj`. The dotnet CLI cannot
load it, so `Sync-NetscootSolution` only reports a missing `.vcxproj`, and `Repair-NetscootSolutionReferences -Fix`
only reports a moved one. Add or re-point it in Visual Studio.

## Use Move-NativeProject

`Import-Module Netscoot` loads the native engine on Windows (install it first if needed, never
auto-install).

```powershell
Import-Module Netscoot
Move-NativeProject -Project ./Aleppo/Aleppo.vcxproj -Destination ./native/Aleppo -WhatIf
# Then, after the user agrees (the move prompts, and an agent's shell is non-interactive):
Move-NativeProject -Project ./Aleppo/Aleppo.vcxproj -Destination ./native/Aleppo -Confirm:$false
```

`-Destination` follows `git mv` rules: an existing directory means move into it keeping the
folder's name (`./native` puts it at `./native/Aleppo`). Otherwise it is the new folder path (a
rename).

It will: move the folder (`git mv` when tracked) including the paired `.vcxproj.filters`; update
the project's path in every `.sln`/`.slnx` entry, in every `ProjectReference` to it (native or
C#/C++/CLI consumers) and in its own `ProjectReference`s; and then **report the native settings it
does not rewrite**. `UnreconciledSettings` on the result object holds the moved project's own
relative or `$(SolutionDir)`-relative settings. A `..`-relative setting in another project that
points into the moved folder is reported as a warning. Together they tell you what to verify or
hand-fix afterward.

## After the move, always

- Fix each reported `AdditionalIncludeDirectories`/`AdditionalLibraryDirectories`/`Import`
  whose `..\` depth changed.
- Rebuild the native + C++/CLI projects in Visual Studio / MSBuild (not `dotnet build`).
- Confirm the `.vcxproj.filters` has no broken `..\` entries.

## Undoing a move

Every move is journaled (on by default) to a per-user data directory outside the working tree, so
git never tracks it and you can reverse a move later, even in a new session, with `Undo-Netscoot`.
It replays the inverse (moves the `.vcxproj` folder and its `.vcxproj.filters` back, re-doing
solution membership). Re-check the native link settings it reports, the same as for a forward move.

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
`Set-NetscootUpdateChannel -Channel Beta` opted into betas). Update a Gallery install with
`Update-Module Netscoot`, an installer install with `Update-Netscoot`, and a dev clone with
`git pull` then `./build.ps1 -Task Install`. A SessionStart hook running `Test-NetscootUpdate -Auto`
can remind automatically. It checks only when the update policy is Enabled, and never updates. Ask
the user before adding it, since it edits their settings.json.
