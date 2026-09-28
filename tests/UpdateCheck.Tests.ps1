#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'src', 'Netscoot.Core', 'Netscoot.Core.psd1')) -Force
}

Describe 'Test-NetscootUpdate' {
    It 'reports an update when the latest tag is newer than the installed version' {
        InModuleScope Netscoot.Core {
            Mock Invoke-RestMethod { @{ tag_name = 'v99.0.0'; html_url = 'https://example/releases/v99.0.0' } }
            $r = Test-NetscootUpdate
            $r.UpdateAvailable | Should -BeTrue
            $r.Latest | Should -Be ([version]'99.0.0')
            $r.Tag | Should -Be 'v99.0.0'
        }
    }

    It 'reports up-to-date when the latest tag is not newer' {
        InModuleScope Netscoot.Core {
            Mock Invoke-RestMethod { @{ tag_name = 'v0.0.1'; html_url = 'https://example/releases/v0.0.1' } }
            $r = Test-NetscootUpdate -ErrorAction Stop
            $r.Tag | Should -Be 'v0.0.1'
            $r.UpdateAvailable | Should -BeFalse
        }
    }

    It 'returns a Netscoot.Update record' {
        InModuleScope Netscoot.Core {
            Mock Invoke-RestMethod { @{ tag_name = 'v0.0.1'; html_url = 'https://example/releases/v0.0.1' } }
            (Test-NetscootUpdate).PSObject.TypeNames | Should -Contain 'Netscoot.Update'
        }
    }

    It 'writes a non-terminating error (not throw) when the request yields no release' {
        InModuleScope Netscoot.Core {
            # An offline / rate-limited / no-release fetch reduces (via the catch) to no usable
            # response; the cmdlet must report it as a non-terminating error, not throw.
            Mock Invoke-RestMethod { $null }
            $errs = @(Test-NetscootUpdate -ErrorAction Continue 2>&1 | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
            $errs.Count | Should -Be 1
            $errs[0].FullyQualifiedErrorId | Should -BeLike 'UpdateCheckFailed*'
        }
    }

    It 'requests the /repos/<owner>/<name> release endpoint, not the numeric /repositories/ one (regression)' {
        # The /repositories/ endpoint expects a numeric repo id and 404s for an owner/name string,
        # so every update check failed (the 404 was swallowed into a generic "could not get release").
        # The prior tests mocked Invoke-RestMethod without checking the URI, so the wrong endpoint
        # slipped through. Assert the exact, correct request path here.
        InModuleScope Netscoot.Core {
            Mock Invoke-RestMethod { @{ tag_name = 'v1.0.0'; html_url = 'x' } }
            Test-NetscootUpdate -Repository 'kappasims/netscoot' | Out-Null
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://api.github.com/repos/kappasims/netscoot/releases/latest'
            }
        }
    }
}

Describe 'Update-Netscoot' {
    It 'does nothing (no download) when already up to date' {
        InModuleScope Netscoot.Core {
            Mock Test-NetscootUpdate { [pscustomobject]@{ Installed = [version]'1.1.0'; Latest = [version]'1.1.0'; Tag = 'v1.1.0'; UpdateAvailable = $false; Url = '' } }
            Mock Invoke-WebRequest {}
            Update-Netscoot | Out-Null
            Should -Invoke Test-NetscootUpdate -Times 1 -Exactly
            Should -Invoke Invoke-WebRequest -Times 0
        }
    }

    It 'downloads the release source archive and never install.ps1' {
        InModuleScope Netscoot.Core {
            Mock Test-NetscootUpdate { [pscustomobject]@{ Installed = [version]'1.0.0'; Latest = [version]'1.1.0'; Tag = 'v1.1.0'; UpdateAvailable = $true; Url = '' } }
            Mock New-Item {}
            Mock Remove-Item {}
            Mock Invoke-WebRequest { throw 'stop after the request' }
            { Update-Netscoot -Confirm:$false } | Should -Throw 'stop after the request'
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://github.com/kappasims/netscoot/archive/refs/tags/v1.1.0.zip'
            }
            Should -Invoke Invoke-WebRequest -Times 0 -ParameterFilter { $Uri -like '*install.ps1' }
            Should -Invoke New-Item -Times 1 -Exactly
            Should -Invoke New-Item -Times 1 -Exactly -ParameterFilter { $Path -like '*netscoot_update_*' }
            Should -Invoke Remove-Item -Times 1 -Exactly
            Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter { $LiteralPath -like '*netscoot_update_*' }
        }
    }

    It 'copies only the module folders out of the archive' {
        InModuleScope Netscoot.Core {
            Mock Test-NetscootUpdate { [pscustomobject]@{ Installed = [version]'1.0.0'; Latest = [version]'1.1.0'; Tag = 'v1.1.0'; UpdateAvailable = $true; Url = '' } }
            Mock New-Item {}
            Mock Remove-Item {}
            Mock Invoke-WebRequest {}
            Mock Expand-Archive {}
            Mock Get-ChildItem -ParameterFilter { $LiteralPath -like '*netscoot_update_*' } {
                [pscustomobject]@{ Name = 'netscoot-1.1.0'; FullName = 'nsfake' }
            }
            Mock Get-ChildItem -ParameterFilter { $LiteralPath -eq [System.IO.Path]::Combine('nsfake', 'src') } {
                foreach ($n in 'Netscoot', 'Netscoot.Core', 'skills', '.claude-plugin') {
                    [pscustomobject]@{ Name = $n; FullName = [System.IO.Path]::Combine('nsfake', 'src', $n) }
                }
            }
            Mock Test-Path -ParameterFilter { $LiteralPath -eq [System.IO.Path]::Combine('nsfake', 'src') } { $true }
            Mock Test-Path -ParameterFilter { $LiteralPath -like '*.psd1' } { $LiteralPath -match '[\\/](Netscoot|Netscoot\.Core)\.psd1$' }
            Mock Test-Path -ParameterFilter { $LiteralPath -like '*Modules*' } { $false }
            Mock Copy-Item {}
            Update-Netscoot -Confirm:$false | Out-Null
            Should -Invoke Copy-Item -Times 2 -Exactly
            Should -Invoke Copy-Item -Times 0 -ParameterFilter { $LiteralPath -match 'skills|\.claude-plugin' }
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://github.com/kappasims/netscoot/archive/refs/tags/v1.1.0.zip'
            }
            Should -Invoke Expand-Archive -Times 1 -Exactly -ParameterFilter { $LiteralPath -like '*netscoot_update_*src.zip' }
            Should -Invoke New-Item -Times 2 -Exactly
            Should -Invoke New-Item -Times 1 -Exactly -ParameterFilter { $Path -like '*netscoot_update_*' }
            Should -Invoke New-Item -Times 1 -Exactly -ParameterFilter { $Path -like '*Modules' }
            Should -Invoke Remove-Item -Times 1 -Exactly
            Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter { $LiteralPath -like '*netscoot_update_*' }
        }
    }

    It 'does not download under -WhatIf even when an update is available' {
        InModuleScope Netscoot.Core {
            Mock Test-NetscootUpdate { [pscustomobject]@{ Installed = [version]'1.0.0'; Latest = [version]'1.1.0'; Tag = 'v1.1.0'; UpdateAvailable = $true; Url = '' } }
            Mock Invoke-WebRequest {}
            Update-Netscoot -WhatIf | Out-Null
            Should -Invoke Test-NetscootUpdate -Times 1 -Exactly
            Should -Invoke Invoke-WebRequest -Times 0
        }
    }
}
