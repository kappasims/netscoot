# JSONC (JSON-with-comments) tolerant reader. VS Code settings.json - which Test-EditorSolutionGuard
# inspects - is JSONC: it permits // line comments, /* */ block comments, and trailing commas, none
# of which ConvertFrom-Json accepts (on either PowerShell edition; Windows PowerShell 5.1 has no
# tolerant mode at all). Rather than fail to read a perfectly valid settings file, strip the comments
# and trailing commas first, respecting string literals, then hand clean JSON to ConvertFrom-Json.

function ConvertFrom-Jsonc {
    # Parse a JSONC string (JSON + // and /* */ comments + trailing commas) into an object. Comments
    # and a single trailing comma before } or ] are removed by a character scanner that does NOT
    # treat // or /* inside a string literal as a comment, and respects backslash escapes. Returns
    # $null for empty/whitespace input. Throws (like ConvertFrom-Json) if the cleaned text is still
    # not valid JSON.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $sb = [System.Text.StringBuilder]::new($Text.Length)
    $i = 0
    $len = $Text.Length
    $inString = $false

    # Drop trailing whitespace and at most one trailing comma already written to the builder. Called
    # in non-string state just before a } or ] is appended, so a trailing comma is removed safely
    # (a comma inside a string is never seen here because we only call this outside strings).
    $trimTrailingComma = {
        $k = $sb.Length - 1
        while ($k -ge 0 -and [char]::IsWhiteSpace($sb[$k])) { $k-- }
        if ($k -ge 0 -and $sb[$k] -eq ',') {
            $sb.Length = $k          # drop the comma; following whitespace is re-emitted by the char itself
        }
    }

    while ($i -lt $len) {
        $c = $Text[$i]

        if ($inString) {
            [void]$sb.Append($c)
            if ($c -eq '\') {
                # Emit the escaped character verbatim (covers \" so it does not end the string).
                if ($i + 1 -lt $len) { [void]$sb.Append($Text[$i + 1]); $i += 2; continue }
            } elseif ($c -eq '"') {
                $inString = $false
            }
            $i++
            continue
        }

        # Not in a string.
        if ($c -eq '"') {
            $inString = $true
            [void]$sb.Append($c)
            $i++
            continue
        }
        if ($c -eq '/' -and $i + 1 -lt $len) {
            $next = $Text[$i + 1]
            if ($next -eq '/') {
                # Line comment: skip to end of line (the newline itself is preserved).
                $i += 2
                while ($i -lt $len -and $Text[$i] -ne "`n") { $i++ }
                continue
            }
            if ($next -eq '*') {
                # Block comment: skip to the closing */.
                $i += 2
                while ($i + 1 -lt $len -and -not ($Text[$i] -eq '*' -and $Text[$i + 1] -eq '/')) { $i++ }
                $i += 2
                continue
            }
        }
        if ($c -eq '}' -or $c -eq ']') {
            & $trimTrailingComma
        }
        [void]$sb.Append($c)
        $i++
    }

    return ($sb.ToString() | ConvertFrom-Json)
}
