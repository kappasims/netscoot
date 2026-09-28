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
#   (see OnRemove). Native stays conditional (Windows-only) because it is imported only behind the
#   platform check below. Manifest NestedModules would load it on every host.
#
# [IO.Path]::Combine (not multi-arg Join-Path) keeps this loading on Windows PowerShell 5.1.

function script:Test-IsWindowsHost {
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return $true }
    if (Test-Path Variable:\IsWindows) { return [bool](Get-Variable -Name IsWindows -ValueOnly) }
    return $false
}

function script:Resolve-EnginePath {
    # The engine manifest path: bundled single-package layout (a subfolder of this module), then the
    # dev/source layout (a sibling).
    param([Parameter(Mandatory)][string]$Name)
    $bundled = [System.IO.Path]::Combine($PSScriptRoot, $Name, "$Name.psd1")
    if (Test-Path $bundled) { return $bundled }
    $sibling = [System.IO.Path]::Combine($PSScriptRoot, '..', $Name, "$Name.psd1")
    if (Test-Path $sibling) { return $sibling }
    throw "Netscoot: the $Name module was not found at $bundled or $sibling."
}

function script:Import-Engine {
    # Import an engine NESTED (not -Global) and re-export its functions (and any aliases) from this
    # umbrella, so the cmdlets are owned by Netscoot.
    param([Parameter(Mandatory)][string]$Name)
    $m = Import-Module (script:Resolve-EnginePath -Name $Name) -Force -PassThru
    $fns = [string[]]@($m.ExportedFunctions.Keys)
    if ($fns.Count) { Export-ModuleMember -Function $fns }
    $aliases = [string[]]@($m.ExportedAliases.Keys)
    if ($aliases.Count) { Export-ModuleMember -Alias $aliases }
}

# Shared FIRST, and -Global: the engine functions resolve its helpers at runtime via the global scope.
Import-Module (script:Resolve-EnginePath -Name 'NetscootShared') -Force -Global

Import-Engine -Name 'Netscoot.Core'
Import-Engine -Name 'Netscoot.Unity'
# Native moves are Windows-only, so the native engine loads only on Windows.
if (Test-IsWindowsHost) { Import-Engine -Name 'Netscoot.Native' }

# The engines are nested, so they unload automatically with this umbrella. NetscootShared is -Global
# (not tied to this module's lifecycle), so clean it up explicitly on removal - otherwise a plain
# `Remove-Module Netscoot` would leave it resident.
$ExecutionContext.SessionState.Module.OnRemove = {
    if (Get-Module -Name NetscootShared) {
        try { Remove-Module -Name NetscootShared -Force -ErrorAction Stop }
        catch { Write-Warning "Could not unload NetscootShared: $($_.Exception.Message)" }
    }
}
