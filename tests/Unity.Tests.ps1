#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Core' ('Netscoot.Core.psd1'))))) -Force
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Unity' ('Netscoot.Unity.psd1'))))) -Force

    function New-UnityFixture {
        # A tiny Unity-shaped tree in a git repo: Assets/Foo/Bar.cs with paired .meta files.
        $root = New-TempRoot -Prefix 'netscoot_uni'
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
        $root = New-TempRoot -Prefix 'netscoot_asm'
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

Describe 'Move-UnityAsset' -Tag 'Integration' {
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

Describe 'Move-UnityAsset new parent folders' -Tag 'Integration' {
    It 'creates a folder .meta for each new folder under Assets' {
        $root = New-UnityFixture
        try {
            $assets = Join-Path $root 'Assets'
            Move-UnityAsset -AssetPath (Join-Path $assets 'Foo') -Destination (Join-Path $assets (Join-Path 'Plugins' (Join-Path 'Deep' 'Foo'))) -RepositoryRoot $root -NoJournal -Confirm:$false | Out-Null
            foreach ($meta in (Join-Path $assets 'Plugins.meta'), (Join-Path $assets (Join-Path 'Plugins' 'Deep.meta'))) {
                $text = [System.IO.File]::ReadAllText($meta)
                $text | Should -Match '(?m)^guid: [0-9a-f]{32}$'
                $text | Should -Match '(?m)^folderAsset: yes$'
            }
            @(Test-UnityMetaIntegrity -Root $assets -WarningAction SilentlyContinue) | Should -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'gives no .meta to a new package root, only to folders inside it' {
        $root = New-UnityFixture
        try {
            $bar = Join-Path $root (Join-Path 'Assets' (Join-Path 'Foo' 'Bar.cs'))
            $packages = Join-Path $root 'Packages'
            New-Item -ItemType Directory -Path $packages | Out-Null
            Move-UnityAsset -AssetPath $bar -Destination (Join-Path $packages (Join-Path 'com.example.tools' (Join-Path 'Runtime' 'Bar.cs'))) -RepositoryRoot $root -NoJournal -Confirm:$false -WarningAction SilentlyContinue | Out-Null
            (Join-Path $packages 'com.example.tools.meta') | Should -Not -Exist
            (Join-Path $packages (Join-Path 'com.example.tools' 'Runtime.meta')) | Should -Exist
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'stages the new folder .meta files with the move' {
        $root = New-UnityFixture
        try {
            $assets = Join-Path $root 'Assets'
            Move-UnityAsset -AssetPath (Join-Path $assets 'Foo') -Destination (Join-Path $assets (Join-Path 'Plugins' 'Foo')) -RepositoryRoot $root -NoJournal -Confirm:$false | Out-Null
            (& git -C $root status --porcelain -- 'Assets/Plugins.meta') | Should -Match '^A  '
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'removes the folders and .meta files it created when the move fails' {
        $root = New-UnityFixture
        try {
            $assets = Join-Path $root 'Assets'
            $bar = Join-Path $assets (Join-Path 'Foo' 'Bar.cs')
            Mock -ModuleName NetscootShared Test-GitAvailable { $false }
            # Like the real Move-PathTracked, create the destination parent before moving.
            Mock -ModuleName Netscoot.Unity Move-PathTracked {
                if ($Source -like '*.meta') { throw 'simulated meta move failure' }
                New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
                Move-Item -LiteralPath $Source -Destination $Destination
            }
            { Move-UnityAsset -AssetPath $bar -Destination (Join-Path $assets (Join-Path 'Plugins' (Join-Path 'Deep' 'Bar.cs'))) -RepositoryRoot $root -Force -NoJournal -Confirm:$false } |
                Should -Throw -ExpectedMessage '*rolled back*'
            $bar | Should -Exist
            (Join-Path $assets 'Plugins') | Should -Not -Exist
            (Join-Path $assets 'Plugins.meta') | Should -Not -Exist
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Undo-Netscoot removes the new folders and their .meta files' {
        $root = New-UnityFixture
        try {
            $assets = Join-Path $root 'Assets'
            Move-UnityAsset -AssetPath (Join-Path $assets 'Foo') -Destination (Join-Path $assets (Join-Path 'Plugins' (Join-Path 'Deep' 'Foo'))) -RepositoryRoot $root -Confirm:$false | Out-Null
            Undo-Netscoot -RepositoryRoot $root -Confirm:$false | Out-Null
            (Join-Path $assets (Join-Path 'Foo' 'Bar.cs')) | Should -Exist
            (Join-Path $assets 'Plugins') | Should -Not -Exist
            (Join-Path $assets 'Plugins.meta') | Should -Not -Exist
            (& git -C $root status --porcelain) | Should -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Undo-Netscoot keeps a new folder that has gained other content' {
        $root = New-UnityFixture
        try {
            $assets = Join-Path $root 'Assets'
            Move-UnityAsset -AssetPath (Join-Path $assets 'Foo') -Destination (Join-Path $assets (Join-Path 'Plugins' 'Foo')) -RepositoryRoot $root -Confirm:$false | Out-Null
            Set-Content -LiteralPath (Join-Path $assets (Join-Path 'Plugins' 'Other.cs')) -Value 'public class Other {}'
            Undo-Netscoot -RepositoryRoot $root -Confirm:$false | Out-Null
            (Join-Path $assets (Join-Path 'Plugins' 'Other.cs')) | Should -Exist
            (Join-Path $assets 'Plugins.meta') | Should -Exist
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'never prunes a folder that is not above the moved asset' {
        $root = New-UnityFixture
        try {
            $assets = Join-Path $root 'Assets'
            $unrelated = Join-Path $assets 'Empty'
            New-Item -ItemType Directory -Path $unrelated | Out-Null
            Move-UnityAsset -AssetPath (Join-Path $assets (Join-Path 'Foo' 'Bar.cs')) -Destination (Join-Path $assets 'Bar.cs') -RepositoryRoot $root `
                -FoldersToPrune $unrelated -NoJournal -Confirm:$false | Out-Null
            $unrelated | Should -Exist
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Test-UnityMetaIntegrity' -Tag 'Integration' {
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

    It 'ignores files inside Unity-hidden folders' {
        $root = New-UnityFixture
        try {
            $assets = Join-Path $root 'Assets'
            foreach ($hidden in 'Samples~', '.hidden') {
                $dir = New-Item -ItemType Directory -Path (Join-Path $assets (Join-Path $hidden 'Nested'))
                Set-Content -LiteralPath (Join-Path $dir.FullName 'x.png') -Value 'x'
            }
            $probs = @(Test-UnityMetaIntegrity -Root $assets -WarningAction SilentlyContinue)
            $probs | Should -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
