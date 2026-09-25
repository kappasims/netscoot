#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'src', 'Netscoot.Core', 'Netscoot.Core.psd1')) -Force
    Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'src', 'Netscoot.Native', 'Netscoot.Native.psd1')) -Force
    Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'src', 'Netscoot.Unity', 'Netscoot.Unity.psd1')) -Force

    function New-AppLibFixture {
        Copy-FixtureTemplate -Key 'rollback-applib' -Prefix 'netscoot_rb' -Build {
            $root = New-TempRoot -Prefix 'netscoot_rb'
            Push-Location $root
            try {
                & git init -q
                New-ClassLibProject -Name Lib -Directory (Join-Path $root (Join-Path 'src' 'Lib')) | Out-Null
                New-ConsoleProject -Name App -Directory (Join-Path $root (Join-Path 'src' 'App')) | Out-Null
                & dotnet add (Join-Path $root (Join-Path 'src' (Join-Path 'App' 'App.csproj'))) reference (Join-Path $root (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))) | Out-Null
                & dotnet new sln -n Demo --format slnx | Out-Null
                & dotnet sln Demo.slnx add (Join-Path $root (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))) (Join-Path $root (Join-Path 'src' (Join-Path 'App' 'App.csproj'))) | Out-Null
            } finally { Pop-Location }
            return $root
        }
    }
}

AfterAll {
    # Netscoot.Native is imported unconditionally here; remove it so it cannot leak into Umbrella.Tests.
    Remove-Module Netscoot.Native -Force -ErrorAction SilentlyContinue
}

