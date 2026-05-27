#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot TestHelpers.ps1)
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Core' ('Netscoot.Core.psd1'))))) -Force
    $script:PrevAutoUpdate = $env:NETSCOOT_AUTOUPDATE
}

AfterAll {
    if ($null -eq $script:PrevAutoUpdate) { Remove-Item Env:\NETSCOOT_AUTOUPDATE -ErrorAction SilentlyContinue }
    else { $env:NETSCOOT_AUTOUPDATE = $script:PrevAutoUpdate }
}

Describe 'Update policy' {
    # These assert the gates short-circuit BEFORE any network call (so they are safe and fast offline).
    # -Scope Process keeps Set-NetscootUpdatePolicy from persisting to the user/machine environment.

    It 'Get-NetscootUpdatePolicy maps the env value to a State' {
        Remove-Item Env:\NETSCOOT_AUTOUPDATE -ErrorAction SilentlyContinue
        (Get-NetscootUpdatePolicy).State | Should -Be 'Manual'
        $env:NETSCOOT_AUTOUPDATE = 'true';  (Get-NetscootUpdatePolicy).State | Should -Be 'Enabled'
        $env:NETSCOOT_AUTOUPDATE = 'false'; (Get-NetscootUpdatePolicy).State | Should -Be 'Disabled'
    }

    It 'Set-NetscootUpdatePolicy -Scope Process sets the session policy and returns it' {
        (Set-NetscootUpdatePolicy -State Enabled -Scope Process -Confirm:$false).State | Should -Be 'Enabled'
        (Get-NetscootUpdatePolicy).State | Should -Be 'Enabled'
        (Set-NetscootUpdatePolicy -State Manual -Scope Process -Confirm:$false).State | Should -Be 'Manual'
        $env:NETSCOOT_AUTOUPDATE | Should -BeNullOrEmpty
    }

    It 'Test-NetscootUpdate -Auto is a no-op when the policy is Manual (default)' {
        Remove-Item Env:\NETSCOOT_AUTOUPDATE -ErrorAction SilentlyContinue
        Test-NetscootUpdate -Auto | Should -BeNullOrEmpty
    }

    It 'Test-NetscootUpdate -Auto is a no-op when the policy is Disabled' {
        $env:NETSCOOT_AUTOUPDATE = 'false'
        Test-NetscootUpdate -Auto | Should -BeNullOrEmpty
    }

    It 'Update-Netscoot refuses (no network) when the policy is Disabled' {
        $env:NETSCOOT_AUTOUPDATE = 'off'
        $r = Update-Netscoot -WarningVariable warn -WarningAction SilentlyContinue
        $r | Should -BeNullOrEmpty
        ($warn -join "`n") | Should -Match 'disabled by the update policy'
    }

    It 'Update-Netscoot -Force does NOT override a machine-scope (admin) Disabled' {
        # An administrator's GPO/Intune push resolves as Source=Machine; -Force must not defeat it.
        Mock -ModuleName Netscoot.Core Get-NetscootUpdatePolicy {
            [pscustomobject]@{ PSTypeName = 'Netscoot.UpdatePolicy'; State = 'Disabled'; Source = 'Machine'; Value = 'false' }
        }
        $r = Update-Netscoot -Force -WarningVariable warn -WarningAction SilentlyContinue
        $r | Should -BeNullOrEmpty
        ($warn -join "`n") | Should -Match 'administrator'
    }

    It 'Update-Netscoot -Force overrides a user-scope Disabled (gate passes to the check)' {
        # A Disabled the user set for themselves (Source=User) is overridable; the gate should fall
        # through to the version check. Stub the check so no network call happens.
        Mock -ModuleName Netscoot.Core Get-NetscootUpdatePolicy {
            [pscustomobject]@{ PSTypeName = 'Netscoot.UpdatePolicy'; State = 'Disabled'; Source = 'User'; Value = 'false' }
        }
        Mock -ModuleName Netscoot.Core Test-NetscootUpdate { $null }
        Update-Netscoot -Force -WarningAction SilentlyContinue | Out-Null
        Should -Invoke -ModuleName Netscoot.Core Test-NetscootUpdate -Times 1
    }
}
