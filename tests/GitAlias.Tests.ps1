#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot TestHelpers.ps1)
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Core' ('Netscoot.Core.psd1'))))) -Force

    function New-RepoFixture {
        $root = New-TempRoot -Prefix 'netscoot_git'
        Push-Location $root
        try {
            & git init -q
            New-StubClassLib -Name Lib -Directory (Join-Path $root (Join-Path 'src' ('Lib'))) | Out-Null
            & dotnet new sln -n Demo --format slnx | Out-Null
            & dotnet sln Demo.slnx add (Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))) | Out-Null
            & git add -A; & git commit -qm fixture | Out-Null
        } finally { Pop-Location }
        return $root
    }
}

Describe 'Register/Unregister-NetscootGitAlias' {
    It 'sets and unsets a repo-local alias' {
        $root = New-RepoFixture
        Push-Location $root
        try {
            Register-NetscootGitAlias -Scope Local -Confirm:$false | Out-Null
            (& git config --local --get alias.netscoot) | Should -Match 'git-netscoot\.ps1'
            Unregister-NetscootGitAlias -Scope Local -Confirm:$false | Out-Null
            (& git config --local --get alias.netscoot) | Should -BeNullOrEmpty
        } finally { Pop-Location; Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'does not set the alias under -WhatIf' {
        $root = New-RepoFixture
        Push-Location $root
        try {
            Register-NetscootGitAlias -Scope Local -WhatIf | Out-Null
            (& git config --local --get alias.netscoot) | Should -BeNullOrEmpty
        } finally { Pop-Location; Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'git netscoot (end-to-end, universal cross-engine routing)' {
    It 'routes a .csproj to the .NET engine' {
        $root = New-RepoFixture
        Push-Location $root
        try {
            Register-NetscootGitAlias -Scope Local -Confirm:$false | Out-Null
            & git -C $root netscoot src/Lib/Lib.csproj libs/Lib --nobuild 2>&1 | Out-Null
            (Join-Path $root (Join-Path 'libs' (Join-Path 'Lib' ('Lib.csproj')))) | Should -Exist
            (Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))) | Should -Not -Exist
        } finally { Pop-Location; Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'routes a Unity asset (under Assets, has .meta) to the Unity engine' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("netscoot_gitu_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path (Join-Path $root (Join-Path 'Assets' ('Foo'))) -Force | Out-Null
        Set-Content (Join-Path $root (Join-Path 'Assets' (Join-Path 'Foo' ('Bar.cs')))) 'public class Bar {}'
        Set-Content (Join-Path $root (Join-Path 'Assets' (Join-Path 'Foo' ('Bar.cs.meta')))) "guid: 11112222333344445555666677778888"
        Push-Location $root
        try {
            & git init -q; & git add -A; & git commit -qm fixture | Out-Null
            Register-NetscootGitAlias -Scope Local -Confirm:$false | Out-Null
            & git -C $root netscoot Assets/Foo/Bar.cs Assets/Moved/Bar.cs 2>&1 | Out-Null
            (Join-Path $root (Join-Path 'Assets' (Join-Path 'Moved' ('Bar.cs')))) | Should -Exist
            (Join-Path $root (Join-Path 'Assets' (Join-Path 'Moved' ('Bar.cs.meta')))) | Should -Exist     # .meta rode along
        } finally { Pop-Location; Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'routes a .ps1 to the PowerShell engine' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("netscoot_gitp_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path (Join-Path $root 'lib') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'app') -Force | Out-Null
        Set-Content (Join-Path $root (Join-Path 'lib' ('helpers.ps1'))) 'function Get-Greeting { "hi" }'
        Set-Content (Join-Path $root (Join-Path 'app' ('main.ps1'))) '. "$PSScriptRoot\..\lib\helpers.ps1"'
        Push-Location $root
        try {
            & git init -q; & git add -A; & git commit -qm fixture | Out-Null
            Register-NetscootGitAlias -Scope Local -Confirm:$false | Out-Null
            & git -C $root netscoot lib/helpers.ps1 shared/helpers.ps1 2>&1 | Out-Null
            (Join-Path $root (Join-Path 'shared' ('helpers.ps1'))) | Should -Exist
            (Get-Content (Join-Path $root (Join-Path 'app' ('main.ps1'))) -Raw) | Should -Match 'shared[\\/]helpers\.ps1'
        } finally { Pop-Location; Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
