#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Core' ('Netscoot.Core.psd1'))))) -Force

    function New-ScriptFixture {
        # lib/helpers.ps1 dot-sourced by app/main.ps1 via $PSScriptRoot.
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("netscoot_ps1_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
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
            $r = Move-PowerShellScript -Path $helpers -Destination $dest -RepoRoot $root -Confirm:$false -WarningAction SilentlyContinue
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
                -RepoRoot $root -WhatIf -WarningVariable w -WarningAction SilentlyContinue
            # WhatIf: nothing moved, but the dynamic reference is reported.
            ($w -join "`n") | Should -Match 'dynamic reference'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
