# Shared move-plan engine used by the move cmdlets so the transaction is uniform.
#
# A move is a transaction: detach references (while old paths resolve) -> move -> reattach.
# Each reconciliation item bundles its Detach + Reattach. Confirmation/preview is the caller's
# job via $PSCmdlet.ShouldProcess (canonical -WhatIf/-Confirm); this engine just runs the
# transaction once the operation is approved.

function New-MoveResult {
    # Build a move cmdlet's result object with a uniform base shape (Engine, Source,
    # Destination, Performed, SkippedCount) plus engine-specific extras, and stamp the
    # given PSTypeName for formatting/filtering. Every move cmdlet emits one of these.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TypeName,
        [Parameter(Mandatory)][ValidateSet('dotnet', 'native', 'unity', 'powershell')][string]$Engine,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [bool]$Performed,
        [int]$SkippedCount = 0,
        [hashtable]$Extra = @{}
    )
    $ordered = [ordered]@{
        Engine       = $Engine
        Source       = $Source
        Destination  = $Destination
        Performed    = $Performed
        SkippedCount = $SkippedCount
    }
    foreach ($k in $Extra.Keys) { $ordered[$k] = $Extra[$k] }
    $obj = [pscustomobject]$ordered
    $obj.PSObject.TypeNames.Insert(0, $TypeName)
    return $obj
}

function Resolve-MoveContext {
    # Shared front-half of every move: resolve git usage (red guidance + ShouldContinue/abort
    # when missing) and whether to confirm per-line. Returns { UseGit; PerLine } or $null on
    # abort (after writing the GitMissingAborted error via the calling cmdlet).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet,
        [switch]$Force,
        [Parameter(Mandatory)]$TargetForError
    )
    $gitMode = Resolve-GitUsage -Cmdlet $Cmdlet -Force:$Force
    if ($gitMode -eq 'Abort') {
        $Cmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                [System.OperationCanceledException]::new('Aborted: git not found and the plain-move fallback was declined.'),
                'GitMissingAborted', [System.Management.Automation.ErrorCategory]::OperationStopped, $TargetForError))
        return $null
    }
    [pscustomobject]@{ UseGit = ($gitMode -eq 'Git') }
}

function New-MoveItem {
    # Build one reconciliation item. Pass module-bound scriptblocks (not .GetNewClosure() -
    # closures rebind to the caller's scope and lose module-private functions like Invoke-Dotnet)
    # and hand loop values in via *Args. Mark Optional for heuristic/non-load-bearing items.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Description,
        [scriptblock]$Detach,
        [object[]]$DetachArgs = @(),
        [scriptblock]$Reattach,
        [object[]]$ReattachArgs = @(),
        [switch]$Optional
    )
    [pscustomobject]@{
        Description  = $Description
        Detach       = $Detach;   DetachArgs   = $DetachArgs
        Reattach     = $Reattach; ReattachArgs = $ReattachArgs
        Optional     = [bool]$Optional
    }
}

