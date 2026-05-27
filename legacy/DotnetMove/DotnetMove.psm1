Set-StrictMode -Version Latest

# Deprecation pointer. The DotnetMove module was renamed to Netscoot. This package no longer ships
# any functionality of its own; it just prints this notice on import. Install the replacement with
# Install-Module Netscoot and use the Netscoot commands (e.g. Invoke-Netscoot, Move-DotnetProject,
# Undo-Netscoot).
Write-Warning 'DotnetMove has been renamed to Netscoot. Install/import Netscoot instead: Install-Module Netscoot; Import-Module Netscoot. See https://github.com/kappasims/netscoot'
