# Retroactive-undo journal. Records one line per completed move so it can be reversed later - an hour
# later, or in a fresh session - with Undo-Netscoot. The move family is symmetric: each entry's
# inverse is the same mover run with source/destination swapped, re-reconciling from the CURRENT
# state (more robust than restoring a stale snapshot).
#
# Storage lives in the per-user application-data directory (not the working tree, not a volatile temp
# dir, not inside .git/ where prune/clean and repository deletion churn it). One folder, "netscoot",
# holds one <leaf>-<hash>.jsonl per repository (the hash of the repository root keeps repositories separate in
# the shared store). Resolves per OS:
#   Windows: %LOCALAPPDATA%                         (e.g. C:\Users\<u>\AppData\Local\netscoot\)
#   macOS:   ~/Library/Application Support          (Apple's LocalAppData equivalent)
#   Linux:   $XDG_DATA_HOME or ~/.local/share       (the XDG persistent-data location)
# Normal backup (Time Machine, roaming profiles, JAMF/Intune) covers these by default.
# $env:NETSCOOT_JOURNAL_HOME overrides the base dir (relocate the store, or isolate it in tests).
#
# Enabled resolution, first match wins:
#   1. an explicit suppression (NETSCOOT_JOURNAL_SUPPRESS, set by Undo around its reverse move)
#   2. $env:NETSCOOT_JOURNAL          (trumps git config, so an admin can force it on/off fleet-wide)
#   3. git config netscoot.journal    (local config wins over global - the persistent "git thing")
#   4. default: ON
#
# Write-ahead log. Invoke-MovePlan appends a 'pending' record for a move BEFORE it runs, then a
# 'committed' (or 'rolledback') record after - same id, a full self-contained line each time. On
# read the latest line per id wins, so a crash that interrupts a move leaves a 'pending' with no
# later record: that move is detectably incomplete (Get-InterruptedMove), and its line carries the
# source/destination and the snapshot path needed to recover it. Writes are append-only (O(1));
# pruning is lazy - only when the file outgrows the size cap do we read once, drop entries past the
# age/size caps (newest kept), and rewrite once. Because each line is complete and the newest per id
# wins, pruning a suffix never corrupts state.

$script:JournalMaxAgeDays = 180
$script:JournalMaxBytes = 1MB
# Schema version stamped on every entry ('v'). Bump only on a non-additive change. Read tolerates
# older/equal: a line with no 'v' is legacy v1 (the pre-WAL single-line format); v2 added the
# pending/committed WAL records. A line with a HIGHER v than this (written by a newer netscoot, e.g.
# after a downgrade) is skipped with a warning rather than misread.
$script:JournalSchemaVersion = 2
$script:JournalNewerWarned = $false
# Hoisted once (not rebuilt per call): a fast path to pull the timestamp out of a compact JSON line
# without paying ConvertFrom-Json for every line during pruning.
$script:JournalTimestampRegex = [regex]'"timestamp"\s*:\s*"([^"]+)"'

function ConvertFrom-JournalLine {
    # Parse one journal line, tolerating a torn/partial line (returns $null) so a single bad line
    # never breaks a read of the whole journal.
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    try { $Line | ConvertFrom-Json } catch { $null }
}

function Read-MoveJournalState {
    # Read all lines and fold them by id (latest line per id wins), preserving first-seen order
    # (chronological). Returns the reconciled entry objects, oldest first, each tagged for display.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $path = Get-MoveJournalPath -RepositoryRoot $RepositoryRoot
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $byId = [ordered]@{}
    foreach ($line in (Get-Content -LiteralPath $path)) {
        $o = ConvertFrom-JournalLine $line
        if (-not $o -or -not $o.id) { continue }
        # Forward-safety: skip a line written by a newer schema than we understand (e.g. after a
        # downgrade) rather than misread it. A missing 'v' is legacy v1.
        $v = if ($o.PSObject.Properties['v']) { [int]$o.v } else { 1 }
        if ($v -gt $script:JournalSchemaVersion) {
            if (-not $script:JournalNewerWarned) {
                Write-Warning "The journal has entries from a newer netscoot (schema v$v > v$script:JournalSchemaVersion); they are ignored. Update netscoot, or clear the journal with Clear-NetscootJournal."
                $script:JournalNewerWarned = $true
            }
            continue
        }
        $byId[$o.id] = $o   # update keeps the original insertion position (chronological)
    }
    foreach ($o in $byId.Values) { $o.PSObject.TypeNames.Insert(0, 'Netscoot.JournalEntry') }
    @($byId.Values)
}