function Invoke-MovePlan {
    # Run the move transaction: detach all reconciliation items (old paths still resolve),
    # perform the move, reattach all items. Confirmation/-WhatIf is the caller's ShouldProcess
    # gate - this only runs once approved.
    #
    # Rollback: any step that fails throws (Invoke-Dotnet throws on non-zero exit; Move-PathTracked
    # throws on a failed move). To avoid leaving a half-reconciled repository, the caller passes the files
    # the reconciliation edits (-BackupPath) and a move-reversing scriptblock (-Rollback). On any
    # failure this restores those files from a snapshot and reverses the move, returning the repository to
    # its pre-move state. This is the safety net for the -Force (no-git) path, which otherwise has
    # no git history to recover from; with git it complements (does not replace) `git restore`.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Caption,
        [AllowEmptyCollection()][object[]]$Items = @(),
        [Parameter(Mandatory)][scriptblock]$Move,
        [object[]]$MoveArgs = @(),
        [string[]]$BackupPath = @(),
        [scriptblock]$Rollback,
        [object[]]$RollbackArgs = @(),
        # Write-ahead journaling. When -Command is supplied and journaling is enabled, a 'pending'
        # record is written BEFORE the transaction and a 'committed'/'rolledback' record after, so an
        # interrupted move is detectable. $UndoParams is the splat that reverses the move (same mover,
        # source/destination swapped). Omit these (or pass -NoJournal) to skip journaling.
        [string]$RepositoryRoot,
        [string]$Command,
        [string]$Engine,
        [string]$Source,
        [string]$Destination,
        [hashtable]$UndoParams,
        [switch]$NoJournal
    )
    Write-Verbose "Reconciling $(@($Items).Count) reference(s) around: $Caption"

    # The edited files we will snapshot, deduped and limited to ones that exist now, in a stable
    # order so the persisted index (f0, f1, ...) matches on recovery.
    $kept = @(@($BackupPath) | Select-Object -Unique | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) })
    $snapDir = $null
    if ($kept.Count) {
        $snapDir = Join-Path ([System.IO.Path]::GetTempPath()) ("netscoot_snap_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $snapDir | Out-Null
    }

    # Write-ahead: record intent before anything reversible happens, so a crash leaves a detectable
    # 'pending' entry (carrying source/destination, the snapshot dir, and the file->index mapping for
    # content recovery).
    $journaling = $Command -and (-not $NoJournal) -and (Test-MoveJournalEnabled -RepositoryRoot $RepositoryRoot)
    $hint = if ($Command -and $UndoParams) { Format-UndoHint -Command $Command -UndoParams $UndoParams } else { $null }
    $entry = $null
    if ($journaling) {
        $entry = Start-MoveJournalEntry -RepositoryRoot $RepositoryRoot -Command $Command -Engine $Engine `
            -Source $Source -Destination $Destination -Undo @{ Command = $Command; Params = $UndoParams } `
            -Snapshot $(if ($snapDir) { $snapDir } else { '' }) -Backup $kept
    }

    # Snapshot the edited files as f0, f1, ... (index = position in $kept), keyed by original path.
    $snap = [ordered]@{}
    if ($snapDir) {
        for ($i = 0; $i -lt $kept.Count; $i++) {
            $copy = Join-Path $snapDir ("f{0}" -f $i)
            Copy-Item -LiteralPath $kept[$i] -Destination $copy -Force
            $snap[$kept[$i]] = $copy
        }
    }

    $moved = $false
    try {
        # NOTE: @var is the splat operator (needs a bare variable); @(expr) is array-subexpression
        # and would pass the whole array as one argument. So copy to a local, then splat.
        foreach ($it in $Items) {
            if ($it.Detach) { $da = @($it.DetachArgs); & $it.Detach @da }
        }
        $ma = @($MoveArgs); & $Move @ma
        $moved = $true
        foreach ($it in $Items) {
            if ($it.Reattach) { $ra = @($it.ReattachArgs); & $it.Reattach @ra }
        }
    } catch {
        $cause = $_
        $rollbackOk = $true
        # Reverse the move first (so files return to where the snapshot expects them)...
        if ($moved -and $Rollback) {
            try { $rba = @($RollbackArgs); & $Rollback @rba }
            catch { $rollbackOk = $false; Write-Warning "Rollback move-back failed: $($_.Exception.Message)" }
        }
        # ...then restore every edited file's original content.
        foreach ($orig in $snap.Keys) {
            try { Copy-Item -LiteralPath $snap[$orig] -Destination $orig -Force }
            catch { $rollbackOk = $false; Write-Warning "Rollback restore failed for ${orig}: $($_.Exception.Message)" }
        }
        if ($rollbackOk) {
            # Cleanly reversed: mark the entry rolled back and drop the (now-moot) snapshot.
            if ($snapDir) { Remove-Item -LiteralPath $snapDir -Recurse -Force -ErrorAction SilentlyContinue }
            if ($journaling) { Complete-MoveJournalEntry -RepositoryRoot $RepositoryRoot -Entry $entry -Status 'rolledback' }
            throw "Move failed and was rolled back to the original state. Cause: $($cause.Exception.Message)"
        }
        # Partial state: leave the 'pending' entry and its snapshot in place so the move is detectable
        # (Get-InterruptedMove) and recoverable (Repair-NetscootJournal).
        throw "Move failed AND rollback was incomplete - the repository may be in a partial state. Check git status, or run Repair-NetscootJournal to recover. Cause: $($cause.Exception.Message)"
    }
    if ($snapDir) { Remove-Item -LiteralPath $snapDir -Recurse -Force -ErrorAction SilentlyContinue }
    if ($journaling) {
        Complete-MoveJournalEntry -RepositoryRoot $RepositoryRoot -Entry $entry -Status 'committed'
        Write-Host "Undo with: Undo-Netscoot   (replays: $hint)" -ForegroundColor DarkGray
    } elseif ($hint) {
        Write-Host "Undo (journaling off): $hint" -ForegroundColor DarkGray
    }

    [pscustomobject]@{ Applied = @($Items).Count; Skipped = 0 }
}
