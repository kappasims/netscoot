#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    # [IO.Path]::Combine (not multi-arg Join-Path) so this loads on Windows PowerShell 5.1 too.
    Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'src', 'Netscoot.Core', 'Netscoot.Core.psd1')) -Force

    function New-PSFixture {
        $root = New-TempRoot -Prefix 'netscoot_psfd'
        return $root
    }
}

Describe 'Move-PowerShell (front door)' {
    It 'routes a .ps1 to Move-PowerShellScript' {
        $root = New-PSFixture
        try {
            $ps1 = Join-Path $root 'helper.ps1'
            Set-Content -LiteralPath $ps1 -Value '"hi"'
            Mock -ModuleName Netscoot.Core Move-PowerShellScript { }
            Move-PowerShell -Path $ps1 -Destination (Join-Path $root 'moved.ps1')
            Should -Invoke -ModuleName Netscoot.Core Move-PowerShellScript -Times 1 -Exactly
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'routes a .psd1 manifest to Move-PowerShellModule' {
        $root = New-PSFixture
        try {
            $psd1 = Join-Path $root 'MyMod.psd1'
            Set-Content -LiteralPath $psd1 -Value '@{ ModuleVersion = "1.0" }'
            Mock -ModuleName Netscoot.Core Move-PowerShellModule { }
            Move-PowerShell -Path $psd1 -Destination (Join-Path $root 'modules')
            Should -Invoke -ModuleName Netscoot.Core Move-PowerShellModule -Times 1 -Exactly
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'routes a module folder to Move-PowerShellModule' {
        $root = New-PSFixture
        try {
            $mod = Join-Path $root 'MyMod'
            New-Item -ItemType Directory -Path $mod | Out-Null
            Set-Content -LiteralPath (Join-Path $mod 'MyMod.psd1') -Value '@{ ModuleVersion = "1.0" }'
            Mock -ModuleName Netscoot.Core Move-PowerShellModule { }
            Move-PowerShell -Path $mod -Destination (Join-Path (Join-Path $root 'modules') 'MyMod')
            Should -Invoke -ModuleName Netscoot.Core Move-PowerShellModule -Times 1 -Exactly
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'writes a non-terminating error for an unsupported type' {
        $root = New-PSFixture
        try {
            $txt = Join-Path $root 'notes.txt'
            Set-Content -LiteralPath $txt -Value 'x'
            Move-PowerShell -Path $txt -Destination (Join-Path $root 'x.txt') -ErrorVariable errs -ErrorAction SilentlyContinue
            $errs[0].FullyQualifiedErrorId | Should -Match 'NotAPowerShellItem'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
