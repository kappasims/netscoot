# netscoot 3.0 beta (opt-in)

3.0 is a **breaking** release in stress-testing. It is published only as an opt-in prerelease so the
stable line (2.6.x) is unaffected until 3.0 has real-world miles. Everyone on a default install stays
on 2.6.x, and you only get 3.0 by explicitly opting in below.

## What changed in 3.0

- **Five cmdlets were renamed** to carry the `Netscoot` brand noun so they no longer collide with
  generic verbs in a shared session: `Get-SolutionInventory` -> `Get-NetscootSolutionInventory`,
  `Sync-Solution` -> `Sync-NetscootSolution`, `Find-PathReference` -> `Find-NetscootPathReference`,
  `Test-SolutionConsistency` -> `Test-NetscootSolutionConsistency`, `Repair-SolutionReferences` ->
  `Repair-NetscootSolutionReferences`. The old names still work as **deprecated aliases** (they warn
  on use), so existing scripts keep running while you migrate. The aliases are removed in 4.0.
- **Move, inventory and analysis results are now real .NET types** (`Netscoot.MoveResult`, etc.)
  instead of `pscustomobject`. Property access and formatting are unchanged. Only code that tested
  `-is [pscustomobject]` is affected. Journal entries, the update-check record and the tool records
  inside `Get-NetscootCapability` stay `pscustomobject`.
- `Clear-NetscootJournal` now prompts before wiping a repository's undo journal (pass
  `-Confirm:$false` to suppress).
- An update channel, `Set-NetscootUpdateChannel` / `Get-NetscootUpdateChannel`, lets an installer
  install take beta builds through `Update-Netscoot`.

Full detail: [CHANGELOG.md](CHANGELOG.md).

## Opt in

### Module (PowerShell Gallery)

```powershell
Update-Module  Netscoot -AllowPrerelease        # already on 2.6.x: moves to the latest 3.0 beta
Install-Module Netscoot -AllowPrerelease        # new install: gets the latest 3.0 beta
```

Later beta builds arrive through the same `Update-Module Netscoot -AllowPrerelease`. To go back to
stable, remove the beta first, since `Import-Module Netscoot` loads the highest installed version:

```powershell
Uninstall-Module Netscoot -AllVersions
Install-Module Netscoot                         # the latest stable release
```

### Installer or clone installs

After installing a 3.0 build with `install.ps1`, `Set-NetscootUpdateChannel -Channel Beta -Scope User`
keeps the in-product updater (`Update-Netscoot`) on the beta line, so later beta builds are offered as
they ship. `Set-NetscootUpdateChannel -Channel Stable -Scope User` returns you to stable updates. Do
not use `Update-Netscoot` on a Gallery install, because it replaces the module folder with an
installer copy.

### Claude Code plugin (skills, with the renamed cmdlets)

```text
/plugin marketplace add kappasims/netscoot@3.0-beta
/plugin install netscoot@netscoot
```

The `@3.0-beta` ref pins you to the beta branch. To take newer skill versions, run
`claude plugin update netscoot@netscoot` in a shell, or open `/plugin` and choose Update now on the
Installed tab. To go back to stable: `/plugin marketplace remove netscoot`, then
`/plugin marketplace add kappasims/netscoot`.

## Reporting

Please report anything that breaks or surprises you (especially around the renamed cmdlets, piping
result objects, and formatting) on the issue tracker. The point of the beta is to find the rough
edges before 3.0 goes stable.
