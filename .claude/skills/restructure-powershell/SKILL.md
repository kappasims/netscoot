---
name: restructure-powershell
description: Use when moving, relocating, or restructuring PowerShell code: moving a .ps1 script, relocating a PowerShell module (its folder or .psd1 manifest), or reorganizing a module layout. Triggers on "move this script," "relocate the module," "restructure the PowerShell module." Cross-platform. For .NET projects (.csproj/.sln) use restructure-dotnet; for native C++ use restructure-native.
---

# Restructuring PowerShell code (scripts + modules, cross-platform)

Purpose (full overview: the [netscoot README](https://github.com/kappasims/netscoot)): a move
that fixes what it would otherwise break. PowerShell has no Visual Studio to reconcile a relocated
file, so netscoot rewrites the script paths a move breaks, changing only the path text.

These cmdlets are **cross-platform** (PowerShell 7 on Windows/Linux/macOS, and Windows
PowerShell 5.1) and need only git. The hazard is **relative references that break when a file
moves**. Unlike a .NET project, there is no manifest/CLI that reconciles every kind:

- **Scripts**: `. path` (dot-source), `& path` (call), `Import-Module <path>` and
  `using module <path>`, often `$PSScriptRoot`-relative. Move the script and those paths no longer
  resolve.
- **Modules**: scripts elsewhere that import the module (or dot-source one of its files) by path,
  and the module's own `.ps1`/`.psm1` paths to files outside it. The `.psd1` manifest's entries are
  module-relative, so a folder move leaves it valid and netscoot does not rewrite it.

Use the installed `netscoot` module (`Import-Module Netscoot`; if it is not installed, point
the user to the project's install steps and let them run them, never auto-install). The single
front door is **`Move-PowerShell`**. It routes a `.ps1` to the script mover and a `.psd1`/module
folder to the module mover. Always dry-run with `-WhatIf` first.

## Analyze/audit first (read-only)

Before moving, use the read-only surface rather than grepping by hand: `Find-NetscootPathReference` (the
build/CI/hook scripts that hardcode a path), `Resolve-MoveEngine` (how a path classifies), and
`Get-NetscootCapability` (git present? platform?). `Test-NetscootSolutionConsistency`,
`Get-NetscootSolutionInventory`, `Repair-NetscootSolutionReferences`, and `Sync-NetscootSolution` are .NET-solution tools;
reach for them when a PowerShell repository also carries `.csproj`/`.sln`. `Get-NetscootSolutionInventory` in
particular lists non-CLI project types a PowerShell solution may include, such as a `.pssproj`,
which `dotnet sln list` does not surface.

```powershell
Import-Module Netscoot

# Script (fixes dot-source/call references via the PowerShell AST):
Move-PowerShell -Path ./lib/helpers.ps1 -Destination ./shared/helpers.ps1 -WhatIf
Move-PowerShell -Path ./lib/helpers.ps1 -Destination ./shared/helpers.ps1

# Module (updates callers and the module's outward paths, then runs Test-ModuleManifest):
Move-PowerShell -Path ./tools/Mayo -Destination ./modules/Mayo
```

You can also call the specialists directly: `Move-PowerShellScript` and `Move-PowerShellModule`.

`-Destination` follows `git mv` rules: an existing directory means move into it keeping the
item's name (`-Destination ./shared` puts the script at `./shared/helpers.ps1`); otherwise it is
the new path, a rename (`-Destination ./shared/helpers.ps1`).

## Heuristic limit: reported, not silently guessed

Script reference fixing is AST-based, so it only resolves what it can prove:

- Literal and `$PSScriptRoot`-based string paths → rewritten (style preserved, including `/` or `\`).
- A path built with **other variables** (e.g. `"$dir\x.ps1"`), or any other string naming the
  moved file (e.g. a `Join-Path` argument or a `Publish-Module -Path` value) → **reported** as a
  possible dynamic reference to verify by hand.
- A path assembled with no string naming the file **cannot be detected**. Grep to be sure.

Treat the result as "fixed what could be proven," not "guaranteed complete."

## Do not

- Rewrite the `.psd1` after a module move; its entries are module-relative and stay valid.
- Move a `.ps1` with a plain `git mv` and assume its callers still work; references break silently.

## Undoing a move

Every move is journaled (on by default) to a per-user data directory outside the working tree
(LocalAppData on Windows, ~/Library/Application Support on macOS, ~/.local/share on Linux), so git
never tracks it and you can reverse a move later - even in a new session - with `Undo-Netscoot`. It
replays the inverse (the same move with source and destination swapped), re-reconciling references
from the current state.

```powershell
Undo-Netscoot -List     # what can be undone
Undo-Netscoot -WhatIf   # preview reversing the most recent move
Undo-Netscoot           # reverse the most recent move (call again to walk back)
```

A move interrupted by a crash is recoverable with `Repair-NetscootJournal`. Opt out per repository
with `Set-NetscootJournal -Enabled $false` (`-Global` for all). See the
[README](https://github.com/kappasims/netscoot).

## The `git netscoot` verb (optional; ask first)

The same routing is also an opt-in git verb: `git netscoot <src> <dst> [--whatif]`. It needs a
one-time alias that `Register-NetscootGitAlias` writes to the user's git config. If you suggest
it or want to use it, prompt the user first and let them register it; do not edit their git
config for them. Never auto-install anything (git, the dotnet SDK, or these modules): if a
prerequisite is missing, tell the user the install command and let them run it.

## Staying current

netscoot does not auto-update. Check with `Test-NetscootUpdate` (compares the installed module to
the latest GitHub release); update in place with `Update-Netscoot`, or from a dev clone with
`git pull` then `./build.ps1 -Task Install`. (Updating from a release before 2.6.1 needs a one-time
manual `Update-Module Netscoot` or installer re-run - those shipped a broken update endpoint; the
in-box updater works from 2.6.1 on.) A SessionStart hook running `Test-NetscootUpdate -Auto` can
remind automatically (gated to the update policy, never updates); ask the user before adding it,
since it edits their settings.json.
