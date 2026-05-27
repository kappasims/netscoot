#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot TestHelpers.ps1)
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Core' ('Netscoot.Core.psd1'))))) -Force

    function New-DispatchFixture {
        $root = New-TempRoot -Prefix 'netscoot_disp'
        Push-Location $root
        try {
            & git init -q
            New-StubClassLib -Name Lib -Directory (Join-Path $root (Join-Path 'src' ('Lib'))) | Out-Null
            & dotnet new sln -n Demo --format slnx | Out-Null
            & dotnet sln Demo.slnx add (Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))) | Out-Null
            Set-Content -LiteralPath (Join-Path $root 'Shared.props') -Value "<Project></Project>" -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $root 'notes.txt') -Value "x" -Encoding UTF8
            & git add -A; & git commit -qm fixture | Out-Null
        } finally { Pop-Location }
        return $root
    }
}

Describe 'Move-DotnetFile (routing)' {
    It 'routes a .csproj to Move-DotnetProject' {
        $root = New-DispatchFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            Move-DotnetFile -Path $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepositoryRoot $root -NoBuild -Confirm:$false -WarningAction SilentlyContinue | Out-Null
            (Join-Path $root (Join-Path 'libs' (Join-Path 'Lib' ('Lib.csproj')))) | Should -Exist
            $lib | Should -Not -Exist
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'routes a .slnx to Move-Solution' {
        $root = New-DispatchFixture
        try {
            $r = Move-DotnetFile -Path (Join-Path $root 'Demo.slnx') -Destination (Join-Path $root (Join-Path 'build' ('Demo.slnx'))) -Confirm:$false -WarningAction SilentlyContinue
            $r.PSObject.TypeNames[0] | Should -Be 'Netscoot.SolutionMoveResult'
            (Join-Path $root (Join-Path 'build' ('Demo.slnx'))) | Should -Exist
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'routes a .props to Move-MSBuildImport' {
        $root = New-DispatchFixture
        try {
            $r = Move-DotnetFile -Path (Join-Path $root 'Shared.props') -Destination (Join-Path $root (Join-Path 'build' ('Shared.props'))) -RepositoryRoot $root -Confirm:$false -WarningAction SilentlyContinue
            $r.PSObject.TypeNames[0] | Should -Be 'Netscoot.ImportMoveResult'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'errors on an unsupported extension' {
        $root = New-DispatchFixture
        try {
            Move-DotnetFile -Path (Join-Path $root 'notes.txt') -Destination (Join-Path $root 'x.txt') `
                -ErrorVariable errs -ErrorAction SilentlyContinue | Out-Null
            $errs[0].FullyQualifiedErrorId | Should -Match 'NotADotnetFile'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'propagates -WhatIf to the specialist (no move)' {
        $root = New-DispatchFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            Move-DotnetFile -Path $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepositoryRoot $root -WhatIf | Out-Null
            $lib | Should -Exist
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Invoke-Netscoot (legacy .vcproj)' {
    It 'rejects a legacy .vcproj with a clear, specific error' {
        $root = New-DispatchFixture
        try {
            $vcproj = Join-Path $root 'Old.vcproj'
            Set-Content -LiteralPath $vcproj -Value '<VisualStudioProject></VisualStudioProject>' -Encoding UTF8
            Invoke-Netscoot -Path $vcproj -Destination (Join-Path $root 'moved') -Confirm:$false `
                -ErrorVariable errs -ErrorAction SilentlyContinue | Out-Null
            $errs[0].FullyQualifiedErrorId | Should -Match 'LegacyVcprojNotSupported'
            $vcproj | Should -Exist   # nothing moved
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Move-DotnetFolder (routing)' {
    It 'routes a folder to Move-DotnetProjectTree' {
        $root = New-DispatchFixture
        try {
            $r = Move-DotnetFolder -Path (Join-Path $root 'src') -Destination (Join-Path $root 'source') -RepositoryRoot $root -NoBuild -Confirm:$false -WarningAction SilentlyContinue
            $r.PSObject.TypeNames[0] | Should -Be 'Netscoot.TreeMoveResult'
            (Join-Path $root (Join-Path 'source' (Join-Path 'Lib' ('Lib.csproj')))) | Should -Exist
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
