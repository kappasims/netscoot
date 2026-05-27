function Undo-Netscoot {
    <#
    .SYNOPSIS
        Reverse previous netscoot moves from the per-user journal.

    .DESCRIPTION
        Each move is recorded in the journal (a per-user data directory: LocalAppData on Windows,
        ~/Library/Application Support on macOS, ~/.local/share on Linux; one file per repository) with
        its inverse: The same mover run with source and destination swapped. Undo-Netscoot replays
        that inverse, re-reconciling from the CURRENT state (more robust than restoring a stale
        snapshot). The reversing move is not itself journaled, so undo walks the history back rather
        than ping-ponging.

        Choose what to reverse (mutually exclusive):
          -Last   (default) the most recent move; call again to walk further back.
          -Id     one specific move, by its journal id (see -List). The safest, most surgical option.
          -After  every move recorded after a given time, newest first.
          -All    every recorded move, newest first.
        -List shows the journal without changing anything.

        Reversing a single move with -Id is the precise choice when the journal is saving you: It
        touches only that one move. But -Id can target a move that is NOT the most recent, and each
        reversal re-reconciles from the CURRENT state, so reversing an older move while later moves
        still reference its old location can leave dangling references. When -Id reverses anything but
        the latest entry, a read-only consistency sweep runs afterward and any references it finds
        broken are reported, with the command to repair them.

        -All and -After reverse several moves, so they are high-impact: They prompt for a yes/no
        confirmation that -Confirm:$false does not silence. Pass -Force to bypass it (for automation),
        or -WhatIf to list the reversals without making changes.

        Journaling must have been on when the moves ran (on by default; opt out with
        $env:NETSCOOT_JOURNAL or git config netscoot.journal false).

    .PARAMETER RepositoryRoot
        Repository whose journal to use, and the boundary every reversal is confined to. Defaults to
        the enclosing git repository root of the current directory.

    .PARAMETER Last
        Reverse only the most recent move (the default).

    .PARAMETER Id
        Reverse one specific move, identified by its journal id (the 8-character id shown by -List).
        Surgical: It reverses only that move. If the move is not the most recent, a read-only
        consistency sweep runs afterward and reports any references the out-of-order reversal broke.

    .PARAMETER After
        Reverse every move recorded strictly after this time, newest first. The time need not match
        any recorded entry.

    .PARAMETER All
        Reverse every recorded move, newest first.

    .PARAMETER Force
        With -All or -After, bypass the confirmation prompt.

    .PARAMETER List
        List the journal (oldest first) and return without undoing anything.

    .OUTPUTS
        The move-result object(s) from the reversing move(s); their type matches the original mover.
        With -List, the journal entries. Nothing when there is nothing to undo.

    .EXAMPLE
        # See what can be undone
        Undo-Netscoot -List
        # Reverse the most recent move (default); call again to walk back
        Undo-Netscoot
        # Reverse one specific move by its journal id (from -List)
        Undo-Netscoot -Id a1b2c3d4
        # Preview reversing the most recent move
        Undo-Netscoot -WhatIf
        # Reverse everything recorded in the last hour (prompts)
        Undo-Netscoot -After (Get-Date).AddHours(-1)
        # Reverse every recorded move (prompts; -Force to skip the prompt)
        Undo-Netscoot -All
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Delegates to a mover cmdlet that calls ShouldProcess')]
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Last')]
    param(
        [string]$RepositoryRoot,
        [Parameter(ParameterSetName = 'Last')][switch]$Last,
        [Parameter(ParameterSetName = 'Id', Mandatory)][string]$Id,
        [Parameter(ParameterSetName = 'After', Mandatory)][datetime]$After,
        [Parameter(ParameterSetName = 'All', Mandatory)][switch]$All,
        [Parameter(ParameterSetName = 'After')][Parameter(ParameterSetName = 'All')][switch]$Force,
        [Parameter(ParameterSetName = 'List', Mandatory)][switch]$List
    )

    if (-not $RepositoryRoot) { $RepositoryRoot = Get-RepositoryRoot -StartPath (Get-Location).Path }
    $repoFull = Resolve-FullPath $RepositoryRoot
    $entries = @(Get-MoveJournalEntries -RepositoryRoot $repoFull)

    if ($List) { return $entries }

    if (-not $entries.Count) {
        # Distinguish "journaling is off" (nothing is being recorded) from "enabled but empty yet".
        if (-not (Test-MoveJournalEnabled -RepositoryRoot $repoFull)) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new("Journaling is off for '$repoFull' (`$env:NETSCOOT_JOURNAL / git config netscoot.journal), so no moves are being recorded to undo."),
                    'JournalingDisabled', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $repoFull))
        } else {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new("No moves recorded yet for '$repoFull'; nothing to undo."),
                    'EmptyJournal', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $repoFull))
        }
        return
    }

    # -Last (default): just the most recent move.
    if ($PSCmdlet.ParameterSetName -eq 'Last') {
        Invoke-MoveJournalUndo -Entry $entries[-1] -RepositoryRoot $repoFull -Preview:$WhatIfPreference
        return
    }

    # -Id: one specific move. Surgical, but it can target an entry that is not the most recent; in
    # that case later moves may still reference its old location, so we warn before and run a
    # read-only consistency sweep after, reporting anything the out-of-order reversal broke.
    if ($PSCmdlet.ParameterSetName -eq 'Id') {
        $idx = -1
        for ($i = 0; $i -lt $entries.Count; $i++) { if ("$($entries[$i].id)" -eq $Id) { $idx = $i; break } }
        if ($idx -lt 0) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new("No journaled move with id '$Id' for '$repoFull'. Run Undo-Netscoot -List to see the recorded ids."),
                    'NoSuchEntry', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $Id))
            return
        }
        $isLatest = ($idx -eq $entries.Count - 1)
        if (-not $isLatest -and -not $WhatIfPreference) {
            $later = $entries.Count - 1 - $idx
            Write-Warning "Reversing journal entry '$Id' out of order: $later later move(s) were recorded after it and may reference its current location. Reconciliation runs from the current state; a consistency sweep follows."
        }
        Invoke-MoveJournalUndo -Entry $entries[$idx] -RepositoryRoot $repoFull -Preview:$WhatIfPreference
        if (-not $isLatest -and -not $WhatIfPreference) { Test-PostUndoConsistency -RepositoryRoot $repoFull }
        return
    }

    # Bulk modes (-All / -After): build the target set newest-first so each reversal re-reconciles
    # after the moves that followed it are already undone.
    $ordered = @(); for ($i = $entries.Count - 1; $i -ge 0; $i--) { $ordered += $entries[$i] }
    if ($All) {
        $targets = $ordered
        $what = "ALL $($targets.Count) journaled move(s)"
    } else {
        $afterUtc = $After.ToUniversalTime()
        $targets = @($ordered | Where-Object {
                # ConvertFrom-Json may hand the timestamp back as a string OR an already-parsed
                # [datetime]; normalize either to a UTC instant (stored values are UTC).
                $t = $_.timestamp; $ts = $null
                if ($t -is [datetime]) { $ts = if ($t.Kind -eq 'Local') { $t.ToUniversalTime() } else { [datetime]::SpecifyKind($t, [System.DateTimeKind]::Utc) } }
                elseif ($t -is [datetimeoffset]) { $ts = $t.UtcDateTime }
                elseif ($t) { try { $ts = ([datetimeoffset]::Parse([string]$t)).UtcDateTime } catch { $ts = $null } }
                $ts -and $ts -gt $afterUtc
            })
        if (-not $targets.Count) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new("No moves recorded after $After for '$repoFull'."),
                    'NoMovesAfter', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $After))
            return
        }
        $what = "$($targets.Count) move(s) recorded after $After"
    }

    # -WhatIf lists the reversals without running them: each later reversal assumes the earlier ones
    # already happened, so a real dry run would reference a path the previous step has not vacated.
    if ($WhatIfPreference) {
        foreach ($e in $targets) {
            Write-Host "What if: Undo $($e.command): $($e.destination) -> $($e.source)  (journal $($e.id))" -ForegroundColor DarkGray
        }
        return
    }
    # High-impact: a hard yes/no gate that -Confirm:$false does not silence; -Force bypasses it.
    if (-not $Force) {
        $q = "Reverse $what for '$repoFull', newest first? This walks back multiple moves in one operation."
        if (-not $PSCmdlet.ShouldContinue($q, 'Undo multiple moves')) { return }
    }
    foreach ($e in $targets) { Invoke-MoveJournalUndo -Entry $e -RepositoryRoot $repoFull }
}

