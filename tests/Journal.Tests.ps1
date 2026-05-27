#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot TestHelpers.ps1)
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Core' ('Netscoot.Core.psd1'))))) -Force

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

Describe 'Move journal + Undo-Netscoot' {
    It 'journals a move in the per-user store and Undo reverses it, popping the entry' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            Move-DotnetProject -Project $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepositoryRoot $root -NoBuild -Confirm:$false | Out-Null

            (Join-Path $root (Join-Path 'libs' (Join-Path 'Lib' ('Lib.csproj')))) | Should -Exist
            @(Get-MoveJournalEntries -RepositoryRoot $root).Count | Should -Be 1
            # The journal lives in the per-user store (outside the repo), so the working tree is untouched.
            (Get-MoveJournalPath -RepositoryRoot $root) | Should -Exist
            (Join-Path $root (Join-Path '.git' ('netscoot'))) | Should -Not -Exist
            (Join-Path $root '.netscoot') | Should -Not -Exist
            Push-Location $root
            try { (& git status --porcelain) -join "`n" | Should -Not -Match 'netscoot|journal' }
            finally { Pop-Location }

            Undo-Netscoot -RepositoryRoot $root -Confirm:$false | Out-Null

            $lib | Should -Exist                                                   # back at the source
            (Join-Path $root (Join-Path 'libs' (Join-Path 'Lib' ('Lib.csproj')))) | Should -Not -Exist
            @(Get-MoveJournalEntries -RepositoryRoot $root).Count | Should -Be 0          # entry popped, undo not re-journaled
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'does not journal when NETSCOOT_JOURNAL is off' {
        $root = New-JournalFixture
        $prev = $env:NETSCOOT_JOURNAL
        $env:NETSCOOT_JOURNAL = 'off'
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            Move-DotnetProject -Project $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepositoryRoot $root -NoBuild -Confirm:$false | Out-Null
            (Get-MoveJournalPath -RepositoryRoot $root) | Should -Not -Exist
            @(Get-MoveJournalEntries -RepositoryRoot $root).Count | Should -Be 0
        } finally {
            $env:NETSCOOT_JOURNAL = $prev
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'a move with -NoJournal is not recorded even when journaling is on' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            Test-MoveJournalEnabled -RepositoryRoot $root | Should -BeTrue           # on by default
            Move-DotnetProject -Project $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepositoryRoot $root -NoBuild -NoJournal -Confirm:$false | Out-Null
            (Join-Path $root (Join-Path 'libs' (Join-Path 'Lib' ('Lib.csproj')))) | Should -Exist   # the move still happened
            @(Get-MoveJournalEntries -RepositoryRoot $root).Count | Should -Be 0                            # but it was not journaled
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Invoke-Netscoot -NoJournal forwards the per-call opt-out to the engine' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            Invoke-Netscoot -Path $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepositoryRoot $root -NoBuild -NoJournal -Confirm:$false | Out-Null
            (Join-Path $root (Join-Path 'libs' (Join-Path 'Lib' ('Lib.csproj')))) | Should -Exist
            @(Get-MoveJournalEntries -RepositoryRoot $root).Count | Should -Be 0
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Set-NetscootJournal -Enabled $false (git config) turns journaling off and back on' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            $libs = Join-Path $root (Join-Path 'libs' ('Lib'))

            Set-NetscootJournal -Enabled $false -RepositoryRoot $root -Confirm:$false | Out-Null
            Test-MoveJournalEnabled -RepositoryRoot $root | Should -BeFalse
            Move-DotnetProject -Project $lib -Destination $libs -RepositoryRoot $root -NoBuild -Confirm:$false | Out-Null
            @(Get-MoveJournalEntries -RepositoryRoot $root).Count | Should -Be 0

            # The env var now trumps git config: forcing NETSCOOT_JOURNAL on overrides git's 'false'.
            $prev = $env:NETSCOOT_JOURNAL
            $env:NETSCOOT_JOURNAL = 'on'
            try { Test-MoveJournalEnabled -RepositoryRoot $root | Should -BeTrue }
            finally { $env:NETSCOOT_JOURNAL = $prev }

            Set-NetscootJournal -Enabled $true -RepositoryRoot $root -Confirm:$false | Out-Null
            Test-MoveJournalEnabled -RepositoryRoot $root | Should -BeTrue
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Clear-NetscootJournal deletes the journal and empties the undo history' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            Move-DotnetProject -Project $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepositoryRoot $root -NoBuild -Confirm:$false | Out-Null
            @(Get-MoveJournalEntries -RepositoryRoot $root).Count | Should -Be 1

            Clear-NetscootJournal -RepositoryRoot $root -Confirm:$false | Out-Null
            (Get-MoveJournalPath -RepositoryRoot $root) | Should -Not -Exist
            @(Get-MoveJournalEntries -RepositoryRoot $root).Count | Should -Be 0
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Undo-Netscoot -List shows entries and -WhatIf changes nothing' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            $newLib = Join-Path $root (Join-Path 'libs' (Join-Path 'Lib' ('Lib.csproj')))
            Move-DotnetProject -Project $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepositoryRoot $root -NoBuild -Confirm:$false | Out-Null

            @(Undo-Netscoot -RepositoryRoot $root -List).Count | Should -Be 1
            Undo-Netscoot -RepositoryRoot $root -WhatIf | Out-Null
            $newLib | Should -Exist                                                 # -WhatIf did not revert
            @(Get-MoveJournalEntries -RepositoryRoot $root).Count | Should -Be 1          # nor pop the entry
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Undo-Netscoot -All -Force reverses every move and empties the journal' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            $libs = Join-Path $root (Join-Path 'libs' (Join-Path 'Lib' ('Lib.csproj')))
            $vendor = Join-Path $root (Join-Path 'vendor' (Join-Path 'Lib' ('Lib.csproj')))

            Move-DotnetProject -Project $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepositoryRoot $root -NoBuild -Confirm:$false | Out-Null
            Move-DotnetProject -Project $libs -Destination (Join-Path $root (Join-Path 'vendor' ('Lib'))) -RepositoryRoot $root -NoBuild -Confirm:$false | Out-Null
            @(Get-MoveJournalEntries -RepositoryRoot $root).Count | Should -Be 2

            # -WhatIf previews without changing anything or popping entries.
            Undo-Netscoot -RepositoryRoot $root -All -WhatIf | Out-Null
            $vendor | Should -Exist
            @(Get-MoveJournalEntries -RepositoryRoot $root).Count | Should -Be 2

            Undo-Netscoot -RepositoryRoot $root -All -Force | Out-Null
            $lib | Should -Exist                                                    # back to the original location
            $vendor | Should -Not -Exist
            @(Get-MoveJournalEntries -RepositoryRoot $root).Count | Should -Be 0          # whole history walked back
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Undo-Netscoot -After reverses moves after a past time, and reports none after a future time' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            Move-DotnetProject -Project $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepositoryRoot $root -NoBuild -Confirm:$false | Out-Null
            @(Get-MoveJournalEntries -RepositoryRoot $root).Count | Should -Be 1

            # No moves after a future time -> non-terminating NoMovesAfter, journal unchanged.
            Undo-Netscoot -RepositoryRoot $root -After (Get-Date).AddMinutes(5) -ErrorVariable errs -ErrorAction SilentlyContinue | Out-Null
            $errs[0].FullyQualifiedErrorId | Should -Match 'NoMovesAfter'
            @(Get-MoveJournalEntries -RepositoryRoot $root).Count | Should -Be 1

            # Everything after a past time is reversed.
            Undo-Netscoot -RepositoryRoot $root -After (Get-Date).AddMinutes(-5) -Force | Out-Null
            $lib | Should -Exist
            @(Get-MoveJournalEntries -RepositoryRoot $root).Count | Should -Be 0
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Undo-Netscoot reports JournalingDisabled when journaling is off and nothing was recorded' {
        $root = New-JournalFixture
        try {
            Set-NetscootJournal -Enabled $false -RepositoryRoot $root -Confirm:$false | Out-Null
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            Move-DotnetProject -Project $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepositoryRoot $root -NoBuild -Confirm:$false | Out-Null
            @(Get-MoveJournalEntries -RepositoryRoot $root).Count | Should -Be 0          # off -> nothing recorded
            Undo-Netscoot -RepositoryRoot $root -ErrorVariable errs -ErrorAction SilentlyContinue | Out-Null
            $errs[0].FullyQualifiedErrorId | Should -Match 'JournalingDisabled'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Undo-Netscoot -Id reverses one specific move and pops only that entry' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            $newLib = Join-Path $root (Join-Path 'libs' (Join-Path 'Lib' ('Lib.csproj')))
            Move-DotnetProject -Project $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepositoryRoot $root -NoBuild -Confirm:$false | Out-Null

            $id = @(Undo-Netscoot -RepositoryRoot $root -List)[-1].id
            $newLib | Should -Exist
            Undo-Netscoot -RepositoryRoot $root -Id $id -Confirm:$false | Out-Null

            $lib | Should -Exist                                                    # reversed
            $newLib | Should -Not -Exist
            @(Get-MoveJournalEntries -RepositoryRoot $root).Count | Should -Be 0          # the entry was popped
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Undo-Netscoot -Id reports NoSuchEntry for an unknown id, changing nothing' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            Move-DotnetProject -Project $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepositoryRoot $root -NoBuild -Confirm:$false | Out-Null

            Undo-Netscoot -RepositoryRoot $root -Id 'deadbeef' -ErrorVariable errs -ErrorAction SilentlyContinue | Out-Null
            $errs[0].FullyQualifiedErrorId | Should -Match 'NoSuchEntry'
            @(Get-MoveJournalEntries -RepositoryRoot $root).Count | Should -Be 1          # untouched
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'writes a non-terminating error when there is nothing to undo' {
        $root = New-JournalFixture
        try {
            Undo-Netscoot -RepositoryRoot $root -ErrorVariable errs -ErrorAction SilentlyContinue | Out-Null
            $errs[0].FullyQualifiedErrorId | Should -Match 'EmptyJournal'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'refuses to replay a tampered journal whose command is not a recognized mover' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            Move-DotnetProject -Project $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepositoryRoot $root -NoBuild -Confirm:$false | Out-Null
            $jp = Get-MoveJournalPath -RepositoryRoot $root
            $e = (Get-Content -Raw -LiteralPath $jp).Trim() | ConvertFrom-Json
            $e.undo.command = 'Remove-Item'                                          # tamper: arbitrary command
            Set-Content -LiteralPath $jp -Value ($e | ConvertTo-Json -Depth 8 -Compress) -Encoding utf8
            { Undo-Netscoot -RepositoryRoot $root -Confirm:$false } | Should -Throw -ExpectedMessage '*not a recognized*'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'refuses to replay a tampered journal whose path escapes the repository' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            Move-DotnetProject -Project $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepositoryRoot $root -NoBuild -Confirm:$false | Out-Null
            $jp = Get-MoveJournalPath -RepositoryRoot $root
            $e = (Get-Content -Raw -LiteralPath $jp).Trim() | ConvertFrom-Json
            $e.undo.params.Destination = (Join-Path ([System.IO.Path]::GetTempPath()) 'netscoot-evil-target')   # tamper: out-of-repo path
            Set-Content -LiteralPath $jp -Value ($e | ConvertTo-Json -Depth 8 -Compress) -Encoding utf8
            { Undo-Netscoot -RepositoryRoot $root -Confirm:$false } | Should -Throw -ExpectedMessage '*outside the repository*'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
