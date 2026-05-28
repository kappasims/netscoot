Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Umbrella bootstrap: a single `Import-Module Netscoot` surfaces every engine's cmdlets. Shipped
# as one package that bundles Shared + the engines; we import them -Global here (no RequiredModules)
# so the Windows-only native engine can be loaded conditionally and best-effort.
# [IO.Path]::Combine (not multi-arg Join-Path) keeps this loading on Windows PowerShell 5.1.

function script:Test-IsWindowsHost {
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return $true }
    if (Test-Path Variable:\IsWindows) { return [bool](Get-Variable -Name IsWindows -ValueOnly) }
    return $false
}

function script:Import-Engine {
    # Find the engine in the bundled single-package layout (a subfolder of this module), then the
    # dev/source layout (a sibling), then an installed module by name.
    param([Parameter(Mandatory)][string]$Name)
    $bundled = [System.IO.Path]::Combine($PSScriptRoot, $Name, "$Name.psd1")
    $sibling = [System.IO.Path]::Combine($PSScriptRoot, '..', $Name, "$Name.psd1")
    if (Test-Path $bundled) { Import-Module $bundled -Force -Global }
    elseif (Test-Path $sibling) { Import-Module $sibling -Force -Global }
    else { Import-Module $Name -Force -Global -ErrorAction Stop }
}

# Shared first: the engines call its helpers (loaded -Global so module functions resolve them).
Import-Engine -Name 'Netscoot.Shared'
Import-Engine -Name 'Netscoot.Core'
Import-Engine -Name 'Netscoot.Unity'
# Native is capability-based: load it only on Windows, and best-effort - if it fails to load, the
# rest of the toolkit still works (native moves are simply unavailable).
if (Test-IsWindowsHost) {
    try { Import-Engine -Name 'Netscoot.Native' }
    catch { Write-Warning "Netscoot: the native C++ engine (Netscoot.Native) did not load; native (.vcxproj) moves are unavailable. $($_.Exception.Message)" }
}

# Unload the nested engines when this umbrella module is removed. We imported them -Global, so a
# plain `Remove-Module Netscoot` would otherwise leave them resident (half-removed state); walking
# them here lets `Remove-Module Netscoot` actually clean up everything we brought in.
$ExecutionContext.SessionState.Module.OnRemove = {
    foreach ($e in 'Netscoot.Native', 'Netscoot.Unity', 'Netscoot.Core', 'Netscoot.Shared') {
        if (Get-Module -Name $e) { Remove-Module -Name $e -Force -ErrorAction SilentlyContinue }
    }
}
