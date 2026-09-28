#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot TestHelpers.ps1)
    Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'src', 'Netscoot.Core', 'Netscoot.Core.psd1')) -Force

    function New-RepoWithNestedWorktree {
        # A repo with a .sln and a .slnx (both listing Lib), plus a linked git worktree nested
        # under .claude/worktrees/wt holding duplicate copies of all of it.
        #
        # Two-phase build so the dotnet-sln work is cached once via Copy-FixtureTemplate (the
        # 4 dotnet calls dominate this file's cost), and the per-test worktree add runs on a
        # fresh copy. The worktree itself cannot live in the cached template - its linkage
        # files (`.git/worktrees/<name>/gitdir`, the worktree's own `.git`) contain absolute
        # paths to the original repo that go stale on copy.
        $root = Copy-FixtureTemplate -Key 'worktree_repo' -Prefix 'netscoot_wt' -Build {
            $r = New-TempRoot -Prefix 'netscoot_wt_tpl'
            Push-Location $r
            try {
                Invoke-Git -Arguments @('init', '-q')
                Invoke-Git -Arguments @('config', 'user.email', 't@t.test')
                Invoke-Git -Arguments @('config', 'user.name', 'test')
                New-ClassLibProject -Name Lib -Directory (Join-Path $r 'Lib') | Out-Null
                Invoke-Dotnet -Arguments @('new', 'sln', '-n', 'Demo', '--format', 'sln')
                Invoke-Dotnet -Arguments @('new', 'sln', '-n', 'Demo', '--format', 'slnx')
                Invoke-Dotnet -Arguments @('sln', 'Demo.sln', 'add', (Join-Path $r (Join-Path 'Lib' 'Lib.csproj')))
                Invoke-Dotnet -Arguments @('sln', 'Demo.slnx', 'add', (Join-Path $r (Join-Path 'Lib' 'Lib.csproj')))
                Invoke-Git -Arguments @('add', '-A')
                Invoke-Git -Arguments @('commit', '-qm', 'fixture')
            } finally { Pop-Location }
            return $r
        }
        Push-Location $root
        try {
            Invoke-Git -Arguments @('worktree', 'add', '--quiet', '-b', 'wt', (Join-Path $root (Join-Path '.claude' (Join-Path 'worktrees' 'wt'))))
        } finally { Pop-Location }
        return $root
    }
}

Describe 'Nested worktrees are excluded from repo scans' -Tag 'Integration' {
    It 'Find-Solutions ignores the worktree copies' {
        $root = New-RepoWithNestedWorktree
        try {
            InModuleScope NetscootShared -Parameters @{ Root = $root } {
                param($Root)
                # Two solutions at the root, not the four that the worktree copy would add.
                @(Find-Solutions -Root $Root).Count | Should -Be 2
                @(Find-Solutions -Root $Root | Where-Object { $_.FullName -match 'worktrees' }) | Should -BeNullOrEmpty
            }
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Test-NetscootSolutionConsistency does not invent a divergence from worktree duplicates' {
        $root = New-RepoWithNestedWorktree
        try {
            $probs = Test-NetscootSolutionConsistency -RepositoryRoot $root -WarningVariable w -WarningAction SilentlyContinue -ErrorAction Stop
            $probs | Should -BeNullOrEmpty                 # both root solutions list Lib: consistent
            ($w -join "`n") | Should -Not -Match 'diverges'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
