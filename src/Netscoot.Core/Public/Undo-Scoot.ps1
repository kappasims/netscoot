function Undo-Scoot {
    <#
    .SYNOPSIS
        Reverse a previous netscoot move, using the journal at the repository root.

    .DESCRIPTION
        Each move is recorded in the journal (a per-user data directory: LocalAppData on Windows,
        ~/Library/Application Support on macOS, ~/.local/share on Linux; one file per repository) with
        its inverse: the same mover run with source and destination
        swapped. Undo-Scoot replays that inverse, re-reconciling the solutions, references, and
        GUIDs from the CURRENT state (more robust than restoring a stale snapshot). By default it
        undoes the most recent move and pops it from the journal, so calling again walks further back
        (LIFO); -Id targets a specific entry and -List shows the journal.

        The reversing move is not itself journaled, so undo walks the history back rather than
        ping-ponging. Journaling must have been on when the original move ran (it is on by default;
        opt out per repository with git config netscoot.journal false, or with
        $env:NETSCOOT_JOURNAL). Undoing an entry that is not the most recent can conflict with
        moves made after it, so prefer undoing in reverse order.

        -All reverses every journaled move (newest first) in one operation. Because that walks back
        the entire history at once it is high-impact: it prompts for a yes/no confirmation that is not
        silenced by -Confirm:$false; pass -Force to bypass the prompt (for automation) or -WhatIf to
        preview each reversal without making changes.

    .PARAMETER RepoRoot
        Repository whose journal to use. Defaults to the enclosing git repository root.

    .PARAMETER Id
        Undo the entry with this journal id instead of the most recent.

    .PARAMETER All
        Reverse every journaled move, newest first. High-impact: prompts for confirmation (use -Force
        to bypass, -WhatIf to preview).

    .PARAMETER Force
        With -All, bypass the confirmation prompt. Ignored without -All.

    .PARAMETER List
        List the journal (oldest first) and return without undoing anything.

    .OUTPUTS
        Without -List, the move-result object from the reversing move (its type matches the original
        mover). With -List, the journal entries. Nothing when the journal is empty.

    .EXAMPLE
        # See what can be undone
        Undo-Scoot -List
        # Preview undoing the most recent move
        Undo-Scoot -WhatIf
        # Undo the most recent move
        Undo-Scoot
        # Undo a specific entry by id
        Undo-Scoot -Id a1b2c3d4
        # Reverse every journaled move (prompts; -Force to skip the prompt)
        Undo-Scoot -All
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Delegates to a mover cmdlet that calls ShouldProcess')]
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Undo')]
    param(
        [string]$RepoRoot,
        [Parameter(ParameterSetName = 'Undo')][string]$Id,
        [Parameter(ParameterSetName = 'All', Mandatory)][switch]$All,
        [Parameter(ParameterSetName = 'All')][switch]$Force,
        [Parameter(ParameterSetName = 'List')][switch]$List
    )

    if (-not $RepoRoot) { $RepoRoot = Get-RepoRoot -StartPath (Get-Location).Path }
    $repoFull = Resolve-FullPath $RepoRoot
    $entries = @(Get-MoveJournalEntries -RepoRoot $repoFull)

    if ($List) { return $entries }

    if (-not $entries.Count) {
        $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new("No moves to undo: the journal for '$repoFull' is empty or missing. Was journaling on (git config netscoot.journal / `$env:NETSCOOT_JOURNAL)?"),
                'EmptyJournal', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $repoFull))
        return
    }

    if ($All) {
        # -WhatIf lists the reversals that would run, newest first, without invoking the movers. We
        # cannot preview them for real: each reversal assumes the moves that followed it are already
        # undone, so a dry run of a later step would reference a path the earlier step has not vacated.
        if ($WhatIfPreference) {
            for ($i = $entries.Count - 1; $i -ge 0; $i--) {
                $e = $entries[$i]
                Write-Host "What if: Undo $($e.command): $($e.destination) -> $($e.source)  (journal $($e.id))" -ForegroundColor DarkGray
            }
            return
        }
        # Reversing every move at once is high-impact, so gate it with ShouldContinue - the canonical
        # hard yes/no prompt that is NOT silenced by -Confirm:$false. -Force bypasses it for automation.
        if (-not $Force) {
            $q = "Reverse ALL $($entries.Count) journaled move(s) for '$repoFull', newest first? This walks back the entire move history in one operation."
            if (-not $PSCmdlet.ShouldContinue($q, 'Undo all moves')) { return }
        }
        # Newest first so each reversal re-reconciles after the moves that followed it are already undone.
        for ($i = $entries.Count - 1; $i -ge 0; $i--) {
            Invoke-MoveJournalUndo -Entry $entries[$i] -RepoRoot $repoFull
        }
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

    Invoke-MoveJournalUndo -Entry $entry -RepoRoot $repoFull -Preview:$WhatIfPreference
}