function ConvertTo-JournalBool {
    # Parse a git-config / env truthy string to $true/$false, or $null when empty/unrecognized.
    param([string]$Value)
    switch -regex (("$Value").Trim().ToLowerInvariant()) {
        '^(1|true|on|yes|enabled)$' { $true; break }
        '^(0|false|off|no|disabled)$' { $false; break }
        default { $null }
    }
}

function Test-MoveJournalEnabled {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$RepositoryRoot)
    if ((ConvertTo-JournalBool $env:NETSCOOT_JOURNAL_SUPPRESS) -eq $true) { return $false }
    # The env var trumps git config: an admin can force journaling on/off fleet-wide (GPO/Intune/
    # profile) regardless of any repository's git setting.
    $envBool = ConvertTo-JournalBool $env:NETSCOOT_JOURNAL
    if ($null -ne $envBool) { return $envBool }
    if ($RepositoryRoot) {
        try {
            $cfg = "$(& git -C $RepositoryRoot config --get netscoot.journal 2>$null)"
            $b = ConvertTo-JournalBool $cfg
            if ($null -ne $b) { return $b }
        } catch { Write-Verbose "git config probe failed: $_" }
    }
    return $true
}

function Get-MoveJournalAppDataRoot {
    # The per-user application-data base, per OS. macOS is special-cased to Application Support
    # because .NET's LocalApplicationData maps to ~/.local/share on Unix (including macOS); on
    # Windows and Linux that mapping is already correct (%LOCALAPPDATA% / $XDG_DATA_HOME).
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # Explicit override (relocation / tests): use it verbatim as the base.
    if ($env:NETSCOOT_JOURNAL_HOME) { return $env:NETSCOOT_JOURNAL_HOME }
    $isMac = (Test-Path Variable:\IsMacOS) -and (Get-Variable -Name IsMacOS -ValueOnly)
    if ($isMac) { return (Join-Path $HOME 'Library/Application Support') }
    $base = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($base)) { $base = Join-Path $HOME '.local/share' }  # defensive fallback
    return $base
}

function Get-MoveJournalPath {
    # Resolve the journal file for a repository in the per-user store: <appdata>/netscoot/<leaf>-<hash>.jsonl.
    # The hash of the (lowercased) repository root keeps different repositories separate in the shared store;
    # the readable leaf name makes the file identifiable.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $dir = Join-Path (Get-MoveJournalAppDataRoot) 'netscoot'
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try { $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($RepositoryRoot.ToLowerInvariant())) }
    finally { $sha.Dispose() }
    $key = -join ($hash[0..3] | ForEach-Object { $_.ToString('x2') })
    $leaf = (Split-Path -Leaf $RepositoryRoot) -replace '[^A-Za-z0-9._-]', '_'
    if (-not $leaf) { $leaf = 'repo' }
    return (Join-Path $dir "$leaf-$key.jsonl")
}

