---
name: restructure-powershell
description: Use when moving, relocating, or restructuring PowerShell code: moving a .ps1 script, relocating a PowerShell module (its folder or .psd1 manifest), or reorganizing a module layout. Triggers on "move this script", "relocate the module", "restructure the PowerShell module". Cross-platform. For .NET projects (.csproj/.sln) use restructure-dotnet; for native C++ use restructure-native.
---

# Restructuring PowerShell code (scripts + modules, cross-platform)

Purpose (full overview: the [netscoot README](https://github.com/kappasims/netscoot)): a move
that fixes what it would otherwise break. PowerShell has no Visual Studio to reconcile a relocated
file, so netscoot rewrites the dot-source/call paths a script move breaks and the `.psd1` manifest
a module move breaks, delegating manifest edits to `Update-ModuleManifest` rather than hand-editing.

These cmdlets are **cross-platform** (PowerShell 7 on Windows/Linux/macOS, and Windows
PowerShell 5.1) and need only git. The hazard is **relative references that break when a file
moves**. Unlike a .NET project, there is no manifest/CLI that reconciles every kind:

- **Scripts**: `. path` (dot-source) and `& path` (call) of other scripts, often
  `$PSScriptRoot`-relative. Move the script and those paths no longer resolve.
- **Modules**: the `.psd1` manifest's `RootModule` / `NestedModules` / `FileList`.

Use the installed `netscoot` module (`Import-Module Netscoot`; if it is not installed, point
the user to the project's install steps and let them run them, never auto-install). The single
front door is **`Move-PowerShell`**. It routes a `.ps1` to the script mover and a `.psd1`/module
folder to the module mover. Always dry-run with `-WhatIf` first.

## Analyze/audit first (read-only)

Before moving, use the read-only surface rather than grepping by hand: `Find-PathReference` (the
build/CI/hook scripts that hardcode a path), `Resolve-MoveEngine` (how a path classifies), and
`Get-ScootCapability` (git present? platform?). `Test-SolutionConsistency`,
`Get-SolutionInventory`, `Repair-SolutionReferences`, and `Sync-Solution` are .NET-solution tools;
reach for them when a PowerShell repository also carries `.csproj`/`.sln`. `Get-SolutionInventory` in
particular lists non-CLI project types a PowerShell solution may include, such as a `.pssproj`,
which `dotnet sln list` does not surface.

```powershell
Import-Module Netscoot

# Script (fixes dot-source/call references via the PowerShell AST):
Move-PowerShell -Path ./lib/helpers.ps1 -Destination ./shared/helpers.ps1 -WhatIf
Move-PowerShell -Path ./lib/helpers.ps1 -Destination ./shared/helpers.ps1

# Module (reconciles the .psd1 manifest via Update-ModuleManifest, then Test-ModuleManifest):
Move-PowerShell -Path ./tools/Mayo -Destination ./modules/Mayo
```

You can also call the specialists directly: `Move-PowerShellScript` and `Move-PowerShellModule`.

`-Destination` follows `git mv` rules: an existing directory means move into it keeping the
item's name (`-Destination ./shared` puts the script at `./shared/helpers.ps1`); otherwise it is
the new path, a rename (`-Destination ./shared/helpers.ps1`). It errors if the target exists.

## Heuristic limit: reported, not silently guessed

Script reference fixing is AST-based, so it only resolves what it can prove:

- Literal and `$PSScriptRoot`-based string paths → rewritten (style preserved).
- A path built with **other variables** (e.g. `"$dir\x.ps1"`) whose leaf matches → **reported**
  as a possible dynamic reference to verify by hand.
- A path built entirely from an expression (e.g. `Join-Path ...`) is not a string node and
  **cannot be detected**. Grep to be sure.

Treat the result as "fixed what could be proven," not "guaranteed complete."

## Module limits (warned, not fixed)

- Dot-sourced relative paths *inside* `.psm1`/`.ps1` files in the module are not reconciled by
  the manifest refresh; verify them.
- Any path computed at runtime.

## Do not

- Hand-edit the `.psd1` to repoint paths; let `Update-ModuleManifest` do it.
- Move a `.ps1` with a plain `git mv` and assume its callers still work; references break silently.

## Undoing a move

Every move is journaled to a per-user data directory (LocalAppData on Windows, ~/Library/Application Support on macOS, ~/.local/share on Linux), so you can reverse it later -
even in a new session - with `Undo-Scoot`. It replays the inverse (the same move with source
and destination swapped), re-reconciling references from the current state.

```powershell
Undo-Scoot -List     # what can be undone
Undo-Scoot -WhatIf   # preview reversing the most recent move
Undo-Scoot           # reverse the most recent move (call again to walk back)
```

Journaling is on by default and stays out of the working tree (it lives inside `.git/`, so git never tracks it).
Opt out per repository with `Set-ScootJournal -Enabled $false` (or `-Global` for all repositories). See the [README](https://github.com/kappasims/netscoot).

## The `git netscoot` verb (optional; ask first)

The same routing is also an opt-in git verb: `git netscoot <src> <dst> [--whatif]`. It needs a
one-time alias that `Register-ScootGitAlias` writes to the user's git config. If you suggest
it or want to use it, prompt the user first and let them register it; do not edit their git
config for them. Never auto-install anything (git, the dotnet SDK, or these modules): if a
prerequisite is missing, tell the user the install command and let them run it.

## Staying current

netscoot does not auto-update; cutting a release changes nothing on an installed machine until
you update. Check with `Test-ScootUpdate` (it compares the installed module to the latest
GitHub release). Update in place with `Update-Scoot` (no git), or re-run the installer:
`irm https://raw.githubusercontent.com/kappasims/netscoot/master/install.ps1 | iex`. From a dev
clone instead, `git pull` then `./build.ps1 -Task Install`. For automatic reminders, consider a
Claude Code SessionStart hook that runs `Test-ScootUpdate -EnableAutoUpdate` (gated: it checks only when `$env:NETSCOOT_AUTOUPDATE` is truthy, and never updates); ask the user before adding it,
since it edits their settings.json.
