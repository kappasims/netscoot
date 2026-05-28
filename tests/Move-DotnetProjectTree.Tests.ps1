#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot TestHelpers.ps1)
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Core' ('Netscoot.Core.psd1'))))) -Force

    function New-TreeFixture {
        # group/{Lib, Lib2->Lib (internal)}, plus App outside group -> Lib (external). One solution.
        Copy-FixtureTemplate -Key 'tree-group' -Prefix 'netscoot_tree' -Build {
            $root = New-TempRoot -Prefix 'netscoot_tree'
            Push-Location $root
            try {
                & git init -q
                New-StubClassLib -Name Lib -Directory (Join-Path $root (Join-Path 'group' ('Lib')))  | Out-Null
                New-StubClassLib -Name Lib2 -Directory (Join-Path $root (Join-Path 'group' ('Lib2'))) | Out-Null
                New-StubConsole -Name App -Directory (Join-Path $root 'App')          | Out-Null
                & dotnet add (Join-Path $root (Join-Path 'group' (Join-Path 'Lib2' ('Lib2.csproj')))) reference (Join-Path $root (Join-Path 'group' (Join-Path 'Lib' ('Lib.csproj')))) | Out-Null
                & dotnet add (Join-Path $root (Join-Path 'App' ('App.csproj')))           reference (Join-Path $root (Join-Path 'group' (Join-Path 'Lib' ('Lib.csproj')))) | Out-Null
                & dotnet new sln -n Demo --format slnx | Out-Null
                & dotnet sln Demo.slnx add (Join-Path $root (Join-Path 'group' (Join-Path 'Lib' ('Lib.csproj')))) (Join-Path $root (Join-Path 'group' (Join-Path 'Lib2' ('Lib2.csproj')))) (Join-Path $root (Join-Path 'App' ('App.csproj'))) | Out-Null
                & git add -A; & git commit -qm fixture | Out-Null
            } finally { Pop-Location }
            return $root
        }
    }
}

Describe 'Move-DotnetProjectTree' {
    It 'moves a folder of projects, fixing external refs while leaving internal refs intact' {
        $root = New-TreeFixture
        try {
            $group = Join-Path $root 'group'
            $dest = Join-Path (Join-Path $root 'moved') 'group'
            $r = Move-DotnetProjectTree -Path $group -Destination $dest -RepositoryRoot $root -NoBuild -Confirm:$false -WarningAction SilentlyContinue
            $r.ProjectsMoved | Should -Be 2
            $r.ConsumerCount | Should -Be 1                      # only App is external

            # External consumer App was repointed under moved/group.
            (Get-Content (Join-Path $root (Join-Path 'App' ('App.csproj'))) -Raw) | Should -Match 'moved[\\/]group[\\/]Lib[\\/]Lib\.csproj'
            # Internal Lib2 -> Lib reference is unchanged (still the sibling relative path).
            (Get-Content (Join-Path $dest (Join-Path 'Lib2' ('Lib2.csproj'))) -Raw) | Should -Match '\.\.[\\/]Lib[\\/]Lib\.csproj'
            # Solution lists the new locations and the whole thing builds.
            $listed = & dotnet sln (Join-Path $root 'Demo.slnx') list
            ($listed -join "`n") | Should -Match 'moved[\\/]group[\\/]Lib2'
            $bo = & dotnet build (Join-Path $root 'Demo.slnx') 2>&1
            $LASTEXITCODE | Should -Be 0 -Because ($bo -join [Environment]::NewLine)
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'refuses to move a folder into its own subtree (no mutation)' {
        $root = New-TreeFixture
        try {
            $group = Join-Path $root 'group'
            $dest = Join-Path $group 'nested'   # under the source folder
            Move-DotnetProjectTree -Path $group -Destination $dest -RepositoryRoot $root -NoBuild -Confirm:$false `
                -ErrorVariable errs -ErrorAction SilentlyContinue | Out-Null
            $errs[0].FullyQualifiedErrorId | Should -Match 'PathOverlap'
            (Join-Path $group (Join-Path 'Lib' ('Lib.csproj'))) | Should -Exist   # nothing moved
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'warns when the move changes Directory.Build.* inheritance' {
        $root = New-TempRoot -Prefix 'netscoot_dbt'
        New-Item -ItemType Directory -Path (Join-Path $root 'area') -Force | Out-Null
        Push-Location $root
        try {
            & git init -q
            Set-Content (Join-Path $root 'Directory.Build.props') '<Project></Project>'
            Set-Content (Join-Path $root (Join-Path 'area' ('Directory.Build.targets'))) '<Project></Project>'   # applies to area/* only
            New-StubClassLib -Name Proj -Directory (Join-Path $root (Join-Path 'area' ('Proj'))) | Out-Null
            & git add -A; & git commit -qm fixture | Out-Null
            # Moving area/Proj out of area/ drops the area Directory.Build.targets from its chain.
            Move-DotnetProjectTree -Path (Join-Path $root (Join-Path 'area' ('Proj'))) -Destination (Join-Path $root 'movedProj') `
                -RepositoryRoot $root -NoBuild -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            ($w -join "`n") | Should -Match 'inheritance changes'
            ($w -join "`n") | Should -Match 'Directory\.Build\.targets'
        } finally { Pop-Location; Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'warns when the move changes Central Package Management (Directory.Packages.props) scope' {
        $root = New-TempRoot -Prefix 'netscoot_cpm'
        New-Item -ItemType Directory -Path (Join-Path $root 'area') -Force | Out-Null
        Push-Location $root
        try {
            & git init -q
            # CPM file applies to area/* only; moving area/Proj out of area drops it.
            Set-Content (Join-Path $root (Join-Path 'area' ('Directory.Packages.props'))) '<Project><PropertyGroup><ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally></PropertyGroup></Project>'
            New-StubClassLib -Name Proj -Directory (Join-Path $root (Join-Path 'area' ('Proj'))) | Out-Null
            & git add -A; & git commit -qm fixture | Out-Null
            Move-DotnetProjectTree -Path (Join-Path $root (Join-Path 'area' ('Proj'))) -Destination (Join-Path $root 'movedProj') `
                -RepositoryRoot $root -NoBuild -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            ($w -join "`n") | Should -Match 'inheritance changes'
            ($w -join "`n") | Should -Match 'Directory\.Packages\.props'
        } finally { Pop-Location; Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
