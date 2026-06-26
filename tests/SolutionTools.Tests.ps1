#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot TestHelpers.ps1)
    Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'src', 'Netscoot.Core', 'Netscoot.Core.psd1')) -Force

    # Delegate to the canonical New-TempRoot (TestHelpers) so the template build uses paths in the
    # canonical /private/var/... form on macOS. Without that, dotnet sln add cannot compute a
    # relative path (cwd canonical, arg in /var/... symlink form) and stores an ABSOLUTE /var/...
    # path inside .slnx; that absolute path then survives the copy to a canonical per-test root and
    # Sync-NetscootSolution fails with a path-mismatch on `dotnet sln add`.
    function New-TempDir { New-TempRoot -Prefix 'netscoot_st' }

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
        Copy-FixtureTemplate -Key 'divergent-both-partial' -Prefix 'netscoot_st' -Build {
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
}

Describe 'Get-NetscootSolutionInventory' {
    It 'surfaces non-CLI projects, folders, items, and unreferenced projects' {
        $root = New-InventoryFixture
        try {
            $inv = Get-NetscootSolutionInventory -RepositoryRoot $root
            ($inv | Where-Object { $_.Kind -eq 'Project' -and $_.Type -eq 'pssproj' }).Name | Should -Be 'Tools.pssproj'
            ($inv | Where-Object { $_.Kind -eq 'SolutionFolder' }).Name | Should -Match 'Solution Items'
            ($inv | Where-Object { $_.Kind -eq 'SolutionItem' }).Name | Should -Be 'README.md'
            ($inv | Where-Object { $_.Kind -eq 'UnreferencedProject' }).Name | Should -Be 'BattleClient.csproj'
            # Lib.csproj is referenced, so it is a Project, not unreferenced.
            ($inv | Where-Object { $_.Kind -eq 'UnreferencedProject' -and $_.Name -eq 'Lib.csproj' }) | Should -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Sync-NetscootSolution' {
    It 'previews additions with -WhatIf and changes nothing' {
        $root = New-DivergentFixture
        try {
            Sync-NetscootSolution -RepositoryRoot $root -WhatIf | Out-Null
            (& dotnet sln (Join-Path $root 'Partial.slnx') list) -join "`n" | Should -Not -Match 'Lib[\\/]Lib\.csproj'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'adds the missing project so membership becomes uniform' {
        $root = New-DivergentFixture
        try {
            $added = Sync-NetscootSolution -RepositoryRoot $root -Confirm:$false
            ($added.Added -join ';') | Should -Match 'Lib[\\/]Lib\.csproj'
            (& dotnet sln (Join-Path $root 'Partial.slnx') list) -join "`n" | Should -Match 'Lib[\\/]Lib\.csproj'
            # Now consistent.
            Test-NetscootSolutionConsistency -RepositoryRoot $root -WarningVariable w -WarningAction SilentlyContinue | Should -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
