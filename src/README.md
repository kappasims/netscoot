# netscoot

A safer way for your agent to restructure .NET, PowerShell, Unity, and native C++ projects. Instead of
the agent hand-editing solution and project files, netscoot uses each format's own tooling where one
exists and otherwise changes only the paths. A move that fails is rolled back on a best-effort basis.
Its analysis commands (solution consistency, dangling and hardcoded references) and repair commands
(solution sync, broken references, interrupted moves) also work on their own.

This folder is the Claude Code plugin: six skills and the netscoot PowerShell module they load, from the
same release. Full documentation is at <https://github.com/kappasims/netscoot>.

## Requirements

- PowerShell 7.2 or later on Windows, Linux or macOS, or Windows PowerShell 5.1.
- The dotnet CLI for .NET projects. git is optional.
- Native C++ (`.vcxproj`) moves are Windows-only.

The plugin never installs any of these. When one is missing, the skills tell you the install command.

## What it runs, writes and fetches

- **Runs:** the netscoot module from this folder, which calls `git` and `dotnet` in the repository you
  ask it to change.
- **Writes:** the files a move changes in that repository. An undo journal in your per-user data folder
  (`%LOCALAPPDATA%\netscoot` on Windows, `~/Library/Application Support/netscoot` on macOS,
  `~/.local/share/netscoot` on Linux). Snapshots of edited files in the system temp folder, removed when
  the move finishes.
- **Fetches:** nothing by itself. Only when you ask it to check for or install a netscoot update does it
  contact `api.github.com` and `github.com`.

It sends no telemetry and reads no credentials.

## Install and update

```text
/plugin marketplace add kappasims/netscoot
/plugin install netscoot@netscoot
```

Claude Code updates the plugin automatically once you turn on auto-update for the netscoot marketplace
(`/plugin`, **Marketplaces** tab). To update by hand, run `claude plugin update netscoot@netscoot`.

## License

MIT
