#requires -Modules Pester

BeforeAll {
    Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'src', 'DotnetMove.Core', 'DotnetMove.Core.psd1')) -Force
}

Describe 'Test-DotnetMoveUpdate' {
    It 'reports an update when the latest tag is newer than the installed version' {
        InModuleScope DotnetMove.Core {
            Mock Invoke-RestMethod { @{ tag_name = 'v99.0.0'; html_url = 'https://example/releases/v99.0.0' } }
            $r = Test-DotnetMoveUpdate
            $r.UpdateAvailable | Should -BeTrue
            $r.Latest | Should -Be ([version]'99.0.0')
            $r.Tag | Should -Be 'v99.0.0'
        }
    }

    It 'reports up-to-date when the latest tag is not newer' {
        InModuleScope DotnetMove.Core {
            Mock Invoke-RestMethod { @{ tag_name = 'v0.0.1'; html_url = 'https://example/releases/v0.0.1' } }
            (Test-DotnetMoveUpdate).UpdateAvailable | Should -BeFalse
        }
    }

    It 'writes a non-terminating error (not throw) when the request yields no release' {
        InModuleScope DotnetMove.Core {
            # An offline / rate-limited / no-release fetch reduces (via the catch) to no usable
            # response; the cmdlet must report it as a non-terminating error, not throw.
            Mock Invoke-RestMethod { $null }
            Test-DotnetMoveUpdate -ErrorVariable err -ErrorAction SilentlyContinue | Out-Null
            ($err.FullyQualifiedErrorId -join ';') | Should -Match 'UpdateCheckFailed'
        }
    }
}
