#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot TestHelpers.ps1)
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Core' ('Netscoot.Core.psd1'))))) -Force

    $script:RealDotnet = (Get-Command dotnet -CommandType Application | Select-Object -First 1).Source

    function Get-MoveError {
        @(Move-DotnetProject -Project 'X:/nope/Foo.csproj' -Destination 'X:/dst' @args `
                -ErrorAction Continue 2>&1 | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
    }
}

Describe 'Resolve-DotnetCommand' {
    It 'uses the stored path ahead of the dotnet on PATH' {
        Mock -ModuleName NetscootShared Get-StoredDotnetPath { $script:RealDotnet }
        $resolved = Resolve-DotnetCommand
        $resolved.Source | Should -Be 'Stored'
        $resolved.Path | Should -Be $script:RealDotnet
    }

    It 'uses the dotnet on PATH when no path is stored' {
        Mock -ModuleName NetscootShared Get-StoredDotnetPath { $null }
        (Resolve-DotnetCommand).Source | Should -Be 'Path'
    }

    It 'throws naming the stored path when that file is gone' {
        Mock -ModuleName NetscootShared Get-StoredDotnetPath { 'X:\gone\dotnet.exe' }
        { Resolve-DotnetCommand } | Should -Throw '*X:\gone\dotnet.exe*'
    }
}

Describe 'First-time setup when dotnet is missing' {
    BeforeEach {
        Mock -ModuleName NetscootShared Test-DotnetAvailable { $false }
        Mock -ModuleName NetscootShared Write-CapabilityGuidance { }
        Mock -ModuleName NetscootShared Save-StoredDotnetPath { }
        Mock -ModuleName NetscootShared Find-DotnetInstall {
            [pscustomobject]@{ Version = '10.0.100'; Path = 'C:\sdk\dotnet.exe'; FoundIn = 'DefaultFolder' }
        }
    }

    It 'stops with the missing-dotnet error when nobody can answer a question' {
        Mock -ModuleName NetscootShared Test-InteractiveSession { $false }
        Mock -ModuleName NetscootShared Read-DotnetInstallChoice { }
        $errs = Get-MoveError
        $errs[0].FullyQualifiedErrorId | Should -BeLike 'DotnetMissing*'
        Should -Invoke -ModuleName NetscootShared Read-DotnetInstallChoice -Times 0 -Exactly
        Should -Invoke -ModuleName NetscootShared Save-StoredDotnetPath -Times 0 -Exactly
    }

    It 'passes the installs it found to the guidance' {
        Mock -ModuleName NetscootShared Test-InteractiveSession { $false }
        Get-MoveError | Out-Null
        Should -Invoke -ModuleName NetscootShared Write-CapabilityGuidance -Times 1 -Exactly -ParameterFilter {
            $Tool -eq 'dotnet' -and $Installs[0].Path -eq 'C:\sdk\dotnet.exe'
        }
    }

    It 'stores the chosen install and lets the command continue' {
        Mock -ModuleName NetscootShared Test-InteractiveSession { $true }
        Mock -ModuleName NetscootShared Read-DotnetInstallChoice { $Installs[0] }
        $errs = Get-MoveError
        Should -Invoke -ModuleName NetscootShared Save-StoredDotnetPath -Times 1 -Exactly -ParameterFilter { $Path -eq 'C:\sdk\dotnet.exe' }
        @($errs | Where-Object { $_.FullyQualifiedErrorId -like 'DotnetMissing*' }).Count | Should -Be 0
    }

    It 'stores nothing and stops when the person declines' {
        Mock -ModuleName NetscootShared Test-InteractiveSession { $true }
        Mock -ModuleName NetscootShared Read-DotnetInstallChoice { $null }
        $errs = Get-MoveError
        $errs[0].FullyQualifiedErrorId | Should -BeLike 'DotnetMissing*'
        Should -Invoke -ModuleName NetscootShared Save-StoredDotnetPath -Times 0 -Exactly
    }

    It 'does not ask or store under -WhatIf' {
        Mock -ModuleName NetscootShared Test-InteractiveSession { $true }
        Mock -ModuleName NetscootShared Read-DotnetInstallChoice { $Installs[0] }
        $errs = Get-MoveError -WhatIf
        $errs[0].FullyQualifiedErrorId | Should -BeLike 'DotnetMissing*'
        Should -Invoke -ModuleName NetscootShared Read-DotnetInstallChoice -Times 0 -Exactly
        Should -Invoke -ModuleName NetscootShared Save-StoredDotnetPath -Times 0 -Exactly
    }
}

Describe 'Set-NetscootDotnetPath validation' {
    It 'refuses a path with no file and stores nothing' {
        Mock -ModuleName Netscoot.Core Save-StoredDotnetPath { }
        $errs = @(Set-NetscootDotnetPath -Path 'X:/nope/dotnet.exe' -ErrorAction Continue 2>&1)
        $errs[0].FullyQualifiedErrorId | Should -BeLike 'DotnetPathNotFound*'
        Should -Invoke -ModuleName Netscoot.Core Save-StoredDotnetPath -Times 0 -Exactly
    }

    It 'refuses an executable that reports no SDK version' {
        Mock -ModuleName Netscoot.Core Save-StoredDotnetPath { }
        Mock -ModuleName Netscoot.Core Get-ExternalToolVersion { $null }
        $errs = @(Set-NetscootDotnetPath -Path $script:RealDotnet -ErrorAction Continue 2>&1)
        $errs[0].FullyQualifiedErrorId | Should -BeLike 'DotnetPathHasNoSdk*'
        Should -Invoke -ModuleName Netscoot.Core Save-StoredDotnetPath -Times 0 -Exactly
    }

    It 'stores nothing under -WhatIf' {
        Mock -ModuleName Netscoot.Core Save-StoredDotnetPath { }
        Set-NetscootDotnetPath -Path $script:RealDotnet -WhatIf
        Should -Invoke -ModuleName Netscoot.Core Save-StoredDotnetPath -Times 0 -Exactly
    }
}

Describe 'The stored dotnet path on disk' -Tag 'Integration' {
    AfterEach {
        Clear-NetscootDotnetPath -Confirm:$false 6>$null
    }

    It 'is reported by Get-NetscootCapability after Set-NetscootDotnetPath' {
        Set-NetscootDotnetPath -Path $script:RealDotnet -Confirm:$false 6>$null
        $dotnet = (Get-NetscootCapability).Dotnet
        $dotnet.Source | Should -Be 'Stored'
        $dotnet.Path | Should -Be $script:RealDotnet
    }

    It 'is gone after Clear-NetscootDotnetPath' {
        Set-NetscootDotnetPath -Path $script:RealDotnet -Confirm:$false 6>$null
        Clear-NetscootDotnetPath -Confirm:$false 6>$null
        Get-StoredDotnetPath | Should -BeNullOrEmpty
        (Get-NetscootCapability).Dotnet.Source | Should -Be 'Path'
    }

    It 'lists the install that is on PATH among the installs found' {
        $found = @((Get-NetscootCapability).DotnetInstalls | ForEach-Object Path)
        $found | Should -Contain $script:RealDotnet
    }
}
