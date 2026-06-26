---
name: netscoot-manage
description: Use to configure netscoot itself (NOT for moving files): the auto-update policy, the per-user move journal, and the `git netscoot` alias. Triggers on "stop netscoot auto-updating," "disable updates," "set update policy," "what's the update policy," "block netscoot updates for our org," "stop journaling moves," "disable the journal," "wipe / clear my undo history," "reset the move journal," "remove the git netscoot alias," "unregister the git verb." For actually moving / restructuring files, use restructure-dotnet / restructure-powershell / restructure-unity / restructure-native; for analyzing / verifying refactors use netscoot-analyze.
---

# Netscoot: configure netscoot itself (the toolkit, not the repository)

Purpose (full overview: the [netscoot README](https://github.com/kappasims/netscoot)): the small
admin / config surface for netscoot itself. These cmdlets change netscoot's behavior or wipe its
local state; they do NOT move repository files. For moves use the `restructure-*` skills; for
read-only analysis use `netscoot-analyze`.

## Map a question to the right cmdlet

| Question | Cmdlet |
| --- | --- |
| What is the current auto-update policy and where was it set? | `Get-NetscootUpdatePolicy` |
| Stop / re-enable netscoot's auto-update behavior | `Set-NetscootUpdatePolicy -State Enabled \| Manual \| Disabled` |
| Disable / re-enable the move journal (per-repository or globally) | `Set-NetscootJournal -Enabled $false [-Global]` (or `$true`) |
| Wipe my undo history for this repository | `Clear-NetscootJournal` |
| Remove the `git netscoot` alias I registered earlier | `Unregister-NetscootGitAlias [-Scope Local\|Global\|System]` |
| Force-check or install a newer netscoot release from GitHub | `Test-NetscootUpdate` / `Update-Netscoot` |
| Opt the updater into (or out of) prerelease beta builds | `Set-NetscootUpdateChannel -Channel Beta \| Stable` / `Get-NetscootUpdateChannel` |

## Update policy

`Get-NetscootUpdatePolicy` returns `{ State; Source; Value }` where:

- `State` is one of `Enabled` / `Manual` / `Disabled`.
- `Source` is `Process` / `User` / `Machine` / `Default`, naming WHERE the policy was set
  (env-var > user-scope > machine-scope GPO/Intune > built-in default).

`Set-NetscootUpdatePolicy -State Disabled` is the right call when an org wants to block
self-updates and centrally pin the version. A Machine-scope `Disabled` set by GPO/Intune is
authoritative: `Update-Netscoot -Force` will REFUSE to override it. A user-scope `Disabled` can
be overridden by `-Force` if the user explicitly wants to install anyway.

`Set-NetscootUpdateChannel -Channel Beta` opts the updater into prerelease (beta) builds; `Stable`
(the default) tracks only non-prerelease releases. `Get-NetscootUpdateChannel` reports the resolved
channel and its source (it reads `NETSCOOT_CHANNEL` with the same Process/User/Machine precedence as
the update policy). The channel is orthogonal to the policy: the policy decides whether the updater
runs, the channel decides which releases it offers.

## Journal (undo history)

The move journal is a per-user, per-repository file in a per-user data directory
(`%LOCALAPPDATA%\netscoot` on Windows, `~/Library/Application Support/netscoot` on macOS,
`~/.local/share/netscoot` on Linux); set `$env:NETSCOOT_JOURNAL_HOME` to relocate the store.
`Set-NetscootJournal -Enabled $false` turns journaling off for the current repository (subsequent
moves are not undoable); add `-Global` to default-off across every repository unless re-enabled.
`Clear-NetscootJournal` wipes this repository's journal file (it does NOT reverse any moves; it
just removes the undo record).

## Git verb

`git netscoot <src> <dst>` works after `Register-NetscootGitAlias`; `Unregister-NetscootGitAlias`
removes it. `-Scope Local` is the current repo's git config, `Global` is the user, `System` is
the machine. Symmetrical to Register.

## Use the installed module

`Import-Module Netscoot` if available. If it is not installed, point the user at the
[install steps](https://github.com/kappasims/netscoot); never auto-install.
