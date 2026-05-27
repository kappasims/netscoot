function Find-MSBuildFiles {
    # Project files + shared .props/.targets beneath a root (anything that can <Import>).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    $exts = @('.csproj', '.fsproj', '.vbproj', '.vcxproj', '.props', '.targets')
    Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in $exts -and $_.FullName -notmatch '[\\/](bin|obj|\.vs|\.git)[\\/]' }
}

function Get-ImportPaths {
    # <Import Project="X"> entries in an MSBuild file. Resolves literal relative paths and the
    # $(MSBuildThisFileDirectory) token (= the file's own dir). Other $(...) tokens are flagged
    # Unresolved (FullPath = $null) so callers can warn rather than guess.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectFile)
    $dir = Split-Path -Parent (Resolve-FullPath $ProjectFile)
    $xml = Read-ProjectXml -Path $ProjectFile
    $out = @()
    foreach ($n in $xml.SelectNodes('//*[local-name()="Import"]')) {
        $proj = $n.GetAttribute('Project')
        if ([string]::IsNullOrWhiteSpace($proj)) { continue }
        $expanded = $proj -replace '\$\(MSBuildThisFileDirectory\)', ($dir + [System.IO.Path]::DirectorySeparatorChar)
        if ($expanded -match '\$\(') {
            $out += [pscustomobject]@{ Raw = $proj; FullPath = $null; Unresolved = $true }
            continue
        }
        $abs = [System.IO.Path]::GetFullPath((Join-Path $dir $expanded))
        $out += [pscustomobject]@{ Raw = $proj; FullPath = $abs; Unresolved = $false }
    }
    return $out
}

function Set-RawImportValue {
    # Precise, formatting-preserving rewrite of a single Import's Project attribute value in a
    # file's raw text (handles both quote styles), preserving the file's UTF-8 BOM state.
    # Not a blind regex: we replace the exact Project="<oldvalue>" token captured from the XML.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string]$OldValue,
        [Parameter(Mandatory)][string]$NewValue
    )
    $full = Resolve-FullPath $File
    $bytes = [System.IO.File]::ReadAllBytes($full)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [System.IO.File]::ReadAllText($full)
    $changed = $false
    foreach ($q in @('"', "'")) {
        $needle = "Project=$q$OldValue$q"
        if ($text.Contains($needle)) {
            $text = $text.Replace($needle, "Project=$q$NewValue$q")
            $changed = $true
        }
    }
    if ($changed) {
        [System.IO.File]::WriteAllText($full, $text, (New-Object System.Text.UTF8Encoding($hasBom)))
    }
    return $changed
}

function Set-RawFileReplacement {
    # Replace an exact literal substring in a file's raw text, preserving UTF-8 BOM state.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string]$Old,
        [Parameter(Mandatory)][string]$New
    )
    $full = Resolve-FullPath $File
    $bytes = [System.IO.File]::ReadAllBytes($full)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [System.IO.File]::ReadAllText($full)
    if (-not $text.Contains($Old)) { return $false }
    $text = $text.Replace($Old, $New)
    [System.IO.File]::WriteAllText($full, $text, (New-Object System.Text.UTF8Encoding($hasBom)))
    return $true
}

function Get-NewImportRaw {
    # Compute the new raw Project value from $ImporterDir to $TargetAbs, preserving a
    # $(MSBuildThisFileDirectory) prefix if the original used one.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ImporterDir,
        [Parameter(Mandatory)][string]$TargetAbs,
        [Parameter(Mandatory)][AllowEmptyString()][string]$OldRaw
    )
    $rel = Get-RelativePathSafe -From $ImporterDir -To $TargetAbs
    if ($OldRaw -match '^\$\(MSBuildThisFileDirectory\)') {
        return '$(MSBuildThisFileDirectory)' + $rel
    }
    return $rel
}
