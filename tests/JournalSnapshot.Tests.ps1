#requires -Modules Pester

# v2 journal snapshot dir lifecycle - regression suite.
#
# Each in-flight move creates a "snapshot" directory holding pre-move copies of the files the move
# will edit, so a crash mid-move leaves enough state for recovery (Repair-NetscootJournal
# -Rollback restores from the snapshot). The dir's location and lifecycle are part of the v2
# contract a future per-move-partition layout (A2 in v3.0) must preserve.
#
# Path semantics, not path shape: assertions reference $entry.snapshot, never a hardcoded
# $env:TEMP/netscoot_snap_<id> pattern. A future layout that relocates snapshots into the journal
# partition dir (e.g. `<journal-home>/<repo>/snapshots/<id>/`) would still satisfy every assertion
# here as long as the journal entry's .snapshot field is the canonical reference.

BeforeAll {
    . (Join-Path $PSScriptRoot TestHelpers.ps1)
    Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'src', 'Netscoot.Core', 'Netscoot.Core.psd1')) -Force
}

Describe 'Snapshot dir lifecycle (v2)' {
    BeforeAll {
        $script:Repo = Copy-FixtureTemplate -Key 'journal-lib-sln' -Prefix 'jsnp' -Build {
            $r = New-TempRoot -Prefix 'jsnp'
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

        # Parse every entry from the journal file (raw read), without folding. Used to find a
        # specific synthetic entry by id and read its .snapshot field.
        function script:Read-AllJournalEntries {
            $path = Get-MoveJournalPath -RepositoryRoot $script:Repo
            if (-not (Test-Path -LiteralPath $path)) { return @() }
            @(Get-Content -LiteralPath $path) | Where-Object { $_.Trim() } |
                ForEach-Object { $_ | ConvertFrom-Json }
        }
    }

    AfterEach {
        Push-Location $script:Repo
        try {
            & git reset --hard HEAD 2>$null | Out-Null
            & git clean -fd 2>$null | Out-Null
        } finally { Pop-Location }
        Clear-NetscootJournal -RepositoryRoot $script:Repo -Confirm:$false -ErrorAction SilentlyContinue
    }

    It 'a successful move leaves no snapshot dir referenced by its committed entry (snapshot field is cleared on commit)' {
        $lib = Join-Path $script:Repo (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))
        Move-DotnetProject -Project $lib -Destination (Join-Path $script:Repo (Join-Path 'libs' 'Lib')) -RepositoryRoot $script:Repo -NoBuild -Confirm:$false | Out-Null
        # The committed (folded) entry has empty .snapshot. The recovery dir on disk that was
        # written during the move has been cleaned up by Invoke-MovePlan's success path.
        $committed = Get-MoveJournalEntries -RepositoryRoot $script:Repo | Select-Object -First 1
        $committed.snapshot | Should -Be ''
    }

    It 'a synthetic pending entry references its snapshot dir at the documented .snapshot field value' {
        $jp = Get-MoveJournalPath -RepositoryRoot $script:Repo
        New-Item -ItemType Directory -Path (Split-Path -Parent $jp) -Force | Out-Null
        $snapDir = New-TempRoot -Prefix 'netscoot_snap'
        Set-Content -LiteralPath (Join-Path $snapDir 'f0') -Value 'snapshot-content'
        $pending = @{ v = 2; id = 'snp00001'; timestamp = (Get-Date).ToUniversalTime().ToString('o'); status = 'pending'; command = 'Move-DotnetProject'; engine = 'dotnet'; source = (Join-Path $script:Repo 'gone'); destination = (Join-Path $script:Repo 'also-gone'); undo = @{ command = 'Move-DotnetProject'; params = @{} }; snapshot = $snapDir; backup = @() }
        Set-Content -LiteralPath $jp -Value (ConvertTo-Json $pending -Depth 6 -Compress) -Encoding utf8

        $entry = Read-AllJournalEntries | Where-Object id -eq 'snp00001' | Select-Object -First 1
        $entry.snapshot | Should -Be $snapDir
        Test-Path -LiteralPath $entry.snapshot | Should -BeTrue
    }

    It 'Repair-NetscootJournal -Rollback restores the file from the snapshot, then deletes the snapshot dir' {
        $edited = Join-Path $script:Repo 'edited.props'
        Set-Content -LiteralPath $edited -Value 'CHANGED'
        $snapDir = New-TempRoot -Prefix 'netscoot_snap'
        Set-Content -LiteralPath (Join-Path $snapDir 'f0') -Value 'ORIGINAL'

        $jp = Get-MoveJournalPath -RepositoryRoot $script:Repo
        New-Item -ItemType Directory -Path (Split-Path -Parent $jp) -Force | Out-Null
        $pending = @{ v = 2; id = 'snp00002'; timestamp = (Get-Date).ToUniversalTime().ToString('o'); status = 'pending'; command = 'Move-DotnetProject'; engine = 'dotnet'; source = (Join-Path $script:Repo 'gone'); destination = (Join-Path $script:Repo 'also-gone'); undo = @{ command = 'Move-DotnetProject'; params = @{} }; snapshot = $snapDir; backup = @($edited) }
        Set-Content -LiteralPath $jp -Value (ConvertTo-Json $pending -Depth 6 -Compress) -Encoding utf8

        Repair-NetscootJournal -RepositoryRoot $script:Repo -Rollback -Id 'snp00002' -Force | Out-Null

        # File restored from the snapshot's f0 copy.
        (Get-Content -LiteralPath $edited -Raw).Trim() | Should -Be 'ORIGINAL'
        # And the snapshot dir is gone (recovery moot once rolled back).
        Test-Path -LiteralPath $snapDir | Should -BeFalse
    }

    It 'Repair-NetscootJournal -ClearOrphanSnapshots removes netscoot_snap_* dirs NOT referenced by any pending entry' {
        # Three orphan snap dirs (no journal entry references them).
        $orphan1 = New-TempRoot -Prefix 'netscoot_snap'
        $orphan2 = New-TempRoot -Prefix 'netscoot_snap'
        $orphan3 = New-TempRoot -Prefix 'netscoot_snap'
        Set-Content -LiteralPath (Join-Path $orphan1 'f0') -Value 'orphan-1'
        Set-Content -LiteralPath (Join-Path $orphan2 'f0') -Value 'orphan-2'
        Set-Content -LiteralPath (Join-Path $orphan3 'f0') -Value 'orphan-3'

        Repair-NetscootJournal -RepositoryRoot $script:Repo -ClearOrphanSnapshots -Confirm:$false | Out-Null

        Test-Path -LiteralPath $orphan1 | Should -BeFalse
        Test-Path -LiteralPath $orphan2 | Should -BeFalse
        Test-Path -LiteralPath $orphan3 | Should -BeFalse
    }

    It '-ClearOrphanSnapshots LEAVES snap dirs that ARE referenced by a pending entry' {
        # One pending entry referencing its own snapshot, and one orphan.
        $referenced = New-TempRoot -Prefix 'netscoot_snap'
        Set-Content -LiteralPath (Join-Path $referenced 'f0') -Value 'referenced'
        $orphan = New-TempRoot -Prefix 'netscoot_snap'
        Set-Content -LiteralPath (Join-Path $orphan 'f0') -Value 'orphan'

        $jp = Get-MoveJournalPath -RepositoryRoot $script:Repo
        New-Item -ItemType Directory -Path (Split-Path -Parent $jp) -Force | Out-Null
        $pending = @{ v = 2; id = 'snp00003'; timestamp = (Get-Date).ToUniversalTime().ToString('o'); status = 'pending'; command = 'Move-DotnetProject'; engine = 'dotnet'; source = (Join-Path $script:Repo 'gone'); destination = (Join-Path $script:Repo 'also-gone'); undo = @{ command = 'Move-DotnetProject'; params = @{} }; snapshot = $referenced; backup = @() }
        Set-Content -LiteralPath $jp -Value (ConvertTo-Json $pending -Depth 6 -Compress) -Encoding utf8

        Repair-NetscootJournal -RepositoryRoot $script:Repo -ClearOrphanSnapshots -Confirm:$false | Out-Null

        # The pending entry's snapshot survives; the orphan is gone.
        Test-Path -LiteralPath $referenced | Should -BeTrue
        Test-Path -LiteralPath $orphan | Should -BeFalse

        # Clean up the surviving referenced snapshot so AfterEach can wipe cleanly.
        Remove-Item -LiteralPath $referenced -Recurse -Force -ErrorAction SilentlyContinue
    }
}
