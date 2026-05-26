# Retroactive-undo journal. A .dotnetmove/journal.jsonl at the repository root records one line per
# completed move so it can be reversed later - an hour later, or in a fresh session - with Undo-DotnetMove.
# The move family is symmetric: each entry's inverse is the same mover run with source/destination
# swapped, which re-reconciles from the CURRENT state (more robust than restoring a stale snapshot).
#
# On by default. Opt out by setting $env:DOTNETMOVE_JOURNAL to 0/false/off/no (install.ps1 -NoJournal
# sets it for you). The module only ever READS that variable, so installing or updating DotnetMove
# can never silently switch journaling back on for someone who opted out.

function Test-MoveJournalEnabled {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $v = "$env:DOTNETMOVE_JOURNAL".Trim().ToLowerInvariant()
    return ($v -notin '0', 'false', 'off', 'no', 'disabled')
}

function Get-MoveJournalPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RepoRoot)
    Join-Path (Join-Path $RepoRoot '.dotnetmove') 'journal.jsonl'
}

function Add-MoveJournalEntry {
    # Append one completed move. $Undo is @{ Command = '<mover>'; Params = @{ <splat to reverse> } }.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$Engine,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][hashtable]$Undo
    )
    $dir = Join-Path $RepoRoot '.dotnetmove'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # Self-ignore: a .gitignore of '*' makes git treat the whole .dotnetmove/ folder (the journal and
    # this file) as ignored, so nothing is ever committed and the repo's own .gitignore is untouched.
    $gi = Join-Path $dir '.gitignore'
    if (-not (Test-Path -LiteralPath $gi)) { [System.IO.File]::WriteAllText($gi, "*`n", [System.Text.UTF8Encoding]::new($false)) }
    $entry = [ordered]@{
        id          = [guid]::NewGuid().ToString('N').Substring(0, 8)
        timestamp   = (Get-Date).ToUniversalTime().ToString('o')
        command     = $Command
        engine      = $Engine
        source      = $Source
        destination = $Destination
        undo        = $Undo
    }
    Add-Content -LiteralPath (Get-MoveJournalPath -RepoRoot $RepoRoot) -Value (ConvertTo-Json $entry -Depth 6 -Compress) -Encoding utf8
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
    # Called by each mover after a successful move: emits a one-line undo hint and, when journaling
    # is enabled, records the reversing invocation. $UndoParams is the splat that reverses the move
    # (the same mover with source/destination swapped).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$Engine,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][hashtable]$UndoParams
    )
    $inv = "$Command " + (($UndoParams.GetEnumerator() | Sort-Object Name | ForEach-Object {
                if ($_.Value -is [bool]) { if ($_.Value) { "-$($_.Key)" } }
                else { "-$($_.Key) '$($_.Value)'" }
            }) -join ' ')
    if (Test-MoveJournalEnabled) {
        Add-MoveJournalEntry -RepoRoot $RepoRoot -Command $Command -Engine $Engine -Source $Source `
            -Destination $Destination -Undo @{ Command = $Command; Params = $UndoParams }
        Write-Host "Undo with: Undo-DotnetMove   (replays: $inv)" -ForegroundColor DarkGray
    } else {
        Write-Host "Undo (journaling off): $inv" -ForegroundColor DarkGray
    }
}
