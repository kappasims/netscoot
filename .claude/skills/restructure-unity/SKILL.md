---
name: restructure-unity
description: Use when moving, relocating, or restructuring assets/folders in a Unity project (including mobile - iOS/Android). Triggers on moving a Unity asset, folder, or .asmdef; reorganizing an Assets/ or Packages/ layout; or any file move inside a Unity project. Cross-platform. Do not move Unity files without their .meta. For pure .NET/.csproj use restructure-dotnet; for native C++ use restructure-native.
---

# Restructuring Unity projects (cross-platform, incl. mobile)

Purpose (full overview: the [netscoot README](https://github.com/kappasims/netscoot)): a move
that does not break references. Where the .NET engines fix what a move breaks, the Unity engine
prevents the break: it always moves an asset together with its `.meta`, so the GUID that scenes,
prefabs, and asmdefs resolve by survives.

Unity's move hazard is the inverse of .NET's. It is not path-fixing:

- asmdef references are by **name or "GUID:..."**, not paths - moving a folder does not
  break them (so you never edit other asmdefs).
- but every asset and folder has a sibling `<name>.meta` carrying a stable **GUID**, and
  scene/prefab/asmdef references resolve by that GUID. **Move files on disk without their
  `.meta` and Unity regenerates fresh GUIDs - every reference to them breaks.**

So the rule: **never move a Unity asset/folder without its `.meta`.** A folder's meta is a
*sibling* (`Assets/Tarragon.meta` for folder `Assets/Tarragon`); descendant metas live inside the folder.

## Analyze/audit first (read-only)

Before moving, audit with the read-only surface rather than scanning `.meta`/asmdef files by hand:
`Test-UnityMetaIntegrity -Root ./Assets` (assets missing a `.meta`, orphan `.meta` whose asset is
gone; see "Validate integrity" below) and `Resolve-MoveEngine` / `Get-ScootCapability`. If the
project also has a managed side (`.csproj`/`.sln`), `Test-SolutionConsistency`,
`Get-SolutionInventory`, `Repair-SolutionReferences` (report mode), and `Sync-Solution` cover that.

## Use Move-UnityAsset

`Import-Module Netscoot` loads the Unity engine (install it first if needed; never
auto-install).

```powershell
Import-Module Netscoot
Move-UnityAsset -AssetPath ./Assets/Plugins/Tarragon -Destination ./Assets/Lib/Tarragon -WhatIf
```

Moves the asset/folder + its `.meta` (git mv when tracked). When moving an `.asmdef` it
reports which asmdefs reference it - informational only, since name/GUID refs survive.

`-Destination` follows `git mv` rules: an existing directory means move into it keeping the
name (`./Assets/Lib` puts it at `./Assets/Lib/Tarragon`); otherwise it is the new path, a
rename. It errors if the target exists. The `.meta` follows the asset either way.

Mobile/all targets: asmdef `includePlatforms`/`excludePlatforms` (iOS, Android, ...) are
plain fields untouched by a move, so platform layouts are preserved.

## Validate integrity

```powershell
Test-UnityMetaIntegrity -Root ./Assets            # warns on problems
Test-UnityMetaIntegrity -Root ./Assets -Strict    # non-terminating errors
```
Reports `MissingMeta` (asset with no `.meta`) and `OrphanMeta` (`.meta` with no asset) - the
Unity analog of dangling references.

## Do not

- Hand-edit generated `Assembly-CSharp*.csproj` / the `.sln` - Unity regenerates them.
- Move only the `.cs`/asset and leave the `.meta` (or vice versa).

## Undoing a move

Every move is journaled to a per-user data directory (LocalAppData on Windows, ~/Library/Application Support on macOS, ~/.local/share on Linux), so you can reverse it later -
even in a new session - with `Undo-Scoot`. It replays the inverse (the asset and its `.meta`
move back together).

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
