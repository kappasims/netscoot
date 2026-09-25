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
        InModuleScope NetscootShared {
            # Test-IsWindowsHost is 5.1-safe; a bare $IsWindows throws here under the module's
            # StrictMode on Windows PowerShell 5.1 (where $IsWindows is not an automatic variable).
            $expected = [bool](Test-IsWindowsHost)
            (Test-PathEqual 'C:\Foo\Bar.csproj' 'C:\foo\bar.csproj') | Should -Be $expected
            (Test-PathEqual 'C:\Foo\Bar.csproj' 'C:\Foo\Bar.csproj') | Should -BeTrue
        }
    }
}

Describe 'Move-NativeProject references' -Tag 'Integration' -Skip:(-not ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop')) {
    BeforeAll {
        # A Visual Studio-shaped Calc library and CalcApp consumer, listed in both a .slnx and a .sln.
        function New-NativeSolutionFixture {
            $root = New-TempRoot -Prefix 'netscoot_natref'
            $project = @'
<?xml version="1.0" encoding="utf-8"?>
<Project DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup Label="Globals">
    <ProjectGuid>{0}</ProjectGuid>
  </PropertyGroup>
  <Import Project="$(VCTargetsPath)\Microsoft.Cpp.Default.props" />
  <ItemDefinitionGroup>
    <ClCompile>
      <AdditionalIncludeDirectories>{1}%(AdditionalIncludeDirectories)</AdditionalIncludeDirectories>
    </ClCompile>
  </ItemDefinitionGroup>
  {2}
  <Import Project="$(VCTargetsPath)\Microsoft.Cpp.targets" />
</Project>
'@
            $reference = "<ItemGroup>`r`n    <ProjectReference Include=`"..\Calc\Calc.vcxproj`">`r`n      <Project>{A1B2C3D4-0000-4000-8000-000000000001}</Project>`r`n    </ProjectReference>`r`n  </ItemGroup>"
            New-Item -ItemType Directory -Path (Join-Path $root 'Calc'), (Join-Path $root 'CalcApp') | Out-Null
            Set-Content -LiteralPath (Join-Path $root (Join-Path 'Calc' 'Calc.vcxproj')) -Value ($project.Replace('{0}', '{A1B2C3D4-0000-4000-8000-000000000001}').Replace('{1}', '').Replace('{2}', ''))
            Set-Content -LiteralPath (Join-Path $root (Join-Path 'CalcApp' 'CalcApp.vcxproj')) -Value ($project.Replace('{0}', '{A1B2C3D4-0000-4000-8000-000000000002}').Replace('{1}', '..\Calc;').Replace('{2}', $reference))
            Set-Content -LiteralPath (Join-Path $root 'Mixed.slnx') -Value @'
<Solution>
  <Configurations>
    <Platform Name="x64" />
  </Configurations>
  <Project Path="Calc/Calc.vcxproj" Id="a1b2c3d4-0000-4000-8000-000000000001" />
  <Project Path="CalcApp/CalcApp.vcxproj" Id="a1b2c3d4-0000-4000-8000-000000000002" />
</Solution>
'@
            Set-Content -LiteralPath (Join-Path $root 'Mixed.sln') -Value @'
Microsoft Visual Studio Solution File, Format Version 12.00
# Visual Studio Version 17
Project("{8BC9CEB8-8B4A-11D0-8D11-00A0C91BC942}") = "Calc", "Calc\Calc.vcxproj", "{A1B2C3D4-0000-4000-8000-000000000001}"
EndProject
Project("{8BC9CEB8-8B4A-11D0-8D11-00A0C91BC942}") = "CalcApp", "CalcApp\CalcApp.vcxproj", "{A1B2C3D4-0000-4000-8000-000000000002}"
EndProject
Global
	GlobalSection(SolutionConfigurationPlatforms) = preSolution
		Debug|x64 = Debug|x64
	EndGlobalSection
	GlobalSection(ProjectConfigurationPlatforms) = postSolution
		{A1B2C3D4-0000-4000-8000-000000000001}.Debug|x64.ActiveCfg = Debug|x64
		{A1B2C3D4-0000-4000-8000-000000000001}.Debug|x64.Build.0 = Debug|x64
	EndGlobalSection
EndGlobal
'@
            Push-Location $root
            try { & git init -q; & git add -A; & git commit -qm fixture | Out-Null } finally { Pop-Location }
            return $root
        }
    }

    It 'rewrites only the path in the .slnx entry, keeping its Id' {
        $root = New-NativeSolutionFixture
        try {
            $slnx = Join-Path $root 'Mixed.slnx'
            $before = [System.IO.File]::ReadAllText($slnx)
            Move-NativeProject -Project (Join-Path $root (Join-Path 'Calc' 'Calc.vcxproj')) -Destination (Join-Path $root (Join-Path 'lib' 'Calc')) -RepositoryRoot $root -NoJournal -Confirm:$false -WarningAction SilentlyContinue | Out-Null
            [System.IO.File]::ReadAllText($slnx) | Should -BeExactly $before.Replace('Path="Calc/Calc.vcxproj"', 'Path="lib/Calc/Calc.vcxproj"')
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rewrites only the path in the .sln entry, keeping its GUID and configuration lines' {
        $root = New-NativeSolutionFixture
        try {
            $sln = Join-Path $root 'Mixed.sln'
            $before = [System.IO.File]::ReadAllText($sln)
            Move-NativeProject -Project (Join-Path $root (Join-Path 'Calc' 'Calc.vcxproj')) -Destination (Join-Path $root (Join-Path 'lib' 'Calc')) -RepositoryRoot $root -NoJournal -Confirm:$false -WarningAction SilentlyContinue | Out-Null
            [System.IO.File]::ReadAllText($sln) | Should -BeExactly $before.Replace('"Calc\Calc.vcxproj"', '"lib\Calc\Calc.vcxproj"')
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'repoints a consuming ProjectReference, keeping its Project GUID' {
        $root = New-NativeSolutionFixture
        try {
            $app = Join-Path $root (Join-Path 'CalcApp' 'CalcApp.vcxproj')
            $before = [System.IO.File]::ReadAllText($app)
            Move-NativeProject -Project (Join-Path $root (Join-Path 'Calc' 'Calc.vcxproj')) -Destination (Join-Path $root (Join-Path 'lib' 'Calc')) -RepositoryRoot $root -NoJournal -Confirm:$false -WarningAction SilentlyContinue | Out-Null
            [System.IO.File]::ReadAllText($app) | Should -BeExactly $before.Replace('Include="..\Calc\Calc.vcxproj"', 'Include="..\lib\Calc\Calc.vcxproj"')
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rebases the moved project''s own ProjectReference' {
        $root = New-NativeSolutionFixture
        try {
            $dest = Join-Path $root (Join-Path 'apps' 'CalcApp')
            Move-NativeProject -Project (Join-Path $root (Join-Path 'CalcApp' 'CalcApp.vcxproj')) -Destination $dest -RepositoryRoot $root -NoJournal -Confirm:$false -WarningAction SilentlyContinue | Out-Null
            [System.IO.File]::ReadAllText((Join-Path $dest 'CalcApp.vcxproj')) | Should -Match ([regex]::Escape('Include="..\..\Calc\Calc.vcxproj"'))
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'reports another project''s include directory that points into the moved folder' {
        $root = New-NativeSolutionFixture
        try {
            Move-NativeProject -Project (Join-Path $root (Join-Path 'Calc' 'Calc.vcxproj')) -Destination (Join-Path $root (Join-Path 'lib' 'Calc')) -RepositoryRoot $root -NoJournal -Confirm:$false -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
            ($warnings -join "`n") | Should -Match ([regex]::Escape('CalcApp.vcxproj: [AdditionalIncludeDirectories] ..\Calc'))
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

AfterAll {
    # This file imports Netscoot.Native unconditionally (it loads on any OS). Remove it so it
    # does not leak into later test files - on non-Windows, Umbrella.Tests asserts it is absent.
    Remove-Module Netscoot.Native -Force -ErrorAction SilentlyContinue
}
