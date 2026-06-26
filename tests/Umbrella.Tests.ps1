#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    # Start from a clean module state so this verifies what the UMBRELLA loads, not what an
    # earlier test file left imported (e.g. Netscoot.Native, which loads on any OS and would
    # otherwise make the non-Windows "native absent" assertion fail).
    Remove-Module Netscoot, Netscoot.Core, Netscoot.Unity, Netscoot.Native -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot' ('Netscoot.psd1'))))) -Force

    function Test-IsWindowsHost {
        if ($PSVersionTable.PSEdition -eq 'Desktop') { return $true }
        if (Test-Path Variable:\IsWindows) { return [bool](Get-Variable -Name IsWindows -ValueOnly) }
        return $false
    }
}

Describe 'Netscoot umbrella' {
    It 'surfaces the core engine cmdlets' {
        Get-Command Move-DotnetProject -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Resolve-MoveEngine -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'surfaces the Unity engine cmdlet' {
        Get-Command Move-UnityAsset -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'surfaces the native engine cmdlet on Windows only' {
        if (Test-IsWindowsHost) {
            Get-Command Move-NativeProject -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        } else {
            Get-Command Move-NativeProject -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }
    }

    It 'OWNS its cmdlets - Get-Command -Module Netscoot and ExportedCommands are populated (regression)' {
        # Before the re-export fix the umbrella loaded the engines -Global, so the cmdlets were owned
        # by the engine modules: Get-Command -Module Netscoot returned nothing and
        # (Get-Module Netscoot).ExportedCommands was empty even though the cmdlets resolved. Now the
        # engines are imported nested and their functions are re-exported, so Netscoot owns them.
        @(Get-Command -Module Netscoot -CommandType Function).Count | Should -BeGreaterThan 0
        (Get-Module Netscoot).ExportedCommands.Count | Should -BeGreaterThan 0
        (Get-Command Get-SolutionInventory).Source | Should -Be 'Netscoot'
        (Get-Command Move-DotnetProject).Source | Should -Be 'Netscoot'
    }

    It 'still resolves NetscootShared helpers at runtime (NetscootShared stays -Global)' {
        # The engines declare no RequiredModules and call Shared's helpers (Resolve-FullPath, etc.)
        # via the global scope. De-globalizing Shared would break this; guard that it still works.
        { Resolve-MoveEngine -Path './a/b.csproj' } | Should -Not -Throw
        Resolve-MoveEngine -Path './a/b.csproj' | Should -Be 'dotnet'
    }

    It 'Remove-Module Netscoot unloads the engines and NetscootShared (no residual)' {
        Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot' ('Netscoot.psd1'))))) -Force
        Remove-Module Netscoot -Force
        @(Get-Module | Where-Object { $_.Name -match 'Netscoot' }) | Should -BeNullOrEmpty
        # Re-import so AfterAll and any later assertions in this file have the module available.
        Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot' ('Netscoot.psd1'))))) -Force
    }
}

AfterAll {
    Remove-Module Netscoot, Netscoot.Core, Netscoot.Unity, Netscoot.Native -Force -ErrorAction SilentlyContinue
}
