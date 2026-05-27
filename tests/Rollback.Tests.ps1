#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'src', 'Netscoot.Core', 'Netscoot.Core.psd1')) -Force

    function New-AppLibFixture {
        $root = New-TempRoot -Prefix 'netscoot_rb'
        Push-Location $root
        try {
            & git init -q
            New-StubClassLib -Name Lib -Directory (Join-Path $root (Join-Path 'src' 'Lib')) | Out-Null
            New-StubConsole -Name App -Directory (Join-Path $root (Join-Path 'src' 'App')) | Out-Null
            & dotnet add (Join-Path $root (Join-Path 'src' (Join-Path 'App' 'App.csproj'))) reference (Join-Path $root (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))) | Out-Null
            & dotnet new sln -n Demo --format slnx | Out-Null
            & dotnet sln Demo.slnx add (Join-Path $root (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))) (Join-Path $root (Join-Path 'src' (Join-Path 'App' 'App.csproj'))) | Out-Null
        } finally { Pop-Location }
        return $root
    }
}

Describe 'Move-DotnetProject rolls back on a failed reattach (-Force / no-git path)' {
    It 'restores the project location, the consumer reference, and solution membership' {
        $root = New-AppLibFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))
            $app = Join-Path $root (Join-Path 'src' (Join-Path 'App' 'App.csproj'))
            $dest = Join-Path $root (Join-Path 'libs' 'Lib')

            # Force the no-git plain-move path, and make every reattach (dotnet ... add) fail so the
            # transaction throws after the detaches + move have already happened.
            Mock -ModuleName Netscoot.Shared Test-GitAvailable { $false }
            Mock -ModuleName Netscoot.Shared Invoke-Dotnet {
                if ($Arguments -contains 'add') { throw 'simulated reattach failure' }
                & dotnet @Arguments 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "dotnet $($Arguments -join ' ') failed" }
            }

            { Move-DotnetProject -Project $lib -Destination $dest -RepoRoot $root -NoBuild -Force -Confirm:$false } |
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
