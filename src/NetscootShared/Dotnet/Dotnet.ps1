function New-DotnetReferenceItems {
    # Build the standard reconciliation items for a managed project move: solution membership,
    # external consumers, and the project's own references - each a detach+reattach pair so the
    # plan engine can confirm/skip per line. The dotnet ref-op scriptblocks live here, once.
    [CmdletBinding()]
    param(
        [object[]]$Solutions = @(),   # objects with .FullName + .Name
        [string[]]$Consumers = @(),   # consumer project paths
        [object[]]$OwnRefs = @(),     # objects with .FullPath
        [Parameter(Mandatory)][string]$OldProj,
        [Parameter(Mandatory)][string]$NewProj,
        [string]$Label = ''
    )
    # Per-edge scriptblocks (the un-batched fallback path: Invoke-MovePlan runs these one at a
    # time when an item carries no batch metadata).
    $slnRemove = { param($Sln, $Proj) Invoke-Dotnet sln $Sln remove $Proj }
    # Folder-aware re-add: $FolderArgs is @('--in-root') for a root project, or @('--solution-folder',
    # '<path>') to restore its original virtual folder. Without this the slnx `add` default re-folds the
    # project to mirror its NEW physical path, littering deep moves with empty folders and losing the
    # original grouping (see Get-ProjectSolutionFolder).
    $slnAdd = { param($Sln, $Proj, $FolderArgs) $a = @('sln', $Sln, 'add') + @($FolderArgs) + @($Proj); Invoke-Dotnet @a }
    $refRemove = { param($Consumer, $Proj) Invoke-Dotnet remove $Consumer reference $Proj }
    $refAdd = { param($Consumer, $Proj) Invoke-Dotnet add $Consumer reference $Proj }
    $ownRemove = { param($Proj, $Target) Invoke-Dotnet remove $Proj reference $Target }
    $ownAdd = { param($Proj, $Target) Invoke-Dotnet add $Proj reference $Target }
    $sfx = if ($Label) { " ($Label)" } else { '' }

    # Batch metadata lets Invoke-MovePlan collapse every edge that shares one dotnet target file
    # into a single spawn (the dotnet CLI takes multiple projects per invocation). Each phase entry
    # is { Key; Prefix; Item }: Key groups co-spawned edges, Prefix is the fixed leading args, and
    # Item is the one variable project token appended (one per edge) to the shared command line.
    # Key embeds the verb so a remove and an add to the same file never merge.
    $items = @()
    foreach ($sln in $Solutions) {
        # Capture the folder the OLD project sits in (it is still listed at build time, before detach)
        # so the re-add restores it. A root project re-adds with --in-root; batching keeps projects that
        # share a solution AND a target folder in one spawn (the folder is part of the batch Key).
        $folder = Get-ProjectSolutionFolder -SolutionFile $sln.FullName -ProjectAbs $OldProj
        if ([string]::IsNullOrEmpty($folder)) { $folderArgs = @('--in-root'); $folderTag = 'root' }
        else { $folderArgs = @('--solution-folder', $folder); $folderTag = $folder }
        $items += New-MoveItem -Description "solution membership: $($sln.Name)$sfx" `
            -Detach $slnRemove -DetachArgs @($sln.FullName, $OldProj) `
            -Reattach $slnAdd -ReattachArgs @($sln.FullName, $NewProj, $folderArgs) `
            -DetachBatch @{ Key = "sln|remove|$($sln.FullName)"; Prefix = @('sln', $sln.FullName, 'remove'); Item = $OldProj } `
            -ReattachBatch @{ Key = "sln|add|$($sln.FullName)|$folderTag"; Prefix = @('sln', $sln.FullName, 'add') + $folderArgs; Item = $NewProj }
    }
    foreach ($c in $Consumers) {
        $items += New-MoveItem -Description "consumer reference: $(Split-Path -Leaf $c)$sfx" `
            -Detach $refRemove -DetachArgs @($c, $OldProj) `
            -Reattach $refAdd -ReattachArgs @($c, $NewProj) `
            -DetachBatch @{ Key = "ref|remove|$c"; Prefix = @('remove', $c, 'reference'); Item = $OldProj } `
            -ReattachBatch @{ Key = "ref|add|$c"; Prefix = @('add', $c, 'reference'); Item = $NewProj }
    }
    foreach ($r in $OwnRefs) {
        $items += New-MoveItem -Description "own reference: $(Split-Path -Leaf $r.FullPath)$sfx" `
            -Detach $ownRemove -DetachArgs @($OldProj, $r.FullPath) `
            -Reattach $ownAdd -ReattachArgs @($NewProj, $r.FullPath) `
            -DetachBatch @{ Key = "own|remove|$OldProj"; Prefix = @('remove', $OldProj, 'reference'); Item = $r.FullPath } `
            -ReattachBatch @{ Key = "own|add|$NewProj"; Prefix = @('add', $NewProj, 'reference'); Item = $r.FullPath }
    }
    return $items
}

function Invoke-DotnetRead {
    # Read-only dotnet call: returns stdout lines, swallows stderr, never throws on it.
    # Windows PowerShell 5.1 turns native stderr into a terminating error when
    # $ErrorActionPreference is Stop; force Continue around the call so it does not.
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Arguments)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return (& dotnet @Arguments 2>$null) }
    finally { $ErrorActionPreference = $prev }
}

function Invoke-Dotnet {
    # Mutating dotnet call: runs, then throws on non-zero exit. Same 5.1 stderr guard.
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Arguments)
    Write-Verbose "dotnet $($Arguments -join ' ')"
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & dotnet @Arguments 2>&1 | Write-Verbose }
    finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}
