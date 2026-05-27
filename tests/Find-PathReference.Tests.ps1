#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Core' ('Netscoot.Core.psd1'))))) -Force

    function New-RefFixture {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("netscoot_ref_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path (Join-Path $root 'lib') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root (Join-Path '.github' ('workflows'))) -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root '.githooks') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'tools') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'src') -Force | Out-Null
        Set-Content (Join-Path $root (Join-Path 'lib' ('Foo.csproj'))) '<Project/>'
        Set-Content (Join-Path $root 'build.ps1') 'dotnet build lib/Foo.csproj'                       # High (exact path, root script)
        Set-Content (Join-Path $root (Join-Path '.github' (Join-Path 'workflows' ('ci.yml')))) "    run: dotnet test lib/Foo.csproj"  # High
        Set-Content (Join-Path $root (Join-Path '.githooks' ('pre-commit'))) 'grep -q lib/Foo.csproj || exit 1'     # High
        Set-Content (Join-Path $root (Join-Path 'tools' ('deploy.ps1'))) 'Copy-Item Foo.csproj $dest'               # Low (leaf only)
        Set-Content (Join-Path $root (Join-Path 'src' ('Other.ps1'))) 'dotnet build lib/Foo.csproj'                 # NOT a candidate (src/ is not an automation dir)
        return $root
    }
}

Describe 'Find-PathReference' {
    It 'flags build/CI/hook references (High) and bare-leaf references (Low)' {
        $root = New-RefFixture
        try {
            $r = Find-PathReference -Path (Join-Path $root (Join-Path 'lib' ('Foo.csproj'))) -RepoRoot $root -WarningAction SilentlyContinue
            $highFiles = ($r | Where-Object Confidence -eq 'High').File
            ($highFiles | ForEach-Object { Split-Path -Leaf $_ }) | Should -Contain 'build.ps1'
            ($highFiles | ForEach-Object { Split-Path -Leaf $_ }) | Should -Contain 'ci.yml'
            ($highFiles | ForEach-Object { Split-Path -Leaf $_ }) | Should -Contain 'pre-commit'
            ($r | Where-Object Confidence -eq 'Low').File | ForEach-Object { Split-Path -Leaf $_ } | Should -Contain 'deploy.ps1'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'does NOT scan ordinary source scripts (only automation dirs/roots)' {
        $root = New-RefFixture
        try {
            $r = Find-PathReference -Path (Join-Path $root (Join-Path 'lib' ('Foo.csproj'))) -RepoRoot $root -WarningAction SilentlyContinue
            ($r.File | ForEach-Object { Split-Path -Leaf $_ }) | Should -Not -Contain 'Other.ps1'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'warns and emits objects with the common reference shape' {
        $root = New-RefFixture
        try {
            $r = Find-PathReference -Path (Join-Path $root (Join-Path 'lib' ('Foo.csproj'))) -RepoRoot $root -WarningVariable w -WarningAction SilentlyContinue
            ($w -join "`n") | Should -Match 'NOT auto-reconciled'
            foreach ($f in 'File', 'Line', 'Confidence', 'Text') { $r[0].PSObject.Properties.Name | Should -Contain $f }
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
