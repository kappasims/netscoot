#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    # Core must load before Native (Native declares RequiredModules = Netscoot.Core).
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Core' ('Netscoot.Core.psd1'))))) -Force
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Native' ('Netscoot.Native.psd1'))))) -Force

    function New-NativeFixture {
        # A minimal hand-written .vcxproj with native path-bearing settings (no build needed).
        $root = New-TempRoot -Prefix 'netscoot_nat'
        $proj = Join-Path $root 'Foo'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        $vcx = Join-Path $proj 'Foo.vcxproj'
        @'
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="Current" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <Import Project="..\shared\Native.props" />
  <ItemDefinitionGroup>
    <ClCompile>
      <AdditionalIncludeDirectories>$(ProjectDir)..\Bar\include;%(AdditionalIncludeDirectories)</AdditionalIncludeDirectories>
    </ClCompile>
    <Link>
      <AdditionalLibraryDirectories>$(SolutionDir)$(Platform)\$(Configuration);%(AdditionalLibraryDirectories)</AdditionalLibraryDirectories>
      <AdditionalDependencies>Bar.lib;%(AdditionalDependencies)</AdditionalDependencies>
    </Link>
  </ItemDefinitionGroup>
</Project>
'@ | Set-Content -LiteralPath $vcx -Encoding UTF8
        return $vcx
    }
}

Describe 'Native project handling' {
    It 'Move-DotnetProject refuses a .vcxproj with a clear error' {
        $vcx = New-NativeFixture
        try {
            Move-DotnetProject -Project $vcx -Destination (Join-Path (Split-Path $vcx) (Join-Path '..' ('moved'))) -ErrorVariable errs -ErrorAction SilentlyContinue | Out-Null
            $errs[0].FullyQualifiedErrorId | Should -Match 'NativeProjectNotSupported'
        } finally { Remove-Item -LiteralPath (Split-Path (Split-Path $vcx)) -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Move-NativeProject (Windows) reports unreconciled native settings under -WhatIf' -Skip:(-not ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop')) {
        $vcx = New-NativeFixture
        try {
            $r = Move-NativeProject -Project $vcx -Destination (Join-Path (Split-Path $vcx) (Join-Path '..' ('moved'))) -RepositoryRoot (Split-Path (Split-Path $vcx)) -WhatIf -WarningAction SilentlyContinue
            $r.Performed | Should -BeFalse
            $r.UnreconciledSettings.Count | Should -BeGreaterThan 0
        } finally { Remove-Item -LiteralPath (Split-Path (Split-Path $vcx)) -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Get-NativePathSettings finds and dedupes the path-bearing settings' {
        $vcx = New-NativeFixture
        try {
            InModuleScope Netscoot.Native -Parameters @{ Vcx = $vcx } {
                param($Vcx)
                $settings = Get-NativePathSettings -ProjectFile $Vcx
                ($settings.Kind | Sort-Object -Unique) | Should -Contain 'Import'
                ($settings.Kind | Sort-Object -Unique) | Should -Contain 'AdditionalLibraryDirectories'
                ($settings.Kind | Sort-Object -Unique) | Should -Contain 'AdditionalIncludeDirectories'
            }
        } finally { Remove-Item -LiteralPath (Split-Path (Split-Path $vcx)) -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'OS-aware path comparison' {
    It 'matches Windows case-insensitivity / non-Windows case-sensitivity' {
        InModuleScope Netscoot.Shared {
            # Test-IsWindowsHost is 5.1-safe; a bare $IsWindows throws here under the module's
            # StrictMode on Windows PowerShell 5.1 (where $IsWindows is not an automatic variable).
            $expected = [bool](Test-IsWindowsHost)
            (Test-PathEqual 'C:\Foo\Bar.csproj' 'C:\foo\bar.csproj') | Should -Be $expected
            (Test-PathEqual 'C:\Foo\Bar.csproj' 'C:\Foo\Bar.csproj') | Should -BeTrue
        }
    }
}

AfterAll {
    # This file imports Netscoot.Native unconditionally (it loads on any OS). Remove it so it
    # does not leak into later test files - on non-Windows, Umbrella.Tests asserts it is absent.
    Remove-Module Netscoot.Native -Force -ErrorAction SilentlyContinue
}
