#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot TestHelpers.ps1)
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Core' ('Netscoot.Core.psd1'))))) -Force

    function New-SoloFixture {
        Copy-FixtureTemplate -Key 'solo-lib-sln' -Prefix 'netscoot_cap' -Build {
            $root = New-TempRoot -Prefix 'netscoot_cap'
            Push-Location $root
            try {
                New-ClassLibProject -Name Lib -Directory (Join-Path $root 'Lib') | Out-Null
                Invoke-Dotnet -Arguments @('new', 'sln', '-n', 'Demo', '--format', 'slnx')
                Invoke-Dotnet -Arguments @('sln', 'Demo.slnx', 'add', (Join-Path $root (Join-Path 'Lib' ('Lib.csproj'))))
            } finally { Pop-Location }
            return $root
        }
    }
}

Describe 'Get-NetscootCapability' {
    It 'reports dotnet present with .slnx support and a platform' {
        $cap = Get-NetscootCapability
        $cap.Dotnet.Present | Should -BeTrue
        $cap.DotnetSupportsSlnx | Should -BeTrue          # .NET 9+ on this machine
        $cap.Platform | Should -BeIn @('Windows', 'macOS', 'Linux')
    }

    It 'reports no .slnx support for a 9.0.1xx SDK' {
        Mock -ModuleName Netscoot.Core Get-ExternalTool -ParameterFilter { $Name -eq 'dotnet' } { [pscustomobject]@{ Name = $Name; Present = $true; Version = '9.0.110' } }
        (Get-NetscootCapability).DotnetSupportsSlnx | Should -BeFalse
    }

    It 'reports .slnx support for a 9.0.200 SDK' {
        Mock -ModuleName Netscoot.Core Get-ExternalTool -ParameterFilter { $Name -eq 'dotnet' } { [pscustomobject]@{ Name = $Name; Present = $true; Version = '9.0.200' } }
        (Get-NetscootCapability).DotnetSupportsSlnx | Should -BeTrue
        Should -Invoke -ModuleName Netscoot.Core Get-ExternalTool -Times 1 -Exactly -ParameterFilter { $Name -eq 'dotnet' }
    }
}

Describe 'Required-tool gating (dotnet)' {
    It 'aborts with a clear error when dotnet is missing' {
        Mock -ModuleName NetscootShared Test-DotnetAvailable { $false }
        Mock -ModuleName NetscootShared Test-InteractiveSession { $false }
        Mock -ModuleName NetscootShared Write-CapabilityGuidance { }
        $errs = @(Move-DotnetProject -Project 'X:/nope/Foo.csproj' -Destination 'X:/dst' `
                -ErrorAction Continue 2>&1 | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
        $errs.Count | Should -Be 1
        $errs[0].FullyQualifiedErrorId | Should -BeLike 'DotnetMissing*'
    }
}

Describe 'Optional-tool fallback (git)' -Tag 'Integration' {
    It 'falls back to a plain move when git is missing and -Force is given' {
        Mock -ModuleName NetscootShared Test-GitAvailable { $false }
        $root = New-SoloFixture
        try {
            $lib = Join-Path $root (Join-Path 'Lib' ('Lib.csproj'))
            $dest = Join-Path $root (Join-Path 'libs' ('Lib'))
            $r = Move-DotnetProject -Project $lib -Destination $dest -RepositoryRoot $root -NoBuild -Force -Confirm:$false -WarningAction SilentlyContinue
            $r.Performed | Should -BeTrue
            (Join-Path $dest 'Lib.csproj') | Should -Exist
            $lib | Should -Not -Exist
            Should -Invoke -ModuleName NetscootShared Test-GitAvailable
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
