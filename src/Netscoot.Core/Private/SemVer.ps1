function Compare-NetscootSemVer {
    <#
    Compare two SemVer 2.0 version strings (optionally `v`-prefixed, with an optional prerelease tag).
    Returns -1 when Reference < Difference, 0 when equal, 1 when Reference > Difference.

    Core (major.minor.patch) compares numerically first. On equal cores, a version WITHOUT a
    prerelease outranks one WITH (stable > prerelease). When both have a prerelease, the dot-separated
    identifiers compare left-to-right: all-digit identifiers numerically; an all-digit identifier ranks
    below an alphanumeric one; alphanumerics compare ordinally; if every shared identifier is equal,
    the longer identifier list wins. (Build metadata is not modeled - netscoot tags never carry it.)
    #>
    param(
        [Parameter(Mandatory)][string]$Reference,
        [Parameter(Mandatory)][string]$Difference
    )

    $parse = {
        param($s)
        if ("$s" -notmatch '^v?(\d+)\.(\d+)\.(\d+)(?:-(.+))?$') {
            throw "Not a parseable version: '$s'"
        }
        [pscustomobject]@{
            Core = [int[]]@([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
            Pre  = if ($Matches[4]) { @($Matches[4].Split('.')) } else { @() }
        }
    }

    $a = & $parse $Reference
    $b = & $parse $Difference

    for ($i = 0; $i -lt 3; $i++) {
        if ($a.Core[$i] -lt $b.Core[$i]) { return -1 }
        if ($a.Core[$i] -gt $b.Core[$i]) { return 1 }
    }

    # Equal cores. A stable (no prerelease) outranks a prerelease.
    $aHasPre = (@($a.Pre).Count -gt 0)
    $bHasPre = (@($b.Pre).Count -gt 0)
    if (-not $aHasPre -and -not $bHasPre) { return 0 }
    if (-not $aHasPre) { return 1 }
    if (-not $bHasPre) { return -1 }

    # Both prerelease: compare identifiers left-to-right per SemVer 2.0 precedence. Re-wrap with @()
    # so a single-identifier prerelease stays an array (a scalar string would index per-character).
    $aPre = @($a.Pre)
    $bPre = @($b.Pre)
    $n = [Math]::Min($aPre.Count, $bPre.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $ai = $aPre[$i]; $bi = $bPre[$i]
        $aNum = ($ai -match '^\d+$')
        $bNum = ($bi -match '^\d+$')
        if ($aNum -and $bNum) {
            $av = [int]$ai; $bv = [int]$bi
            if ($av -lt $bv) { return -1 }
            if ($av -gt $bv) { return 1 }
        } elseif ($aNum -ne $bNum) {
            # Numeric identifiers always have lower precedence than alphanumeric ones.
            return $(if ($aNum) { -1 } else { 1 })
        } else {
            $cmp = [string]::CompareOrdinal($ai, $bi)
            if ($cmp -lt 0) { return -1 }
            if ($cmp -gt 0) { return 1 }
        }
    }

    # All shared identifiers equal: the longer list wins.
    if ($aPre.Count -lt $bPre.Count) { return -1 }
    if ($aPre.Count -gt $bPre.Count) { return 1 }
    return 0
}
