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

    It 'Test-ScootUpdate -EnableAutoUpdate is a no-op when NETSCOOT_AUTOUPDATE is unset' {
        Remove-Item Env:\NETSCOOT_AUTOUPDATE -ErrorAction SilentlyContinue
        $r = Test-ScootUpdate -EnableAutoUpdate
        $r | Should -BeNullOrEmpty
    }

    It 'Test-ScootUpdate -EnableAutoUpdate is a no-op when NETSCOOT_AUTOUPDATE is off' {
        $env:NETSCOOT_AUTOUPDATE = 'false'
        $r = Test-ScootUpdate -EnableAutoUpdate
        $r | Should -BeNullOrEmpty
    }

    It 'Update-Scoot refuses (no network) when NETSCOOT_AUTOUPDATE is off' {
        $env:NETSCOOT_AUTOUPDATE = 'off'
        $r = Update-Scoot -WarningVariable warn -WarningAction SilentlyContinue
        $r | Should -BeNullOrEmpty
        ($warn -join "`n") | Should -Match 'disabled by policy'
    }
}
