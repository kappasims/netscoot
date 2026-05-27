#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot TestHelpers.ps1)
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Core' ('Netscoot.Core.psd1'))))) -Force

    function New-DivergentRepo {
        # Two solutions: Both.sln lists Lib+App; Partial.slnx lists App only -> Lib diverges.
        $root = New-TempRoot -Prefix 'netscoot_div'
        Push-Location $root
        try {
            & git init -q
            New-StubClassLib -Name Lib -Directory (Join-Path $root 'Lib') | Out-Null
            New-StubConsole -Name App -Directory (Join-Path $root 'App') | Out-Null
            & dotnet new sln -n Both --format sln | Out-Null
            & dotnet sln Both.sln add (Join-Path $root (Join-Path 'Lib' ('Lib.csproj'))) (Join-Path $root (Join-Path 'App' ('App.csproj'))) | Out-Null
            & dotnet new sln -n Partial --format slnx | Out-Null
            & dotnet sln Partial.slnx add (Join-Path $root (Join-Path 'App' ('App.csproj'))) | Out-Null
        } finally { Pop-Location }
        return $root
    }
}

Describe 'Test-SolutionConsistency' {
    It 'warns about and emits the divergent project' {
        $root = New-DivergentRepo
        try {
            $result = Test-SolutionConsistency -RepositoryRoot $root -WarningVariable warns -WarningAction SilentlyContinue
            $result.Project | Should -Match 'Lib\.csproj'
            ($result.AbsentFrom -join ',') | Should -Match 'Partial\.slnx'
            $warns | Should -Not -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'escalates to a non-terminating error under -Strict' {
        $root = New-DivergentRepo
        try {
            Test-SolutionConsistency -RepositoryRoot $root -Strict -ErrorVariable errs -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
            $errs | Should -Not -BeNullOrEmpty
            $errs[0].FullyQualifiedErrorId | Should -Match 'SolutionDivergence'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'accepts RepositoryRoot from the pipeline (Get-Item)' {
        $root = New-DivergentRepo
        try {
            $result = Get-Item $root | Test-SolutionConsistency -WarningAction SilentlyContinue
            $result.Project | Should -Match 'Lib\.csproj'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
