---
name: restructure-unity
description: Use when moving, relocating, or restructuring assets/folders in a Unity project (including mobile - iOS/Android). Triggers on moving a Unity asset, folder, or .asmdef; reorganizing an Assets/ or Packages/ layout; or any file move inside a Unity project. Cross-platform. Do not move Unity files without their .meta. For pure .NET/.csproj use restructure-dotnet, and for native C++ use restructure-native.
---

# Restructuring Unity projects (cross-platform, incl. mobile)

Purpose (full overview: the [netscoot README](https://github.com/kappasims/netscoot)): a move
that does not break references. Where the .NET engines fix what a move breaks, the Unity engine
prevents the break: it always moves an asset together with its `.meta`, so the GUID that scenes,
prefabs, and asmdefs resolve by survives.

Unity's move hazard is the inverse of .NET's. It is not path-fixing:

- asmdef references are by **name or "GUID:..."**, not paths. Moving a folder does not
  break them, so you never edit other asmdefs.
- But every asset and folder has a sibling `<name>.meta` carrying a stable **GUID**, and
  scene/prefab/asmdef references resolve by that GUID. **Move files on disk without their
  `.meta` and Unity regenerates fresh GUIDs, and every reference to them breaks.**

So the rule: **never move a Unity asset/folder without its `.meta`.** A folder's meta is a
*sibling* (`Assets/Tarragon.meta` for folder `Assets/Tarragon`). Descendant metas live inside the folder.

## Analyze/audit first (read-only)

Before moving, audit with the read-only surface rather than scanning `.meta`/asmdef files by hand:
`Test-UnityMetaIntegrity -Root ./Assets` (assets missing a `.meta`, orphan `.meta` whose asset is
gone, see "Validate integrity" below) and `Resolve-MoveEngine` / `Get-NetscootCapability`. If the
project also has a managed side (`.csproj`/`.sln`), `Test-NetscootSolutionConsistency`,
`Get-NetscootSolutionInventory`, `Repair-NetscootSolutionReferences` (report mode), and `Sync-NetscootSolution` cover that.

## Use Move-UnityAsset

`Import-Module Netscoot` loads the Unity engine (install it first if needed, never
auto-install).

```powershell
Import-Module Netscoot
Move-UnityAsset -AssetPath ./Assets/Plugins/Tarragon -Destination ./Assets/Lib/Tarragon -WhatIf
# Then, after the user agrees (the move prompts, and an agent's shell is non-interactive):
Move-UnityAsset -AssetPath ./Assets/Plugins/Tarragon -Destination ./Assets/Lib/Tarragon -Confirm:$false
```

Moves the asset/folder + its `.meta` (git mv when tracked). When moving an `.asmdef` it
reports which asmdefs reference it. That is informational only, since name/GUID refs survive.

If the destination needs new parent folders, each one under `Assets/` (or inside a package) gets a
folder `.meta` with a fresh GUID, staged with the move, so it is committed once rather than
generated differently on each machine. `Undo-Netscoot` moves the asset back and removes those
folders and their `.meta` files again, as long as nothing else was added to them.

`-Destination` follows `git mv` rules: an existing directory means move into it keeping the
name (`./Assets/Lib` puts it at `./Assets/Lib/Tarragon`). Otherwise it is the new path, a
rename. The `.meta` follows the asset either way.

Mobile/all targets: asmdef `includePlatforms`/`excludePlatforms` (iOS, Android, ...) are
plain fields untouched by a move, so platform layouts are preserved.

## Validate integrity

```powershell
Test-UnityMetaIntegrity -Root ./Assets            # warns on problems
Test-UnityMetaIntegrity -Root ./Assets -Strict    # non-terminating errors
```

Reports `MissingMeta` (asset with no `.meta`) and `OrphanMeta` (`.meta` with no asset), the Unity
analog of dangling references. It skips Unity-hidden entries (names starting with `.`, folders
ending with `~`) and everything inside them.

## Do not

- Hand-edit generated `Assembly-CSharp*.csproj` / the `.sln`. Unity regenerates them.
- Move only the `.cs`/asset and leave the `.meta` (or vice versa).

## Undoing a move

Every move is journaled (on by default) to a per-user data directory outside the working tree, so
git never tracks it and you can reverse a move later, even in a new session, with `Undo-Netscoot`.
It replays the inverse (the asset and its `.meta` move back together).

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
