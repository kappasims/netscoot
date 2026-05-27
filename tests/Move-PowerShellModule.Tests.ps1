#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Core' ('Netscoot.Core.psd1'))))) -Force

    function New-ModuleFixture {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("netscoot_mod_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $mod = Join-Path $root 'MyMod'
        New-Item -ItemType Directory -Path $mod -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $mod 'MyMod.psm1') -Value 'function Get-X { 1 }; Export-ModuleMember -Function Get-X' -Encoding UTF8
        New-ModuleManifest -Path (Join-Path $mod 'MyMod.psd1') -RootModule 'MyMod.psm1' -FunctionsToExport 'Get-X'
        Push-Location $root
        try { & git init -q; & git add -A; & git commit -qm fixture | Out-Null } finally { Pop-Location }
        return $root
    }
}

Describe 'Move-PowerShellModule' {
    It 'moves the module folder and keeps the manifest valid' {
        $root = New-ModuleFixture
        try {
            $mod = Join-Path $root 'MyMod'
            $dest = Join-Path (Join-Path $root 'modules') 'MyMod'
            $r = Move-PowerShellModule -ModulePath $mod -Destination $dest -Confirm:$false -WarningAction SilentlyContinue
            (Join-Path $dest 'MyMod.psd1') | Should -Exist
            $mod | Should -Not -Exist
            (Test-ModuleManifest -Path (Join-Path $dest 'MyMod.psd1') -ErrorAction SilentlyContinue).Name | Should -Be 'MyMod'
            # Now emits a result with the common base shape (audit #4).
            $r.PSObject.TypeNames[0] | Should -Be 'Netscoot.PSModuleMoveResult'
            $r.Engine | Should -Be 'powershell'
            $r.Performed | Should -BeTrue
            foreach ($f in 'Engine', 'Source', 'Destination', 'Performed', 'SkippedCount') { $r.PSObject.Properties.Name | Should -Contain $f }
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'accepts the .psd1 manifest path directly and supports -WhatIf' {
        $root = New-ModuleFixture
        try {
            $psd1 = Join-Path (Join-Path $root 'MyMod') 'MyMod.psd1'
            Move-PowerShellModule -ModulePath $psd1 -Destination (Join-Path (Join-Path $root 'modules') 'MyMod') -WhatIf -WarningAction SilentlyContinue
            $psd1 | Should -Exist   # -WhatIf made no change
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
