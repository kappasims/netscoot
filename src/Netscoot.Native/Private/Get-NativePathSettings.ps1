function Get-NativePathSettings {
    # Path-bearing MSBuild settings in a .vcxproj that a folder move can invalidate and
    # the dotnet CLI cannot reconcile. Returns Netscoot.NativeSetting objects { Kind, Value }
    # (surfaced on a NativeMoveResult's UnreconciledSettings) for reporting.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectFile)
    $xml = Read-ProjectXml -Path $ProjectFile
    $found = @()
    $nodeKinds = 'AdditionalIncludeDirectories', 'AdditionalLibraryDirectories',
                 'AdditionalDependencies', 'OutDir', 'IntDir', 'PrecompiledHeaderFile'
    foreach ($kind in $nodeKinds) {
        foreach ($n in $xml.SelectNodes("//*[local-name()='$kind']")) {
            $v = $n.InnerText
            if ($v -and ($v -match '\.\.[\\/]' -or $v -match '\$\(SolutionDir\)')) {
                $found += [Netscoot.NativeSetting]@{ Kind = $kind; Value = $v.Trim() }
            }
        }
    }
    foreach ($imp in $xml.SelectNodes("//*[local-name()='Import']")) {
        $p = $imp.GetAttribute('Project')
        if ($p -and ($p -match '\.\.[\\/]' -or $p -match '\$\(SolutionDir\)')) {
            $found += [Netscoot.NativeSetting]@{ Kind = 'Import'; Value = $p.Trim() }
        }
    }
    # Dedupe identical Kind+Value pairs repeated across build configurations.
    $seen = @{}
    $unique = @()
    foreach ($f in $found) {
        $key = "$($f.Kind)|$($f.Value)"
        if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $unique += $f }
    }
    return $unique
}
