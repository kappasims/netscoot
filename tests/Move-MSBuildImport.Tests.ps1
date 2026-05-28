#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Core' ('Netscoot.Core.psd1'))))) -Force

    function New-ImportFixture {
        # root/Shared.props ; src/App/App.csproj imports it via ..\..\Shared.props
        $root = New-TempRoot -Prefix 'netscoot_imp'
        $app = Join-Path (Join-Path $root 'src') 'App'
        New-Item -ItemType Directory -Path $app -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'Shared.props') -Encoding UTF8 -Value @'
<Project>
  <PropertyGroup>
    <SharedFlag>true</SharedFlag>
  </PropertyGroup>
</Project>
'@
        Set-Content -LiteralPath (Join-Path $app 'App.csproj') -Encoding UTF8 -Value @'
<Project Sdk="Microsoft.NET.Sdk">
  <Import Project="..\..\Shared.props" />
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
  </PropertyGroup>
</Project>
'@
        Set-Content -LiteralPath (Join-Path $app 'Program.cs') -Value 'System.Console.WriteLine("hi");' -Encoding UTF8
        Push-Location $root
        try { & git init -q; & git add -A; & git commit -qm fixture | Out-Null } finally { Pop-Location }
        return $root
    }

    function New-VcxprojImportFixture {
        # root/Shared.props ; Native/Native.vcxproj (old-style, MSBuild xmlns) imports it via ..\Shared.props
        $root = New-TempRoot -Prefix 'netscoot_vcx'
        $nat = Join-Path $root 'Native'
        New-Item -ItemType Directory -Path $nat -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'Shared.props') -Encoding UTF8 -Value @'
<Project>
  <PropertyGroup>
    <SharedFlag>true</SharedFlag>
  </PropertyGroup>
</Project>
'@
        Set-Content -LiteralPath (Join-Path $nat 'Native.vcxproj') -Encoding UTF8 -Value @'
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="Current" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <Import Project="..\Shared.props" />
  <ItemGroup>
    <ClCompile Include="main.cpp" />
  </ItemGroup>
</Project>
'@
        Push-Location $root
        try { & git init -q; & git add -A; & git commit -qm fixture | Out-Null } finally { Pop-Location }
        return $root
    }
}

Describe 'Move-MSBuildImport' {
    It 'fixes a consumer<Import> relative path and the project still builds' {
        $root = New-ImportFixture
        try {
            $props = Join-Path $root 'Shared.props'
            $dest = Join-Path (Join-Path $root 'build') 'Shared.props'
            $r = Move-MSBuildImport -Path $props -Destination $dest -RepositoryRoot $root -Confirm:$false -WarningAction SilentlyContinue
            $r.ImportersFixed | Should -Be 1
            $dest | Should -Exist
            $props | Should -Not -Exist

            $appText = Get-Content (Join-Path $root (Join-Path 'src' (Join-Path 'App' ('App.csproj')))) -Raw
            $appText | Should -Match 'Project="\.\.[\\/]\.\.[\\/]build[\\/]Shared\.props"'

            $bo = & dotnet build (Join-Path $root (Join-Path 'src' (Join-Path 'App' ('App.csproj')))) 2>&1
            $LASTEXITCODE | Should -Be 0 -Because ($bo -join [Environment]::NewLine)
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'warns (not fix) for location-based Directory.Build.props' {
        $root = New-ImportFixture
        try {
            Set-Content -LiteralPath (Join-Path $root 'Directory.Build.props') -Encoding UTF8 -Value "<Project></Project>"
            $r = Move-MSBuildImport -Path (Join-Path $root 'Directory.Build.props') `
                -Destination (Join-Path (Join-Path $root 'build') 'Directory.Build.props') `
                -RepositoryRoot $root -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue
            $r.AutoImported | Should -BeTrue
            ($w -join "`n") | Should -Match 'imported by LOCATION'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'fixes a native .vcxproj <Import> path too (path-only, any OS)' {
        $root = New-VcxprojImportFixture
        try {
            $r = Move-MSBuildImport -Path (Join-Path $root 'Shared.props') `
                -Destination (Join-Path (Join-Path $root 'build') 'Shared.props') `
                -RepositoryRoot $root -Confirm:$false -WarningAction SilentlyContinue
            $r.ImportersFixed | Should -Be 1
            (Get-Content (Join-Path $root (Join-Path 'Native' ('Native.vcxproj'))) -Raw) |
                Should -Match 'Project="\.\.[\\/]build[\\/]Shared\.props"'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
