#requires -Modules Pester

# Guards the umbrella Netscoot.psd1's declared public surface against drift. Background:
#   - Adding/removing public cmdlets in the engines while forgetting the umbrella manifest used to
#     ship silently: the cmdlet worked at runtime (the engines own the export, loaded -Global),
#     but the Gallery (which indexes the manifest, not the runtime) didn't list it by name. 2.2.0
#     shipped that way for Get-NetscootUpdatePolicy / Set-NetscootUpdatePolicy / Repair-NetscootJournal
#     until this gate landed.
# The contract: Netscoot.psd1's FunctionsToExport must equal the UNION of the public engines'
# FunctionsToExport (Core + Unity + Native; Shared is internal plumbing, intentionally excluded).
# Same for AliasesToExport.
# Parsed from the .psd1 files on disk (Import-PowerShellDataFile), so the assertion holds on every
# OS regardless of which engines actually load (Native is Windows-only at runtime).

BeforeAll {
    $script:repo = Resolve-Path (Join-Path $PSScriptRoot '..')
    function Read-ManifestField {
        param([Parameter(Mandatory)][string]$Module, [Parameter(Mandatory)][string]$Field)
        $psd = Join-Path $script:repo (Join-Path 'src' (Join-Path $Module "$Module.psd1"))
        $data = Import-PowerShellDataFile -LiteralPath $psd
        return @($data[$Field])
    }
}

Describe 'Umbrella manifest declares exactly what the public engines export' {
    BeforeAll {
        $script:publicEngines = @('Netscoot.Core', 'Netscoot.Unity', 'Netscoot.Native')
        $script:umbrellaFns   = @(Read-ManifestField -Module 'Netscoot' -Field 'FunctionsToExport') | Sort-Object
        $script:umbrellaAls   = @(Read-ManifestField -Module 'Netscoot' -Field 'AliasesToExport')   | Sort-Object
        $script:engineFns = @($publicEngines | ForEach-Object { Read-ManifestField -Module $_ -Field 'FunctionsToExport' }) | Sort-Object -Unique
        $script:engineAls = @($publicEngines | ForEach-Object { Read-ManifestField -Module $_ -Field 'AliasesToExport'   }) | Where-Object { $_ } | Sort-Object -Unique
    }

    It 'umbrella FunctionsToExport equals the union of the public engines' {
        $missing = @(Compare-Object $script:umbrellaFns $script:engineFns | Where-Object SideIndicator -eq '=>' | ForEach-Object InputObject)
        $extra   = @(Compare-Object $script:umbrellaFns $script:engineFns | Where-Object SideIndicator -eq '<=' | ForEach-Object InputObject)
        $missing.Count | Should -Be 0 -Because "the umbrella manifest is missing engine functions: $($missing -join ', ')"
        $extra.Count   | Should -Be 0 -Because "the umbrella manifest lists functions no engine exports: $($extra -join ', ')"
    }

    It 'umbrella AliasesToExport equals the union of the public engines' {
        $missing = @(Compare-Object $script:umbrellaAls $script:engineAls | Where-Object SideIndicator -eq '=>' | ForEach-Object InputObject)
        $extra   = @(Compare-Object $script:umbrellaAls $script:engineAls | Where-Object SideIndicator -eq '<=' | ForEach-Object InputObject)
        $missing.Count | Should -Be 0 -Because "the umbrella manifest is missing engine aliases: $($missing -join ', ')"
        $extra.Count   | Should -Be 0 -Because "the umbrella manifest lists aliases no engine exports: $($extra -join ', ')"
    }

    It 'Netscoot.Shared functions are NOT in the umbrella surface (internal plumbing only)' {
        # Captures the "Shared is internal" rule explicitly so a future maintainer who adds a Shared
        # name to Netscoot.psd1 trips the gate. Engines see Shared because we Import-Module -Global,
        # but it must not be advertised on the Gallery.
        $sharedFns = @(Read-ManifestField -Module 'Netscoot.Shared' -Field 'FunctionsToExport')
        $overlap = @($sharedFns | Where-Object { $script:umbrellaFns -contains $_ })
        $overlap.Count | Should -Be 0 -Because "the umbrella manifest lists Shared (internal) functions: $($overlap -join ', ')"
    }
}
