#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Core' ('Netscoot.Core.psd1'))))) -Force

    function New-EngineFixture {
        $root = New-TempRoot -Prefix 'netscoot_eng'
        New-Item -ItemType Directory -Path (Join-Path $root (Join-Path 'Assets' ('Art'))) -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'proj') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'mod') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'empty') -Force | Out-Null
        Set-Content (Join-Path $root (Join-Path 'Assets' (Join-Path 'Art' ('logo.png')))) 'PNG'
        Set-Content (Join-Path $root (Join-Path 'Assets' (Join-Path 'Art' ('logo.png.meta')))) 'guid: abc'
        Set-Content (Join-Path $root (Join-Path 'proj' ('App.csproj'))) '<Project/>'
        Set-Content (Join-Path $root (Join-Path 'mod' ('Mod.psd1'))) '@{}'
        return $root
    }
}

Describe 'Resolve-MoveEngine' {
    It 'classifies by extension' {
        Resolve-MoveEngine 'lib/Foo.csproj'      | Should -Be 'dotnet'
        Resolve-MoveEngine 'lib/Foo.fsproj'      | Should -Be 'dotnet'
        Resolve-MoveEngine 'App.sln'             | Should -Be 'dotnet'
        Resolve-MoveEngine 'App.slnx'            | Should -Be 'dotnet'
        Resolve-MoveEngine 'Directory.Build.props' | Should -Be 'dotnet'
        Resolve-MoveEngine 'Native.vcxproj'      | Should -Be 'native'
        Resolve-MoveEngine 'Game.asmdef'         | Should -Be 'unity'
        Resolve-MoveEngine 'Build.ps1'           | Should -Be 'ps-script'
        Resolve-MoveEngine 'Mod.psd1'            | Should -Be 'ps-module'
        Resolve-MoveEngine 'notes.txt'           | Should -Be 'unknown'
    }

    It 'classifies a path under an Assets/ tree as unity' {
        Resolve-MoveEngine 'C:/repo/Assets/Art/logo.png' | Should -Be 'unity'
    }

    It 'classifies a file with a sidecar .meta as unity' {
        $root = New-EngineFixture
        try {
            Resolve-MoveEngine (Join-Path $root (Join-Path 'Assets' (Join-Path 'Art' ('logo.png')))) | Should -Be 'unity'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force }
    }

    It 'classifies folders by content' {
        $root = New-EngineFixture
        try {
            Resolve-MoveEngine (Join-Path $root 'proj')  | Should -Be 'dotnet'
            Resolve-MoveEngine (Join-Path $root 'mod')   | Should -Be 'ps-module'
            Resolve-MoveEngine (Join-Path $root 'empty') | Should -Be 'unknown'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force }
    }

    It 'accepts pipeline input' {
        ('a.csproj', 'b.vcxproj' | Resolve-MoveEngine) | Should -Be @('dotnet', 'native')
    }
}
