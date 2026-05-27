---
name: restructure-native
description: Use when moving or restructuring a native C++ or C++/CLI project (.vcxproj) in a Visual Studio solution on Windows. Triggers on moving a .vcxproj folder, relocating a native library, or restructuring a mixed managed+native solution. Windows-only. For pure managed .csproj/.fsproj/.vbproj use the restructure-dotnet skill instead.
---

# Restructuring native / C++ projects (.vcxproj), Windows only

Purpose (full overview: the [netscoot README](https://github.com/kappasims/netscoot)): a move
that reconciles what it can and reports the rest. Unlike the managed engines, the dotnet CLI cannot
fix a native project's link paths, so netscoot updates solution membership and moves the folder
(with its paired `.vcxproj.filters`), then reports every `$(SolutionDir)`-relative setting you must
verify by hand rather than silently editing it.

Native projects do not fit the dotnet-CLI delegation model that managed projects use.
`dotnet sln add/remove` can update solution membership for a `.vcxproj`, but the dotnet CLI
**cannot** reconcile how native projects actually link:

- `<AdditionalIncludeDirectories>` / `<AdditionalLibraryDirectories>` (often `..\` or `$(SolutionDir)`-relative)
- `<AdditionalDependencies>` (e.g. `Tarragon.lib`, resolved via the library dirs above)
- `<Import Project="..\shared\Tarragon.props" />` of shared `.props`/`.targets`
- `$(SolutionDir)`-relative `<OutDir>`/`<IntDir>` and PCH paths
- the paired `.vcxproj.filters`

C++/CLI is Windows-only (`<CLRSupport>`, `#pragma managed`, `<Windows.h>`), so this is gated.

Scope is `.vcxproj` (the MSBuild format, Visual Studio 2010 and later) - covering both pure native
C++ and C++/CLI. The legacy `.vcproj` (pre-VS2010) is **not** supported: it predates MSBuild, so
nothing here can process it. Passing a `.vcproj` is rejected with a clear error; convert it to
`.vcxproj` first (open it in VS 2010+).

## Analyze/audit first (read-only)

Before moving, inspect with the read-only surface instead of parsing `.sln`/`.vcxproj` by hand:
`Test-SolutionConsistency` (membership divergence across solutions, `-Debug` for the full matrix),
`Get-SolutionInventory` (full solution contents - it surfaces `.vcxproj` and other non-CLI project
types that `dotnet sln list` omits, plus projects in no solution), `Repair-SolutionReferences` (no
flags, to report dangling entries), `Find-PathReference`, and `Get-NetscootCapability`. To resolve
a reported divergence, run `Sync-Solution` (or `dotnet sln <solution> add <project>` by hand). These
cover solution membership for `.vcxproj` too; the native link settings are what `Move-NativeProject`
reports separately.

## Use Move-NativeProject

`Import-Module Netscoot` loads the native engine on Windows (install it first if needed; never
auto-install).

```powershell
Import-Module Netscoot
Move-NativeProject -Project ./Aleppo/Aleppo.vcxproj -Destination ./native/Aleppo -WhatIf
```

`-Destination` follows `git mv` rules: an existing directory means move into it keeping the
folder's name (`./native` puts it at `./native/Aleppo`); otherwise it is the new folder path (a
rename). It errors if the resulting folder already exists.

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

## Undoing a move

Every move is journaled to a per-user data directory (LocalAppData on Windows, ~/Library/Application Support on macOS, ~/.local/share on Linux), so you can reverse it later -
even in a new session - with `Undo-Netscoot`. It replays the inverse (moves the `.vcxproj` folder
and its `.vcxproj.filters` back, re-doing solution membership); re-check the native link settings
it reports, the same as for a forward move.

```powershell
Undo-Netscoot -List     # what can be undone
Undo-Netscoot -WhatIf   # preview reversing the most recent move
Undo-Netscoot           # reverse the most recent move (call again to walk back)
```

Journaling is on by default and stays out of the working tree (it lives inside `.git/`, so git never tracks it).
Opt out per repository with `Set-NetscootJournal -Enabled $false` (or `-Global` for all repositories). See the [README](https://github.com/kappasims/netscoot).

## The `git netscoot` verb (optional; ask first)

The same routing is also an opt-in git verb: `git netscoot <src> <dst> [--whatif]`. It needs a
one-time alias that `Register-NetscootGitAlias` writes to the user's git config. If you suggest
it or want to use it, prompt the user first and let them register it; do not edit their git
config for them. Never auto-install anything (git, the dotnet SDK, or these modules): if a
prerequisite is missing, tell the user the install command and let them run it.

## Staying current

netscoot does not auto-update; cutting a release changes nothing on an installed machine until
you update. Check with `Test-NetscootUpdate` (it compares the installed module to the latest
GitHub release). Update in place with `Update-Netscoot` (no git), or re-run the installer:
`irm https://raw.githubusercontent.com/kappasims/netscoot/master/install.ps1 | iex`. From a dev
clone instead, `git pull` then `./build.ps1 -Task Install`. For automatic reminders, consider a
Claude Code SessionStart hook that runs `Test-NetscootUpdate -EnableAutoUpdate` (gated: it checks only when `$env:NETSCOOT_AUTOUPDATE` is truthy, and never updates); ask the user before adding it,
since it edits their settings.json.
