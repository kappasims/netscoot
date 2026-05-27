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
    $slnRemove = { param($Sln, $Proj) Invoke-Dotnet sln $Sln remove $Proj }
    $slnAdd = { param($Sln, $Proj) Invoke-Dotnet sln $Sln add $Proj }
    $refRemove = { param($Consumer, $Proj) Invoke-Dotnet remove $Consumer reference $Proj }
    $refAdd = { param($Consumer, $Proj) Invoke-Dotnet add $Consumer reference $Proj }
    $ownRemove = { param($Proj, $Target) Invoke-Dotnet remove $Proj reference $Target }
    $ownAdd = { param($Proj, $Target) Invoke-Dotnet add $Proj reference $Target }
    $sfx = if ($Label) { " ($Label)" } else { '' }

    $items = @()
    foreach ($sln in $Solutions) {
        $items += New-MoveItem -Description "solution membership: $($sln.Name)$sfx" `
            -Detach $slnRemove -DetachArgs @($sln.FullName, $OldProj) `
            -Reattach $slnAdd -ReattachArgs @($sln.FullName, $NewProj)
    }
    foreach ($c in $Consumers) {
        $items += New-MoveItem -Description "consumer reference: $(Split-Path -Leaf $c)$sfx" `
            -Detach $refRemove -DetachArgs @($c, $OldProj) `
            -Reattach $refAdd -ReattachArgs @($c, $NewProj)
    }
    foreach ($r in $OwnRefs) {
        $items += New-MoveItem -Description "own reference: $(Split-Path -Leaf $r.FullPath)$sfx" `
            -Detach $ownRemove -DetachArgs @($OldProj, $r.FullPath) `
            -Reattach $ownAdd -ReattachArgs @($NewProj, $r.FullPath)
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
