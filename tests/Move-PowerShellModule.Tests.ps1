#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Core' ('Netscoot.Core.psd1'))))) -Force

    function New-ModuleFixture {
        $root = New-TempRoot -Prefix 'netscoot_mod'
        $mod = Join-Path $root 'MyMod'
        New-Item -ItemType Directory -Path $mod -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $mod 'MyMod.psm1') -Value 'function Get-X { 1 }; Export-ModuleMember -Function Get-X' -Encoding UTF8
        New-ModuleManifest -Path (Join-Path $mod 'MyMod.psd1') -RootModule 'MyMod.psm1' -FunctionsToExport 'Get-X'
        Push-Location $root
        try { & git init -q; & git add -A; & git commit -qm fixture | Out-Null } finally { Pop-Location }
        return $root
    }
}

Describe 'Move-PowerShellModule' -Tag 'Integration' {
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
            foreach ($f in 'Engine', 'Source', 'Destination', 'Performed') { $r.PSObject.Properties.Name | Should -Contain $f }
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

Describe 'Move-PowerShellModule references' -Tag 'Integration' {
    BeforeAll {
        # MyMod dot-sources lib/common.ps1 from outside itself; use.ps1 and using.ps1 import it by path.
        function New-ReferencedModuleFixture {
            $root = New-TempRoot -Prefix 'netscoot_modref'
            $mod = Join-Path $root 'MyMod'
            New-Item -ItemType Directory -Path $mod, (Join-Path $root 'lib') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $root (Join-Path 'lib' 'common.ps1')) -Value 'function Get-Common { 1 }'
            Set-Content -LiteralPath (Join-Path $mod 'MyMod.psm1') -Value ". `"`$PSScriptRoot/../lib/common.ps1`"`nfunction Get-X { Get-Common }"
            New-ModuleManifest -Path (Join-Path $mod 'MyMod.psd1') -RootModule 'MyMod.psm1' -FunctionsToExport 'Get-X' -VariablesToExport @()
            Set-Content -LiteralPath (Join-Path $root 'use.ps1') -Value "Import-Module `"`$PSScriptRoot/MyMod/MyMod.psd1`"`nGet-X"
            Set-Content -LiteralPath (Join-Path $root 'using.ps1') -Value 'using module ./MyMod/MyMod.psd1'
            Push-Location $root
            try { & git init -q; & git add -A; & git commit -qm fixture | Out-Null } finally { Pop-Location }
            return $root
        }
    }

    It 'repoints an Import-Module caller and the caller still runs' {
        $root = New-ReferencedModuleFixture
        try {
            Move-PowerShellModule -ModulePath (Join-Path $root 'MyMod') -Destination (Join-Path (Join-Path $root 'modules') 'MyMod') -NoJournal -Confirm:$false -WarningAction SilentlyContinue | Out-Null
            (Get-Content -LiteralPath (Join-Path $root 'use.ps1'))[0] | Should -BeExactly 'Import-Module "$PSScriptRoot/modules/MyMod/MyMod.psd1"'
            (& pwsh -NoProfile -File (Join-Path $root 'use.ps1')) | Should -Be 1
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'repoints a using module statement' {
        $root = New-ReferencedModuleFixture
        try {
            Move-PowerShellModule -ModulePath (Join-Path $root 'MyMod') -Destination (Join-Path (Join-Path $root 'modules') 'MyMod') -NoJournal -Confirm:$false -WarningAction SilentlyContinue | Out-Null
            (Get-Content -LiteralPath (Join-Path $root 'using.ps1') -Raw).Trim() | Should -BeExactly 'using module ./modules/MyMod/MyMod.psd1'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rebases a module file''s dot-source to a script outside the module' {
        $root = New-ReferencedModuleFixture
        try {
            $dest = Join-Path (Join-Path $root 'modules') 'MyMod'
            Move-PowerShellModule -ModulePath (Join-Path $root 'MyMod') -Destination $dest -NoJournal -Confirm:$false -WarningAction SilentlyContinue | Out-Null
            (Get-Content -LiteralPath (Join-Path $dest 'MyMod.psm1'))[0] | Should -BeExactly '. "$PSScriptRoot/../../lib/common.ps1"'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'leaves the manifest byte-for-byte unchanged' {
        $root = New-ReferencedModuleFixture
        try {
            $before = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $root (Join-Path 'MyMod' 'MyMod.psd1'))))
            $dest = Join-Path (Join-Path $root 'modules') 'MyMod'
            Move-PowerShellModule -ModulePath (Join-Path $root 'MyMod') -Destination $dest -NoJournal -Confirm:$false -WarningAction SilentlyContinue | Out-Null
            [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $dest 'MyMod.psd1'))) | Should -BeExactly $before
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
