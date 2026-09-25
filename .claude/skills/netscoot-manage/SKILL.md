---
name: netscoot-manage
description: Use to configure netscoot itself (NOT for moving files): the auto-update policy and update channel, the per-user move journal, and the `git netscoot` alias. Triggers on "stop netscoot auto-updating," "disable updates," "set update policy," "what's the update policy," "block netscoot updates for our org," "check for netscoot updates," "update netscoot," "opt into netscoot betas," "switch the update channel," "stop journaling moves," "disable the journal," "wipe / clear my undo history," "reset the move journal," "remove the git netscoot alias," "unregister the git verb." For actually moving / restructuring files, use restructure-dotnet / restructure-powershell / restructure-unity / restructure-native, and for analyzing / verifying refactors use netscoot-analyze.
---

# Netscoot: configure netscoot itself (the toolkit, not the repository)

Purpose (full overview: the [netscoot README](https://github.com/kappasims/netscoot)): the small
admin / config surface for netscoot itself. These cmdlets change netscoot's behavior or wipe its
local state. They do NOT move repository files. For moves use the `restructure-*` skills, and for
read-only analysis use `netscoot-analyze`.

## Map a question to the right cmdlet

| Question | Cmdlet |
| --- | --- |
| What is the current auto-update policy and where was it set? | `Get-NetscootUpdatePolicy` |
| Stop / re-enable netscoot's auto-update behavior | `Set-NetscootUpdatePolicy -State Enabled \| Manual \| Disabled` |
| Disable / re-enable the move journal (per-repository or globally) | `Set-NetscootJournal -Enabled $false [-Global]` (or `$true`) |
| Wipe my undo history for this repository | `Clear-NetscootJournal` |
| Remove the `git netscoot` alias I registered earlier | `Unregister-NetscootGitAlias [-Scope Local\|Global]` |
| Check for or install a newer netscoot release | `Test-NetscootUpdate` / `Update-Netscoot` (Gallery installs: `Update-Module Netscoot`) |
| Opt the updater into (or out of) prerelease beta builds | `Set-NetscootUpdateChannel -Channel Beta \| Stable -Scope User` / `Get-NetscootUpdateChannel` |

## Update policy

`Get-NetscootUpdatePolicy` returns `{ State; Source; Value }` where:

- `State` is one of `Enabled` / `Manual` / `Disabled`.
- `Source` is `Process` / `User` / `Machine` / `Default`, naming WHERE the policy was set.

`Set-NetscootUpdatePolicy -State Disabled` defaults to `-Scope User`, which blocks updates for the
current user, and `Update-Netscoot -Force` can override it. When an org wants to block self-updates
and centrally pin the version, use `-Scope Machine` in an elevated session, or push
`NETSCOOT_AUTOUPDATE=0` machine-wide through Group Policy / Intune. `-Force` never overrides that.

`Set-NetscootUpdateChannel -Channel Beta` opts the updater into prerelease (beta) builds, and
`Stable` (the default) tracks only non-prerelease releases. Its default scope is `Process`, and each
agent shell call is a new process, so pass `-Scope User` to make it stick (Windows), or add the
printed `export` line to the shell profile (Linux, macOS). Switch back at the same scope.
`Get-NetscootUpdateChannel` reports the resolved channel and its source (it reads
`NETSCOOT_CHANNEL` with the same Process/User/Machine precedence as the update policy). The policy
decides whether the updater runs, and the channel decides which releases it offers. A Gallery
install takes betas through `Update-Module Netscoot -AllowPrerelease` instead, since
`Update-Netscoot` replaces the module folder with an installer copy.

Installs of 2.6.0 or earlier shipped a broken update endpoint, so their in-box `Test-NetscootUpdate`
and `Update-Netscoot` cannot fetch the fix. Update those once by the install path: `Update-Module
Netscoot` (Gallery), `git pull` then `./build.ps1 -Task Install` (clone), or re-running `install.ps1`.

## Journal (undo history)

The move journal is a per-user, per-repository file in a per-user data directory
(`%LOCALAPPDATA%\netscoot` on Windows, `~/Library/Application Support/netscoot` on macOS,
`$XDG_DATA_HOME/netscoot` or `~/.local/share/netscoot` on Linux). Set `$env:NETSCOOT_JOURNAL_HOME`
to relocate the store. `Set-NetscootJournal -Enabled $false` turns journaling off for the current
repository, so later moves are not undoable. Add `-Global` to default it off across every
repository unless re-enabled. A `NETSCOOT_JOURNAL` environment variable, when set, overrides both.
`Clear-NetscootJournal` wipes this repository's journal file. It does NOT reverse any moves, it
only removes the undo record.

## Git verb

`git netscoot <src> <dst>` works after `Register-NetscootGitAlias`, and `Unregister-NetscootGitAlias`
removes it. `-Scope Local` (the default) is the current repository's git config, and `Global` is the
user's. Both cmdlets take the same scopes.

## Use the installed module

`Import-Module Netscoot` if available. If it is not installed, point the user at the
[install steps](https://github.com/kappasims/netscoot). Never auto-install.
