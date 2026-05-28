# Per-entry journal storage helpers.
#
# Alongside the existing single-file journal (one .jsonl per repository, one line per state
# transition, see Journal.ps1), these helpers store each entry as its own file in a per-repository
# directory:
#
#   <appdata>/netscoot/<leaf>-<hash>.jsonl       <- existing single-file storage
#   <appdata>/netscoot/<leaf>-<hash>/entries/    <- per-entry storage (this file's helpers)
#       20260529143012123-a1b2c3d4.json
#       20260529143245456-e5f6g7h8.json
#
# Filename is `<yyyyMMddHHmmssfff>-<id>.json`, so directory listing sorted by name is chronological.
# Same repository-identity hash as Get-MoveJournalPath; the two storage modes are co-located under
# the same key but distinguished by extension (`.jsonl` file vs `/` directory).
#
# Nothing in NetscootShared.psd1's existing call graph routes through these helpers yet - the
# movers, Repair-NetscootJournal, and the journal-reading cmdlets still use the single-file API.
# Adding the parallel data path now keeps the surface small per change; later phases switch
# callers over after coverage is solid.

function Get-MoveJournalPartitionDir {
    # Resolve the per-entry partition directory for a repository. Sibling to Get-MoveJournalPath;
    # the directory does NOT have to exist yet (callers create it on first write). Returns the
    # `<appdata>/netscoot/<leaf>-<hash>/entries/` path.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $filePath = Get-MoveJournalPath -RepositoryRoot $RepositoryRoot
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($filePath)
    $parent = [System.IO.Path]::GetDirectoryName($filePath)
    return ([System.IO.Path]::Combine($parent, $stem, 'entries'))
}

function Get-MoveJournalPartitionEntryPath {
    # Compute the partition file path for one entry. Filename embeds the entry's timestamp (UTC,
    # millisecond precision so sub-second moves are still ordered) and the 8-char id, so the
    # filename is sortable AND uniquely identifies the move. The function reads the timestamp from
    # the entry; it does not generate one (the entry is the source of truth).
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Entry
    )
    $dir = Get-MoveJournalPartitionDir -RepositoryRoot $RepositoryRoot
    $ts = [datetime]::Parse(("$($Entry.timestamp)"), [cultureinfo]::InvariantCulture).ToUniversalTime()
    $stamp = $ts.ToString('yyyyMMddHHmmssfff')
    return ([System.IO.Path]::Combine($dir, "$stamp-$($Entry.id).json"))
}

function Write-MoveJournalPartitionEntry {
    # Create a new per-entry file using CreateNew semantics - opens for write and throws if a file
    # at that path already exists. Same-id collision (vanishingly unlikely with random 8-hex ids)
    # is detectable rather than silently overwriting. Concurrent writers with DIFFERENT ids never
    # touch the same file and are safe regardless of locks.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Entry
    )
    $path = Get-MoveJournalPartitionEntryPath -RepositoryRoot $RepositoryRoot -Entry $Entry
    $dir = [System.IO.Path]::GetDirectoryName($path)
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $json = ConvertTo-Json $Entry -Depth 6 -Compress
    $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $stream.Write($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }
    return $path
}

function Read-MoveJournalPartitionEntries {
    # Enumerate every entry file in the partition, sorted by filename (which is chronological
    # because the filename embeds the entry timestamp). Returns parsed entry objects. A file whose
    # contents fail to parse is skipped without aborting the read, mirroring the single-file
    # journal's tolerance for a torn line. Returns an empty array when the partition dir does not
    # exist yet.
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $dir = Get-MoveJournalPartitionDir -RepositoryRoot $RepositoryRoot
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        try {
            $raw = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
            $parsed = $raw | ConvertFrom-Json
            if ($parsed) { $out.Add($parsed) }
        } catch {
            # Skip torn/corrupt files; do not abort the whole read.
            continue
        }
    }
    # Return the underlying array. Callers that need a guaranteed-array binding use @(Read-...)
    # at the call site (the standing PS5.1 + StrictMode guard pattern in this codebase).
    return $out.ToArray()
}

function Set-MoveJournalPartitionEntry {
    # Atomically replace an existing entry file with a new state (e.g. pending -> committed).
    # Writes to a sibling .tmp, then File.Replace (Windows) / File.Move with overwrite (Unix).
    # Concurrent readers see either the old state or the new state, never a half-written one.
    # The on-disk filename does not change: the timestamp+id in the filename is the move's
    # identity for the partition's lifetime, regardless of subsequent status transitions.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EntryPath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$NewEntry
    )
    $tmp = $EntryPath + '.tmp'
    $json = ConvertTo-Json $NewEntry -Depth 6 -Compress
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
    if ((Test-IsWindowsHost) -or ($PSVersionTable.PSEdition -eq 'Desktop')) {
        # File.Replace: atomic on NTFS; tolerates the destination being missing (would throw, but
        # the caller's contract is that EntryPath was just read so it exists). [NullString]::Value
        # is PowerShell's idiomatic way to pass C# null to a string parameter - $null gets coerced
        # to an empty string, which the underlying Win32 call then rejects as "path is empty".
        [System.IO.File]::Replace($tmp, $EntryPath, [NullString]::Value)
    } else {
        # POSIX rename(2) is atomic. .NET 5+ File.Move with overwrite=true wraps it.
        [System.IO.File]::Move($tmp, $EntryPath, $true)
    }
}

function Remove-MoveJournalPartitionEntry {
    # Delete one entry's file. Used by the post-crash Repair-Rollback recovery path, which removes
    # the entry rather than transitioning it (mirrors the single-file storage's behavior of
    # compacting a rolled-back id out of the file).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$EntryPath)
    if (Test-Path -LiteralPath $EntryPath) {
        Remove-Item -LiteralPath $EntryPath -Force
    }
}