function Select-RecentJournalLine {
    # Single pass: keep the newest lines that are within the age cap and whose cumulative size stays
    # under the byte cap. Input is oldest-first; output preserves that order. The newest line is
    # always kept (so a move is never silently dropped).
    [CmdletBinding()]
    param([string[]]$Lines)
    $cutoff = [datetime]::UtcNow.AddDays(-$script:JournalMaxAgeDays)
    $keep = [System.Collections.Generic.List[string]]::new($Lines.Count)
    $bytes = 0
    $utf8 = [System.Text.Encoding]::UTF8

    for ($i = $Lines.Count - 1; $i -ge 0; $i--) {
        $line = $Lines[$i]
        $ts = $null

        # Fast path: pull the timestamp straight out of the compact JSON with a hoisted regex.
        $m = $script:JournalTimestampRegex.Match($line)
        if ($m.Success) {
            $dto = [datetimeoffset]::MinValue
            if ([datetimeoffset]::TryParse($m.Groups[1].Value, [ref]$dto)) { $ts = $dto.UtcDateTime }
        }

        # Fallback: a reordered or odd line - parse it. ConvertFrom-Json may hand the timestamp back
        # as a string OR an already-parsed [datetime]; normalize either to a UTC instant.
        if ($null -eq $ts) {
            try {
                $t = ($line | ConvertFrom-Json).timestamp
                if ($t -is [datetime]) { $ts = if ($t.Kind -eq 'Local') { $t.ToUniversalTime() } else { [datetime]::SpecifyKind($t, [System.DateTimeKind]::Utc) } }
                elseif ($t -is [datetimeoffset]) { $ts = $t.UtcDateTime }
                elseif ($t) { $dto = [datetimeoffset]::MinValue; if ([datetimeoffset]::TryParse([string]$t, [ref]$dto)) { $ts = $dto.UtcDateTime } }
            } catch { $ts = $null }
        }

        if ($ts -and $ts -lt $cutoff) { break }   # older than the age cap: this and all earlier drop
        $sz = $utf8.GetByteCount($line) + 1
        if ($keep.Count -gt 0 -and ($bytes + $sz) -gt $script:JournalMaxBytes) { break }
        $bytes += $sz
        $keep.Add($line)   # O(1); we reverse once at the end instead of Insert(0) per line
    }

    $keep.Reverse()   # restore oldest-first
    $keep
}

function Compress-MoveJournalLines {
    # Fold to one line per id (the latest, by append order), preserving chronological order, and drop
    # ids whose latest outcome is 'rolledback' (reversed - no history to keep). This collapses a
    # completed move's pending+committed pair back to a single small committed line, so the journal
    # does not keep growing at two fat lines per move. Run during pruning. Torn lines are dropped.
    [CmdletBinding()]
    param([string[]]$Lines)
    $byId = [ordered]@{}
    foreach ($line in $Lines) {
        $o = ConvertFrom-JournalLine $line
        if (-not $o -or -not $o.id) { continue }
        $byId[$o.id] = [pscustomobject]@{ Line = $line; Status = "$($o.status)" }   # latest line per id
    }
    $out = [System.Collections.Generic.List[string]]::new($byId.Count)
    foreach ($v in $byId.Values) {
        if ($v.Status -eq 'rolledback') { continue }
        $out.Add($v.Line)
    }
    $out
}

function New-MoveJournalEntry {
    # Build a fresh 'pending' entry (with a new id). The caller appends it before the move, then
    # flips .status to 'committed'/'rolledback' and appends again. Each line is a complete,
    # self-contained record. $Undo is @{ Command = '<mover>'; Params = @{ <splat> } }. $Snapshot is
    # the temp dir holding the originals of the files the move edits (for crash recovery), or ''.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$Engine,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][hashtable]$Undo,
        [string]$Snapshot = '',
        [string[]]$Backup = @()
    )
    [ordered]@{
        v           = $script:JournalSchemaVersion
        id          = [guid]::NewGuid().ToString('N').Substring(0, 8)
        timestamp   = [datetime]::UtcNow.ToString('o')
        status      = 'pending'
        command     = $Command
        engine      = $Engine
        source      = $Source
        destination = $Destination
        undo        = $Undo
        snapshot    = $Snapshot
        # Original paths of the edited files, in the order they were copied into the snapshot dir as
        # f0, f1, ... (index = file name). Recovery restores snapshot/f<i> -> backup[i].
        backup      = @($Backup)
    }
}

function Write-MoveJournalEntry {
    # Append one entry object (at its current status) as a compact JSON line.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Entry
    )
    Write-MoveJournalLines -RepositoryRoot $RepositoryRoot -Lines (ConvertTo-Json $Entry -Depth 6 -Compress)
}

