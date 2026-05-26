---
name: restructure-native
description: Use when moving or restructuring a native C++ or C++/CLI project (.vcxproj) in a Visual Studio solution on Windows. Triggers on moving a .vcxproj folder, relocating a native library, or restructuring a mixed managed+native solution. Windows-only. For pure managed .csproj/.fsproj/.vbproj use the restructure-dotnet skill instead.
---

# Restructuring native / C++ projects (.vcxproj), Windows only

Native projects do not fit the dotnet-CLI delegation model that managed projects use.
`dotnet sln add/remove` can update solution membership for a `.vcxproj`, but the dotnet CLI
**cannot** reconcile how native projects actually link:

- `<AdditionalIncludeDirectories>` / `<AdditionalLibraryDirectories>` (often `..\` or `$(SolutionDir)`-relative)
- `<AdditionalDependencies>` (e.g. `Tarragon.lib`, resolved via the library dirs above)
- `<Import Project="..\shared\Tarragon.props" />` of shared `.props`/`.targets`
- `$(SolutionDir)`-relative `<OutDir>`/`<IntDir>` and PCH paths
- the paired `.vcxproj.filters`

C++/CLI is Windows-only (`<CLRSupport>`, `#pragma managed`, `<Windows.h>`), so this is gated.

## Analyze/audit first (read-only)

Before moving, inspect with the read-only surface instead of parsing `.sln`/`.vcxproj` by hand:
`Test-SolutionConsistency` (membership divergence across solutions, `-Debug` for the full matrix),
`Get-SolutionInventory` (full solution contents - it surfaces `.vcxproj` and other non-CLI project
types that `dotnet sln list` omits, plus projects in no solution), `Repair-SolutionReferences` (no
flags, to report dangling entries), `Find-PathReference`, and `Get-DotnetMoveCapability`. To resolve
a reported divergence, run `Sync-Solution` (or `dotnet sln <solution> add <project>` by hand). These
cover solution membership for `.vcxproj` too; the native link settings are what `Move-NativeProject`
reports separately.

## Use Move-NativeProject

`Import-Module DotnetMove` loads the native engine on Windows (install it first if needed; never
auto-install).

```powershell
Import-Module DotnetMove
Move-NativeProject -Project ./Aleppo/Aleppo.vcxproj -Destination ./native/Aleppo -WhatIf
```

It will: update `.sln`/`.slnx` membership via `dotnet sln`, move the folder (`git mv` when
tracked) including the paired `.vcxproj.filters`, and then **report every relative /
`$(SolutionDir)`-relative native setting** it could not safely rewrite. It does not silently
edit those MSBuild paths; the report (`UnreconciledSettings` on the result object, plus
warnings) tells you exactly what to verify or hand-fix afterward.

## After the move, always

- Fix each reported `AdditionalIncludeDirectories`/`AdditionalLibraryDirectories`/`Import`
  whose `..\` depth changed.
- Rebuild the native + C++/CLI projects in Visual Studio / MSBuild (not `dotnet build`).
- Confirm the `.vcxproj.filters` has no broken `..\` entries.

## The `git dotnetmv` verb (optional; ask first)

The same routing is also an opt-in git verb: `git dotnetmv <src> <dst> [--whatif]`. It needs a
one-time alias that `Register-DotnetMvGitAlias` writes to the user's git config. If you suggest
it or want to use it, prompt the user first and let them register it; do not edit their git
config for them. Never auto-install anything (git, the dotnet SDK, or these modules): if a
prerequisite is missing, tell the user the install command and let them run it.

## Staying current

DotnetMove does not auto-update; cutting a release changes nothing on an installed machine until
you update. Check with `Test-DotnetMoveUpdate` (it compares the installed module to the latest
GitHub release). Update in place with `Update-DotnetMove` (no git), or re-run the installer:
`irm https://raw.githubusercontent.com/kappasims/dotnet-move/master/install.ps1 | iex`. From a dev
clone instead, `git pull` then `./build.ps1 -Task Install`. For automatic reminders, consider a
Claude Code SessionStart hook that runs `Test-DotnetMoveUpdate`; ask the user before adding it,
since it edits their settings.json.
