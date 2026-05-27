function Repair-NetscootJournal {
    <#
    .SYNOPSIS
        Report and recover moves the journal recorded as started but never finished (interrupted by a
        crash), and clear orphaned recovery snapshots.

    .DESCRIPTION
        Each move is written ahead: a `pending` record before it runs, a `committed`/`rolledback`
        record after. A move with a `pending` record and no outcome was interrupted (the process died
        mid-move), so the working tree may be partway between the old and new layout.

        Read-only by default: It lists the interrupted moves and changes nothing. Then choose an action
        (both confine every path to the repository, and prompt unless -Force):
          -Rollback  return the move to its pre-move state - restore the edited files from the
                     recovery snapshot, move the destination back to the source, and drop the entry.
          -Discard   accept the working tree as-is and just forget the interrupted entry (no file
                     changes), removing its snapshot.
        -Id limits the action to one entry (by its journal id). -ClearOrphanSnapshots deletes leftover
        `netscoot_snap_*` recovery directories in the temp folder that no pending entry references.

    .PARAMETER RepositoryRoot
        Repository whose journal to inspect, and the boundary every recovery is confined to. Defaults
        to the enclosing git repository root of the current directory.

    .PARAMETER Rollback
        Roll each interrupted move back to its pre-move state (high-impact: prompts unless -Force).

    .PARAMETER Discard
        Forget each interrupted move without touching the working tree (removes its snapshot).

    .PARAMETER Id
        Act on only the interrupted move with this journal id.

    .PARAMETER Force
        Skip the confirmation prompt (for automation).

    .PARAMETER ClearOrphanSnapshots
        Delete temp recovery snapshots (`netscoot_snap_*`) that no pending entry references.

    .OUTPUTS
        Netscoot.JournalEntry - the interrupted entries (report mode), or those acted on.

    .EXAMPLE
        # See what was interrupted (read-only)
        Repair-NetscootJournal
        # Roll everything interrupted back to its pre-move state
        Repair-NetscootJournal -Rollback
        # Forget one interrupted move, keeping the working tree as-is
        Repair-NetscootJournal -Discard -Id a1b2c3d4
        # Clean up leftover recovery snapshots
        Repair-NetscootJournal -ClearOrphanSnapshots
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Report')]
    [OutputType('Netscoot.JournalEntry')]
    param(
        [string]$RepositoryRoot,
        [Parameter(ParameterSetName = 'Rollback', Mandatory)][switch]$Rollback,
        [Parameter(ParameterSetName = 'Discard', Mandatory)][switch]$Discard,
        [Parameter(ParameterSetName = 'Rollback')][Parameter(ParameterSetName = 'Discard')][string]$Id,
        [Parameter(ParameterSetName = 'Rollback')][Parameter(ParameterSetName = 'Discard')][switch]$Force,
        [switch]$ClearOrphanSnapshots
    )

    if (-not $RepositoryRoot) { $RepositoryRoot = Get-RepositoryRoot -StartPath (Get-Location).Path }
    $repoFull = Resolve-FullPath $RepositoryRoot
    $rootPrefix = $repoFull.TrimEnd([char]'\', [char]'/') + [System.IO.Path]::DirectorySeparatorChar
    $interrupted = @(Get-InterruptedMove -RepositoryRoot $repoFull)

    # Confine a journal-supplied path to the repository (the journal is a data file; a tampered entry
    # must not drive a recovery to touch files outside the repo).
    $inRepo = {
        param([string]$p)
        if ([string]::IsNullOrWhiteSpace($p)) { return $false }
        $full = [System.IO.Path]::GetFullPath($p)
        $full -eq $repoFull.TrimEnd([char]'\', [char]'/') -or $full.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    }

    if ($ClearOrphanSnapshots) {
        $referenced = @($interrupted | ForEach-Object { "$($_.snapshot)" } | Where-Object { $_ })
        $tmp = [System.IO.Path]::GetTempPath()
        $orphans = @(Get-ChildItem -LiteralPath $tmp -Directory -Filter 'netscoot_snap_*' -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notin $referenced })
        foreach ($o in $orphans) {
            if ($Force -or $PSCmdlet.ShouldProcess($o.FullName, 'delete orphan recovery snapshot')) {
                Remove-Item -LiteralPath $o.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        Write-Host "Cleared $($orphans.Count) orphan snapshot(s)." -ForegroundColor DarkGray
    }

    # Report mode: list and return, change nothing.
    if ($PSCmdlet.ParameterSetName -eq 'Report') {
        if ($interrupted.Count) {
            Write-Warning "$($interrupted.Count) interrupted move(s) for '$repoFull'. Recover with: Repair-NetscootJournal -Rollback   (or -Discard to keep the current state)."
        } else {
            Write-Host 'No interrupted moves.' -ForegroundColor Green
        }
        return $interrupted
    }

    # Wrap the whole if-expression in @(): a single-element result flowing out of an if-block unwraps
    # to a scalar, and Windows PowerShell 5.1 (StrictMode) then has no .Count on it.
    $targets = @(if ($Id) { $interrupted | Where-Object { "$($_.id)" -eq $Id } } else { $interrupted })
    if (-not $targets.Count) {
        $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new("No interrupted move$(if ($Id) { " with id '$Id'" }) for '$repoFull'."),
                'NoInterruptedMove', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $repoFull))
        return
    }

    foreach ($e in $targets) {
        $src = "$($e.source)"; $dst = "$($e.destination)"
        if ($Rollback) {
            if (-not ($Force -or $PSCmdlet.ShouldProcess($repoFull, "roll back interrupted $($e.command): $dst -> $src"))) { continue }

            # 1. Restore the edited files from the snapshot (snapshot/f<i> -> backup[i]).
            $snapDir = "$($e.snapshot)"
            if ($snapDir -and (Test-Path -LiteralPath $snapDir)) {
                $backup = @($e.backup)
                for ($i = 0; $i -lt $backup.Count; $i++) {
                    $f = Join-Path $snapDir ("f{0}" -f $i)
                    if ((Test-Path -LiteralPath $f) -and (& $inRepo $backup[$i])) {
                        Copy-Item -LiteralPath $f -Destination $backup[$i] -Force
                    }
                }
            }
            # 2. Reverse the move when it clearly happened: destination present, source gone.
            if ((& $inRepo $src) -and (& $inRepo $dst) -and (Test-Path -LiteralPath $dst) -and -not (Test-Path -LiteralPath $src)) {
                Move-PathTracked -UseGit (Test-GitAvailable) -Source $dst -Destination $src -RepositoryRoot $repoFull
            } elseif (Test-Path -LiteralPath $dst) {
                Write-Warning "Could not auto-reverse the move ($dst -> $src): the source already exists or the path is outside the repository. Files were restored from the snapshot; verify by hand."
            }
            # 3. Clean up: drop the snapshot and the journal entry.
            if ($snapDir -and (Test-Path -LiteralPath $snapDir)) { Remove-Item -LiteralPath $snapDir -Recurse -Force -ErrorAction SilentlyContinue }
            Remove-MoveJournalEntry -RepositoryRoot $repoFull -Id $e.id
            Write-Host "Rolled back $($e.command) (journal $($e.id))." -ForegroundColor Cyan
        } else {
            # -Discard
            if (-not ($Force -or $PSCmdlet.ShouldProcess($repoFull, "discard interrupted $($e.command) (keep the working tree as-is)"))) { continue }
            $snapDir = "$($e.snapshot)"
            if ($snapDir -and (Test-Path -LiteralPath $snapDir)) { Remove-Item -LiteralPath $snapDir -Recurse -Force -ErrorAction SilentlyContinue }
            Remove-MoveJournalEntry -RepositoryRoot $repoFull -Id $e.id
            Write-Host "Discarded interrupted $($e.command) (journal $($e.id))." -ForegroundColor DarkGray
        }
        $e
    }
}