function Invoke-MoveJournalUndo {
    # Replay one journal entry's inverse move, then pop it (unless previewing). Suppresses journaling
    # for the reversing move via the highest-precedence flag, so undo walks the history back (never
    # re-journals) even when git config enables journaling for the repository.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [switch]$Preview
    )
    $cmd = "$($Entry.undo.command)"
    # Defense-in-depth: the journal is a data file in a per-user dir, so never replay an arbitrary
    # command name from it. Only the recognized movers may run; a corrupt/tampered entry is refused.
    $allowed = @(
        'Move-DotnetProject', 'Move-DotnetProjectTree', 'Move-DotnetFile', 'Move-DotnetFolder',
        'Move-MSBuildImport', 'Move-Solution', 'Move-PowerShell', 'Move-PowerShellScript',
        'Move-PowerShellModule', 'Move-NativeProject', 'Move-UnityAsset', 'Invoke-Netscoot'
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
    # and the prefix check rejects anything resolving outside this repository, capping the blast radius.
    $rootFull = [System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([char]'\', [char]'/')
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

    if (-not $Preview) { Remove-MoveJournalEntry -RepositoryRoot $RepositoryRoot -Id $Entry.id }
}

function Test-PostUndoConsistency {
    # Best-effort read-only sweep after an out-of-order reversal, to surface references the reversal
    # may have left dangling. Reconciliation by engine differs; today this covers the .NET case
    # (solution membership and ProjectReferences) via Repair-SolutionReferences in its read-only mode.
    # Findings are aggregated into a single warning with the one-line repair command; a clean sweep
    # is noted quietly. Never throws - a missing tool or probe failure must not mask the undo itself.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    if (-not (Get-Command Repair-SolutionReferences -ErrorAction SilentlyContinue)) { return }
    try {
        # Read-only (no -Fix/-Prune): returns one object per dangling entry. Suppress its progress
        # (info stream 6) and any "dotnet unavailable" error (stream 2) - this is a courtesy check.
        $problems = @(Repair-SolutionReferences -RepositoryRoot $RepositoryRoot -ErrorAction SilentlyContinue 6>$null 2>$null)
    } catch {
        Write-Verbose "Post-undo consistency probe failed: $_"
        return
    }
    if ($problems.Count) {
        $byKind = ($problems | Group-Object Resolution | Sort-Object Name | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
        Write-Warning "Post-undo consistency: $($problems.Count) reference(s) are now dangling ($byKind). Repair with: Repair-SolutionReferences -RepositoryRoot '$RepositoryRoot' -Fix"
    } else {
        Write-Host 'Post-undo consistency: no dangling references detected.' -ForegroundColor DarkGray
    }
}
