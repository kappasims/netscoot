#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot TestHelpers.ps1)
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'DotnetMove.Core' ('DotnetMove.Core.psd1'))))) -Force

    function New-JournalFixture {
        $root = New-TempRoot -Prefix 'journal'
        Push-Location $root
        try {
            & git init -q
            New-StubClassLib -Name Lib -Directory (Join-Path $root (Join-Path 'src' ('Lib'))) | Out-Null
            & dotnet new sln -n Demo | Out-Null
            $sln = (Get-ChildItem -LiteralPath $root -File -Filter '*.sln').FullName
            & dotnet sln $sln add (Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))) | Out-Null
            & git add -A; & git commit -qm fixture | Out-Null
        } finally { Pop-Location }
        return $root
    }
}

Describe 'Move journal + Undo-DotnetMove' {
    It 'journals a move under the git dir and Undo reverses it, popping the entry' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            Move-DotnetProject -Project $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepoRoot $root -NoBuild -Confirm:$false | Out-Null

            (Join-Path $root (Join-Path 'libs' (Join-Path 'Lib' ('Lib.csproj')))) | Should -Exist
            @(Get-MoveJournalEntries -RepoRoot $root).Count | Should -Be 1
            # The journal lives inside the git dir, so it is never tracked and never in the working tree.
            (Join-Path $root (Join-Path '.git' (Join-Path 'dotnetmove' ('journal.jsonl')))) | Should -Exist
            (Join-Path $root '.dotnetmove') | Should -Not -Exist
            Push-Location $root
            try { (& git status --porcelain) -join "`n" | Should -Not -Match 'dotnetmove' }
            finally { Pop-Location }

            Undo-DotnetMove -RepoRoot $root -Confirm:$false | Out-Null

            $lib | Should -Exist                                                   # back at the source
            (Join-Path $root (Join-Path 'libs' (Join-Path 'Lib' ('Lib.csproj')))) | Should -Not -Exist
            @(Get-MoveJournalEntries -RepoRoot $root).Count | Should -Be 0          # entry popped, undo not re-journaled
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'does not journal when DOTNETMOVE_JOURNAL is off' {
        $root = New-JournalFixture
        $prev = $env:DOTNETMOVE_JOURNAL
        $env:DOTNETMOVE_JOURNAL = 'off'
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            Move-DotnetProject -Project $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepoRoot $root -NoBuild -Confirm:$false | Out-Null
            (Join-Path $root (Join-Path '.git' ('dotnetmove'))) | Should -Not -Exist
            @(Get-MoveJournalEntries -RepoRoot $root).Count | Should -Be 0
        } finally {
            $env:DOTNETMOVE_JOURNAL = $prev
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'a move with -NoJournal is not recorded even when journaling is on' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            Test-MoveJournalEnabled -RepoRoot $root | Should -BeTrue           # on by default
            Move-DotnetProject -Project $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepoRoot $root -NoBuild -NoJournal -Confirm:$false | Out-Null
            (Join-Path $root (Join-Path 'libs' (Join-Path 'Lib' ('Lib.csproj')))) | Should -Exist   # the move still happened
            @(Get-MoveJournalEntries -RepoRoot $root).Count | Should -Be 0                            # but it was not journaled
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Move-Dotnet -NoJournal forwards the per-call opt-out to the engine' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            Move-Dotnet -Path $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepoRoot $root -NoBuild -NoJournal -Confirm:$false | Out-Null
            (Join-Path $root (Join-Path 'libs' (Join-Path 'Lib' ('Lib.csproj')))) | Should -Exist
            @(Get-MoveJournalEntries -RepoRoot $root).Count | Should -Be 0
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Set-DotnetMoveJournal -Enabled $false (git config) turns journaling off and back on' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            $libs = Join-Path $root (Join-Path 'libs' ('Lib'))

            Set-DotnetMoveJournal -Enabled $false -RepoRoot $root -Confirm:$false | Out-Null
            Test-MoveJournalEnabled -RepoRoot $root | Should -BeFalse
            Move-DotnetProject -Project $lib -Destination $libs -RepoRoot $root -NoBuild -Confirm:$false | Out-Null
            @(Get-MoveJournalEntries -RepoRoot $root).Count | Should -Be 0

            # git config wins over the env-var escape hatch (config-first precedence).
            $prev = $env:DOTNETMOVE_JOURNAL
            $env:DOTNETMOVE_JOURNAL = 'on'
            try { Test-MoveJournalEnabled -RepoRoot $root | Should -BeFalse }
            finally { $env:DOTNETMOVE_JOURNAL = $prev }

            Set-DotnetMoveJournal -Enabled $true -RepoRoot $root -Confirm:$false | Out-Null
            Test-MoveJournalEnabled -RepoRoot $root | Should -BeTrue
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Clear-DotnetMoveJournal deletes the journal and empties the undo history' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            Move-DotnetProject -Project $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepoRoot $root -NoBuild -Confirm:$false | Out-Null
            @(Get-MoveJournalEntries -RepoRoot $root).Count | Should -Be 1

            Clear-DotnetMoveJournal -RepoRoot $root -Confirm:$false | Out-Null
            (Get-MoveJournalPath -RepoRoot $root) | Should -Not -Exist
            @(Get-MoveJournalEntries -RepoRoot $root).Count | Should -Be 0
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Undo-DotnetMove -List shows entries and -WhatIf changes nothing' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            $newLib = Join-Path $root (Join-Path 'libs' (Join-Path 'Lib' ('Lib.csproj')))
            Move-DotnetProject -Project $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepoRoot $root -NoBuild -Confirm:$false | Out-Null

            @(Undo-DotnetMove -RepoRoot $root -List).Count | Should -Be 1
            Undo-DotnetMove -RepoRoot $root -WhatIf | Out-Null
            $newLib | Should -Exist                                                 # -WhatIf did not revert
            @(Get-MoveJournalEntries -RepoRoot $root).Count | Should -Be 1          # nor pop the entry
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Undo-DotnetMove -All -Force reverses every move and empties the journal' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            $libs = Join-Path $root (Join-Path 'libs' (Join-Path 'Lib' ('Lib.csproj')))
            $vendor = Join-Path $root (Join-Path 'vendor' (Join-Path 'Lib' ('Lib.csproj')))

            Move-DotnetProject -Project $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepoRoot $root -NoBuild -Confirm:$false | Out-Null
            Move-DotnetProject -Project $libs -Destination (Join-Path $root (Join-Path 'vendor' ('Lib'))) -RepoRoot $root -NoBuild -Confirm:$false | Out-Null
            @(Get-MoveJournalEntries -RepoRoot $root).Count | Should -Be 2

            # -WhatIf previews without changing anything or popping entries.
            Undo-DotnetMove -RepoRoot $root -All -WhatIf | Out-Null
            $vendor | Should -Exist
            @(Get-MoveJournalEntries -RepoRoot $root).Count | Should -Be 2

            Undo-DotnetMove -RepoRoot $root -All -Force | Out-Null
            $lib | Should -Exist                                                    # back to the original location
            $vendor | Should -Not -Exist
            @(Get-MoveJournalEntries -RepoRoot $root).Count | Should -Be 0          # whole history walked back
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'writes a non-terminating error when there is nothing to undo' {
        $root = New-JournalFixture
        try {
            Undo-DotnetMove -RepoRoot $root -ErrorVariable errs -ErrorAction SilentlyContinue | Out-Null
            $errs[0].FullyQualifiedErrorId | Should -Match 'EmptyJournal'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
