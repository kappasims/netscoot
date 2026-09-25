#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Core' ('Netscoot.Core.psd1'))))) -Force

    function New-ScriptFixture {
        # lib/helpers.ps1 dot-sourced by app/main.ps1 via $PSScriptRoot.
        $root = New-TempRoot -Prefix 'netscoot_ps1'
        New-Item -ItemType Directory -Path (Join-Path $root 'lib') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'app') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root (Join-Path 'lib' ('helpers.ps1'))) -Encoding UTF8 -Value 'function Get-Greeting { "hi" }'
        Set-Content -LiteralPath (Join-Path $root (Join-Path 'app' ('main.ps1'))) -Encoding UTF8 -Value @'
. "$PSScriptRoot\..\lib\helpers.ps1"
Get-Greeting
'@
        Push-Location $root
        try { & git init -q; & git add -A; & git commit -qm fixture | Out-Null } finally { Pop-Location }
        return $root
    }
}

Describe 'Move-PowerShellScript' {
    It 'fixes a dot-source reference and the script still runs' {
        $root = New-ScriptFixture
        try {
            $helpers = Join-Path $root (Join-Path 'lib' ('helpers.ps1'))
            $dest = Join-Path (Join-Path $root 'shared') 'helpers.ps1'
            $r = Move-PowerShellScript -Path $helpers -Destination $dest -RepositoryRoot $root -Confirm:$false -WarningAction SilentlyContinue
            $r.ReferencersFixed | Should -Be 1
            $dest | Should -Exist

            $mainText = Get-Content (Join-Path $root (Join-Path 'app' ('main.ps1'))) -Raw
            $mainText | Should -Match '\$PSScriptRoot[\\/]\.\.[\\/]shared[\\/]helpers\.ps1'

            # Run main.ps1 in a child pwsh; the fixed dot-source must resolve.
            $out = & pwsh -NoProfile -File (Join-Path $root (Join-Path 'app' ('main.ps1')))
            ($out -join '') | Should -Match 'hi'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'flags a dynamically-built reference as unresolved instead of guessing' {
        $root = New-ScriptFixture
        try {
            Set-Content -LiteralPath (Join-Path $root (Join-Path 'app' ('dyn.ps1'))) -Encoding UTF8 -Value @'
$libDir = "$PSScriptRoot\..\lib"
. "$libDir\helpers.ps1"
'@
            $r = Move-PowerShellScript -Path (Join-Path $root (Join-Path 'lib' ('helpers.ps1'))) `
                -Destination (Join-Path (Join-Path $root 'shared') 'helpers.ps1') `
                -RepositoryRoot $root -WhatIf -WarningVariable w -WarningAction SilentlyContinue
            # WhatIf: nothing moved, but the dynamic reference is reported.
            ($w -join "`n") | Should -Match 'dynamic reference'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Move-PowerShellScript path style and coverage' -Tag 'Integration' {
    It 'keeps a caller''s forward slashes' {
        $root = New-ScriptFixture
        try {
            $caller = Join-Path $root 'slash.ps1'
            Set-Content -LiteralPath $caller -Value '. "$PSScriptRoot/lib/helpers.ps1"'
            Move-PowerShellScript -Path (Join-Path $root (Join-Path 'lib' 'helpers.ps1')) -Destination (Join-Path (Join-Path $root 'shared') 'helpers.ps1') `
                -RepositoryRoot $root -NoJournal -Confirm:$false -WarningAction SilentlyContinue | Out-Null
            (Get-Content -LiteralPath $caller -Raw).Trim() | Should -BeExactly '. "$PSScriptRoot/shared/helpers.ps1"'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'reports a Join-Path argument that names the moved script' {
        $root = New-ScriptFixture
        try {
            Set-Content -LiteralPath (Join-Path $root 'joined.ps1') -Value ". (Join-Path `$PSScriptRoot 'lib\helpers.ps1')"
            Move-PowerShellScript -Path (Join-Path $root (Join-Path 'lib' 'helpers.ps1')) -Destination (Join-Path (Join-Path $root 'shared') 'helpers.ps1') `
                -RepositoryRoot $root -WhatIf -WarningVariable w -WarningAction SilentlyContinue
            ($w -join "`n") | Should -Match ([regex]::Escape('"lib\helpers.ps1"'))
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rebases the moved script''s own Import-Module path' {
        $root = New-ScriptFixture
        try {
            New-Item -ItemType Directory -Path (Join-Path $root (Join-Path 'modules' 'M')) -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $root (Join-Path 'modules' (Join-Path 'M' 'M.psd1'))) -Value '@{ ModuleVersion = ''1.0.0'' }'
            $script = Join-Path $root 'use.ps1'
            Set-Content -LiteralPath $script -Value 'Import-Module "$PSScriptRoot/modules/M/M.psd1"'
            $dest = Join-Path (Join-Path $root 'bin') 'use.ps1'
            Move-PowerShellScript -Path $script -Destination $dest -RepositoryRoot $root -NoJournal -Confirm:$false -WarningAction SilentlyContinue | Out-Null
            (Get-Content -LiteralPath $dest -Raw).Trim() | Should -BeExactly 'Import-Module "$PSScriptRoot/../modules/M/M.psd1"'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
