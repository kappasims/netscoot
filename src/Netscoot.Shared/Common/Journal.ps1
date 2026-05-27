# Retroactive-undo journal. Records one line per completed move so it can be reversed later - an hour
# later, or in a fresh session - with Undo-Netscoot. The move family is symmetric: each entry's
# inverse is the same mover run with source/destination swapped, re-reconciling from the CURRENT
# state (more robust than restoring a stale snapshot).
#
# Storage lives in the per-user application-data directory (not the working tree, not a volatile temp
# dir, not inside .git/ where prune/clean and repo deletion churn it). One folder, "netscoot",
# holds one <repo-leaf>-<hash>.jsonl per repository (the hash of the repo root keeps repos separate in
# the shared store). Resolves per OS:
#   Windows: %LOCALAPPDATA%                         (e.g. C:\Users\<u>\AppData\Local\netscoot\)
#   macOS:   ~/Library/Application Support          (Apple's LocalAppData equivalent)
#   Linux:   $XDG_DATA_HOME or ~/.local/share       (the XDG persistent-data location)
# Enterprise backup (Time Machine, roaming profiles, JAMF/Intune) covers these by default.
# $env:NETSCOOT_JOURNAL_HOME overrides the base dir (relocate the store, or isolate it in tests).
#
# Enabled resolution, first match wins:
#   1. an explicit suppression (NETSCOOT_JOURNAL_SUPPRESS, set by Undo around its reverse move)
#   2. git config netscoot.journal   (local config wins over global - the persistent "git thing")
#   3. $env:NETSCOOT_JOURNAL          (the no-git / CI escape hatch)
#   4. default: ON
#
# Pruning keeps the journal small: on each write it drops entries older than the age cap and, oldest
# first, anything beyond the size cap - in a single pass (read once, filter, write once).

$script:JournalMaxAgeDays = 180
$script:JournalMaxBytes = 1MB

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
    param([string]$RepoRoot)
    if ((ConvertTo-JournalBool $env:NETSCOOT_JOURNAL_SUPPRESS) -eq $true) { return $false }
    if ($RepoRoot) {
        try {
            $cfg = "$(& git -C $RepoRoot config --get netscoot.journal 2>$null)"
            $b = ConvertTo-JournalBool $cfg
            if ($null -ne $b) { return $b }
        } catch { Write-Verbose "git config probe failed: $_" }
    }
    $b = ConvertTo-JournalBool $env:NETSCOOT_JOURNAL
    if ($null -ne $b) { return $b }
    return $true
}

function Get-MoveJournalAppDataRoot {
    # The per-user application-data base, per OS. macOS is special-cased to Application Support
    # because .NET's LocalApplicationData maps to ~/.local/share on Unix (including macOS); on
    # Windows and Linux that mapping is already correct (%LOCALAPPDATA% / $XDG_DATA_HOME).
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # Explicit override (enterprise relocation / tests): use it verbatim as the base.
    if ($env:NETSCOOT_JOURNAL_HOME) { return $env:NETSCOOT_JOURNAL_HOME }
    $isMac = (Test-Path Variable:\IsMacOS) -and (Get-Variable -Name IsMacOS -ValueOnly)
    if ($isMac) { return (Join-Path $HOME 'Library/Application Support') }
    $base = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($base)) { $base = Join-Path $HOME '.local/share' }  # defensive fallback
    return $base
}

function Get-MoveJournalPath {
    # Resolve the journal file for a repo in the per-user store: <appdata>/netscoot/<leaf>-<hash>.jsonl.
    # The hash of the (lowercased) repo root keeps different repositories separate in the shared store;
    # the readable leaf name makes the file identifiable.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RepoRoot)
    $dir = Join-Path (Get-MoveJournalAppDataRoot) 'netscoot'
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try { $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($RepoRoot.ToLowerInvariant())) }
    finally { $sha.Dispose() }
    $key = -join ($hash[0..3] | ForEach-Object { $_.ToString('x2') })
    $leaf = (Split-Path -Leaf $RepoRoot) -replace '[^A-Za-z0-9._-]', '_'
    if (-not $leaf) { $leaf = 'repo' }
    return (Join-Path $dir "$leaf-$key.jsonl")
}

