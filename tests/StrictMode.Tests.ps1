#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Core' ('Netscoot.Core.psd1'))))) -Force
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Native' ('Netscoot.Native.psd1'))))) -Force
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Unity' ('Netscoot.Unity.psd1'))))) -Force
}

Describe 'StrictMode is enforced in every module' {
    # Guards against anyone removing Set-StrictMode -Version Latest from a module loader:
    # accessing an undefined variable inside the module scope must throw.
    It '<Module> runs its code under StrictMode' -ForEach @(
        @{ Module = 'Netscoot.Shared' }
        @{ Module = 'Netscoot.Core' }
        @{ Module = 'Netscoot.Native' }
        @{ Module = 'Netscoot.Unity' }
    ) {
        { InModuleScope $Module { $__definitely_not_a_real_variable__ } } |
            Should -Throw -ExpectedMessage '*has not been set*'
    }
}
