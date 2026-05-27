#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Core' ('Netscoot.Core.psd1'))))) -Force
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Unity' ('Netscoot.Unity.psd1'))))) -Force

    function New-UnityFixture {
        # A tiny Unity-shaped tree in a git repo: Assets/Foo/Bar.cs with paired .meta files.
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("netscoot_uni_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $foo = Join-Path (Join-Path $root 'Assets') 'Foo'
        New-Item -ItemType Directory -Path $foo -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $foo 'Bar.cs') -Value 'public class Bar {}' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $foo 'Bar.cs.meta') -Value "fileFormatVersion: 2`nguid: 1111111111111111aaaaaaaaaaaaaaaa" -Encoding UTF8
        # A folder's .meta is a SIBLING of the folder (Assets/Foo.meta), not inside it.
        Set-Content -LiteralPath (Join-Path (Split-Path $foo) 'Foo.meta') -Value "fileFormatVersion: 2`nguid: 2222222222222222bbbbbbbbbbbbbbbb" -Encoding UTF8
        Push-Location $root
        try { & git init -q; & git add -A; & git commit -qm fixture | Out-Null } finally { Pop-Location }
        return $root
    }

    function New-UnityAsmdefFixture {
        # Assets/Lib (Lib.asmdef) and Assets/App (App.asmdef references "Lib"), with metas.
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("netscoot_asm_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $assets = Join-Path $root 'Assets'
        foreach ($pair in @(@('Lib', '[]'), @('App', '["Lib"]'))) {
            $name = $pair[0]; $refs = $pair[1]
            $dir = Join-Path $assets $name
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir "$name.asmdef") -Value "{ `"name`": `"$name`", `"references`": $refs }" -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $dir "$name.asmdef.meta") -Value "fileFormatVersion: 2`nguid: $($name.PadRight(32,'0'))" -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $assets "$name.meta") -Value "fileFormatVersion: 2`nguid: $(($name+'dir').PadRight(32,'0'))" -Encoding UTF8
        }
        Push-Location $root
        try { & git init -q; & git add -A; & git commit -qm fixture | Out-Null } finally { Pop-Location }
        return $root
    }
}

Describe 'Move-UnityAsset' {
    It 'moves the asset together with its .meta' {
        $root = New-UnityFixture
        try {
            $bar = Join-Path (Join-Path (Join-Path $root 'Assets') 'Foo') 'Bar.cs'
            $dest = Join-Path (Join-Path (Join-Path $root 'Assets') 'Baz') 'Bar.cs'
            $r = Move-UnityAsset -AssetPath $bar -Destination $dest -RepositoryRoot $root -Confirm:$false -WarningAction SilentlyContinue
            $dest | Should -Exist
            "$dest.meta" | Should -Exist
            $bar | Should -Not -Exist
            "$bar.meta" | Should -Not -Exist
            $r.MetaMoved | Should -BeTrue
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'moves a folder with its sibling .meta and descendant .meta intact' {
        $root = New-UnityFixture
        try {
            $foo = Join-Path (Join-Path $root 'Assets') 'Foo'
            $dest = Join-Path (Join-Path (Join-Path $root 'Assets') 'Sub') 'Foo'
            Move-UnityAsset -AssetPath $foo -Destination $dest -RepositoryRoot $root -Confirm:$false -WarningAction SilentlyContinue | Out-Null
            $dest | Should -Exist
            "$dest.meta" | Should -Exist                                   # sibling folder meta moved
            (Join-Path $dest 'Bar.cs.meta') | Should -Exist               # descendant meta rode along
            (Join-Path (Join-Path $root 'Assets') 'Foo.meta') | Should -Not -Exist
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'accepts the asset from the pipeline and honors -WhatIf' {
        $root = New-UnityFixture
        try {
            $bar = Join-Path (Join-Path (Join-Path $root 'Assets') 'Foo') 'Bar.cs'
            $r = Get-Item $bar | Move-UnityAsset -Destination (Join-Path (Split-Path $bar) 'Renamed.cs') -RepositoryRoot $root -WhatIf
            $r.Performed | Should -BeFalse
            $bar | Should -Exist
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'reports asmdef referencers when moving an .asmdef' {
        $root = New-UnityAsmdefFixture
        try {
            $lib = Join-Path (Join-Path (Join-Path $root 'Assets') 'Lib') 'Lib.asmdef'
            $r = Move-UnityAsset -AssetPath $lib -Destination (Join-Path (Join-Path $root 'Assets') 'Core/Lib.asmdef') -RepositoryRoot $root -WhatIf -WarningAction SilentlyContinue
            $r.IsAsmdef | Should -BeTrue
            $r.ReferencedBy | Should -Contain 'App'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'warns when an asset has no .meta' {
        $root = New-UnityFixture
        try {
            $foo = Join-Path (Join-Path $root 'Assets') 'Foo'
            Set-Content -LiteralPath (Join-Path $foo 'NoMeta.cs') -Value 'x'
            Move-UnityAsset -AssetPath (Join-Path $foo 'NoMeta.cs') -Destination (Join-Path $foo 'Moved.cs') -RepositoryRoot $root -WhatIf -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            ($w -join "`n") | Should -Match 'No .meta'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Test-UnityMetaIntegrity' {
    It 'flags an orphan .meta and a missing .meta' {
        $root = New-UnityFixture
        try {
            $foo = Join-Path (Join-Path $root 'Assets') 'Foo'
            Remove-Item -LiteralPath (Join-Path $foo 'Bar.cs')              # leaves Bar.cs.meta orphaned
            Set-Content -LiteralPath (Join-Path $foo 'New.cs') -Value 'x'   # asset with no .meta
            $probs = Test-UnityMetaIntegrity -Root (Join-Path $root 'Assets') -WarningAction SilentlyContinue
            ($probs | Where-Object Kind -eq 'OrphanMeta').Path  | Should -Match 'Bar\.cs\.meta'
            ($probs | Where-Object Kind -eq 'MissingMeta').Path | Should -Match 'New\.cs'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