function Invoke-MoveJournalUndo {
    # Replay one journal entry's inverse move, then pop it (unless previewing). Suppresses journaling
    # for the reversing move via the highest-precedence flag, so undo walks the history back (never
    # re-journals) even when git config enables journaling for the repository.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$Preview
    )
    $cmd = "$($Entry.undo.command)"
    # Defense-in-depth: the journal is a data file in a per-user dir, so never replay an arbitrary
    # command name from it. Only the recognized movers may run; a corrupt/tampered entry is refused.
    $allowed = @(
        'Move-DotnetProject', 'Move-DotnetProjectTree', 'Move-DotnetFile', 'Move-DotnetFolder',
        'Move-MSBuildImport', 'Move-Solution', 'Move-PowerShell', 'Move-PowerShellScript',
        'Move-PowerShellModule', 'Move-NativeProject', 'Move-UnityAsset', 'Invoke-Scoot'
    )
    if ($cmd -notin $allowed) {
        throw "Refusing to replay journal entry '$($Entry.id)': '$cmd' is not a recognized Netscoot mover (the journal may be corrupt or tampered with)."
    }
    $params = @{}
    foreach ($p in $Entry.undo.params.PSObject.Properties) { $params[$p.Name] = $p.Value }
    $params['Confirm'] = $false
    if ($Preview) { $params['WhatIf'] = $true }

    # Confine every path parameter to the repository the journal belongs to. The allowlist above
    # guards the command, but the params are still attacker-controlled in a tampered journal: an
    # absolute Source/Destination (or a '..' traversal) could otherwise drive a real mover to
    # relocate or -Force-overwrite files anywhere the user can write. GetFullPath collapses '..',
    # and the prefix check rejects anything resolving outside this repo, capping the blast radius.
    $rootFull = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd([char]'\', [char]'/')
    $rootPrefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
    foreach ($k in 'Project', 'Path', 'ModulePath', 'AssetPath', 'Destination') {
        if (-not $params.ContainsKey($k)) { continue }
        $raw = [string]$params[$k]
        $combined = if ([System.IO.Path]::IsPathRooted($raw)) { $raw } else { Join-Path $rootFull $raw }
        $resolved = [System.IO.Path]::GetFullPath($combined)
        if ($resolved -ne $rootFull -and -not $resolved.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to replay journal entry '$($Entry.id)': path '$raw' resolves outside the repository '$rootFull' (the journal may be tampered with)."
        }
    }

    Write-Host "Undoing $($Entry.command): $($Entry.destination) -> $($Entry.source)  (journal $($Entry.id))" -ForegroundColor Cyan

    $prev = $env:NETSCOOT_JOURNAL_SUPPRESS
    $env:NETSCOOT_JOURNAL_SUPPRESS = '1'
    try {
        & $cmd @params
    } finally {
        $env:NETSCOOT_JOURNAL_SUPPRESS = $prev
    }

    if (-not $Preview) { Remove-MoveJournalEntry -RepoRoot $RepoRoot -Id $Entry.id }
}
