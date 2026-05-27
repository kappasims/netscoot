function Clear-NetscootJournal {
    <#
    .SYNOPSIS
        Delete a repository's move journal, discarding its undo history.

    .DESCRIPTION
        Removes this repository's journal file from the per-user store (LocalAppData on Windows,
        ~/Library/Application Support on macOS, ~/.local/share on Linux). The journal prunes itself on every write (entries older than the age
        cap, then oldest-first past the size cap), so this is rarely needed; use it to wipe the undo
        history outright. After clearing, Undo-Netscoot has nothing to reverse until the next move.
        It does not change whether journaling is on - use Set-NetscootJournal for that.

    .PARAMETER RepositoryRoot
        Repository whose journal to delete. Defaults to the enclosing git repository root.

    .OUTPUTS
        None.

    .EXAMPLE
        # Discard the undo history for this repository
        Clear-NetscootJournal
        # Preview without deleting
        Clear-NetscootJournal -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param([string]$RepositoryRoot)

    if (-not $RepositoryRoot) { $RepositoryRoot = Get-RepositoryRoot -StartPath (Get-Location).Path }
    $repoFull = Resolve-FullPath $RepositoryRoot
    $path = Get-MoveJournalPath -RepositoryRoot $repoFull

    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "No journal to clear for '$repoFull'." -ForegroundColor DarkGray
        return
    }
    if (-not $PSCmdlet.ShouldProcess($path, 'Delete move journal')) { return }
    Remove-Item -LiteralPath $path -Force
    Write-Host "Cleared the move journal for '$repoFull'." -ForegroundColor DarkGray
}