function Select-RecentJournalLine {
    # Single pass: keep the newest lines that are within the age cap and whose cumulative size stays
    # under the byte cap. Input is oldest-first; output preserves that order. The newest line is
    # always kept (so a move is never silently dropped).
    [CmdletBinding()]
    param([string[]]$Lines)
    $cutoff = (Get-Date).ToUniversalTime().AddDays(-$script:JournalMaxAgeDays)
    $keep = [System.Collections.Generic.List[string]]::new()
    $bytes = 0
    for ($i = $Lines.Count - 1; $i -ge 0; $i--) {
        $line = $Lines[$i]
        $ts = $null
        try { $ts = ([datetimeoffset]::Parse((($line | ConvertFrom-Json).timestamp))).UtcDateTime } catch { $ts = $null }
        if ($ts -and $ts -lt $cutoff) { break }   # older than the age cap: this and all earlier drop
        $sz = [System.Text.Encoding]::UTF8.GetByteCount($line) + 1
        if ($keep.Count -gt 0 -and ($bytes + $sz) -gt $script:JournalMaxBytes) { break }
        $bytes += $sz
        $keep.Insert(0, $line)
    }
    , $keep.ToArray()
}

function Add-MoveJournalEntry {
    # Append one completed move (then prune). $Undo is @{ Command = '<mover>'; Params = @{ <splat> } }.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$Engine,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][hashtable]$Undo
    )
    $path = Get-MoveJournalPath -RepoRoot $RepoRoot
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $entry = [ordered]@{
        id          = [guid]::NewGuid().ToString('N').Substring(0, 8)
        timestamp   = (Get-Date).ToUniversalTime().ToString('o')
        command     = $Command
        engine      = $Engine
        source      = $Source
        destination = $Destination
        undo        = $Undo
    }
    $existing = if (Test-Path -LiteralPath $path) { @(Get-Content -LiteralPath $path | Where-Object { $_.Trim() }) } else { @() }
    $kept = Select-RecentJournalLine -Lines (@($existing) + (ConvertTo-Json $entry -Depth 6 -Compress))
    Set-Content -LiteralPath $path -Value $kept -Encoding utf8
}

function Get-MoveJournalEntries {
    # All journal entries, oldest first.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)
    $path = Get-MoveJournalPath -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    @(Get-Content -LiteralPath $path | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Remove-MoveJournalEntry {
    # Drop one entry by id (called after a successful undo).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Id)
    $path = Get-MoveJournalPath -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $path)) { return }
    $kept = @(Get-Content -LiteralPath $path | Where-Object { $_.Trim() } | Where-Object { ($_ | ConvertFrom-Json).id -ne $Id })
    if ($kept.Count) { Set-Content -LiteralPath $path -Value $kept -Encoding utf8 }
    else { Remove-Item -LiteralPath $path -Force }
}

function Register-MoveUndo {
    # Called by each mover after a successful move: emits a one-line undo hint and, when journaling is
    # enabled, records the reversing invocation. $UndoParams is the splat that reverses the move (the
    # same mover with source/destination swapped).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$Engine,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][hashtable]$UndoParams,
        # Per-call opt-out: skip journaling this one move (the caller's -NoJournal). Still prints the
        # one-line undo hint so the inverse invocation is visible, just without recording it.
        [switch]$NoJournal
    )
    $inv = "$Command " + (($UndoParams.GetEnumerator() | Sort-Object Name | ForEach-Object {
                if ($_.Value -is [bool]) { if ($_.Value) { "-$($_.Key)" } }
                else { "-$($_.Key) '$($_.Value)'" }
            }) -join ' ')
    if (-not $NoJournal -and (Test-MoveJournalEnabled -RepoRoot $RepoRoot)) {
        Add-MoveJournalEntry -RepoRoot $RepoRoot -Command $Command -Engine $Engine -Source $Source `
            -Destination $Destination -Undo @{ Command = $Command; Params = $UndoParams }
        Write-Host "Undo with: Undo-Netscoot   (replays: $inv)" -ForegroundColor DarkGray
    } else {
        Write-Host "Undo (journaling off): $inv" -ForegroundColor DarkGray
    }
}
