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
                Invoke-Git -Arguments @('init', '-q')
                New-ClassLibProject -Name Lib -Directory (Join-Path $root (Join-Path 'group' ('Lib')))  | Out-Null
                New-ClassLibProject -Name Lib2 -Directory (Join-Path $root (Join-Path 'group' ('Lib2'))) | Out-Null
                New-ConsoleProject -Name App -Directory (Join-Path $root 'App')          | Out-Null
                Invoke-Dotnet -Arguments @('add', (Join-Path $root (Join-Path 'group' (Join-Path 'Lib2' ('Lib2.csproj')))), 'reference', (Join-Path $root (Join-Path 'group' (Join-Path 'Lib' ('Lib.csproj')))))
                Invoke-Dotnet -Arguments @('add', (Join-Path $root (Join-Path 'App' ('App.csproj'))), 'reference', (Join-Path $root (Join-Path 'group' (Join-Path 'Lib' ('Lib.csproj')))))
                Invoke-Dotnet -Arguments @('new', 'sln', '-n', 'Demo', '--format', 'slnx')
                Invoke-Dotnet -Arguments @('sln', 'Demo.slnx', 'add', (Join-Path $root (Join-Path 'group' (Join-Path 'Lib' ('Lib.csproj')))), (Join-Path $root (Join-Path 'group' (Join-Path 'Lib2' ('Lib2.csproj')))), (Join-Path $root (Join-Path 'App' ('App.csproj'))))
                Invoke-Git -Arguments @('add', '-A')
                Invoke-Git -Arguments @('commit', '-qm', 'fixture')
            } finally { Pop-Location }
            return $root
        }
    }
}

Describe 'Move-DotnetProjectTree' -Tag 'Integration' {
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
            $LASTEXITCODE | Should -Be 0
            ($listed -join "`n") | Should -Match 'moved[\\/]group[\\/]Lib2'
            $bo = & dotnet build (Join-Path $root 'Demo.slnx') 2>&1
            $LASTEXITCODE | Should -Be 0 -Because ($bo -join [Environment]::NewLine)
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'reports Built = false when any project fails to build, not only the last one' {
        $root = New-TreeFixture
        try {
            # group/Lib builds first and fails, group/Lib2 builds last and succeeds.
            Mock -ModuleName Netscoot.Core dotnet -ParameterFilter { $args[0] -eq 'build' -and $args[1] -match '[\\/]Lib\.csproj$' } { $global:LASTEXITCODE = 1 }
            Mock -ModuleName Netscoot.Core dotnet -ParameterFilter { $args[0] -eq 'build' -and $args[1] -match '[\\/]Lib2\.csproj$' } { $global:LASTEXITCODE = 0 }
            $r = Move-DotnetProjectTree -Path (Join-Path $root 'group') -Destination (Join-Path $root 'moved') -RepositoryRoot $root `
                -Confirm:$false -WarningAction SilentlyContinue
            $r.Built | Should -BeFalse
            Should -Invoke -ModuleName Netscoot.Core dotnet -Times 1 -Exactly -ParameterFilter { $args[0] -eq 'build' -and $args[1] -match '[\\/]Lib\.csproj$' }
            Should -Invoke -ModuleName Netscoot.Core dotnet -Times 1 -Exactly -ParameterFilter { $args[0] -eq 'build' -and $args[1] -match '[\\/]Lib2\.csproj$' }
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'warns that a .vcxproj in the folder moves without its references being updated' {
        $root = New-TreeFixture
        try {
            $native = New-Item -ItemType Directory -Path (Join-Path $root (Join-Path 'group' 'Native'))
            Set-Content -LiteralPath (Join-Path $native.FullName 'Native.vcxproj') -Value '<Project/>'
            Move-DotnetProjectTree -Path (Join-Path $root 'group') -Destination (Join-Path $root 'moved') -RepositoryRoot $root `
                -NoBuild -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            ($w -join "`n") | Should -Match 'Native\.vcxproj moves with the folder'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'refuses to move a folder into its own subtree (no mutation)' {
        $root = New-TreeFixture
        try {
            $group = Join-Path $root 'group'
            $dest = Join-Path $group 'nested'   # under the source folder
            $errs = @(Move-DotnetProjectTree -Path $group -Destination $dest -RepositoryRoot $root -NoBuild -Confirm:$false `
                    -ErrorAction Continue 2>&1 | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
            $errs.Count | Should -Be 1
            $errs[0].FullyQualifiedErrorId | Should -BeLike 'PathOverlap*'
            (Join-Path $group (Join-Path 'Lib' ('Lib.csproj'))) | Should -Exist   # nothing moved
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'warns when the move changes Directory.Build.* inheritance' {
        $root = New-TempRoot -Prefix 'netscoot_dbt'
        New-Item -ItemType Directory -Path (Join-Path $root 'area') -Force | Out-Null
        Push-Location $root
        try {
            Invoke-Git -Arguments @('init', '-q')
            Set-Content (Join-Path $root 'Directory.Build.props') '<Project></Project>'
            Set-Content (Join-Path $root (Join-Path 'area' ('Directory.Build.targets'))) '<Project></Project>'   # applies to area/* only
            New-ClassLibProject -Name Proj -Directory (Join-Path $root (Join-Path 'area' ('Proj'))) | Out-Null
            Invoke-Git -Arguments @('add', '-A')
            Invoke-Git -Arguments @('commit', '-qm', 'fixture')
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
            Invoke-Git -Arguments @('init', '-q')
            # CPM file applies to area/* only; moving area/Proj out of area drops it.
            Set-Content (Join-Path $root (Join-Path 'area' ('Directory.Packages.props'))) '<Project><PropertyGroup><ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally></PropertyGroup></Project>'
            New-ClassLibProject -Name Proj -Directory (Join-Path $root (Join-Path 'area' ('Proj'))) | Out-Null
            Invoke-Git -Arguments @('add', '-A')
            Invoke-Git -Arguments @('commit', '-qm', 'fixture')
            Move-DotnetProjectTree -Path (Join-Path $root (Join-Path 'area' ('Proj'))) -Destination (Join-Path $root 'movedProj') `
                -RepositoryRoot $root -NoBuild -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            ($w -join "`n") | Should -Match 'inheritance changes'
            ($w -join "`n") | Should -Match 'Directory\.Packages\.props'
        } finally { Pop-Location; Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
