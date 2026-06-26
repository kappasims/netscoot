#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot TestHelpers.ps1)
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Core' ('Netscoot.Core.psd1'))))) -Force

    function New-DivergentRepo {
        # Two solutions: Both.sln lists Lib+App; Partial.slnx lists App only -> Lib diverges.
        Copy-FixtureTemplate -Key 'divergent-both-partial' -Prefix 'netscoot_div' -Build {
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

    It 'reports a .pssproj that diverges across solutions (regression: managed-only filter would silently mark this clean)' {
        # Two solutions; the .slnx lists Tools.pssproj, the .sln does not. A managed-only filter
        # (cs|fs|vb|vcx)proj would skip the pssproj and report "all agree" - the failure mode the
        # user dogfooded against a real dual-solution repo. Hand-write both solution files so the
        # test is independent of dotnet sln's behavior on non-managed project kinds.
        $root = New-TempRoot -Prefix 'netscoot_psspr'
        try {
            $stub = "<Project Sdk=`"Microsoft.NET.Sdk`"></Project>"
            New-Item -ItemType Directory -Path (Join-Path $root 'App') | Out-Null
            Set-Content -LiteralPath (Join-Path $root (Join-Path 'App' 'App.csproj')) -Value $stub -Encoding UTF8
            New-Item -ItemType Directory -Path (Join-Path $root 'Tools') | Out-Null
            Set-Content -LiteralPath (Join-Path $root (Join-Path 'Tools' 'Tools.pssproj')) -Value $stub -Encoding UTF8

            # .slnx (lists both)
            Set-Content -LiteralPath (Join-Path $root 'Both.slnx') -Encoding UTF8 -Value @"
<Solution>
  <Project Path="App/App.csproj" />
  <Project Path="Tools/Tools.pssproj" />
</Solution>
"@
            # .sln (lists App.csproj only - no Tools.pssproj)
            Set-Content -LiteralPath (Join-Path $root 'Partial.sln') -Encoding UTF8 -Value @"
Microsoft Visual Studio Solution File, Format Version 12.00
Project("{9A19103F-16F7-4668-BE54-9A1E7A4F7556}") = "App", "App\App.csproj", "{11111111-1111-1111-1111-111111111111}"
EndProject
"@
            $result = @(Test-SolutionConsistency -RepositoryRoot $root -WarningAction SilentlyContinue)
            $pss = $result | Where-Object { $_.Project -match 'Tools\.pssproj' }
            $pss | Should -Not -BeNullOrEmpty -Because 'a pssproj that diverges across solutions must show up in the consistency report'
            ($pss.AbsentFrom -join ',') | Should -Match 'Partial\.sln'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'does NOT flag intentionally-separate solutions that share no projects (regression: every project read as diverging)' {
        # Three independent solutions, each with its own project and no overlap (a standalone client,
        # a server, a tools solution). The pre-fix behavior unioned every project across all
        # solutions and flagged each as absent from the other two - a false positive on a clean tree.
        $root = New-TempRoot -Prefix 'netscoot_indep'
        try {
            $stub = "<Project Sdk=`"Microsoft.NET.Sdk`"></Project>"
            foreach ($name in 'Client', 'Server', 'Tools') {
                New-Item -ItemType Directory -Path (Join-Path $root $name) | Out-Null
                Set-Content -LiteralPath (Join-Path $root (Join-Path $name "$name.csproj")) -Value $stub -Encoding UTF8
                Set-Content -LiteralPath (Join-Path $root "$name.slnx") -Encoding UTF8 -Value @"
<Solution>
  <Project Path="$name/$name.csproj" />
</Solution>
"@
            }
            $result = @(Test-SolutionConsistency -RepositoryRoot $root -WarningVariable warns -WarningAction SilentlyContinue)
            $result | Should -BeNullOrEmpty -Because 'solutions that share no projects were never meant to agree'
            $warns | Should -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'still catches drift within an overlapping pair while ignoring an independent solution in the same repo' {
        # Both.slnx and Partial.slnx share App (a mirror pair that has drifted: Both also lists Lib).
        # Other.slnx is independent (lists only Widget). Lib must be flagged (real drift in the pair);
        # Widget must NOT be flagged (Other shares nothing with the pair).
        $root = New-TempRoot -Prefix 'netscoot_mixed'
        try {
            $stub = "<Project Sdk=`"Microsoft.NET.Sdk`"></Project>"
            foreach ($p in 'App', 'Lib', 'Widget') {
                New-Item -ItemType Directory -Path (Join-Path $root $p) | Out-Null
                Set-Content -LiteralPath (Join-Path $root (Join-Path $p "$p.csproj")) -Value $stub -Encoding UTF8
            }
            Set-Content -LiteralPath (Join-Path $root 'Both.slnx') -Encoding UTF8 -Value @"
<Solution>
  <Project Path="App/App.csproj" />
  <Project Path="Lib/Lib.csproj" />
</Solution>
"@
            Set-Content -LiteralPath (Join-Path $root 'Partial.slnx') -Encoding UTF8 -Value @"
<Solution>
  <Project Path="App/App.csproj" />
</Solution>
"@
            Set-Content -LiteralPath (Join-Path $root 'Other.slnx') -Encoding UTF8 -Value @"
<Solution>
  <Project Path="Widget/Widget.csproj" />
</Solution>
"@
            $result = @(Test-SolutionConsistency -RepositoryRoot $root -WarningAction SilentlyContinue)
            ($result | Where-Object { $_.Project -match 'Lib\.csproj' }) | Should -Not -BeNullOrEmpty -Because 'drift within the overlapping mirror pair must still be caught'
            ($result | Where-Object { $_.Project -match 'Widget\.csproj' }) | Should -BeNullOrEmpty -Because 'an independent solution must not be compared against the pair'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
