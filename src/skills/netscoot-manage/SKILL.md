---
name: netscoot-manage
description: >-
  Use to configure netscoot itself (NOT for moving files): the update policy of an installed netscoot module, the per-user move journal, and the `git netscoot` alias. Triggers on "stop netscoot auto-updating," "disable updates," "set update policy," "what's the update policy," "block netscoot updates for our org," "check for netscoot updates," "update netscoot," "stop journaling moves," "disable the journal," "wipe / clear my undo history," "reset the move journal," "remove the git netscoot alias," "unregister the git verb." For actually moving / restructuring files, use restructure-dotnet / restructure-powershell / restructure-unity / restructure-native, and for analyzing / verifying refactors use netscoot-analyze.
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
| Tell netscoot which dotnet to run when it is not on PATH | `Set-NetscootDotnetPath -Path <path>` |
| Make netscoot forget the stored dotnet path | `Clear-NetscootDotnetPath` |
| Remove the `git netscoot` alias I registered earlier | `Unregister-NetscootGitAlias [-Scope Local\|Global]` |
| Check for or install a newer netscoot release | `Test-NetscootUpdate` / `Update-Netscoot` (Gallery installs: `Update-Module Netscoot`) |

## Update policy

`Get-NetscootUpdatePolicy` returns `{ State; Source; Value }` where:

- `State` is one of `Enabled` / `Manual` / `Disabled`.
- `Source` is `Process` / `User` / `Machine` / `Default`, naming WHERE the policy was set.

`Set-NetscootUpdatePolicy -State Disabled` defaults to `-Scope User`, which blocks updates for the
current user, and `Update-Netscoot -Force` can override it. When an org wants to block self-updates
and centrally pin the version, use `-Scope Machine` in an elevated session, or push
`NETSCOOT_AUTOUPDATE=0` machine-wide through Group Policy / Intune. `-Force` never overrides that.

Installs of 2.6.0 or earlier shipped a broken update endpoint, so their in-box `Test-NetscootUpdate`
and `Update-Netscoot` cannot fetch the fix. Update those once by the install path: `Update-Module
Netscoot` (Gallery) or re-running `install.ps1`.

## Journal (undo history)

The move journal is a per-user, per-repository file in a per-user data directory
(`%LOCALAPPDATA%\netscoot` on Windows, `~/Library/Application Support/netscoot` on macOS,
`$XDG_DATA_HOME/netscoot` or `~/.local/share/netscoot` on Linux). Set the `NETSCOOT_JOURNAL_HOME`
environment variable to relocate the store. `Set-NetscootJournal -Enabled $false` turns journaling off for the current
repository, so later moves are not undoable. Add `-Global` to default it off across every
repository unless re-enabled. A `NETSCOOT_JOURNAL` environment variable, when set, overrides both.
`Clear-NetscootJournal` wipes this repository's journal file. It does NOT reverse any moves, it
only removes the undo record.

## dotnet path

`Set-NetscootDotnetPath -Path <path>` stores the dotnet executable netscoot runs, in `settings.json`
in the same per-user data directory as the journal. The stored path is used ahead of a dotnet on
PATH. `(Get-NetscootCapability).DotnetInstalls` lists the installs to choose from, and
`(Get-NetscootCapability).Dotnet.Source` says whether the one in use is `Stored` or from `Path`.
`Clear-NetscootDotnetPath` removes the stored path. Ask the user which install they want before
storing one.

## Git verb

`git netscoot <src> <dst>` works after `Register-NetscootGitAlias`, and `Unregister-NetscootGitAlias`
removes it. `-Scope Local` (the default) is the current repository's git config, and `Global` is the
user's. Both cmdlets take the same scopes.

## Load the module

Load the netscoot module that ships with this plugin:
`Import-Module "${CLAUDE_PLUGIN_ROOT}/Netscoot/Netscoot.psd1"`. The update policy,
`Test-NetscootUpdate` and `Update-Netscoot` govern the user's own installed module, not this plugin's
copy, which updates with the plugin.
