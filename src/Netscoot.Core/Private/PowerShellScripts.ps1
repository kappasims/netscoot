function Find-PowerShellFiles {
    # .ps1/.psm1 beneath a root.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.ps1', '.psm1' -and $_.FullName -notmatch '[\\/]\.git[\\/]' }
}

function Get-PowerShellScriptReferences {
    # The file paths a script names, via the PowerShell AST: dot-source (`. path`) and call
    # (`& path`) of a .ps1, `Import-Module <path>` and `using module <path>`. Literal and
    # $PSScriptRoot-based paths resolve to Paths (Netscoot.StoredPath). A path built from other
    # variables, and any other string that looks like a path (a Join-Path argument, a
    # Publish-Module -Path value), is returned in Dynamic by its raw text so a mover can report it.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$File)
    $full = Resolve-FullPath $File
    $dir = Split-Path -Parent $full
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$null, [ref]$null)
    $stringTypes = [System.Management.Automation.Language.StringConstantExpressionAst], [System.Management.Automation.Language.ExpandableStringExpressionAst]
    $importSwitches = 'Force', 'Global', 'PassThru', 'AsCustomObject', 'NoClobber', 'DisableNameChecking', 'SkipEditionCheck', 'UseWindowsPowerShell'

    # Each candidate is the string node holding a path, and whether it must name a .ps1.
    $candidates = @()
    foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $op = $c.InvocationOperator.ToString()
        if ($op -eq 'Dot' -or $op -eq 'Ampersand') {
            $first = $c.CommandElements[0]
            if ($first.GetType() -in $stringTypes) { $candidates += [pscustomobject]@{ Node = $first; ScriptOnly = $true } }
            continue
        }
        if ($c.GetCommandName() -notin 'Import-Module', 'ipmo') { continue }
        $elements = @($c.CommandElements | Select-Object -Skip 1)
        for ($i = 0; $i -lt $elements.Count; $i++) {
            $e = $elements[$i]
            if ($e -is [System.Management.Automation.Language.CommandParameterAst]) {
                if ($e.ParameterName -eq 'Name') {
                    $value = if ($e.Argument) { $e.Argument } elseif ($i + 1 -lt $elements.Count) { $elements[$i + 1] } else { $null }
                    if ($value -and $value.GetType() -in $stringTypes) { $candidates += [pscustomobject]@{ Node = $value; ScriptOnly = $false } }
                    break
                }
                if (-not $e.Argument -and $e.ParameterName -notin $importSwitches) { $i++ }
                continue
            }
            if ($e.GetType() -in $stringTypes) { $candidates += [pscustomobject]@{ Node = $e; ScriptOnly = $false } }
            break
        }
    }
    foreach ($u in $ast.UsingStatements) {
        if ($u.UsingStatementKind -eq 'Module' -and $u.Name) { $candidates += [pscustomobject]@{ Node = $u.Name; ScriptOnly = $false } }
    }

    $paths = @()
    $dynamic = @()
    $claimed = [System.Collections.Generic.HashSet[object]]::new()
    foreach ($cand in $candidates) {
        $raw = $cand.Node.Value
        [void]$claimed.Add($cand.Node)
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        if ($cand.ScriptOnly -and $raw -notmatch '\.ps1$') { continue }
        # A bare module name (no separator, no module file extension) is resolved by PSModulePath, not a path.
        if (-not $cand.ScriptOnly -and $raw -notmatch '[\\/]' -and $raw -notmatch '\.(psd1|psm1|dll)$') { continue }
        $expanded = $raw -replace '\$PSScriptRoot', $dir
        if ($expanded -match '\$') { $dynamic += [pscustomobject]@{ File = $full; Raw = $raw }; continue }
        # Windows-style '\' separators still resolve on Unix, where '\' is otherwise a literal character.
        $expanded = $expanded.Replace('\', [System.IO.Path]::DirectorySeparatorChar)
        $abs = if ([System.IO.Path]::IsPathRooted($expanded)) { [System.IO.Path]::GetFullPath($expanded) }
               else { [System.IO.Path]::GetFullPath((Join-Path $dir $expanded)) }
        $paths += [Netscoot.StoredPath]::InScript($full, $raw, $abs.TrimEnd('\', '/'))
    }
    foreach ($s in $ast.FindAll({ param($n) $n.GetType() -in $stringTypes }, $true)) {
        if (-not $claimed.Contains($s) -and $s.Value -match '[\\/]|\.ps(1|m1|d1)$') { $dynamic += [pscustomobject]@{ File = $full; Raw = $s.Value } }
    }
    return [pscustomobject]@{ Paths = $paths; Dynamic = $dynamic }
}
