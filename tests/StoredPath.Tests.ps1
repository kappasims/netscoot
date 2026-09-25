#requires -Modules Pester

BeforeAll {
    Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'src', 'NetscootShared', 'NetscootShared.psd1')) -Force

    # A fake absolute root: nothing here reads or writes the filesystem.
    $script:Root = if ([System.IO.Path]::DirectorySeparatorChar -eq '\') { 'C:\repo' } else { '/repo' }
    function Get-RootedPath { param([string[]]$Segments) [System.IO.Path]::Combine([string[]](@($script:Root) + $Segments)) }
}

Describe 'Netscoot.StoredPath text' {
    It 'keeps a .slnx entry on forward slashes when its target moves' {
        $ref = [Netscoot.StoredPath]::InSlnxEntry((Get-RootedPath 'Demo.slnx'), 'src/Lib/Lib.csproj', (Get-RootedPath 'src', 'Lib', 'Lib.csproj'))
        $ref.RawPointingAt((Get-RootedPath 'libs', 'Lib', 'Lib.csproj')) | Should -BeExactly 'libs/Lib/Lib.csproj'
    }

    It 'writes a separator-free .slnx entry with a forward slash once it needs one' {
        $ref = [Netscoot.StoredPath]::InSlnxEntry((Get-RootedPath 'Demo.slnx'), 'Lib.csproj', (Get-RootedPath 'Lib.csproj'))
        $ref.RawFollowing((Get-RootedPath 'build', 'Demo.slnx')) | Should -BeExactly '../Lib.csproj'
    }

    It 'writes a separator-free .sln entry with a backslash once it needs one' {
        $ref = [Netscoot.StoredPath]::InSolutionEntry((Get-RootedPath 'Demo.sln'), 'Lib.csproj', (Get-RootedPath 'Lib.csproj'))
        $ref.RawFollowing((Get-RootedPath 'build', 'Demo.sln')) | Should -BeExactly '..\Lib.csproj'
    }

    It 'repoints a ProjectReference Include in its backslash style' {
        $ref = [Netscoot.StoredPath]::InAttribute((Get-RootedPath 'native', 'CalcApp', 'CalcApp.vcxproj'), 'Include', '..\Calc\Calc.vcxproj', (Get-RootedPath 'native', 'Calc', 'Calc.vcxproj'))
        $ref.RawPointingAt((Get-RootedPath 'native', 'lib', 'Calc', 'Calc.vcxproj')) | Should -BeExactly '..\lib\Calc\Calc.vcxproj'
    }

    It 'keeps the $(MSBuildThisFileDirectory) prefix on an Import' {
        $ref = [Netscoot.StoredPath]::InAttribute((Get-RootedPath 'src', 'App', 'App.csproj'), 'Project', '$(MSBuildThisFileDirectory)..\..\Shared.props', (Get-RootedPath 'Shared.props'))
        $ref.RawPointingAt((Get-RootedPath 'build', 'Shared.props')) | Should -BeExactly '$(MSBuildThisFileDirectory)..\..\build\Shared.props'
    }

    It 'keeps a script path on $PSScriptRoot with forward slashes' {
        $ref = [Netscoot.StoredPath]::InScript((Get-RootedPath 'Main.ps1'), '$PSScriptRoot/lib/Common.ps1', (Get-RootedPath 'lib', 'Common.ps1'))
        $ref.RawPointingAt((Get-RootedPath 'shared', 'Common.ps1')) | Should -BeExactly '$PSScriptRoot/shared/Common.ps1'
    }

    It 'keeps a script path on $PSScriptRoot with backslashes' {
        $ref = [Netscoot.StoredPath]::InScript((Get-RootedPath 'Main.ps1'), '$PSScriptRoot\lib\Common.ps1', (Get-RootedPath 'lib', 'Common.ps1'))
        $ref.RawPointingAt((Get-RootedPath 'shared', 'Common.ps1')) | Should -BeExactly '$PSScriptRoot\shared\Common.ps1'
    }

    It 'prefixes a dot-relative script path that lands in the same folder' {
        $ref = [Netscoot.StoredPath]::InScript((Get-RootedPath 'Main.ps1'), './lib/Common.ps1', (Get-RootedPath 'lib', 'Common.ps1'))
        $ref.RawPointingAt((Get-RootedPath 'Common.ps1')) | Should -BeExactly './Common.ps1'
    }

    It 'rebases a script path when the file holding it moves deeper' {
        $ref = [Netscoot.StoredPath]::InScript((Get-RootedPath 'Main.ps1'), '$PSScriptRoot/lib/Common.ps1', (Get-RootedPath 'lib', 'Common.ps1'))
        $ref.RawFollowing((Get-RootedPath 'bin', 'Main.ps1')) | Should -BeExactly '$PSScriptRoot/../lib/Common.ps1'
    }
}
