# Shared move-plan engine used by the move cmdlets so the transaction is uniform.
#
# A move is a transaction: detach references (while old paths resolve) -> move -> reattach.
# Each reconciliation item bundles its Detach + Reattach. Confirmation/preview is the caller's
# job via $PSCmdlet.ShouldProcess (canonical -WhatIf/-Confirm); this engine just runs the
# transaction once the operation is approved.

function Write-MovePlan {
    # Emit a structured plan summary via Write-Verbose, so `-WhatIf -Verbose` reveals what a mover
    # would touch (solutions edited, consumer references repointed, own references rebased, etc.).
    # $Items is an ordered dictionary: scalars print inline, arrays print as a count line plus one
    # "- value" per element. Movers call this once they have computed their plan and before
    # Invoke-MovePlan, so a dry-run user can preview the reconciliation without trusting it silently.
    #
    # Why -Cmdlet: PowerShell does NOT auto-propagate $VerbosePreference across module boundaries -
    # a Netscoot.Core mover with -Verbose has $VerbosePreference='Continue', but a plain Write-Verbose
    # called from inside this Netscoot.Shared function runs against Shared's own (default) preference.
    # Threading the caller's $PSCmdlet through and using $Cmdlet.WriteVerbose routes the records into
    # the CALLER's stream, so -Verbose at the mover level lights up these lines as the user expects.
    param(
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet,
        [Parameter(Mandatory)][string]$Caption,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Items
    )
    $Cmdlet.WriteVerbose("Plan: $Caption")
    foreach ($k in $Items.Keys) {
        $v = $Items[$k]
        if ($null -eq $v) { $Cmdlet.WriteVerbose(("  {0}: (none)" -f $k)); continue }
        if ($v -is [string] -or $v.GetType().IsValueType) {
            $Cmdlet.WriteVerbose(("  {0}: {1}" -f $k, $v))
            continue
        }
        $arr = @($v)
        if ($arr.Count -eq 0) { $Cmdlet.WriteVerbose(("  {0}: (none)" -f $k)); continue }
        $Cmdlet.WriteVerbose(("  {0} ({1}):" -f $k, $arr.Count))
        foreach ($i in $arr) { $Cmdlet.WriteVerbose(("    - $i")) }
    }
}

function New-MoveResult {
    # Build a move cmdlet's result object with a uniform base shape (Engine, Source,
    # Destination, Performed, SkippedCount) plus engine-specific extras, and stamp the
    # given PSTypeName for formatting/filtering. Every move cmdlet emits one of these.
    #
    # Source/Destination are ABSOLUTE paths (the concrete on-disk locations the move acted on),
    # unlike the repository-relative paths the inventory/analysis result types emit.
    #
    # $Extra is typed [System.Collections.IDictionary] (not [hashtable]) and callers pass an
    # [ordered] dictionary, so the engine-specific properties keep their written order. A plain
    # [hashtable] enumerates by hash, which would scramble the property order against the documented
    # shape (docs/output-types.psd1) and the default Format-List output.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TypeName,
        [Parameter(Mandatory)][ValidateSet('dotnet', 'native', 'unity', 'powershell')][string]$Engine,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [bool]$Performed,
        [int]$SkippedCount = 0,
        [System.Collections.IDictionary]$Extra = [ordered]@{}
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
        [switch]$Optional,
        # Optional batch metadata (see New-DotnetReferenceItems). When present, Invoke-MovePlan
        # coalesces every item sharing a .Key into one dotnet spawn instead of running the
        # per-item scriptblock. Items without it run individually via Detach/Reattach as before.
        [hashtable]$DetachBatch,
        [hashtable]$ReattachBatch
    )
    [pscustomobject]@{
        Description   = $Description
        Detach        = $Detach;   DetachArgs    = $DetachArgs
        Reattach      = $Reattach; ReattachArgs  = $ReattachArgs
        Optional      = [bool]$Optional
        DetachBatch   = $DetachBatch
        ReattachBatch = $ReattachBatch
    }
}

function Invoke-MovePhase {
    # Run one phase (Detach or Reattach) of a move's reconciliation items.
    #
    # Performance: items carrying batch metadata for the phase (a hashtable { Key; Prefix; Item })
    # are coalesced - every item sharing a .Key collapses into ONE `dotnet` spawn whose command line
    # is the shared .Prefix followed by each item's .Item token. So all removes from one solution
    # become one `dotnet sln <sln> remove p1 p2 ...`, all re-adds become one `... add p1 p2 ...`,
    # and likewise per consumer/own-ref file - turning the old per-edge spawn count into one per file.
    #
    # Items WITHOUT batch metadata for this phase fall back to their per-item scriptblock (Detach/
    # Reattach), exactly as before, so generic non-dotnet items (e.g. Move-Solution's path rebases)
    # are unaffected.
    #
    # Groups and singletons run in first-appearance order; ordering across phases (detach-before-
    # move-before-reattach) is enforced by the caller. A batched spawn failing throws like any other,
    # so the caller's snapshot/rollback restores the whole pre-move state regardless of how far the
    # batch got (rollback restores file *content*, not individual CLI edits, so a partially-applied
    # multi-project spawn is reverted just the same).
    [CmdletBinding()]
    param(
        [object[]]$Items = @(),
        [Parameter(Mandatory)][ValidateSet('Detach', 'Reattach')][string]$Phase
    )
    $sbProp = $Phase                       # 'Detach' / 'Reattach'
    $argProp = "${Phase}Args"              # 'DetachArgs' / 'ReattachArgs'
    $batchProp = "${Phase}Batch"           # 'DetachBatch' / 'ReattachBatch'

    # Accumulate batched item tokens by Key (first appearance fixes both group order and the
    # project order within each spawn), and run un-batched items inline in place.
    $order = [System.Collections.Generic.List[string]]::new()
    $groups = @{}
    foreach ($it in $Items) {
        $batch = $it.$batchProp
        if ($batch) {
            $key = $batch.Key
            if (-not $groups.ContainsKey($key)) {
                $order.Add($key)
                $groups[$key] = [pscustomobject]@{ Prefix = @($batch.Prefix); Items = [System.Collections.Generic.List[string]]::new() }
            }
            $groups[$key].Items.Add([string]$batch.Item)
        } else {
            $sb = $it.$sbProp
            if ($sb) { $a = @($it.$argProp); & $sb @a }
        }
    }
    # NOTE: @var is the splat operator (needs a bare variable); @(expr) is array-subexpression and
    # would pass the whole array as one argument. So build the bare arg array, then splat it.
    foreach ($key in $order) {
        $g = $groups[$key]
        $callArgs = @($g.Prefix) + @($g.Items)
        Invoke-Dotnet @callArgs
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
        # Detach every item, then move, then reattach - the ordering invariant (all detaches while
        # old paths resolve; all reattaches after) holds regardless of batching, because batching
        # only coalesces calls *within* a single phase, never across the move.
        Invoke-MovePhase -Items $Items -Phase 'Detach'
        $ma = @($MoveArgs); & $Move @ma
        $moved = $true
        Invoke-MovePhase -Items $Items -Phase 'Reattach'
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
