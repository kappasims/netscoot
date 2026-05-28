#requires -Modules Pester

# Per-entry journal storage helpers.
#
# The functions under test live in NetscootShared/Common/JournalPartition.ps1. They store one
# journal entry per file under <appdata>/netscoot/<leaf>-<hash>/entries/. The single-file storage
# (Get-MoveJournalPath / Get-MoveJournalEntries / etc.) is unchanged and unused here.
#
# Coverage focuses on the helpers' externally-observable behavior: where files land, what gets
# written, what gets read, ordering, and atomic-create semantics. These are the contracts later
# callers will rely on.

BeforeAll {
    . (Join-Path $PSScriptRoot TestHelpers.ps1)
    Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'src', 'NetscootShared', 'NetscootShared.psd1')) -Force
}

Describe 'JournalPartition helpers' {
    BeforeAll {
        # Per-Describe fake repository root - the helpers hash it for the partition's identity, so
        # any path works as long as it's stable across the Describe.
        $script:Repo = New-TempRoot -Prefix 'jpart'

        function script:New-TestEntry {
            param(
                [string]$Id = ([guid]::NewGuid().ToString('N').Substring(0, 8)),
                [datetime]$Timestamp = [datetime]::UtcNow,
                [string]$Status = 'pending'
            )
            [ordered]@{
                v           = 2
                id          = $Id
                timestamp   = $Timestamp.ToString('o')
                status      = $Status
                command     = 'Move-DotnetProject'
                engine      = 'dotnet'
                source      = 'src/A/A.csproj'
                destination = 'libs/A/A.csproj'
                undo        = @{ Command = 'Move-DotnetProject'; Params = @{} }
                snapshot    = ''
                backup      = @()
            }
        }
    }

    AfterEach {
        # Wipe the partition dir so each test starts clean. The single-file journal (if any
        # accidentally got created) is also removed.
        $partDir = Get-MoveJournalPartitionDir -RepositoryRoot $script:Repo
        $partRoot = [System.IO.Path]::GetDirectoryName($partDir)
        if (Test-Path -LiteralPath $partRoot) { Remove-Item -LiteralPath $partRoot -Recurse -Force -ErrorAction SilentlyContinue }
        $jp = Get-MoveJournalPath -RepositoryRoot $script:Repo
        if (Test-Path -LiteralPath $jp) { Remove-Item -LiteralPath $jp -Force -ErrorAction SilentlyContinue }
    }

    Context 'Get-MoveJournalPartitionDir' {
        It 'returns a path that is a sibling of Get-MoveJournalPath' {
            $filePath = Get-MoveJournalPath -RepositoryRoot $script:Repo
            $partDir = Get-MoveJournalPartitionDir -RepositoryRoot $script:Repo
            # Same parent directory ('<appdata>/netscoot/').
            [System.IO.Path]::GetDirectoryName($filePath) | Should -Be ([System.IO.Path]::GetDirectoryName([System.IO.Path]::GetDirectoryName($partDir)))
            # Different identities: file vs directory under the same <leaf>-<hash> key.
            $filePath | Should -Not -Be $partDir
        }

        It 'returns the same path for the same repository' {
            $a = Get-MoveJournalPartitionDir -RepositoryRoot $script:Repo
            $b = Get-MoveJournalPartitionDir -RepositoryRoot $script:Repo
            $a | Should -Be $b
        }

        It 'returns different paths for different repositories' {
            $other = New-TempRoot -Prefix 'jpart2'
            try {
                Get-MoveJournalPartitionDir -RepositoryRoot $script:Repo | Should -Not -Be (Get-MoveJournalPartitionDir -RepositoryRoot $other)
            } finally { Remove-Item -LiteralPath $other -Recurse -Force -ErrorAction SilentlyContinue }
        }

        It 'does not create the directory; callers create on write' {
            $partDir = Get-MoveJournalPartitionDir -RepositoryRoot $script:Repo
            Test-Path -LiteralPath $partDir | Should -BeFalse
        }
    }

    Context 'Get-MoveJournalPartitionEntryPath' {
        It 'filename embeds the entry timestamp (UTC, millisecond precision) and the id' {
            $entry = New-TestEntry -Id 'abc12345' -Timestamp ([datetime]::new(2026, 5, 29, 14, 30, 12, 123, [System.DateTimeKind]::Utc))
            $path = Get-MoveJournalPartitionEntryPath -RepositoryRoot $script:Repo -Entry $entry
            [System.IO.Path]::GetFileName($path) | Should -Be '20260529143012123-abc12345.json'
        }

        It 'parses an entry whose timestamp string has a UTC marker' {
            $entry = New-TestEntry -Id '00000001'
            $entry.timestamp = '2026-05-29T14:30:12.0000000Z'
            $path = Get-MoveJournalPartitionEntryPath -RepositoryRoot $script:Repo -Entry $entry
            [System.IO.Path]::GetFileName($path) | Should -Be '20260529143012000-00000001.json'
        }

        It 'places the entry file inside the partition dir' {
            $entry = New-TestEntry
            $expected = Get-MoveJournalPartitionDir -RepositoryRoot $script:Repo
            $path = Get-MoveJournalPartitionEntryPath -RepositoryRoot $script:Repo -Entry $entry
            [System.IO.Path]::GetDirectoryName($path) | Should -Be $expected
        }
    }

    Context 'Write-MoveJournalPartitionEntry' {
        It 'creates the partition dir on first write and writes the entry file' {
            $entry = New-TestEntry -Id 'wrt00001'
            $path = Write-MoveJournalPartitionEntry -RepositoryRoot $script:Repo -Entry $entry
            Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
            $partDir = Get-MoveJournalPartitionDir -RepositoryRoot $script:Repo
            Test-Path -LiteralPath $partDir -PathType Container | Should -BeTrue
        }

        It 'returns the path that was written' {
            $entry = New-TestEntry -Id 'wrt00002'
            $expected = Get-MoveJournalPartitionEntryPath -RepositoryRoot $script:Repo -Entry $entry
            $returned = Write-MoveJournalPartitionEntry -RepositoryRoot $script:Repo -Entry $entry
            $returned | Should -Be $expected
        }

        It 'writes the entry as compact JSON that round-trips through ConvertFrom-Json' {
            $entry = New-TestEntry -Id 'wrt00003'
            $path = Write-MoveJournalPartitionEntry -RepositoryRoot $script:Repo -Entry $entry
            $roundTrip = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            $roundTrip.id | Should -Be 'wrt00003'
            $roundTrip.status | Should -Be 'pending'
            $roundTrip.command | Should -Be 'Move-DotnetProject'
        }

        It 'throws on a duplicate write (same timestamp + same id)' {
            $entry = New-TestEntry -Id 'wrt00004'
            Write-MoveJournalPartitionEntry -RepositoryRoot $script:Repo -Entry $entry | Out-Null
            { Write-MoveJournalPartitionEntry -RepositoryRoot $script:Repo -Entry $entry } | Should -Throw
        }
    }

    Context 'Read-MoveJournalPartitionEntries' {
        It 'returns an empty array when no partition dir exists' {
            $result = Read-MoveJournalPartitionEntries -RepositoryRoot $script:Repo
            @($result).Count | Should -Be 0
        }

        It 'reads back a single written entry with its fields intact' {
            $entry = New-TestEntry -Id 'rd000001'
            Write-MoveJournalPartitionEntry -RepositoryRoot $script:Repo -Entry $entry | Out-Null
            $read = @(Read-MoveJournalPartitionEntries -RepositoryRoot $script:Repo)
            $read.Count | Should -Be 1
            $read[0].id | Should -Be 'rd000001'
        }

        It 'returns entries in chronological order regardless of write order' {
            $t1 = [datetime]::new(2026, 5, 29, 10, 0, 0, [System.DateTimeKind]::Utc)
            $t2 = [datetime]::new(2026, 5, 29, 11, 0, 0, [System.DateTimeKind]::Utc)
            $t3 = [datetime]::new(2026, 5, 29, 12, 0, 0, [System.DateTimeKind]::Utc)
            # Write out of order: t2, t1, t3
            Write-MoveJournalPartitionEntry -RepositoryRoot $script:Repo -Entry (New-TestEntry -Id 'b0000002' -Timestamp $t2) | Out-Null
            Write-MoveJournalPartitionEntry -RepositoryRoot $script:Repo -Entry (New-TestEntry -Id 'a0000001' -Timestamp $t1) | Out-Null
            Write-MoveJournalPartitionEntry -RepositoryRoot $script:Repo -Entry (New-TestEntry -Id 'c0000003' -Timestamp $t3) | Out-Null
            $ids = @(Read-MoveJournalPartitionEntries -RepositoryRoot $script:Repo) | ForEach-Object id
            $ids | Should -Be @('a0000001', 'b0000002', 'c0000003')
        }

        It 'skips a corrupt entry file and continues with the rest' {
            $good = New-TestEntry -Id 'good0001'
            Write-MoveJournalPartitionEntry -RepositoryRoot $script:Repo -Entry $good | Out-Null
            $partDir = Get-MoveJournalPartitionDir -RepositoryRoot $script:Repo
            # Hand-write a torn/corrupt file alongside the good one.
            Set-Content -LiteralPath (Join-Path $partDir '99999999999999999-torn0001.json') -Value '{ not valid json' -Encoding UTF8
            $read = @(Read-MoveJournalPartitionEntries -RepositoryRoot $script:Repo)
            $read.Count | Should -Be 1
            $read[0].id | Should -Be 'good0001'
        }
    }

    Context 'Set-MoveJournalPartitionEntry (atomic state transition)' {
        It 'replaces the entry contents in place, leaving the filename unchanged' {
            $entry = New-TestEntry -Id 'set00001' -Status 'pending'
            $path = Write-MoveJournalPartitionEntry -RepositoryRoot $script:Repo -Entry $entry
            # Transition to committed (the typical pending -> committed pattern).
            $committed = [ordered]@{}
            foreach ($k in $entry.Keys) { $committed[$k] = $entry[$k] }
            $committed.status = 'committed'
            $committed.snapshot = ''
            $committed.backup = @()
            Set-MoveJournalPartitionEntry -EntryPath $path -NewEntry $committed
            # Same path - filename did not change.
            Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
            # Contents reflect the new state.
            $roundTrip = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            $roundTrip.status | Should -Be 'committed'
        }

        It 'leaves no temp file behind after a successful replace' {
            $entry = New-TestEntry -Id 'set00002'
            $path = Write-MoveJournalPartitionEntry -RepositoryRoot $script:Repo -Entry $entry
            $entry.status = 'committed'
            Set-MoveJournalPartitionEntry -EntryPath $path -NewEntry $entry
            Test-Path -LiteralPath ($path + '.tmp') | Should -BeFalse
        }
    }

    Context 'Remove-MoveJournalPartitionEntry' {
        It 'deletes the entry file' {
            $entry = New-TestEntry -Id 'rm000001'
            $path = Write-MoveJournalPartitionEntry -RepositoryRoot $script:Repo -Entry $entry
            Remove-MoveJournalPartitionEntry -EntryPath $path
            Test-Path -LiteralPath $path | Should -BeFalse
        }

        It 'is a no-op (no error) on a path that does not exist' {
            $ghost = Join-Path (Get-MoveJournalPartitionDir -RepositoryRoot $script:Repo) 'nothing-here.json'
            { Remove-MoveJournalPartitionEntry -EntryPath $ghost } | Should -Not -Throw
        }
    }

    Context 'Existing single-file API is untouched' {
        # Sanity: writing to the partition does not touch the single-file journal, and vice versa.
        It 'writing a partition entry does not create the single-file journal' {
            $entry = New-TestEntry -Id 'iso00001'
            Write-MoveJournalPartitionEntry -RepositoryRoot $script:Repo -Entry $entry | Out-Null
            Test-Path -LiteralPath (Get-MoveJournalPath -RepositoryRoot $script:Repo) | Should -BeFalse
        }
    }
}
