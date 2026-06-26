Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Umbrella bootstrap: a single `Import-Module Netscoot` surfaces every engine's cmdlets AS THIS
# module's own. Two distinct mechanisms, on purpose:
#
#   NetscootShared is loaded -Global. The engines declare no RequiredModules, so their functions
#   resolve Shared's helpers (Resolve-FullPath, etc.) at RUNTIME through the global scope. This must
#   stay global - de-globalizing it breaks every command, since the engine functions would no longer
#   find the helpers they call.
#
#   The engines (Core/Unity/Native) are imported NESTED (not -Global) and their functions re-exported
#   here, so `Get-Command -Module Netscoot` owns all 31 cmdlets, (Get-Module Netscoot).ExportedCommands
#   is populated, and the manifest's FunctionsToExport matches what is actually exported (no
#   "exports functions the root module does not define" warning). As nested modules they also unload
#   automatically when `Remove-Module Netscoot` runs - only the -Global Shared needs explicit cleanup
#   (see OnRemove). Native stays conditional (Windows-only, best-effort) precisely because its
#   functions are only re-exported inside the guarded try below - manifest NestedModules would load
#   it unconditionally and fail the whole import on a non-Windows / missing-C++ host.
#
# [IO.Path]::Combine (not multi-arg Join-Path) keeps this loading on Windows PowerShell 5.1.

function script:Test-IsWindowsHost {
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return $true }
    if (Test-Path Variable:\IsWindows) { return [bool](Get-Variable -Name IsWindows -ValueOnly) }
    return $false
}

function script:Resolve-EnginePath {
    # The engine manifest path: bundled single-package layout (a subfolder of this module), then the
    # dev/source layout (a sibling); $null means fall back to importing by module name.
    param([Parameter(Mandatory)][string]$Name)
    $bundled = [System.IO.Path]::Combine($PSScriptRoot, $Name, "$Name.psd1")
    if (Test-Path $bundled) { return $bundled }
    $sibling = [System.IO.Path]::Combine($PSScriptRoot, '..', $Name, "$Name.psd1")
    if (Test-Path $sibling) { return $sibling }
    return $null
}

function script:Import-Engine {
    # Import an engine NESTED (not -Global) and re-export its functions (and any aliases) from this
    # umbrella, so the cmdlets are owned by Netscoot.
    param([Parameter(Mandatory)][string]$Name)
    $path = script:Resolve-EnginePath -Name $Name
    $m = if ($path) { Import-Module $path -Force -PassThru } else { Import-Module $Name -Force -PassThru -ErrorAction Stop }
    $fns = [string[]]@($m.ExportedFunctions.Keys)
    if ($fns.Count) { Export-ModuleMember -Function $fns }
    $aliases = [string[]]@($m.ExportedAliases.Keys)
    if ($aliases.Count) { Export-ModuleMember -Alias $aliases }
}

# Shared FIRST, and -Global: the engine functions resolve its helpers at runtime via the global scope.
$sharedPath = script:Resolve-EnginePath -Name 'NetscootShared'
if ($sharedPath) { Import-Module $sharedPath -Force -Global } else { Import-Module 'NetscootShared' -Force -Global -ErrorAction Stop }

Import-Engine -Name 'Netscoot.Core'
Import-Engine -Name 'Netscoot.Unity'
# Native is capability-based: load it only on Windows, and best-effort - if it fails to load, the
# rest of the toolkit still works (native moves are simply unavailable).
if (Test-IsWindowsHost) {
    try { Import-Engine -Name 'Netscoot.Native' }
    catch { Write-Warning "Netscoot: the native C++ engine (Netscoot.Native) did not load; native (.vcxproj) moves are unavailable. $($_.Exception.Message)" }
}

# The engines are nested, so they unload automatically with this umbrella. NetscootShared is -Global
# (not tied to this module's lifecycle), so clean it up explicitly on removal - otherwise a plain
# `Remove-Module Netscoot` would leave it resident.
$ExecutionContext.SessionState.Module.OnRemove = {
    if (Get-Module -Name NetscootShared) { Remove-Module -Name NetscootShared -Force -ErrorAction SilentlyContinue }
}
