function Undo-DotnetMove {
    <#
    .SYNOPSIS
        Reverse a previous DotnetMove move, using the journal at the repository root.

    .DESCRIPTION
        Each move is recorded in .dotnetmove/journal.jsonl with its inverse: the same mover run with
        source and destination swapped. Undo-DotnetMove replays that inverse, re-reconciling the
        solutions, references, and GUIDs from the CURRENT state (more robust than restoring a stale
        snapshot). By default it undoes the most recent move and pops it from the journal, so calling
        again walks further back (LIFO); -Id targets a specific entry and -List shows the journal.

        The reversing move is not itself journaled, so undo walks the history back rather than
        ping-ponging. Journaling must have been on when the original move ran (it is on by default;
        opt out with $env:DOTNETMOVE_JOURNAL). Undoing an entry that is not the most recent can
        conflict with moves made after it, so prefer undoing in reverse order.

    .PARAMETER RepoRoot
        Repo whose journal to use. Defaults to the enclosing git repo root.

    .PARAMETER Id
        Undo the entry with this journal id instead of the most recent.

    .PARAMETER List
        List the journal (oldest first) and return without undoing anything.

    .OUTPUTS
        Without -List, the move-result object from the reversing move (its type matches the original
        mover). With -List, the journal entries. Nothing when the journal is empty.

    .EXAMPLE
        # See what can be undone
        Undo-DotnetMove -List
        # Preview undoing the most recent move
        Undo-DotnetMove -WhatIf
        # Undo the most recent move
        Undo-DotnetMove
        # Undo a specific entry by id
        Undo-DotnetMove -Id a1b2c3d4
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Delegates to a mover cmdlet that calls ShouldProcess')]
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Undo')]
    param(
        [string]$RepoRoot,
        [Parameter(ParameterSetName = 'Undo')][string]$Id,
        [Parameter(ParameterSetName = 'List')][switch]$List
    )

    if (-not $RepoRoot) { $RepoRoot = Get-RepoRoot -StartPath (Get-Location).Path }
    $repoFull = Resolve-FullPath $RepoRoot
    $entries = @(Get-MoveJournalEntries -RepoRoot $repoFull)

    if ($List) { return $entries }

    if (-not $entries.Count) {
        $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new("No moves to undo: the journal under '$repoFull/.dotnetmove' is empty or missing. Was journaling on (`$env:DOTNETMOVE_JOURNAL)?"),
                'EmptyJournal', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $repoFull))
        return
    }

    $entry = if ($Id) { $entries | Where-Object { $_.id -eq $Id } | Select-Object -Last 1 } else { $entries[-1] }
    if (-not $entry) {
        $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new("No journal entry with id '$Id'. Use -List to see ids."),
                'EntryNotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $Id))
        return
    }
    if ($entry.id -ne $entries[-1].id) {
        Write-Warning "Undoing '$($entry.id)' which is not the most recent move; moves made after it may depend on it."
    }

    # Rebuild the reversing mover call from the recorded splat.
    $cmd = "$($entry.undo.command)"
    $params = @{}
    foreach ($p in $entry.undo.params.PSObject.Properties) { $params[$p.Name] = $p.Value }
    $params['Confirm'] = $false
    if ($WhatIfPreference) { $params['WhatIf'] = $true }

    Write-Host "Undoing $($entry.command): $($entry.destination) -> $($entry.source)  (journal $($entry.id))" -ForegroundColor Cyan

    # Suppress journaling for the reversing move so undo walks the history back (does not re-journal).
    $prev = $env:DOTNETMOVE_JOURNAL
    $env:DOTNETMOVE_JOURNAL = 'off'
    try {
        & $cmd @params
    } finally {
        $env:DOTNETMOVE_JOURNAL = $prev
    }

    if (-not $WhatIfPreference) { Remove-MoveJournalEntry -RepoRoot $repoFull -Id $entry.id }
}
