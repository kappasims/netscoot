function Find-PowerShellFiles {
    # .ps1/.psm1 beneath a root.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.ps1', '.psm1' -and $_.FullName -notmatch '[\\/]\.git[\\/]' }
}

function Get-PowerShellScriptReferences {
    # Dot-source (`. path`) and call (`& path`) invocations of a .ps1 in a script, via the
    # PowerShell AST (reliable across editions). Resolves literal paths and the $PSScriptRoot
    # token (= the script's own dir); other variables/expressions are flagged Unresolved.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$File)
    $full = Resolve-FullPath $File
    $dir = Split-Path -Parent $full
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$tokens, [ref]$errs)
    $out = @()
    $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($c in $cmds) {
        $op = $c.InvocationOperator.ToString()
        if ($op -ne 'Dot' -and $op -ne 'Ampersand') { continue }
        if ($c.CommandElements.Count -lt 1) { continue }
        $first = $c.CommandElements[0]
        $raw = $null
        if ($first -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $raw = $first.Value }
        elseif ($first -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { $raw = $first.Value }
        else { continue }
        if ([string]::IsNullOrWhiteSpace($raw) -or $raw -notmatch '\.ps1$') { continue }
        $expanded = $raw -replace '\$PSScriptRoot', $dir
        if ($expanded -match '\$') { $out += [pscustomobject]@{ Raw = $raw; Abs = $null; Unresolved = $true }; continue }
        # Normalize Windows-style '\' separators to the platform's so a repository authored on Windows
        # still resolves on Unix (where '\' is a literal path character, not a separator).
        $expanded = $expanded.Replace('\', [System.IO.Path]::DirectorySeparatorChar)
        $abs = if ([System.IO.Path]::IsPathRooted($expanded)) { [System.IO.Path]::GetFullPath($expanded) }
               else { [System.IO.Path]::GetFullPath((Join-Path $dir $expanded)) }
        $out += [pscustomobject]@{ Raw = $raw; Abs = $abs; Unresolved = $false }
    }
    return $out
}

function Get-NewScriptRaw {
    # New raw reference text from $RefDir to $TargetAbs, preserving the original style:
    # $PSScriptRoot-prefixed, or a leading .\ for current-dir-relative dot-sourcing.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RefDir,
        [Parameter(Mandatory)][string]$TargetAbs,
        [Parameter(Mandatory)][AllowEmptyString()][string]$OldRaw
    )
    $rel = Get-RelativePathSafe -From $RefDir -To $TargetAbs   # platform separator
    $sep = [System.IO.Path]::DirectorySeparatorChar
    if ($OldRaw -match '^\$PSScriptRoot') { return '$PSScriptRoot' + $sep + $rel }
    if ($rel -notmatch '^\.\.?[\\/]') { return '.' + $sep + $rel }   # ensure dot-source finds a local path
    return $rel
}
