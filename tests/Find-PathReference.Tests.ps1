#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Core' ('Netscoot.Core.psd1'))))) -Force

    function New-RefFixture {
        $root = New-TempRoot -Prefix 'netscoot_ref'
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
            $r = Find-PathReference -Path (Join-Path $root (Join-Path 'lib' ('Foo.csproj'))) -RepositoryRoot $root -WarningAction SilentlyContinue
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
            $r = Find-PathReference -Path (Join-Path $root (Join-Path 'lib' ('Foo.csproj'))) -RepositoryRoot $root -WarningAction SilentlyContinue
            ($r.File | ForEach-Object { Split-Path -Leaf $_ }) | Should -Not -Contain 'Other.ps1'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It '-AllFiles scans ordinary source files the default classifier skips (e.g. src/Other.ps1)' {
        $root = New-RefFixture
        try {
            $default = Find-PathReference -Path (Join-Path $root (Join-Path 'lib' ('Foo.csproj'))) -RepositoryRoot $root -WarningAction SilentlyContinue
            ($default.File | ForEach-Object { Split-Path -Leaf $_ }) | Should -Not -Contain 'Other.ps1'

            $all = Find-PathReference -Path (Join-Path $root (Join-Path 'lib' ('Foo.csproj'))) -RepositoryRoot $root -AllFiles -WarningAction SilentlyContinue
            ($all.File | ForEach-Object { Split-Path -Leaf $_ }) | Should -Contain 'Other.ps1' -Because '-AllFiles searches every text file, including source the default scan skips'
            # The original build/CI/hook hits are still present under -AllFiles.
            ($all.File | ForEach-Object { Split-Path -Leaf $_ }) | Should -Contain 'build.ps1'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It '-AllFiles still excludes binary files and cache/vendor directories' {
        $root = New-RefFixture
        try {
            # A binary file and a cached file under bin/, both containing the search path.
            Set-Content -LiteralPath (Join-Path $root 'lib\Foo.dll') -Value 'lib/Foo.csproj inside a fake binary' -Encoding UTF8
            New-Item -ItemType Directory -Path (Join-Path $root 'bin') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $root (Join-Path 'bin' 'cached.txt')) -Value 'lib/Foo.csproj' -Encoding UTF8

            $all = Find-PathReference -Path (Join-Path $root (Join-Path 'lib' ('Foo.csproj'))) -RepositoryRoot $root -AllFiles -WarningAction SilentlyContinue
            $leaves = @($all.File | ForEach-Object { Split-Path -Leaf $_ })
            $leaves | Should -Not -Contain 'Foo.dll'     -Because 'binary extensions are skipped even under -AllFiles'
            $leaves | Should -Not -Contain 'cached.txt'  -Because 'cache/vendor dirs (bin/) are excluded even under -AllFiles'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'warns and emits objects with the common reference shape' {
        $root = New-RefFixture
        try {
            $r = Find-PathReference -Path (Join-Path $root (Join-Path 'lib' ('Foo.csproj'))) -RepositoryRoot $root -WarningVariable w -WarningAction SilentlyContinue
            ($w -join "`n") | Should -Match 'NOT auto-reconciled'
            foreach ($f in 'File', 'Line', 'Confidence', 'Text') { $r[0].PSObject.Properties.Name | Should -Contain $f }
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'derives the repository root from the current directory, not from -Path, so sweeping an already-moved (nonexistent) path does not throw (regression)' {
        # The canonical use is sweeping the OLD identifier after a rename - the needle no longer
        # exists on disk. Pre-fix, with -RepositoryRoot omitted, the cmdlet derived the repo root by
        # walking up FROM the -Path needle, so Get-RepositoryRoot's Get-Item threw on the missing
        # path. Fix: derive the root from the current directory; the needle is a search string, not
        # a location.
        $root = New-RefFixture
        Push-Location $root
        try {
            & git init -q   # so Get-RepositoryRoot resolves to $root via .git, deterministically
            # Simulate "after the rename": the old project path is gone from disk.
            Remove-Item -LiteralPath (Join-Path $root (Join-Path 'lib' ('Foo.csproj'))) -Force

            # Pre-fix this threw at Get-RepositoryRoot (Get-Item on the missing -Path needle); a throw
            # here fails the test, which is the regression guard. Then confirm it still finds the
            # lingering references in the build/CI/hook files (the whole point of the sweep).
            $r = Find-PathReference -Path 'lib\Foo.csproj' -WarningAction SilentlyContinue
            ($r | Where-Object Confidence -eq 'High' | ForEach-Object { Split-Path -Leaf $_.File }) |
                Should -Contain 'build.ps1' -Because 'the old path is exactly what we are sweeping for'
        } finally {
            Pop-Location
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
