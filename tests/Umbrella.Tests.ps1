#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    # Start from a clean module state so this verifies what the UMBRELLA loads, not what an
    # earlier test file left imported (e.g. DotnetMove.Native, which loads on any OS and would
    # otherwise make the non-Windows "native absent" assertion fail).
    Remove-Module DotnetMove, DotnetMove.Core, DotnetMove.Unity, DotnetMove.Native -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'DotnetMove' ('DotnetMove.psd1'))))) -Force

    function Test-IsWindowsHost {
        if ($PSVersionTable.PSEdition -eq 'Desktop') { return $true }
        if (Test-Path Variable:\IsWindows) { return [bool](Get-Variable -Name IsWindows -ValueOnly) }
        return $false
    }
}

Describe 'DotnetMove umbrella' {
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
}

AfterAll {
    Remove-Module DotnetMove, DotnetMove.Core, DotnetMove.Unity, DotnetMove.Native -Force -ErrorAction SilentlyContinue
}
