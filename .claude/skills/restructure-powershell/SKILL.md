---
name: restructure-powershell
description: Use when moving, relocating, or restructuring PowerShell code: moving a .ps1 script, relocating a PowerShell module (its folder or .psd1 manifest), or reorganizing a module layout. Triggers on "move this script," "relocate the module," "restructure the PowerShell module." Cross-platform. For .NET projects (.csproj/.sln) use restructure-dotnet, for Unity assets use restructure-unity, and for native C++ use restructure-native.
---

# Restructuring PowerShell code (scripts + modules, cross-platform)

Purpose (full overview: the [netscoot README](https://github.com/kappasims/netscoot)): a move
that fixes what it would otherwise break. PowerShell has no Visual Studio to reconcile a relocated
file, so netscoot rewrites the script paths a move breaks, changing only the path text.

These cmdlets are **cross-platform** (PowerShell 7 on Windows/Linux/macOS, and Windows
PowerShell 5.1). They need no dotnet CLI, and git is optional (without it, a move falls back to a
plain `Move-Item`). The hazard is **relative references that break when a file moves**. Unlike a
.NET project, there is no manifest/CLI that reconciles every kind:

- **Scripts**: `. path` (dot-source), `& path` (call), `Import-Module <path>` and
  `using module <path>`, often `$PSScriptRoot`-relative. Move the script and those paths no longer
  resolve.
- **Modules**: scripts elsewhere that import the module (or dot-source one of its files) by path,
  and the module's own `.ps1`/`.psm1` paths to files outside it. The `.psd1` manifest's entries are
  module-relative, so a folder move leaves it valid and netscoot does not rewrite it.

Use the installed `netscoot` module (`Import-Module Netscoot`). If it is not installed, point the
user to the project's install steps and let them run them. Never auto-install. The single front door
is **`Move-PowerShell`**. It routes a `.ps1` to the script mover and a `.psd1`/module folder to the
module mover. Always dry-run with `-WhatIf` first. A real move prompts for confirmation and an
agent's shell is non-interactive, so after the user agrees, run it with `-Confirm:$false`.

## Analyze/audit first (read-only)

Before moving, use the read-only surface rather than grepping by hand: `Find-NetscootPathReference` (the
build/CI/hook scripts that hardcode a path), `Resolve-MoveEngine` (how a path classifies), and
`Get-NetscootCapability` (git present? platform?). `Test-NetscootSolutionConsistency`,
`Get-NetscootSolutionInventory`, `Repair-NetscootSolutionReferences`, and `Sync-NetscootSolution` are .NET-solution tools.
Reach for them when a PowerShell repository also carries `.csproj`/`.sln` (`Repair-NetscootSolutionReferences`
and `Sync-NetscootSolution` need the dotnet CLI). `Get-NetscootSolutionInventory` in particular lists non-CLI project
types a PowerShell solution may include, such as a `.pssproj`, which `dotnet sln list` does not
surface.

```powershell
Import-Module Netscoot

# Script (fixes dot-source/call/Import-Module references via the PowerShell AST):
Move-PowerShell -Path ./lib/helpers.ps1 -Destination ./shared/helpers.ps1 -WhatIf
Move-PowerShell -Path ./lib/helpers.ps1 -Destination ./shared/helpers.ps1 -Confirm:$false

# Module (updates callers and the module's outward paths, then runs Test-ModuleManifest):
Move-PowerShell -Path ./tools/Mayo -Destination ./modules/Mayo -Confirm:$false
```

You can also call the specialists directly: `Move-PowerShellScript` and `Move-PowerShellModule`.

`-Destination` follows `git mv` rules: an existing directory means move into it keeping the
item's name (`-Destination ./shared` puts the script at `./shared/helpers.ps1`). Otherwise it is
the new path, a rename (`-Destination ./shared/helpers.ps1`).

## Heuristic limit: reported, not silently guessed

Script reference fixing is AST-based, so it only resolves what it can prove:

- Literal and `$PSScriptRoot`-based string paths → rewritten as whole tokens (style preserved,
  including `/` or `\`, and the file's encoding kept). A relative path is resolved against the
  referencing script's own folder.
- A path built with **other variables** (e.g. `"$dir\x.ps1"`), or any other string naming the
  moved file (e.g. a `Join-Path` argument or a `Publish-Module -Path` value) → **reported** as a
  possible dynamic reference to verify by hand.
- A path assembled with no string naming the file **cannot be detected**. Grep to be sure.

Treat the result as "fixed what could be proven," not "guaranteed complete."

## Do not

- Rewrite the `.psd1` after a module move. Its entries are module-relative and stay valid.
- Move a `.ps1` with a plain `git mv` and assume its callers still work. References break silently.

## Undoing a move

Every move is journaled (on by default) to a per-user data directory outside the working tree, so
git never tracks it and you can reverse a move later, even in a new session, with `Undo-Netscoot`.
It replays the inverse (the same move with source and destination swapped), re-reconciling
references from the current state.

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
`Set-NetscootUpdateChannel -Channel Beta` opted into betas). Update a Gallery install with `Update-Module Netscoot`, an installer
install with `Update-Netscoot`, and a dev clone with `git pull` then `./build.ps1 -Task Install`. A
SessionStart hook running `Test-NetscootUpdate -Auto` can remind automatically. It checks only when
the update policy is Enabled, and never updates. Ask the user before adding it, since it edits their
settings.json.
