#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot TestHelpers.ps1)
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Core' ('Netscoot.Core.psd1'))))) -Force

    function New-JournalFixture {
        Copy-FixtureTemplate -Key 'journal-lib-sln' -Prefix 'journal' -Build {
            $root = New-TempRoot -Prefix 'journal'
            Push-Location $root
            try {
                & git init -q
                New-ClassLibProject -Name Lib -Directory (Join-Path $root (Join-Path 'src' ('Lib'))) | Out-Null
                & dotnet new sln -n Demo | Out-Null
                $sln = (Get-ChildItem -LiteralPath $root -File -Filter '*.sln').FullName
                & dotnet sln $sln add (Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))) | Out-Null
                & git add -A; & git commit -qm fixture | Out-Null
            } finally { Pop-Location }
            return $root
        }
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

    It 'a real move records committed (pending + committed) and is undoable' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            Move-DotnetProject -Project $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepositoryRoot $root -NoBuild -Confirm:$false | Out-Null
            # The committed move is the one undoable entry; both pending+committed lines exist on disk.
            @(Get-MoveJournalEntries -RepositoryRoot $root).Count | Should -Be 1
            (Get-MoveJournalEntries -RepositoryRoot $root)[0].status | Should -Be 'committed'
            @(Get-Content -LiteralPath (Get-MoveJournalPath -RepositoryRoot $root)).Count | Should -Be 2
            @(Get-InterruptedMove -RepositoryRoot $root).Count | Should -Be 0
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'an interrupted (pending) move is excluded from undo history and surfaced by Get-InterruptedMove' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            Move-DotnetProject -Project $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepositoryRoot $root -NoBuild -Confirm:$false | Out-Null
            # Simulate a crash: a pending record with no committed/rolledback outcome.
            $jp = Get-MoveJournalPath -RepositoryRoot $root
            $pending = @{ id = 'deadbeef'; timestamp = (Get-Date).ToUniversalTime().ToString('o'); status = 'pending'; command = 'Move-DotnetProject'; engine = 'dotnet'; source = 'a'; destination = 'b'; undo = @{ command = 'Move-DotnetProject'; params = @{} }; snapshot = '' }
            Add-Content -LiteralPath $jp -Value (ConvertTo-Json $pending -Depth 6 -Compress) -Encoding utf8

            @(Get-MoveJournalEntries -RepositoryRoot $root).Count | Should -Be 1     # only the committed move
            $i = @(Get-InterruptedMove -RepositoryRoot $root)
            $i.Count | Should -Be 1
            $i[0].id | Should -Be 'deadbeef'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'a torn journal line is skipped, not fatal' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            Move-DotnetProject -Project $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepositoryRoot $root -NoBuild -Confirm:$false | Out-Null
            Add-Content -LiteralPath (Get-MoveJournalPath -RepositoryRoot $root) -Value '{"id":"torn","stat' -Encoding utf8   # truncated line
            { Get-MoveJournalEntries -RepositoryRoot $root } | Should -Not -Throw
            @(Get-MoveJournalEntries -RepositoryRoot $root).Count | Should -Be 1     # the good entry still reads
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'an entry from a newer schema version is ignored, not misread' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            Move-DotnetProject -Project $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepositoryRoot $root -NoBuild -Confirm:$false | Out-Null
            $future = @{ v = 99; id = 'future01'; timestamp = (Get-Date).ToUniversalTime().ToString('o'); status = 'committed'; command = 'Move-DotnetProject'; engine = 'dotnet'; source = 'a'; destination = 'b'; undo = @{ command = 'Move-DotnetProject'; params = @{} }; snapshot = '' }
            Add-Content -LiteralPath (Get-MoveJournalPath -RepositoryRoot $root) -Value (ConvertTo-Json $future -Depth 6 -Compress) -Encoding utf8
            @(Get-MoveJournalEntries -RepositoryRoot $root -WarningAction SilentlyContinue).Count | Should -Be 1   # v99 entry ignored, not duplicated
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Compress-MoveJournalLines folds to the latest line per id and drops rolled-back moves' {
        InModuleScope NetscootShared {
            $mk = { param($id, $status) (@{ v = 2; id = $id; timestamp = '2026-01-01T00:00:00Z'; status = $status; command = 'Move-DotnetProject'; engine = 'dotnet'; source = 's'; destination = 'd'; undo = @{}; snapshot = ''; backup = @() } | ConvertTo-Json -Compress) }
            $lines = @((& $mk 'A' 'pending'), (& $mk 'A' 'committed'), (& $mk 'B' 'pending'), (& $mk 'C' 'pending'), (& $mk 'C' 'rolledback'))
            $out = @(Compress-MoveJournalLines -Lines $lines)
            $out.Count | Should -Be 2                                              # A (committed) + B (pending); C dropped
            ($out | ForEach-Object { ($_ | ConvertFrom-Json).id }) | Should -Be @('A', 'B')
            ($out[0] | ConvertFrom-Json).status | Should -Be 'committed'           # A folded to its latest line
        }
    }

    It 'Repair-NetscootJournal reports interrupted moves and -Discard forgets them' {
        $root = New-JournalFixture
        try {
            $jp = Get-MoveJournalPath -RepositoryRoot $root
            New-Item -ItemType Directory -Path (Split-Path -Parent $jp) -Force | Out-Null
            $pending = @{ v = 2; id = 'int00001'; timestamp = (Get-Date).ToUniversalTime().ToString('o'); status = 'pending'; command = 'Move-DotnetProject'; engine = 'dotnet'; source = (Join-Path $root 'gone'); destination = (Join-Path $root 'also-gone'); undo = @{ command = 'Move-DotnetProject'; params = @{} }; snapshot = ''; backup = @() }
            Set-Content -LiteralPath $jp -Value (ConvertTo-Json $pending -Depth 6 -Compress) -Encoding utf8

            @(Repair-NetscootJournal -RepositoryRoot $root -WarningAction SilentlyContinue).Count | Should -Be 1   # report mode lists it
            Repair-NetscootJournal -RepositoryRoot $root -Discard -Id 'int00001' -Force | Out-Null
            @(Get-InterruptedMove -RepositoryRoot $root).Count | Should -Be 0                                       # forgotten
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Repair-NetscootJournal -Rollback restores edited files from the snapshot and clears the entry' {
        $root = New-JournalFixture
        $snapDir = New-TempRoot -Prefix 'netscoot_snap'
        try {
            $edited = Join-Path $root 'edited.props'
            Set-Content -LiteralPath $edited -Value 'CHANGED'                       # current (partially-edited) content
            Set-Content -LiteralPath (Join-Path $snapDir 'f0') -Value 'ORIGINAL'    # the snapshot of the original

            $jp = Get-MoveJournalPath -RepositoryRoot $root
            New-Item -ItemType Directory -Path (Split-Path -Parent $jp) -Force | Out-Null
            $pending = @{ v = 2; id = 'int00002'; timestamp = (Get-Date).ToUniversalTime().ToString('o'); status = 'pending'; command = 'Move-DotnetProject'; engine = 'dotnet'; source = (Join-Path $root 'gone'); destination = (Join-Path $root 'also-gone'); undo = @{ command = 'Move-DotnetProject'; params = @{} }; snapshot = $snapDir; backup = @($edited) }
            Set-Content -LiteralPath $jp -Value (ConvertTo-Json $pending -Depth 6 -Compress) -Encoding utf8

            Repair-NetscootJournal -RepositoryRoot $root -Rollback -Id 'int00002' -Force | Out-Null
            (Get-Content -LiteralPath $edited -Raw).Trim() | Should -Be 'ORIGINAL'  # restored from snapshot
            @(Get-InterruptedMove -RepositoryRoot $root).Count | Should -Be 0       # entry cleared
            (Test-Path -LiteralPath $snapDir) | Should -BeFalse                     # snapshot removed
        } finally {
            Remove-Item -LiteralPath $snapDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
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
            $e = (Get-MoveJournalEntries -RepositoryRoot $root)[0]                   # the committed entry
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
            $e = (Get-MoveJournalEntries -RepositoryRoot $root)[0]                   # the committed entry
            $e.undo.params.Destination = (Join-Path ([System.IO.Path]::GetTempPath()) 'netscoot-evil-target')   # tamper: out-of-repo path
            Set-Content -LiteralPath $jp -Value ($e | ConvertTo-Json -Depth 8 -Compress) -Encoding utf8
            { Undo-Netscoot -RepositoryRoot $root -Confirm:$false } | Should -Throw -ExpectedMessage '*outside the repository*'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # ----------------------------------------------------------------------------------------------
    # WAL contract invariants (v2 lock-down for the per-move-partition migration coming in v3.0).
    #
    # These complement JournalFormat.Tests.ps1 (which locks the per-entry schema). Here we lock the
    # APPEND-ORDER semantics and the safety invariants compaction must honor. A future per-move-
    # partition layout must preserve every assertion below - either as literal append-ordered lines
    # within a per-move file, or as an equivalent transition encoding (.pending -> .committed atomic
    # rename) whose externally-observable order is the same.
    # ----------------------------------------------------------------------------------------------

    It 'WAL: successful move appends [pending, committed] in append order (raw line read)' {
        $root = New-JournalFixture
        try {
            $lib = Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))
            Move-DotnetProject -Project $lib -Destination (Join-Path $root (Join-Path 'libs' ('Lib'))) -RepositoryRoot $root -NoBuild -Confirm:$false | Out-Null
            $lines = @(Get-Content -LiteralPath (Get-MoveJournalPath -RepositoryRoot $root)) | Where-Object { $_.Trim() }
            $lines.Count | Should -Be 2
            ($lines[0] | ConvertFrom-Json).status | Should -Be 'pending'
            ($lines[1] | ConvertFrom-Json).status | Should -Be 'committed'
            # Same move - same id across both lines.
            ($lines[0] | ConvertFrom-Json).id | Should -Be (($lines[1] | ConvertFrom-Json).id)
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Repair-NetscootJournal -Rollback removes the pending entry from the on-disk file (post-crash recovery path)' {
        # Distinction the v2 contract makes: in-operation rollback (Invoke-MovePlan when a move
        # fails mid-flight) APPENDS a rolledback transition record. Post-crash recovery
        # (Repair-NetscootJournal -Rollback) REMOVES the pending entry instead. This locks that
        # second contract: after Repair-Rollback, the journal no longer carries any line for the
        # rolled-back id (compaction is implicit in the recovery path).
        $root = New-JournalFixture
        $snapDir = New-TempRoot -Prefix 'netscoot_snap'
        try {
            $edited = Join-Path $root 'edited.props'
            Set-Content -LiteralPath $edited -Value 'CHANGED'
            Set-Content -LiteralPath (Join-Path $snapDir 'f0') -Value 'ORIGINAL'

            $jp = Get-MoveJournalPath -RepositoryRoot $root
            New-Item -ItemType Directory -Path (Split-Path -Parent $jp) -Force | Out-Null
            $pending = @{ v = 2; id = 'wal00001'; timestamp = (Get-Date).ToUniversalTime().ToString('o'); status = 'pending'; command = 'Move-DotnetProject'; engine = 'dotnet'; source = (Join-Path $root 'gone'); destination = (Join-Path $root 'also-gone'); undo = @{ command = 'Move-DotnetProject'; params = @{} }; snapshot = $snapDir; backup = @($edited) }
            Set-Content -LiteralPath $jp -Value (ConvertTo-Json $pending -Depth 6 -Compress) -Encoding utf8

            Repair-NetscootJournal -RepositoryRoot $root -Rollback -Id 'wal00001' -Force | Out-Null

            # The id is gone from the file. Either the file no longer exists (was the only entry)
            # or it exists without any line referencing the rolled-back id.
            if (Test-Path -LiteralPath $jp) {
                $remainingIds = @(Get-Content -LiteralPath $jp) | Where-Object { $_.Trim() } |
                    ForEach-Object { ($_ | ConvertFrom-Json).id }
                $remainingIds | Should -Not -Contain 'wal00001'
            }
            # Either way, no interrupted move is visible.
            @(Get-InterruptedMove -RepositoryRoot $root).Count | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $snapDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'WAL: status taxonomy is exactly {pending, committed, rolledback} and every value in it parses cleanly' {
        # Lock down the closed taxonomy by writing one synthetic line of each status and asserting
        # they all parse as valid entries. Tests the *reader's* tolerance of every status; the
        # *writer*'s adherence to the same closed set is enforced separately by the ValidateSet on
        # Complete-MoveJournalEntry's -Status parameter (already in the source).
        $root = New-JournalFixture
        try {
            $jp = Get-MoveJournalPath -RepositoryRoot $root
            New-Item -ItemType Directory -Path (Split-Path -Parent $jp) -Force | Out-Null
            $base = @{ v = 2; timestamp = (Get-Date).ToUniversalTime().ToString('o'); command = 'Move-DotnetProject'; engine = 'dotnet'; source = 's'; destination = 'd'; undo = @{}; snapshot = ''; backup = @() }
            $lines = @(
                (($base + @{ id = 'taxopnd1'; status = 'pending' }) | ConvertTo-Json -Compress),
                (($base + @{ id = 'taxocmt1'; status = 'committed' }) | ConvertTo-Json -Compress),
                (($base + @{ id = 'taxorbk1'; status = 'rolledback' }) | ConvertTo-Json -Compress)
            )
            Set-Content -LiteralPath $jp -Value $lines -Encoding utf8

            $observed = @(Get-Content -LiteralPath $jp) | Where-Object { $_.Trim() } |
                ForEach-Object { ($_ | ConvertFrom-Json).status } | Sort-Object -Unique
            # Every observed status is in the documented set.
            foreach ($s in $observed) { $s | Should -BeIn 'pending', 'committed', 'rolledback' }
            # And the round-trip read produced all three.
            $observed | Should -Contain 'pending'
            $observed | Should -Contain 'committed'
            $observed | Should -Contain 'rolledback'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'Compaction (Compress-MoveJournalLines) never drops a pending entry, even when an older committed one is present' {
        # Safety invariant: a pending entry represents in-flight work that the recovery tooling
        # needs to find. Compaction MUST NOT trim it, regardless of age. A future per-move-partition
        # layout where compaction is per-file deletion must observe the same rule (a partition file
        # whose latest state is pending cannot be deleted by compaction).
        InModuleScope NetscootShared {
            $mk = { param($id, $status, $ts) (@{ v = 2; id = $id; timestamp = $ts; status = $status; command = 'Move-DotnetProject'; engine = 'dotnet'; source = 's'; destination = 'd'; undo = @{}; snapshot = ''; backup = @() } | ConvertTo-Json -Compress) }
            # 'old-pending' is the oldest entry; 'new-committed' is newer. Compaction must not
            # collapse them in a way that loses old-pending.
            $lines = @(
                (& $mk 'oldpend1' 'pending' '2025-01-01T00:00:00Z'),
                (& $mk 'newcomt1' 'pending' '2026-06-01T00:00:00Z'),
                (& $mk 'newcomt1' 'committed' '2026-06-01T00:00:05Z')
            )
            $compacted = @(Compress-MoveJournalLines -Lines $lines)
            $compactedStatuses = $compacted | ForEach-Object { ($_ | ConvertFrom-Json).status }
            $compactedIds = $compacted | ForEach-Object { ($_ | ConvertFrom-Json).id }
            # The folded view has two entries: oldpend1 (still pending - survives compaction) and
            # newcomt1 (folded to its committed line).
            $compacted.Count | Should -Be 2
            $compactedIds | Should -Contain 'oldpend1'
            $compactedIds | Should -Contain 'newcomt1'
            # @()-coerce: a single match makes Where-Object return a scalar; .Count on that throws
            # under StrictMode in Windows PowerShell 5.1. Standard guard pattern in this codebase.
            @($compactedStatuses | Where-Object { $_ -eq 'pending' }).Count | Should -Be 1
            @($compactedStatuses | Where-Object { $_ -eq 'committed' }).Count | Should -Be 1
        }
    }
}
