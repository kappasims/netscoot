Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Umbrella bootstrap: a single `Import-Module DotnetMove` surfaces every engine's cmdlets.
# We import the siblings -Global rather than via RequiredModules because the native engine is
# Windows-only - a hard RequiredModules entry would fail to install/load on Linux/macOS. So we
# always load the cross-platform engines and add native only on Windows.
# [IO.Path]::Combine (not multi-arg Join-Path) keeps this loading on Windows PowerShell 5.1.

function script:Test-IsWindowsHost {
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return $true }
    if (Test-Path Variable:\IsWindows) { return [bool](Get-Variable -Name IsWindows -ValueOnly) }
    return $false
}

function script:Import-EngineSibling {
    # Prefer an installed module by name; else the sibling source manifest next to this one.
    param([Parameter(Mandatory)][string]$Name)
    $manifest = [System.IO.Path]::Combine($PSScriptRoot, '..', $Name, "$Name.psd1")
    if (Test-Path $manifest) { Import-Module $manifest -Force -Global }
    else { Import-Module $Name -Force -Global -ErrorAction Stop }
}

# Shared first: the engines declare it in RequiredModules, so it must be loadable when they import.
Import-EngineSibling -Name 'DotnetMove.Shared'
Import-EngineSibling -Name 'DotnetMove.Core'
Import-EngineSibling -Name 'DotnetMove.Unity'
if (Test-IsWindowsHost) { Import-EngineSibling -Name 'DotnetMove.Native' }
