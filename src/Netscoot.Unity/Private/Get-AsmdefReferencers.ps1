function Get-AsmdefReferencers {
    # asmdef files (under $RepositoryRoot) whose "references" include the given asmdef by name or
    # "GUID:<guid>". References are logical (not paths) so they survive a move - info only.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AsmdefPath,
        [Parameter(Mandatory)][string]$RepositoryRoot
    )
    $full = Resolve-FullPath $AsmdefPath
    $name = $null
    try { $name = (Get-Content -LiteralPath $full -Raw | ConvertFrom-Json).name }
    catch { Write-Warning "Could not parse ${full}, so referencers by name are not reported: $($_.Exception.Message)" }
    $guid = $null
    $meta = "$full.meta"
    if (Test-Path -LiteralPath $meta) {
        $m = (Select-String -LiteralPath $meta -Pattern '^guid:\s*([0-9a-fA-F]+)' | Select-Object -First 1)
        if ($m) { $guid = $m.Matches[0].Groups[1].Value }
    }
    $referencers = @()
    # Exclude Unity caches anchored at the repository root (not "Temp" anywhere - the OS temp dir
    # itself contains that segment), plus .git.
    $rootLen = (Resolve-FullPath $RepositoryRoot).TrimEnd('\', '/').Length
    $asmdefs = Get-TreeItem -Root $RepositoryRoot -File |
        Where-Object {
            $_.Extension -eq '.asmdef' -and
            $_.FullName.Substring($rootLen) -notmatch '^[\\/](Library|Temp|obj)[\\/]' -and
            $_.FullName -notmatch '[\\/]\.git[\\/]'
        }
    foreach ($a in $asmdefs) {
        if (Test-PathEqual $a.FullName $full) { continue }
        try { $asmdef = Get-Content -LiteralPath $a.FullName -Raw | ConvertFrom-Json }
        catch {
            Write-Warning "Could not parse $($a.FullName), so it is not checked as a referencer: $($_.Exception.Message)"
            continue
        }
        if (-not $asmdef.PSObject.Properties['references']) { continue }
        foreach ($r in $asmdef.references) {
            if (($name -and $r -eq $name) -or ($guid -and $r -eq "GUID:$guid")) {
                $referencers += $asmdef.name
                break
            }
        }
    }
    return $referencers
}
