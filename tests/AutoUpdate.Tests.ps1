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

Describe 'Auto-update gating' {
    # These assert the gates short-circuit BEFORE any network call (so they are safe and fast offline).

    It 'Test-NetscootUpdate -EnableAutoUpdate is a no-op when NETSCOOT_AUTOUPDATE is unset' {
        Remove-Item Env:\NETSCOOT_AUTOUPDATE -ErrorAction SilentlyContinue
        $r = Test-NetscootUpdate -EnableAutoUpdate
        $r | Should -BeNullOrEmpty
    }

    It 'Test-NetscootUpdate -EnableAutoUpdate is a no-op when NETSCOOT_AUTOUPDATE is off' {
        $env:NETSCOOT_AUTOUPDATE = 'false'
        $r = Test-NetscootUpdate -EnableAutoUpdate
        $r | Should -BeNullOrEmpty
    }

    It 'Update-Netscoot refuses (no network) when NETSCOOT_AUTOUPDATE is off' {
        $env:NETSCOOT_AUTOUPDATE = 'off'
        $r = Update-Netscoot -WarningVariable warn -WarningAction SilentlyContinue
        $r | Should -BeNullOrEmpty
        ($warn -join "`n") | Should -Match 'disabled by policy'
    }
}
