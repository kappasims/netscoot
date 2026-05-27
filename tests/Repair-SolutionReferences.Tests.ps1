#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot TestHelpers.ps1)
    Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'src', 'Netscoot.Core', 'Netscoot.Core.psd1')) -Force

    function New-RepairFixtureBase {
        # App -> Lib in a solution. Returns the repo root with Lib still in place.
        $root = New-TempRoot -Prefix 'netscoot_rep'
        Push-Location $root
        try {
            & git init -q
            New-StubClassLib -Name Lib -Directory (Join-Path $root 'Lib') | Out-Null
            New-StubConsole -Name App -Directory (Join-Path $root 'App') | Out-Null
            & dotnet add (Join-Path $root (Join-Path 'App' 'App.csproj')) reference (Join-Path $root (Join-Path 'Lib' 'Lib.csproj')) | Out-Null
            & dotnet new sln -n Demo --format slnx | Out-Null
            & dotnet sln Demo.slnx add (Join-Path $root (Join-Path 'Lib' 'Lib.csproj')) (Join-Path $root (Join-Path 'App' 'App.csproj')) | Out-Null
        } finally { Pop-Location }
        return $root
    }

    function New-MovedFixture {
        # Lib's folder is moved by hand (no reconciliation), so the .sln entry and App's
        # <ProjectReference> dangle but Lib.csproj still exists at the new path.
        $root = New-RepairFixtureBase
        New-Item -ItemType Directory -Path (Join-Path $root 'libs') | Out-Null
        Move-Item -LiteralPath (Join-Path $root 'Lib') -Destination (Join-Path $root (Join-Path 'libs' 'Lib'))
        return $root
    }

    function New-DeletedFixture {
        # Lib is deleted outright, so the dangling entries have no new home.
        $root = New-RepairFixtureBase
        Remove-Item -LiteralPath (Join-Path $root 'Lib') -Recurse -Force
        return $root
    }

    function New-DuplicateLeafBase {
        # App -> Widgets (at src/Widgets), in a solution. A second, unrelated project also named
        # Widgets.csproj lives at $DecoyDir, so the leaf name 'Widgets.csproj' is not unique.
        param([Parameter(Mandatory)][string]$DecoyDir)
        $root = New-TempRoot -Prefix 'netscoot_amb'
        $srcWidgets = Join-Path $root (Join-Path 'src' 'Widgets')
        Push-Location $root
        try {
            & git init -q
            New-StubClassLib -Name Widgets -Directory $srcWidgets | Out-Null
            New-StubConsole -Name App -Directory (Join-Path $root 'App') | Out-Null
            & dotnet add (Join-Path $root (Join-Path 'App' 'App.csproj')) reference (Join-Path $srcWidgets 'Widgets.csproj') | Out-Null
            New-StubClassLib -Name Widgets -Directory (Join-Path $root $DecoyDir) | Out-Null   # decoy, same leaf
            & dotnet new sln -n Demo --format slnx | Out-Null
            & dotnet sln Demo.slnx add (Join-Path $srcWidgets 'Widgets.csproj') (Join-Path $root (Join-Path 'App' 'App.csproj')) | Out-Null
        } finally { Pop-Location }
        return $root
    }
}

