#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot TestHelpers.ps1)
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Core' ('Netscoot.Core.psd1'))))) -Force

    function New-SoloFixture {
        $root = New-TempRoot -Prefix 'netscoot_cap'
        Push-Location $root
        try {
            New-StubClassLib -Name Lib -Directory (Join-Path $root 'Lib') | Out-Null
            & dotnet new sln -n Demo --format slnx | Out-Null
            & dotnet sln Demo.slnx add (Join-Path $root (Join-Path 'Lib' ('Lib.csproj'))) | Out-Null
        } finally { Pop-Location }
        return $root
    }
}

Describe 'Get-NetscootCapability' {
    It 'reports dotnet present with .slnx support and a platform' {
        $cap = Get-NetscootCapability
        $cap.Dotnet.Present | Should -BeTrue
        $cap.DotnetSupportsSlnx | Should -BeTrue          # .NET 9+ on this machine
        $cap.Platform | Should -BeIn @('Windows', 'macOS', 'Linux')
    }
}

Describe 'Required-tool gating (dotnet)' {
    It 'aborts with a clear error when dotnet is missing' {
        Mock -ModuleName Netscoot.Shared Test-DotnetAvailable { $false }
        Move-DotnetProject -Project 'X:/nope/Foo.csproj' -Destination 'X:/dst' `
            -ErrorVariable errs -ErrorAction SilentlyContinue | Out-Null
        $errs[0].FullyQualifiedErrorId | Should -Match 'DotnetMissing'
    }
}

Describe 'Optional-tool fallback (git)' {
    It 'falls back to a plain move when git is missing and -Force is given' {
        Mock -ModuleName Netscoot.Shared Test-GitAvailable { $false }
        $root = New-SoloFixture
        try {
            $lib = Join-Path $root (Join-Path 'Lib' ('Lib.csproj'))
            $dest = Join-Path $root (Join-Path 'libs' ('Lib'))
            $r = Move-DotnetProject -Project $lib -Destination $dest -RepositoryRoot $root -NoBuild -Force -Confirm:$false -WarningAction SilentlyContinue
            $r.Performed | Should -BeTrue
            (Join-Path $dest 'Lib.csproj') | Should -Exist
            $lib | Should -Not -Exist
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
