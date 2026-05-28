#requires -Modules Pester

# v2 journal on-disk format - regression suite.
#
# The v2 journal is a WAL (write-ahead log): each move appends a 'pending' record before the work
# starts, then a 'committed' or 'rolledback' outcome record after. The on-disk file is an append-
# only sequence of state-TRANSITIONS, not a sequence of final states. Reading folds-by-id
# (latest line per id wins) to yield the logical entry set.
#
# Locks down: file shape (JSONL), per-entry field set, the WAL pending->committed sequence,
# command-name mapping, schema-version forward-safety, -NoJournal behavior. When a future change
# (e.g. the per-move-partition journal coming in v3.0 / A2) reformats the journal, the migration
# must preserve every invariant locked here.
#
# Observable-only: assertions are against file contents on disk plus public cmdlet behavior, not
# against any internal helper's return shape. The v2 contract is the on-disk + public-cmdlet
# contract; internal APIs are free to evolve as long as those stay stable.

BeforeAll {
    . (Join-Path $PSScriptRoot TestHelpers.ps1)
    Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'src', 'Netscoot.Core', 'Netscoot.Core.psd1')) -Force
}

Describe 'Journal on-disk format (v2)' {
    BeforeAll {
        # Per-Describe shared repo, freshly copied from the cached template. Reuses the
        # 'journal-lib-sln' key from Journal.Tests so the template is built ONCE per session.
        $script:Repo = Copy-FixtureTemplate -Key 'journal-lib-sln' -Prefix 'jfmt' -Build {
            $r = New-TempRoot -Prefix 'jfmt'
            Push-Location $r
            try {
                & git init -q
                New-StubClassLib -Name Lib -Directory (Join-Path $r (Join-Path 'src' 'Lib')) | Out-Null
                & dotnet new sln -n Demo | Out-Null
                $sln = (Get-ChildItem -LiteralPath $r -File -Filter '*.sln').FullName
                & dotnet sln $sln add (Join-Path $r (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))) | Out-Null
                & git add -A; & git commit -qm fixture | Out-Null
            } finally { Pop-Location }
            return $r
        }

        # Raw JSONL line read - the format contract is what's on disk, parsed in the same way
        # any other tool would parse it. Skip empty/whitespace lines (defensive against trailing
        # newlines).
        function script:Read-RawJournalLines {
            $path = Get-MoveJournalPath -RepositoryRoot $script:Repo
            if (-not (Test-Path -LiteralPath $path)) { return @() }
            @(Get-Content -LiteralPath $path) | Where-Object { $_.Trim() }
        }

        # Parse each line; the WAL contract is that every line is a complete, self-contained,
        # parseable JSON object. A line that fails to parse is a real corruption signal.
        function script:Read-ParsedJournal {
            @(Read-RawJournalLines | ForEach-Object { $_ | ConvertFrom-Json })
        }

        # Fold the WAL: latest line per id wins, in append order. Mirrors what Get-MoveJournalEntries
        # does internally via Read-MoveJournalState. Used to check the LOGICAL entry state, not the
        # raw transition log.
        function script:Read-FoldedJournal {
            $byId = [ordered]@{}
            foreach ($e in Read-ParsedJournal) { $byId[$e.id] = $e }
            @($byId.Values)
        }
    }

    # Reset working tree + journal between tests so each It starts from the pristine committed
    # state. git reset --hard restores moved files; Clear-NetscootJournal drops the journal file.
    AfterEach {
        Push-Location $script:Repo
        try {
            & git reset --hard HEAD 2>$null | Out-Null
            & git clean -fd 2>$null | Out-Null
        } finally { Pop-Location }
        Clear-NetscootJournal -RepositoryRoot $script:Repo -Confirm:$false -ErrorAction SilentlyContinue
    }

    Context 'File shape' {
        It 'every non-empty line in the journal file is parseable JSON' {
            $lib = Join-Path $script:Repo (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))
            Move-DotnetProject -Project $lib -Destination (Join-Path $script:Repo (Join-Path 'libs' 'Lib')) -RepositoryRoot $script:Repo -NoBuild -Confirm:$false | Out-Null
            $lines = Read-RawJournalLines
            $lines.Count | Should -BeGreaterOrEqual 1
            foreach ($line in $lines) {
                { $line | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw
            }
        }

        It '-NoJournal does not create a journal file' {
            $lib = Join-Path $script:Repo (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))
            $journalPath = Get-MoveJournalPath -RepositoryRoot $script:Repo
            Test-Path -LiteralPath $journalPath | Should -BeFalse
            Move-DotnetProject -Project $lib -Destination (Join-Path $script:Repo (Join-Path 'libs' 'Lib')) -RepositoryRoot $script:Repo -NoBuild -NoJournal -Confirm:$false | Out-Null
            Test-Path -LiteralPath $journalPath | Should -BeFalse
        }
    }

    Context 'WAL semantics' {
        It 'a successful move appends a pending record followed by a committed record (same id)' {
            $lib = Join-Path $script:Repo (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))
            Move-DotnetProject -Project $lib -Destination (Join-Path $script:Repo (Join-Path 'libs' 'Lib')) -RepositoryRoot $script:Repo -NoBuild -Confirm:$false | Out-Null
            $entries = Read-ParsedJournal
            $entries.Count | Should -Be 2
            $entries[0].status | Should -Be 'pending'
            $entries[1].status | Should -Be 'committed'
            $entries[0].id | Should -Be $entries[1].id   # same move
        }

        It 'after folding by id, the logical entry for a successful move has status=committed' {
            $lib = Join-Path $script:Repo (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))
            Move-DotnetProject -Project $lib -Destination (Join-Path $script:Repo (Join-Path 'libs' 'Lib')) -RepositoryRoot $script:Repo -NoBuild -Confirm:$false | Out-Null
            $folded = Read-FoldedJournal
            $folded.Count | Should -Be 1
            $folded[0].status | Should -Be 'committed'
        }

        It 'commit record clears the snapshot and backup fields (recovery moot once committed)' {
            $lib = Join-Path $script:Repo (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))
            Move-DotnetProject -Project $lib -Destination (Join-Path $script:Repo (Join-Path 'libs' 'Lib')) -RepositoryRoot $script:Repo -NoBuild -Confirm:$false | Out-Null
            $commit = Read-ParsedJournal | Where-Object status -eq 'committed' | Select-Object -First 1
            $commit.snapshot | Should -Be ''
            @($commit.backup).Count | Should -Be 0
        }
    }

    Context 'Per-entry field shape (the documented schema)' {
        It 'has the documented field set {v, id, timestamp, status, command, engine, source, destination, undo, snapshot, backup}' {
            $lib = Join-Path $script:Repo (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))
            Move-DotnetProject -Project $lib -Destination (Join-Path $script:Repo (Join-Path 'libs' 'Lib')) -RepositoryRoot $script:Repo -NoBuild -Confirm:$false | Out-Null
            $entry = (Read-ParsedJournal)[0]
            foreach ($f in 'v', 'id', 'timestamp', 'status', 'command', 'engine', 'source', 'destination', 'undo', 'snapshot', 'backup') {
                $entry.PSObject.Properties.Name | Should -Contain $f
            }
        }

        It 'v (schema version) is a positive integer' {
            $lib = Join-Path $script:Repo (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))
            Move-DotnetProject -Project $lib -Destination (Join-Path $script:Repo (Join-Path 'libs' 'Lib')) -RepositoryRoot $script:Repo -NoBuild -Confirm:$false | Out-Null
            $entry = (Read-ParsedJournal)[0]
            ([int]$entry.v) -gt 0 | Should -BeTrue
        }

        It 'id is 8 lowercase hex characters' {
            $lib = Join-Path $script:Repo (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))
            Move-DotnetProject -Project $lib -Destination (Join-Path $script:Repo (Join-Path 'libs' 'Lib')) -RepositoryRoot $script:Repo -NoBuild -Confirm:$false | Out-Null
            $entry = (Read-ParsedJournal)[0]
            $entry.id | Should -Match '^[a-f0-9]{8}$'
        }

        It 'timestamp parses as a DateTime' {
            $lib = Join-Path $script:Repo (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))
            Move-DotnetProject -Project $lib -Destination (Join-Path $script:Repo (Join-Path 'libs' 'Lib')) -RepositoryRoot $script:Repo -NoBuild -Confirm:$false | Out-Null
            $entry = (Read-ParsedJournal)[0]
            { [datetime]::Parse($entry.timestamp, [cultureinfo]::InvariantCulture) } | Should -Not -Throw
        }

        It 'engine is one of the documented enum values' {
            $lib = Join-Path $script:Repo (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))
            Move-DotnetProject -Project $lib -Destination (Join-Path $script:Repo (Join-Path 'libs' 'Lib')) -RepositoryRoot $script:Repo -NoBuild -Confirm:$false | Out-Null
            $entry = (Read-ParsedJournal)[0]
            $entry.engine | Should -BeIn 'dotnet', 'native', 'unity', 'powershell'
        }

        It 'source and destination are absolute paths' {
            $lib = Join-Path $script:Repo (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))
            Move-DotnetProject -Project $lib -Destination (Join-Path $script:Repo (Join-Path 'libs' 'Lib')) -RepositoryRoot $script:Repo -NoBuild -Confirm:$false | Out-Null
            $entry = (Read-ParsedJournal)[0]
            [System.IO.Path]::IsPathRooted($entry.source) | Should -BeTrue
            [System.IO.Path]::IsPathRooted($entry.destination) | Should -BeTrue
        }

        It 'paths with spaces survive round-trip' {
            $lib = Join-Path $script:Repo (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))
            $destWithSpace = Join-Path $script:Repo 'lib with space'
            Move-DotnetProject -Project $lib -Destination $destWithSpace -RepositoryRoot $script:Repo -NoBuild -Confirm:$false | Out-Null
            $entry = (Read-ParsedJournal)[0]
            $entry.destination | Should -Match 'lib with space'
            Test-Path -LiteralPath $entry.destination | Should -BeTrue
        }

        It 'undo field carries Command and Params so the move can be replayed' {
            $lib = Join-Path $script:Repo (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))
            Move-DotnetProject -Project $lib -Destination (Join-Path $script:Repo (Join-Path 'libs' 'Lib')) -RepositoryRoot $script:Repo -NoBuild -Confirm:$false | Out-Null
            $entry = (Read-ParsedJournal)[0]
            $entry.undo.PSObject.Properties.Name | Should -Contain 'Command'
            $entry.undo.PSObject.Properties.Name | Should -Contain 'Params'
            $entry.undo.Command | Should -Be 'Move-DotnetProject'
        }
    }

    Context 'Command-field per mover (the engine-cmdlet -> command mapping)' {
        It 'Move-DotnetProject writes command="Move-DotnetProject"' {
            $lib = Join-Path $script:Repo (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))
            Move-DotnetProject -Project $lib -Destination (Join-Path $script:Repo (Join-Path 'libs' 'Lib')) -RepositoryRoot $script:Repo -NoBuild -Confirm:$false | Out-Null
            (Read-FoldedJournal)[0].command | Should -Be 'Move-DotnetProject'
        }
    }

    Context 'Multi-move sequences (id uniqueness and chronological order)' {
        It 'each move produces a distinct id across a sequence' {
            $lib = Join-Path $script:Repo (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))
            Move-DotnetProject -Project $lib -Destination (Join-Path $script:Repo (Join-Path 'libs1' 'Lib')) -RepositoryRoot $script:Repo -NoBuild -Confirm:$false | Out-Null
            $lib2 = Join-Path $script:Repo (Join-Path 'libs1' (Join-Path 'Lib' 'Lib.csproj'))
            Move-DotnetProject -Project $lib2 -Destination (Join-Path $script:Repo (Join-Path 'libs2' 'Lib')) -RepositoryRoot $script:Repo -NoBuild -Confirm:$false | Out-Null
            $lib3 = Join-Path $script:Repo (Join-Path 'libs2' (Join-Path 'Lib' 'Lib.csproj'))
            Move-DotnetProject -Project $lib3 -Destination (Join-Path $script:Repo (Join-Path 'libs3' 'Lib')) -RepositoryRoot $script:Repo -NoBuild -Confirm:$false | Out-Null

            $folded = Read-FoldedJournal
            $folded.Count | Should -Be 3
            ($folded | ForEach-Object id | Sort-Object -Unique).Count | Should -Be 3
        }

        It 'timestamps on the folded (committed) entries are monotonically non-decreasing' {
            $lib = Join-Path $script:Repo (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))
            Move-DotnetProject -Project $lib -Destination (Join-Path $script:Repo (Join-Path 'libs1' 'Lib')) -RepositoryRoot $script:Repo -NoBuild -Confirm:$false | Out-Null
            $lib2 = Join-Path $script:Repo (Join-Path 'libs1' (Join-Path 'Lib' 'Lib.csproj'))
            Move-DotnetProject -Project $lib2 -Destination (Join-Path $script:Repo (Join-Path 'libs2' 'Lib')) -RepositoryRoot $script:Repo -NoBuild -Confirm:$false | Out-Null

            $folded = Read-FoldedJournal
            $folded.Count | Should -Be 2
            $t0 = [datetime]::Parse($folded[0].timestamp, [cultureinfo]::InvariantCulture)
            $t1 = [datetime]::Parse($folded[1].timestamp, [cultureinfo]::InvariantCulture)
            ($t1 -ge $t0) | Should -BeTrue
        }
    }
}
