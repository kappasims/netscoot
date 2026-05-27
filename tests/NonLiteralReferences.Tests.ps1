#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot TestHelpers.ps1)
    Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'src', 'Netscoot.Core', 'Netscoot.Core.psd1')) -Force

    function New-TempDir {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ("netscoot_nlr_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $d | Out-Null
        return $d
    }

    function Add-ProjectReference {
        # Append a raw <ProjectReference> (optionally conditional) to a project file's first ItemGroup.
        param([string]$ProjectFile, [string]$Include, [string]$Condition)
        $cond = if ($Condition) { " Condition=`"$Condition`"" } else { '' }
        $xml = "  <ItemGroup><ProjectReference Include=`"$Include`"$cond /></ItemGroup>`n</Project>"
        $text = (Get-Content -LiteralPath $ProjectFile -Raw) -replace '</Project>\s*$', $xml
        Set-Content -LiteralPath $ProjectFile -Value $text -Encoding UTF8
    }
}

Describe 'Reference classification' {
    It 'flags non-literal and conditional ProjectReferences, leaves literals alone' {
        $dir = New-TempDir
        try {
            $proj = Join-Path $dir 'P.csproj'
            Set-Content -LiteralPath $proj -Encoding UTF8 -Value "<Project Sdk=`"Microsoft.NET.Sdk`">`n</Project>"
            Add-ProjectReference -ProjectFile $proj -Include '..\Lib\Lib.csproj'                 # literal
            Add-ProjectReference -ProjectFile $proj -Include '$(SharedDir)\Shared.csproj'         # MSBuild property
            Add-ProjectReference -ProjectFile $proj -Include '..\plugins\*.csproj'                # wildcard
            Add-ProjectReference -ProjectFile $proj -Include '..\Opt\Opt.csproj' -Condition "'`$(Cfg)'=='Debug'"  # conditional but literal path

            InModuleScope Netscoot.Shared -Parameters @{ Proj = $proj } {
                param($Proj)
                $refs = Get-ProjectReferencePaths -ProjectFile $Proj
                ($refs | Where-Object { $_.Raw -eq '..\Lib\Lib.csproj' }).IsLiteral | Should -BeTrue
                ($refs | Where-Object { $_.Raw -like '*SharedDir*' }).IsLiteral | Should -BeFalse
                ($refs | Where-Object { $_.Raw -like '*plugins*' }).IsLiteral | Should -BeFalse
                ($refs | Where-Object { $_.Raw -eq '..\Opt\Opt.csproj' }).HasCondition | Should -BeTrue

                $unrec = Get-UnreconcilableReferences -ProjectFile $Proj
                ($unrec.Raw | Sort-Object) | Should -Be (@('$(SharedDir)\Shared.csproj', '..\Opt\Opt.csproj', '..\plugins\*.csproj') | Sort-Object)
            }
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Move-DotnetProject with a non-literal reference' {
    It 'warns that the reference cannot be reconciled (and the literal move still planned)' {
        $root = New-TempDir
        Push-Location $root
        try {
            & git init -q
            New-StubClassLib -Name Lib -Directory (Join-Path $root (Join-Path 'src' 'Lib')) | Out-Null
            & dotnet new sln -n Demo --format slnx | Out-Null
            & dotnet sln Demo.slnx add (Join-Path $root (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))) | Out-Null
            Add-ProjectReference -ProjectFile (Join-Path $root (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))) -Include '$(SharedDir)\Shared.csproj'
            & git add -A; & git commit -qm fixture | Out-Null

            # -WhatIf: the warning is emitted before any mutation, so this is side-effect free.
            Move-DotnetProject -Project (Join-Path $root (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))) `
                -Destination (Join-Path $root (Join-Path 'libs' 'Lib')) -RepositoryRoot $root -NoBuild -WhatIf `
                -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            ($w -join "`n") | Should -Match 'unreconcilable ProjectReference'
            ($w -join "`n") | Should -Match 'SharedDir'
        } finally { Pop-Location; Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Repair-SolutionReferences and non-literal references' {
    It 'does not report a non-literal reference as dangling' {
        $root = New-TempDir
        Push-Location $root
        try {
            & git init -q
            New-StubClassLib -Name Lib -Directory (Join-Path $root 'Lib') | Out-Null
            Add-ProjectReference -ProjectFile (Join-Path $root (Join-Path 'Lib' 'Lib.csproj')) -Include '$(PluginDir)\Plugin.csproj'
            $probs = Repair-SolutionReferences -RepositoryRoot $root
            # The only csproj has just a non-literal reference, so there is nothing dangling.
            ($probs | Where-Object { $_.Kind -eq 'Reference' }) | Should -BeNullOrEmpty
        } finally { Pop-Location; Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