Describe 'Repair-SolutionReferences' {
    It 'reports dangling entries and whether each can be relocated' {
        $root = New-MovedFixture
        try {
            $probs = Repair-SolutionReferences -RepoRoot $root
            ($probs.Kind | Sort-Object -Unique) | Should -Contain 'Solution'
            ($probs.Kind | Sort-Object -Unique) | Should -Contain 'Reference'
            ($probs.Resolution | Sort-Object -Unique) | Should -Contain 'Relocatable'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 're-points dangling entries at the moved project with -Fix (and it builds)' {
        $root = New-MovedFixture
        try {
            Repair-SolutionReferences -RepoRoot $root -Fix -Confirm:$false | Out-Null
            $list = (& dotnet sln (Join-Path $root 'Demo.slnx') list) -join "`n"
            $list | Should -Match 'libs[\\/]Lib[\\/]Lib\.csproj'
            $bo = & dotnet build (Join-Path $root 'Demo.slnx') 2>&1
            $LASTEXITCODE | Should -Be 0 -Because ($bo -join [Environment]::NewLine)
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'disambiguates duplicate leaf names by path proximity and relocates (and it builds)' {
        # src/Widgets moves to tools/Widgets (its folder name 'Widgets' survives); a decoy
        # Widgets.csproj sits at legacy/Widgets.csproj. The moved copy shares more trailing
        # path with the old reference, so it wins uniquely.
        $root = New-DuplicateLeafBase -DecoyDir 'legacy'
        try {
            New-Item -ItemType Directory -Path (Join-Path $root 'tools') | Out-Null
            Move-Item -LiteralPath (Join-Path $root (Join-Path 'src' 'Widgets')) -Destination (Join-Path $root (Join-Path 'tools' 'Widgets'))

            $probs = Repair-SolutionReferences -RepoRoot $root
            ($probs | Where-Object { $_.Resolution -eq 'Ambiguous' }) | Should -BeNullOrEmpty
            ($probs | Where-Object { $_.Resolution -eq 'Relocatable' }) | Should -Not -BeNullOrEmpty
            (($probs.NewPath | Where-Object { $_ }) -join ';') | Should -Match 'tools[\\/]Widgets[\\/]Widgets\.csproj'
            (($probs.NewPath | Where-Object { $_ }) -join ';') | Should -Not -Match 'legacy'

            Repair-SolutionReferences -RepoRoot $root -Fix -Confirm:$false | Out-Null
            (& dotnet sln (Join-Path $root 'Demo.slnx') list) -join "`n" | Should -Match 'tools[\\/]Widgets[\\/]Widgets\.csproj'
            $bo = & dotnet build (Join-Path $root 'Demo.slnx') 2>&1
            $LASTEXITCODE | Should -Be 0 -Because ($bo -join [Environment]::NewLine)
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'stays Ambiguous on a genuine tie and -Fix leaves it untouched' {
        # src/Widgets moves to a/Widgets; the decoy is at b/Widgets/Widgets.csproj. Both candidates
        # share exactly the trailing 'Widgets/Widgets.csproj', so neither wins.
        $root = New-DuplicateLeafBase -DecoyDir (Join-Path 'b' 'Widgets')
        try {
            New-Item -ItemType Directory -Path (Join-Path $root 'a') | Out-Null
            Move-Item -LiteralPath (Join-Path $root (Join-Path 'src' 'Widgets')) -Destination (Join-Path $root (Join-Path 'a' 'Widgets'))

            $probs = Repair-SolutionReferences -RepoRoot $root
            ($probs | Where-Object { $_.Resolution -eq 'Ambiguous' }) | Should -Not -BeNullOrEmpty

            # -Fix cannot resolve a tie, so the stale src/Widgets entry remains in the solution.
            Repair-SolutionReferences -RepoRoot $root -Fix -Confirm:$false | Out-Null
            (& dotnet sln (Join-Path $root 'Demo.slnx') list) -join "`n" | Should -Match 'src[\\/]Widgets[\\/]Widgets\.csproj'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'leaves a genuinely-missing entry for -Prune, which removes it' {
        $root = New-DeletedFixture
        try {
            # -Fix cannot relocate a deleted project; the entry stays.
            Repair-SolutionReferences -RepoRoot $root -Fix -Confirm:$false | Out-Null
            (& dotnet sln (Join-Path $root 'Demo.slnx') list) -join "`n" | Should -Match 'Lib[\\/]Lib\.csproj'
            # -Prune removes the gone entries.
            Repair-SolutionReferences -RepoRoot $root -Prune -Confirm:$false | Out-Null
            (& dotnet sln (Join-Path $root 'Demo.slnx') list) -join "`n" | Should -Not -Match 'Lib[\\/]Lib\.csproj'
            (Get-Content (Join-Path $root (Join-Path 'App' 'App.csproj')) -Raw) | Should -Not -Match 'Lib\.csproj'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
