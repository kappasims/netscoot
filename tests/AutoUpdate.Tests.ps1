#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot TestHelpers.ps1)
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'DotnetMove.Core' ('DotnetMove.Core.psd1'))))) -Force
    $script:PrevAutoUpdate = $env:DOTNETMOVE_AUTOUPDATE
}

AfterAll {
    if ($null -eq $script:PrevAutoUpdate) { Remove-Item Env:\DOTNETMOVE_AUTOUPDATE -ErrorAction SilentlyContinue }
    else { $env:DOTNETMOVE_AUTOUPDATE = $script:PrevAutoUpdate }
}

Describe 'Auto-update gating' {
    # These assert the gates short-circuit BEFORE any network call (so they are safe and fast offline).

    It 'Test-DotnetMoveUpdate -EnableAutoUpdate is a no-op when DOTNETMOVE_AUTOUPDATE is unset' {
        Remove-Item Env:\DOTNETMOVE_AUTOUPDATE -ErrorAction SilentlyContinue
        $r = Test-DotnetMoveUpdate -EnableAutoUpdate
        $r | Should -BeNullOrEmpty
    }

    It 'Test-DotnetMoveUpdate -EnableAutoUpdate is a no-op when DOTNETMOVE_AUTOUPDATE is off' {
        $env:DOTNETMOVE_AUTOUPDATE = 'false'
        $r = Test-DotnetMoveUpdate -EnableAutoUpdate
        $r | Should -BeNullOrEmpty
    }

    It 'Update-DotnetMove refuses (no network) when DOTNETMOVE_AUTOUPDATE is off' {
        $env:DOTNETMOVE_AUTOUPDATE = 'off'
        $r = Update-DotnetMove -WarningVariable warn -WarningAction SilentlyContinue
        $r | Should -BeNullOrEmpty
        ($warn -join "`n") | Should -Match 'disabled by policy'
    }
}
