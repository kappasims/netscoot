function Get-AsmdefReferencers {
    # asmdef files (under $RepoRoot) whose "references" include the given asmdef by name or
    # "GUID:<guid>". References are logical (not paths) so they survive a move - info only.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AsmdefPath,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $full = Resolve-FullPath $AsmdefPath
    $name = $null
    try { $name = (Get-Content -LiteralPath $full -Raw | ConvertFrom-Json).name } catch { Write-Verbose "could not parse asmdef name from ${full}: $_" }
    $guid = $null
    $meta = "$full.meta"
    if (Test-Path -LiteralPath $meta) {
        $m = (Select-String -LiteralPath $meta -Pattern '^guid:\s*([0-9a-fA-F]+)' | Select-Object -First 1)
        if ($m) { $guid = $m.Matches[0].Groups[1].Value }
    }
    $referencers = @()
    # Exclude Unity caches anchored at the repository root (not "Temp" anywhere - the OS temp dir
    # itself contains that segment), plus .git.
    $rootLen = (Resolve-FullPath $RepoRoot).TrimEnd('\', '/').Length
    $asmdefs = Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Extension -eq '.asmdef' -and
            $_.FullName.Substring($rootLen) -notmatch '^[\\/](Library|Temp|obj)[\\/]' -and
            $_.FullName -notmatch '[\\/]\.git[\\/]'
        }
    foreach ($a in $asmdefs) {
        if (Test-PathEqual $a.FullName $full) { continue }
        $refs = $null
        try { $refs = (Get-Content -LiteralPath $a.FullName -Raw | ConvertFrom-Json).references } catch { continue }
        if (-not $refs) { continue }
        foreach ($r in $refs) {
            if (($name -and $r -eq $name) -or ($guid -and $r -eq "GUID:$guid")) {
                $referencers += (Get-Content -LiteralPath $a.FullName -Raw | ConvertFrom-Json).name
                break
            }
        }
    }
    return $referencers
}
