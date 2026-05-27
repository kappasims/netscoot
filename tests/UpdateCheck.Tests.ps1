#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'src', 'Netscoot.Core', 'Netscoot.Core.psd1')) -Force
}

Describe 'Test-ScootUpdate' {
    It 'reports an update when the latest tag is newer than the installed version' {
        InModuleScope Netscoot.Core {
            Mock Invoke-RestMethod { @{ tag_name = 'v99.0.0'; html_url = 'https://example/releases/v99.0.0' } }
            $r = Test-ScootUpdate
            $r.UpdateAvailable | Should -BeTrue
            $r.Latest | Should -Be ([version]'99.0.0')
            $r.Tag | Should -Be 'v99.0.0'
        }
    }

    It 'reports up-to-date when the latest tag is not newer' {
        InModuleScope Netscoot.Core {
            Mock Invoke-RestMethod { @{ tag_name = 'v0.0.1'; html_url = 'https://example/releases/v0.0.1' } }
            (Test-ScootUpdate).UpdateAvailable | Should -BeFalse
        }
    }

    It 'writes a non-terminating error (not throw) when the request yields no release' {
        InModuleScope Netscoot.Core {
            # An offline / rate-limited / no-release fetch reduces (via the catch) to no usable
            # response; the cmdlet must report it as a non-terminating error, not throw.
            Mock Invoke-RestMethod { $null }
            Test-ScootUpdate -ErrorVariable err -ErrorAction SilentlyContinue | Out-Null
            ($err.FullyQualifiedErrorId -join ';') | Should -Match 'UpdateCheckFailed'
        }
    }
}

Describe 'Update-Scoot' {
    It 'does nothing (no download) when already up to date' {
        InModuleScope Netscoot.Core {
            Mock Test-ScootUpdate { [pscustomobject]@{ Installed = [version]'1.1.0'; Latest = [version]'1.1.0'; Tag = 'v1.1.0'; UpdateAvailable = $false; Url = '' } }
            Mock Invoke-WebRequest {}
            Update-Scoot | Out-Null
            Should -Invoke Invoke-WebRequest -Times 0
        }
    }

    It 'does not download under -WhatIf even when an update is available' {
        InModuleScope Netscoot.Core {
            Mock Test-ScootUpdate { [pscustomobject]@{ Installed = [version]'1.0.0'; Latest = [version]'1.1.0'; Tag = 'v1.1.0'; UpdateAvailable = $true; Url = '' } }
            Mock Invoke-WebRequest {}
            Update-Scoot -WhatIf | Out-Null
            Should -Invoke Invoke-WebRequest -Times 0
        }
    }
}
