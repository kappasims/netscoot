#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot TestHelpers.ps1)
    Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'src', 'Netscoot.Core', 'Netscoot.Core.psd1')) -Force

    function New-TempDir {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ("netscoot_st_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $d | Out-Null
        return $d
    }

    function New-InventoryFixture {
        # A .slnx that lists a .csproj, a non-CLI .pssproj, a solution folder, and a solution item;
        # plus an on-disk .csproj that no solution references.
        $root = New-TempDir
        Push-Location $root
        try { & git init -q } finally { Pop-Location }
        $stub = "<Project Sdk=`"Microsoft.NET.Sdk`"></Project>"
        New-Item -ItemType Directory -Path (Join-Path $root 'Lib') | Out-Null
        Set-Content -LiteralPath (Join-Path $root (Join-Path 'Lib' 'Lib.csproj')) -Value $stub -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $root 'Tools') | Out-Null
        Set-Content -LiteralPath (Join-Path $root (Join-Path 'Tools' 'Tools.pssproj')) -Value $stub -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $root 'BattleClient') | Out-Null
        Set-Content -LiteralPath (Join-Path $root (Join-Path 'BattleClient' 'BattleClient.csproj')) -Value $stub -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root 'README.md') -Value '# readme' -Encoding UTF8
        $slnx = @"
<Solution>
  <Folder Name="/Solution Items/">
    <File Path="README.md" />
  </Folder>
  <Project Path="Lib/Lib.csproj" />
  <Project Path="Tools/Tools.pssproj" />
</Solution>
"@
        Set-Content -LiteralPath (Join-Path $root 'Demo.slnx') -Value $slnx -Encoding UTF8
        return $root
    }

    function New-DivergentFixture {
        # Both.sln lists Lib+App; Partial.slnx lists only App, so Lib's membership diverges.
        $root = New-TempDir
        Push-Location $root
        try {
            & git init -q
            New-StubClassLib -Name Lib -Directory (Join-Path $root 'Lib') | Out-Null
            New-StubConsole -Name App -Directory (Join-Path $root 'App') | Out-Null
            & dotnet new sln -n Both --format sln | Out-Null
            & dotnet sln Both.sln add (Join-Path $root (Join-Path 'Lib' 'Lib.csproj')) (Join-Path $root (Join-Path 'App' 'App.csproj')) | Out-Null
            & dotnet new sln -n Partial --format slnx | Out-Null
            & dotnet sln Partial.slnx add (Join-Path $root (Join-Path 'App' 'App.csproj')) | Out-Null
        } finally { Pop-Location }
        return $root
    }
}

Describe 'Get-SolutionInventory' {
    It 'surfaces non-CLI projects, folders, items, and unreferenced projects' {
        $root = New-InventoryFixture
        try {
            $inv = Get-SolutionInventory -RepoRoot $root
            ($inv | Where-Object { $_.Kind -eq 'Project' -and $_.Type -eq 'pssproj' }).Name | Should -Be 'Tools.pssproj'
            ($inv | Where-Object { $_.Kind -eq 'SolutionFolder' }).Name | Should -Match 'Solution Items'
            ($inv | Where-Object { $_.Kind -eq 'SolutionItem' }).Name | Should -Be 'README.md'
            ($inv | Where-Object { $_.Kind -eq 'UnreferencedProject' }).Name | Should -Be 'BattleClient.csproj'
            # Lib.csproj is referenced, so it is a Project, not unreferenced.
            ($inv | Where-Object { $_.Kind -eq 'UnreferencedProject' -and $_.Name -eq 'Lib.csproj' }) | Should -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Sync-Solution' {
    It 'previews additions with -WhatIf and changes nothing' {
        $root = New-DivergentFixture
        try {
            Sync-Solution -RepoRoot $root -WhatIf | Out-Null
            (& dotnet sln (Join-Path $root 'Partial.slnx') list) -join "`n" | Should -Not -Match 'Lib[\\/]Lib\.csproj'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'adds the missing project so membership becomes uniform' {
        $root = New-DivergentFixture
        try {
            $added = Sync-Solution -RepoRoot $root -Confirm:$false
            ($added.Added -join ';') | Should -Match 'Lib[\\/]Lib\.csproj'
            (& dotnet sln (Join-Path $root 'Partial.slnx') list) -join "`n" | Should -Match 'Lib[\\/]Lib\.csproj'
            # Now consistent.
            Test-SolutionConsistency -RepoRoot $root -WarningVariable w -WarningAction SilentlyContinue | Should -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
