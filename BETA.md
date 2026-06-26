# netscoot 3.0 beta (opt-in)

3.0 is a **breaking** release in stress-testing. It is published only as an opt-in prerelease so the
stable line (2.6.x) is unaffected until 3.0 has real-world miles. Everyone on a default install stays
on 2.6.x; you only get 3.0 by explicitly opting in below.

## What changed in 3.0

- **Five cmdlets were renamed** to carry the `Netscoot` brand noun so they no longer collide with
  generic verbs in a shared session: `Get-SolutionInventory` -> `Get-NetscootSolutionInventory`,
  `Sync-Solution` -> `Sync-NetscootSolution`, `Find-PathReference` -> `Find-NetscootPathReference`,
  `Test-SolutionConsistency` -> `Test-NetscootSolutionConsistency`, `Repair-SolutionReferences` ->
  `Repair-NetscootSolutionReferences`. The old names still work as **deprecated aliases** (they warn
  on use), so existing scripts keep running while you migrate.
- **Result and report objects are now real .NET types** (`Netscoot.MoveResult`, etc.) instead of
  `pscustomobject`. Property access and formatting are unchanged; only code that tested
  `-is [pscustomobject]` is affected.
- `Clear-NetscootJournal` now prompts before wiping a repository's undo journal (pass
  `-Confirm:$false` to suppress).

Full detail: [CHANGELOG.md](CHANGELOG.md).

## Opt in

### Module (PowerShell Gallery)

```powershell
Install-Module Netscoot -AllowPrerelease       # gets 3.0.0-beta; default installs stay on 2.6.x
Update-Module  Netscoot -AllowPrerelease        # later beta builds
```

To go back to stable: `Install-Module Netscoot -Force` (installs the latest non-prerelease).

Once you are on a 3.0 build, `Set-NetscootUpdateChannel Beta` keeps the in-product updater
(`Update-Netscoot`) on the beta line, so later beta builds are offered as they ship.
`Set-NetscootUpdateChannel Stable` returns you to stable updates.

### Claude Code plugin (skills, with the renamed cmdlets)

```text
/plugin marketplace add kappasims/netscoot@3.0-beta
/plugin install netscoot@netscoot
/plugin update netscoot
```

The `@3.0-beta` ref pins you to the beta branch; `/plugin update` keeps you on it. To go back to
stable: `/plugin marketplace remove netscoot`, then `/plugin marketplace add kappasims/netscoot`.

## Reporting

Please report anything that breaks or surprises you (especially around the renamed cmdlets, piping
result objects, and formatting) on the issue tracker. The point of the beta is to find the rough
edges before 3.0 goes stable.
