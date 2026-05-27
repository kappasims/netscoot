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

Describe 'Move journal + Undo-Scoot' {
    It 'journals a move in the per-user store and Undo reverses it, popping the entry' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            Move-DotnetProject -Project $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepoRoot $root -NoBuild -Confirm:$false | Out-Null

            (Join-Path $root (Join-Path 'libs' (Join-Path 'Lib' ('Lib.csproj')))) | Should -Exist
            @(Get-MoveJournalEntries -RepoRoot $root).Count | Should -Be 1
            # The journal lives in the per-user store (outside the repo), so the working tree is untouched.
            (Get-MoveJournalPath -RepoRoot $root) | Should -Exist
            (Join-Path $root (Join-Path '.git' ('netscoot'))) | Should -Not -Exist
            (Join-Path $root '.netscoot') | Should -Not -Exist
            Push-Location $root
            try { (& git status --porcelain) -join "`n" | Should -Not -Match 'netscoot|journal' }
            finally { Pop-Location }

            Undo-Scoot -RepoRoot $root -Confirm:$false | Out-Null

            $lib | Should -Exist                                                   # back at the source
            (Join-Path $root (Join-Path 'libs' (Join-Path 'Lib' ('Lib.csproj')))) | Should -Not -Exist
            @(Get-MoveJournalEntries -RepoRoot $root).Count | Should -Be 0          # entry popped, undo not re-journaled
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'does not journal when NETSCOOT_JOURNAL is off' {
        $root = New-JournalFixture
        $prev = $env:NETSCOOT_JOURNAL
        $env:NETSCOOT_JOURNAL = 'off'
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            Move-DotnetProject -Project $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepoRoot $root -NoBuild -Confirm:$false | Out-Null
            (Get-MoveJournalPath -RepoRoot $root) | Should -Not -Exist
            @(Get-MoveJournalEntries -RepoRoot $root).Count | Should -Be 0
        } finally {
            $env:NETSCOOT_JOURNAL = $prev
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

    It 'Invoke-Scoot -NoJournal forwards the per-call opt-out to the engine' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            Invoke-Scoot -Path $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepoRoot $root -NoBuild -NoJournal -Confirm:$false | Out-Null
            (Join-Path $root (Join-Path 'libs' (Join-Path 'Lib' ('Lib.csproj')))) | Should -Exist
            @(Get-MoveJournalEntries -RepoRoot $root).Count | Should -Be 0
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Set-ScootJournal -Enabled $false (git config) turns journaling off and back on' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            $libs = Join-Path $root (Join-Path 'libs' ('Lib'))

            Set-ScootJournal -Enabled $false -RepoRoot $root -Confirm:$false | Out-Null
            Test-MoveJournalEnabled -RepoRoot $root | Should -BeFalse
            Move-DotnetProject -Project $lib -Destination $libs -RepoRoot $root -NoBuild -Confirm:$false | Out-Null
            @(Get-MoveJournalEntries -RepoRoot $root).Count | Should -Be 0

            # git config wins over the env-var escape hatch (config-first precedence).
            $prev = $env:NETSCOOT_JOURNAL
            $env:NETSCOOT_JOURNAL = 'on'
            try { Test-MoveJournalEnabled -RepoRoot $root | Should -BeFalse }
            finally { $env:NETSCOOT_JOURNAL = $prev }

            Set-ScootJournal -Enabled $true -RepoRoot $root -Confirm:$false | Out-Null
            Test-MoveJournalEnabled -RepoRoot $root | Should -BeTrue
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Clear-ScootJournal deletes the journal and empties the undo history' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            Move-DotnetProject -Project $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepoRoot $root -NoBuild -Confirm:$false | Out-Null
            @(Get-MoveJournalEntries -RepoRoot $root).Count | Should -Be 1

            Clear-ScootJournal -RepoRoot $root -Confirm:$false | Out-Null
            (Get-MoveJournalPath -RepoRoot $root) | Should -Not -Exist
            @(Get-MoveJournalEntries -RepoRoot $root).Count | Should -Be 0
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Undo-Scoot -List shows entries and -WhatIf changes nothing' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            $newLib = Join-Path $root (Join-Path 'libs' (Join-Path 'Lib' ('Lib.csproj')))
            Move-DotnetProject -Project $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepoRoot $root -NoBuild -Confirm:$false | Out-Null

            @(Undo-Scoot -RepoRoot $root -List).Count | Should -Be 1
            Undo-Scoot -RepoRoot $root -WhatIf | Out-Null
            $newLib | Should -Exist                                                 # -WhatIf did not revert
            @(Get-MoveJournalEntries -RepoRoot $root).Count | Should -Be 1          # nor pop the entry
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Undo-Scoot -All -Force reverses every move and empties the journal' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            $libs = Join-Path $root (Join-Path 'libs' (Join-Path 'Lib' ('Lib.csproj')))
            $vendor = Join-Path $root (Join-Path 'vendor' (Join-Path 'Lib' ('Lib.csproj')))

            Move-DotnetProject -Project $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepoRoot $root -NoBuild -Confirm:$false | Out-Null
            Move-DotnetProject -Project $libs -Destination (Join-Path $root (Join-Path 'vendor' ('Lib'))) -RepoRoot $root -NoBuild -Confirm:$false | Out-Null
            @(Get-MoveJournalEntries -RepoRoot $root).Count | Should -Be 2

            # -WhatIf previews without changing anything or popping entries.
            Undo-Scoot -RepoRoot $root -All -WhatIf | Out-Null
            $vendor | Should -Exist
            @(Get-MoveJournalEntries -RepoRoot $root).Count | Should -Be 2

            Undo-Scoot -RepoRoot $root -All -Force | Out-Null
            $lib | Should -Exist                                                    # back to the original location
            $vendor | Should -Not -Exist
            @(Get-MoveJournalEntries -RepoRoot $root).Count | Should -Be 0          # whole history walked back
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'writes a non-terminating error when there is nothing to undo' {
        $root = New-JournalFixture
        try {
            Undo-Scoot -RepoRoot $root -ErrorVariable errs -ErrorAction SilentlyContinue | Out-Null
            $errs[0].FullyQualifiedErrorId | Should -Match 'EmptyJournal'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'refuses to replay a tampered journal whose command is not a recognized mover' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            Move-DotnetProject -Project $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepoRoot $root -NoBuild -Confirm:$false | Out-Null
            $jp = Get-MoveJournalPath -RepoRoot $root
            $e = (Get-Content -Raw -LiteralPath $jp).Trim() | ConvertFrom-Json
            $e.undo.command = 'Remove-Item'                                          # tamper: arbitrary command
            Set-Content -LiteralPath $jp -Value ($e | ConvertTo-Json -Depth 8 -Compress) -Encoding utf8
            { Undo-Scoot -RepoRoot $root -Confirm:$false } | Should -Throw -ExpectedMessage '*not a recognized*'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'refuses to replay a tampered journal whose path escapes the repository' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            Move-DotnetProject -Project $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepoRoot $root -NoBuild -Confirm:$false | Out-Null
            $jp = Get-MoveJournalPath -RepoRoot $root
            $e = (Get-Content -Raw -LiteralPath $jp).Trim() | ConvertFrom-Json
            $e.undo.params.Destination = (Join-Path ([System.IO.Path]::GetTempPath()) 'netscoot-evil-target')   # tamper: out-of-repo path
            Set-Content -LiteralPath $jp -Value ($e | ConvertTo-Json -Depth 8 -Compress) -Encoding utf8
            { Undo-Scoot -RepoRoot $root -Confirm:$false } | Should -Throw -ExpectedMessage '*outside the repository*'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
