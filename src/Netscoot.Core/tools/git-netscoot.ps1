#!/usr/bin/env pwsh
# Forwarder for the opt-in `git netscoot` alias. Git appends the user's args, so this is
# invoked as: pwsh -NoProfile -File git-netscoot.ps1 <src> <dst> [--whatif] [--force] [--nobuild]
#
# This only adapts git-style args to PowerShell and hands off to Invoke-Netscoot, the top-level
# cmdlet that branches by detected type to each engine (the .NET project model, PowerShell,
# Unity, or native C++). All routing lives in that tested cmdlet; this never edits PATH or git
# config itself.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Netscoot.Core (which exports Invoke-Netscoot) is always required.
if (-not (Get-Command Invoke-Netscoot -ErrorAction SilentlyContinue)) {
    $coreManifest = [System.IO.Path]::Combine($PSScriptRoot, '..', 'Netscoot.Core.psd1')
    if (Test-Path -LiteralPath $coreManifest) {
        # Running from a clone: the sibling Shared module is not on the module path, so load it by
        # path first (Core calls its helpers but declares no RequiredModules), then Core. When
        # installed, the else branch imports by name and PowerShell auto-loads Shared on first use.
        $sharedManifest = [System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'Netscoot.Shared', 'Netscoot.Shared.psd1')
        if (Test-Path -LiteralPath $sharedManifest) { Import-Module $sharedManifest -Force }
        Import-Module $coreManifest -Force
    } else {
        Import-Module Netscoot.Core -ErrorAction Stop
    }
}

# Parse git-style args: first two non-flag tokens are source/destination.
$rest = @(); $whatIf = $false; $force = $false; $noBuild = $false
foreach ($a in $args) {
    switch -regex ($a) {
        '^--whatif$'  { $whatIf = $true; continue }
        '^--force$'   { $force = $true; continue }
        '^--nobuild$' { $noBuild = $true; continue }
        default       { $rest += $a }
    }
}
if ($rest.Count -lt 2) {
    Write-Host 'usage: git netscoot <source> <destination> [--whatif] [--force] [--nobuild]' -ForegroundColor Red
    exit 2
}
$src = $rest[0]; $dst = $rest[1]

# `!`-aliases run at the repository top-level with GIT_PREFIX = the subdir the user invoked from;
# resolve relative args against it so paths mean what the user typed.
if ($env:GIT_PREFIX) {
    if (-not [System.IO.Path]::IsPathRooted($src)) { $src = Join-Path $env:GIT_PREFIX $src }
    if (-not [System.IO.Path]::IsPathRooted($dst)) { $dst = Join-Path $env:GIT_PREFIX $dst }
}

$params = @{ Path = $src; Destination = $dst; WhatIf = $whatIf; Confirm = $false }
if ($force) { $params.Force = $true }
if ($noBuild) { $params.NoBuild = $true }
# Let Invoke-Netscoot derive the repository root from the target path. Do NOT use
# `git rev-parse --show-toplevel`: git canonicalizes symlinks (on macOS the temp/repository path
# /var/folders/... becomes /private/var/folders/...), which would not match the OS-form paths the
# rest of the toolkit uses (Get-ChildItem, Get-RepositoryRoot), breaking path comparisons on a repository that
# sits under a symlinked directory.

Invoke-Netscoot @params