function Format-UndoHint {
    # The one-line "replays: ..." invocation shown after a move.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Command, [Parameter(Mandatory)][hashtable]$UndoParams)
    "$Command " + (($UndoParams.GetEnumerator() | Sort-Object Name | ForEach-Object {
                if ($_.Value -is [bool]) { if ($_.Value) { "-$($_.Key)" } }
                else { "-$($_.Key) '$($_.Value)'" }
            }) -join ' ')
}

function Write-MoveJournalLines {
    # Append one or more compact JSON lines to a repository's journal. The append is O(1); pruning is
    # lazy - only when the file has grown past the size cap do we read it once, prune, and rewrite.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Lines
    )
    if (-not $Lines.Count) { return }
    $path = Get-MoveJournalPath -RepositoryRoot $RepositoryRoot
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Add-Content -LiteralPath $path -Value $Lines -Encoding utf8
    # Lazy prune: skip the full read/rewrite unless the file actually outgrew the cap. First compact
    # (fold each id to its latest line, dropping superseded pending and rolled-back entries), then
    # apply the age/size caps to what remains.
    $info = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if ($info -and $info.Length -gt $script:JournalMaxBytes) {
        $all = @(Get-Content -LiteralPath $path | Where-Object { $_.Trim() })
        $kept = Select-RecentJournalLine -Lines @(Compress-MoveJournalLines -Lines $all)
        Set-Content -LiteralPath $path -Value $kept -Encoding utf8
    }
}

function Start-MoveJournalEntry {
    # Append the 'pending' record before a move runs, and return the entry object so the caller can
    # flip its status and append again once the move succeeds or rolls back.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$Engine,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][hashtable]$Undo,
        [string]$Snapshot = '',
        [string[]]$Backup = @()
    )
    $entry = New-MoveJournalEntry -Command $Command -Engine $Engine -Source $Source `
        -Destination $Destination -Undo $Undo -Snapshot $Snapshot -Backup $Backup
    Write-MoveJournalEntry -RepositoryRoot $RepositoryRoot -Entry $entry
    $entry
}

function Complete-MoveJournalEntry {
    # Append the outcome record for a started entry: 'committed' (the move finished) or 'rolledback'
    # (it failed and was reversed). On commit the snapshot reference is cleared (recovery moot).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Entry,
        [Parameter(Mandatory)][ValidateSet('committed', 'rolledback')][string]$Status
    )
    $Entry.status = $Status
    if ($Status -eq 'committed') { $Entry.snapshot = ''; $Entry.backup = @() }   # recovery moot once done
    Write-MoveJournalEntry -RepositoryRoot $RepositoryRoot -Entry $Entry
}

function Get-MoveJournalEntries {
    # Completed (committed) moves, oldest first - the undoable history. A line with no status field
    # is a legacy pre-WAL entry and is treated as committed. Pending (interrupted) and rolled-back
    # moves are excluded.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    @(Read-MoveJournalState -RepositoryRoot $RepositoryRoot |
        Where-Object { -not $_.PSObject.Properties['status'] -or $_.status -eq 'committed' })
}

function Get-InterruptedMove {
    # Moves with a 'pending' record and no later outcome: interrupted by a crash, so the working tree
    # may be mid-move. Each carries source/destination and the snapshot path needed to recover.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    @(Read-MoveJournalState -RepositoryRoot $RepositoryRoot | Where-Object { $_.status -eq 'pending' })
}

function Remove-MoveJournalEntry {
    # Drop every line for an id (pending + outcome) - called after a successful undo, or to clear a
    # recovered interrupted move. Torn lines are dropped too (defensive read).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot, [Parameter(Mandatory)][string]$Id)
    $path = Get-MoveJournalPath -RepositoryRoot $RepositoryRoot
    if (-not (Test-Path -LiteralPath $path)) { return }
    $kept = @(Get-Content -LiteralPath $path | Where-Object {
            $o = ConvertFrom-JournalLine $_
            $o -and $o.id -ne $Id
        })
    if ($kept.Count) { Set-Content -LiteralPath $path -Value $kept -Encoding utf8 }
    else { Remove-Item -LiteralPath $path -Force }
}