Describe 'Move-DotnetProject rolls back on a failed reattach (-Force / no-git path)' -Tag 'Integration' {
    It 'restores the project location, the consumer reference, and solution membership' {
        $root = New-AppLibFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))
            $app = Join-Path $root (Join-Path 'src' (Join-Path 'App' 'App.csproj'))
            $dest = Join-Path $root (Join-Path 'libs' 'Lib')

            # Force the no-git plain-move path, and make every reattach (dotnet ... add) fail so the
            # transaction throws after the detaches + move have already happened.
            Mock -ModuleName NetscootShared Test-GitAvailable { $false }
            Mock -ModuleName NetscootShared Invoke-Dotnet {
                if ($Arguments -contains 'add') { throw 'simulated reattach failure' }
                & dotnet @Arguments 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "dotnet $($Arguments -join ' ') failed" }
            }

            { Move-DotnetProject -Project $lib -Destination $dest -RepositoryRoot $root -NoBuild -Force -Confirm:$false } |
                Should -Throw -ExpectedMessage '*rolled back*'

            # Project is back at its original location, not at the destination.
            $lib | Should -Exist
            (Join-Path $dest 'Lib.csproj') | Should -Not -Exist
            # Consumer reference restored to the original relative path.
            (Get-Content -LiteralPath $app -Raw) | Should -Match 'Lib\.csproj'
            (Get-Content -LiteralPath $app -Raw) | Should -Not -Match 'libs'
            # Solution membership restored to the original path.
            (& dotnet sln (Join-Path $root 'Demo.slnx') list) -join "`n" | Should -Match 'src[\\/]Lib[\\/]Lib\.csproj'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Every other mover rolls back on a failed step (-Force / no-git path)' -Tag 'Integration' {
    BeforeAll {
        # Simulates a reattach that edited one file (the first item's, wherever it now lives) and then failed.
        $script:FailReattachAfterEdit = {
            $ref = $Items[0].ReattachArgs[0]
            $file = if (Test-Path -LiteralPath $ref.File) { $ref.File } else { $Items[0].ReattachArgs[1] }
            Add-Content -LiteralPath $file -Value 'partial edit'
            throw 'simulated reattach failure'
        }
    }

    BeforeEach {
        Mock -ModuleName NetscootShared Test-GitAvailable { $false }
    }

    It 'Move-PowerShellScript restores the script and its caller' {
        $root = New-TempRoot -Prefix 'netscoot_rbps'
        try {
            $lib = Join-Path $root (Join-Path 'lib' 'Common.ps1')
            $main = Join-Path $root 'Main.ps1'
            New-Item -ItemType Directory -Path (Split-Path $lib) | Out-Null
            Set-Content -LiteralPath $lib -Value 'function Write-Common { }'
            Set-Content -LiteralPath $main -Value '. "$PSScriptRoot/lib/Common.ps1"'
            $before = Get-Content -LiteralPath $main -Raw
            Mock -ModuleName NetscootShared Invoke-MovePhase -ParameterFilter { $Phase -eq 'Reattach' } -MockWith $script:FailReattachAfterEdit

            { Move-PowerShellScript -Path $lib -Destination (Join-Path $root (Join-Path 'shared' 'Common.ps1')) -RepositoryRoot $root -Force -Confirm:$false } |
                Should -Throw -ExpectedMessage '*rolled back*'

            $lib | Should -Exist
            (Join-Path $root (Join-Path 'shared' 'Common.ps1')) | Should -Not -Exist
            Get-Content -LiteralPath $main -Raw | Should -Be $before
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Move-MSBuildImport restores the import file and its importer' {
        $root = New-TempRoot -Prefix 'netscoot_rbimp'
        try {
            $props = Join-Path $root 'Shared.props'
            Set-Content -LiteralPath $props -Value '<Project />'
            $app = New-ClassLibProject -Name App -Directory (Join-Path $root (Join-Path 'src' 'App'))
            $text = (Get-Content -LiteralPath $app -Raw) -replace '(<Project Sdk="Microsoft\.NET\.Sdk">)', "`$1`n  <Import Project=`"..\..\Shared.props`" />"
            Set-Content -LiteralPath $app -Value $text -NoNewline
            $before = Get-Content -LiteralPath $app -Raw
            Mock -ModuleName NetscootShared Invoke-MovePhase -ParameterFilter { $Phase -eq 'Reattach' } -MockWith $script:FailReattachAfterEdit

            { Move-MSBuildImport -Path $props -Destination (Join-Path $root (Join-Path 'build' 'Shared.props')) -RepositoryRoot $root -Force -Confirm:$false } |
                Should -Throw -ExpectedMessage '*rolled back*'

            $props | Should -Exist
            (Join-Path $root (Join-Path 'build' 'Shared.props')) | Should -Not -Exist
            Get-Content -LiteralPath $app -Raw | Should -Be $before
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Move-Solution restores the solution and its stored project paths' {
        $root = New-TempRoot -Prefix 'netscoot_rbsln'
        try {
            $lib = New-ClassLibProject -Name Lib -Directory (Join-Path $root (Join-Path 'src' 'Lib'))
            Push-Location $root
            try { & dotnet new sln -n Demo --format slnx | Out-Null; & dotnet sln Demo.slnx add $lib | Out-Null } finally { Pop-Location }
            $sln = Join-Path $root 'Demo.slnx'
            $before = Get-Content -LiteralPath $sln -Raw
            Mock -ModuleName NetscootShared Invoke-MovePhase -ParameterFilter { $Phase -eq 'Reattach' } -MockWith $script:FailReattachAfterEdit

            { Move-Solution -Path $sln -Destination (Join-Path $root (Join-Path 'build' 'Demo.slnx')) -Force -Confirm:$false } |
                Should -Throw -ExpectedMessage '*rolled back*'

            $sln | Should -Exist
            (Join-Path $root (Join-Path 'build' 'Demo.slnx')) | Should -Not -Exist
            Get-Content -LiteralPath $sln -Raw | Should -Be $before
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Move-NativeProject restores the project folder and solution membership' -Skip:(-not ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop')) {
        $root = New-TempRoot -Prefix 'netscoot_rbnat'
        try {
            $dir = Join-Path $root 'Calc'
            New-Item -ItemType Directory -Path $dir | Out-Null
            $vcx = Join-Path $dir 'Calc.vcxproj'
            Set-Content -LiteralPath $vcx -Value '<?xml version="1.0" encoding="utf-8"?><Project ToolsVersion="Current" xmlns="http://schemas.microsoft.com/developer/msbuild/2003" />'
            Push-Location $root
            try { & dotnet new sln -n Demo --format slnx | Out-Null; & dotnet sln Demo.slnx add $vcx | Out-Null } finally { Pop-Location }
            $sln = Join-Path $root 'Demo.slnx'
            $before = Get-Content -LiteralPath $sln -Raw
            Mock -ModuleName NetscootShared Invoke-MovePhase -ParameterFilter { $Phase -eq 'Reattach' } -MockWith $script:FailReattachAfterEdit

            { Move-NativeProject -Project $vcx -Destination (Join-Path $root (Join-Path 'native' 'Calc')) -RepositoryRoot $root -Force -Confirm:$false -WarningAction SilentlyContinue } |
                Should -Throw -ExpectedMessage '*rolled back*'

            $vcx | Should -Exist
            (Join-Path $root (Join-Path 'native' 'Calc')) | Should -Not -Exist
            Get-Content -LiteralPath $sln -Raw | Should -Be $before
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Move-UnityAsset puts the asset back when its .meta cannot follow' {
        $root = New-TempRoot -Prefix 'netscoot_rbuni'
        try {
            $assets = Join-Path $root 'Assets'
            New-Item -ItemType Directory -Path (Join-Path $assets 'Sub') -Force | Out-Null
            $cs = Join-Path $assets 'Foo.cs'
            Set-Content -LiteralPath $cs -Value 'public class Foo {}'
            Set-Content -LiteralPath "$cs.meta" -Value "fileFormatVersion: 2`nguid: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            Mock -ModuleName Netscoot.Unity Move-PathTracked {
                if ($Source -like '*.meta') { throw 'simulated meta move failure' }
                Move-Item -LiteralPath $Source -Destination $Destination
            }

            { Move-UnityAsset -AssetPath $cs -Destination (Join-Path $assets 'Sub') -RepositoryRoot $root -Force -Confirm:$false } |
                Should -Throw -ExpectedMessage '*rolled back*'

            $cs | Should -Exist
            "$cs.meta" | Should -Exist
            (Join-Path $assets (Join-Path 'Sub' 'Foo.cs')) | Should -Not -Exist
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
