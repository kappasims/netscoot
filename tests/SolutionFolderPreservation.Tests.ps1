BeforeAll {
    . (Join-Path $PSScriptRoot TestHelpers.ps1)
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Core' ('Netscoot.Core.psd1'))))) -Force

    # Both projects grouped under a 'src' SOLUTION folder (virtual grouping, independent of the disk
    # path). A move must keep the moved project in that folder, not re-fold it to mirror the new path.
    function New-FolderFixture {
        param([ValidateSet('sln', 'slnx')][string]$Format = 'slnx')
        Copy-FixtureTemplate -Key "slnfolder-$Format" -Prefix 'netscoot_fld' -Build {
            $root = New-TempRoot -Prefix 'netscoot_fld'
            Push-Location $root
            try {
                & git init -q
                New-ClassLibProject -Name Core -Directory (Join-Path $root (Join-Path 'src' 'Core')) | Out-Null
                New-ConsoleProject -Name App -Directory (Join-Path $root (Join-Path 'src' 'App')) | Out-Null
                & dotnet new sln -n Demo --format $Format | Out-Null
                $sln = (Get-ChildItem -LiteralPath $root -File -Include '*.sln', '*.slnx').FullName
                & dotnet sln $sln add (Join-Path 'src' (Join-Path 'Core' 'Core.csproj')) --solution-folder src | Out-Null
                & dotnet sln $sln add (Join-Path 'src' (Join-Path 'App' 'App.csproj')) --solution-folder src | Out-Null
                & git add -A; & git commit -qm fixture | Out-Null
            } finally { Pop-Location }
            return $root
        }
    }

    # A project deliberately at the solution ROOT (--in-root, no folder). A move must keep it at the
    # root, not let slnx's default `add` re-fold it into a path-mirrored folder.
    function New-RootFixture {
        Copy-FixtureTemplate -Key 'slnroot' -Prefix 'netscoot_rt' -Build {
            $root = New-TempRoot -Prefix 'netscoot_rt'
            Push-Location $root
            try {
                & git init -q
                New-ClassLibProject -Name Core -Directory (Join-Path $root (Join-Path 'src' 'Core')) | Out-Null
                & dotnet new sln -n Demo --format slnx | Out-Null
                & dotnet sln Demo.slnx add (Join-Path 'src' (Join-Path 'Core' 'Core.csproj')) --in-root | Out-Null
                & git add -A; & git commit -qm fixture | Out-Null
            } finally { Pop-Location }
            return $root
        }
    }

    function Get-MovedFolder {
        # The solution-folder the Core project sits in after a move ($null at root).
        param([string]$Root)
        $sln = (Get-ChildItem -LiteralPath $Root -File -Include '*.sln', '*.slnx').FullName
        $parsed = Read-Solution -SolutionFile $sln
        ($parsed.Projects | Where-Object { $_.Stored -match 'Core\.csproj$' }).Folder
    }
}

Describe 'Solution-folder preservation on move' {
    It 'keeps the moved project in its original solution folder (<Format>, spaces in destination)' -ForEach @(
        @{ Format = 'slnx' }, @{ Format = 'sln' }
    ) {
        $root = New-FolderFixture -Format $Format
        try {
            Move-DotnetProject -Project (Join-Path $root (Join-Path 'src' (Join-Path 'Core' 'Core.csproj'))) `
                -Destination (Join-Path $root (Join-Path 'src' 'Core Library')) -RepositoryRoot $root -NoBuild -Confirm:$false | Out-Null
            Get-MovedFolder -Root $root | Should -Be 'src'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'a deep move keeps the folder and creates no empty intermediate folders (slnx)' {
        $root = New-FolderFixture -Format slnx
        try {
            Move-DotnetProject -Project (Join-Path $root (Join-Path 'src' (Join-Path 'Core' 'Core.csproj'))) `
                -Destination (Join-Path $root (Join-Path 'src' (Join-Path 'a' (Join-Path 'b' (Join-Path 'c' 'Core'))))) `
                -RepositoryRoot $root -NoBuild -Confirm:$false | Out-Null
            Get-MovedFolder -Root $root | Should -Be 'src'
            # Only the original /src/ folder should exist - no /src/a/, /src/a/b/, ... litter.
            $sln = (Get-ChildItem -LiteralPath $root -File -Include '*.slnx').FullName
            @((Read-Solution -SolutionFile $sln).Folders) | Should -Be @('/src/')
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'keeps a root-level project at the root instead of auto-foldering it (slnx)' {
        $root = New-RootFixture
        try {
            Move-DotnetProject -Project (Join-Path $root (Join-Path 'src' (Join-Path 'Core' 'Core.csproj'))) `
                -Destination (Join-Path $root (Join-Path 'src' (Join-Path 'deep' 'Core'))) `
                -RepositoryRoot $root -NoBuild -Confirm:$false | Out-Null
            Get-MovedFolder -Root $root | Should -BeNullOrEmpty
            $sln = (Get-ChildItem -LiteralPath $root -File -Include '*.slnx').FullName
            @((Read-Solution -SolutionFile $sln).Folders).Count | Should -Be 0
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
