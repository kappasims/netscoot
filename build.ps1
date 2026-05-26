#requires -Version 5.1
<#
.SYNOPSIS
    Build entry point for DotnetMove: run tests, lint, or install the modules.

.DESCRIPTION
    Tasks:
      Test    (default) - import the three modules (validates load + RequiredModules wiring)
                          and run the Pester suite. Non-zero exit on failure (for CI).
      Analyze           - run PSScriptAnalyzer over src/ if it is available.
      Install           - copy the modules + their Shared sibling into a PowerShell module
                          path so `Import-Module DotnetMove.Core` works by name.
      Docs              - regenerate the "Command reference" section of README.md from the
                          cmdlets' comment-based help.
      Release -Version  - stamp a semver into every module manifest (ModuleVersion), then gate on
                          static analysis (PSScriptAnalyzer, required + clean) and the tests; with
                          -Publish also commit, tag vX.Y.Z, push, and create the GitHub release -
                          keeping the installed ModuleVersion equal to the tag.

.EXAMPLE
    ./build.ps1                       # run the tests
    ./build.ps1 -Task Analyze
    ./build.ps1 -Task Install         # into the per-user module path
    ./build.ps1 -Task Install -InstallPath D:\Modules
    ./build.ps1 -Task Docs            # regenerate the README Command reference section
    ./build.ps1 -Task Release -Version 1.1.0           # stamp manifests, run tests (no publish)
    ./build.ps1 -Task Release -Version 1.1.0 -Publish  # also commit, tag, push, gh release
#>
[CmdletBinding()]
param(
    [ValidateSet('Test', 'Analyze', 'Install', 'Docs', 'Release', 'Publish')]
    [string]$Task = 'Test',
    [string]$InstallPath,
    # Publish: PowerShell Gallery NuGet API key. Without it, Publish only stages + validates the
    # bundled package (dry run) - it does not publish.
    [string]$ApiKey,
    # Release: the semver to stamp into every module manifest (keeps ModuleVersion == the tag).
    [string]$Version,
    # Release: also commit, tag vX.Y.Z, push, and create the GitHub release. Without it, Release
    # only stamps the manifests locally so you can review the bump before publishing.
    [switch]$Publish
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
# Shared first: the engines require it (RequiredModules), so it must import/install before them.
$modules = 'DotnetMove.Shared', 'DotnetMove.Core', 'DotnetMove.Native', 'DotnetMove.Unity'
# The umbrella bootstrap imports the engines above; it ships but is not in the per-engine
# import/test loop (importing it would pull the engines in a second time).
$umbrella = 'DotnetMove'

function script:Test-IsWindowsBuild {
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return $true }
    if (Test-Path Variable:\IsWindows) { return [bool](Get-Variable -Name IsWindows -ValueOnly) }
    return $false
}

function Invoke-TestTask {
    if (-not (Get-Module -ListAvailable Pester | Where-Object Version -ge ([version]'5.0'))) {
        # Do not auto-install (matches the toolkit's "never auto-install" stance); instruct instead.
        throw "Pester 5+ is required to run the tests. Install it: Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -SkipPublisherCheck"
    }
    Import-Module Pester -MinimumVersion 5.0 -Force

    # Importing all three validates loading + the RequiredModules dependency before tests run.
    foreach ($m in $modules) {
        Import-Module ([System.IO.Path]::Combine($root, 'src', $m, "$m.psd1")) -Force
    }
    Write-Host "Imported: $((Get-Command -Module $modules).Count) cmdlets across $($modules.Count) modules." -ForegroundColor Green

    $cfg = New-PesterConfiguration
    $cfg.Run.Path = Join-Path $root 'tests'
    $cfg.Run.Exit = $true          # non-zero exit on failure (CI)
    $cfg.Output.Verbosity = 'Detailed'
    Invoke-Pester -Configuration $cfg
}

function Invoke-AnalyzeTask {
    if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
        Write-Warning 'PSScriptAnalyzer not installed; skipping. (Install-Module PSScriptAnalyzer -Scope CurrentUser)'
        return
    }
    Import-Module PSScriptAnalyzer
    $settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
    # Enumerate the files ourselves and analyze each: Invoke-ScriptAnalyzer's own -Recurse
    # directory walk throws a NullReferenceException on some runner PSSA versions, and per-file
    # also isolates a crashing rule to the offending file instead of failing the whole run.
    $files = Get-ChildItem -Path (Join-Path $root 'src') -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1'
    $results = foreach ($f in $files) { Invoke-ScriptAnalyzer -Path $f.FullName -Settings $settings }
    if ($results) {
        $results | Format-Table -AutoSize | Out-String | Write-Host
        throw "PSScriptAnalyzer reported $(@($results).Count) finding(s)."
    }
    Write-Host 'PSScriptAnalyzer: clean.' -ForegroundColor Green
}

function Invoke-InstallTask {
    if (-not $InstallPath) {
        # Default to the CurrentUser module directory for the edition running this script, so the
        # install lands somewhere already on $env:PSModulePath (PowerShell 7 and Windows
        # PowerShell 5.1 use different folders).
        $InstallPath = if (Test-IsWindowsBuild) {
            $editionDir = if ($PSVersionTable.PSEdition -eq 'Core') { 'PowerShell' } else { 'WindowsPowerShell' }
            Join-Path ([Environment]::GetFolderPath('MyDocuments')) (Join-Path $editionDir 'Modules')
        } else {
            Join-Path $HOME '.local/share/powershell/Modules'
        }
    }
    New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
    foreach ($name in ($modules + $umbrella)) {
        $dest = Join-Path $InstallPath $name
        if (Test-Path $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        Copy-Item -LiteralPath (Join-Path $root (Join-Path 'src' ($name))) -Destination $dest -Recurse -Force
    }
    Write-Host "Installed DotnetMove (all engines + Shared) to: $InstallPath" -ForegroundColor Green

    $sep = [System.IO.Path]::PathSeparator
    $onPath = ($env:PSModulePath -split $sep) | Where-Object { $_.TrimEnd('\', '/') -ieq $InstallPath.TrimEnd('\', '/') }
    if ($onPath) {
        Write-Host 'Ready. Import it by name:' -ForegroundColor Green
        Write-Host '    Import-Module DotnetMove          # all engines'
        Write-Host '    Register-DotnetMvGitAlias -Scope Global   # optional: enable `git dotnetmv`'
    } else {
        Write-Host "That folder is NOT on `$env:PSModulePath. Add it for this session with:" -ForegroundColor Yellow
        Write-Host "    `$env:PSModulePath = '$InstallPath' + '$sep' + `$env:PSModulePath"
        Write-Host '    Import-Module DotnetMove'
    }
}

function Invoke-DocsTask {
    foreach ($m in $modules) {
        Import-Module ([System.IO.Path]::Combine($root, 'src', $m, "$m.psd1")) -Force
    }
    # Document only the public engine modules. DotnetMove.Shared is internal infrastructure (its
    # helpers are not part of the user-facing API), so it is imported above but not listed here.
    $docModules = @($modules | Where-Object { $_ -ne 'DotnetMove.Shared' })

    function Format-HelpText { param($Field) (($Field | ForEach-Object { $_.Text }) -join "`n").Trim() }
    # Escape characters that markdown would otherwise eat in prose: '<...>' renders as an HTML
    # tag, and '$...$' as math. Applied to help prose only, never to code blocks.
    function ConvertTo-MdText {
        param([string]$Text)
        # Wrap $(...) / $var tokens in backticks so no renderer treats them as math (\$ escaping
        # is honored inconsistently), and escape < > so they are not read as HTML tags. Code
        # blocks are emitted separately and never passed through here.
        $Text = [regex]::Replace($Text, '\$\([^)]*\)|\$\w+', { param($mm) '`' + $mm.Value + '`' })
        $Text.Replace('<', '&lt;').Replace('>', '&gt;')
    }

    # Output-type registry (typedefs). Each cmdlet declares the type(s) it emits via
    # [OutputType('DotnetMove.X')]; we look the name up here to render a link + a terse code-view
    # of its structure, and to build the "Output types" section. Single source of truth for shapes.
    $typeDefs = Import-PowerShellDataFile ([System.IO.Path]::Combine($root, 'docs', 'output-types.psd1'))
    $typeAlt = ($typeDefs.Keys | ForEach-Object { [regex]::Escape($_) }) -join '|'

    # Dispatch diagrams (cmdlet name -> ASCII routing map). Rendered as a monospaced block in the
    # Output section for cmdlets that route by extension/type, in place of a prose description.
    $dispatchDiagrams = Import-PowerShellDataFile ([System.IO.Path]::Combine($root, 'docs', 'dispatch-diagrams.psd1'))

    # Fields (Name+Type) present in every one of the given types - the shared shape of a cmdlet
    # that emits several result types, so the reference can say whether they are related or wholly
    # heterogeneous. Returns the common field objects (from the first type), in declared order.
    function Get-CommonFields {
        param([string[]]$Names)
        $defs = @($Names | Where-Object { $typeDefs.ContainsKey($_) } | ForEach-Object { $typeDefs[$_] })
        if ($defs.Count -lt 2) { return @() }
        $rest = @($defs | Select-Object -Skip 1)
        @($defs[0].Fields) | Where-Object {
            $f = $_
            -not ($rest | Where-Object { -not (@($_.Fields) | Where-Object { $_.Name -eq $f.Name -and $_.Type -eq $f.Type }) })
        }
    }

    # GitHub heading anchor for a type entry: lowercase, drop all but [a-z0-9 -], spaces to dashes
    # (so 'DotnetMove.PathReference' -> 'dotnetmovepathreference').
    function Get-TypeAnchor { param([string]$Name) (($Name.ToLower() -replace '[^a-z0-9 -]', '') -replace ' ', '-') }
    function Format-TypeLink { param([string]$Name) "[$Name](#$(Get-TypeAnchor $Name))" }

    # Terse, monospaced rendering of a type's structure: a header line (the type name, with [] when
    # the commands emit an array) then one aligned line per field: name, type, optional note.
    function Format-TypeCodeView {
        param([string]$Name, [hashtable]$Def)
        $fields = @($Def.Fields)
        $nameW = ($fields | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
        $typeW = ($fields | ForEach-Object { $_.Type.Length } | Measure-Object -Maximum).Maximum
        $lines = @($Name + $(if ($Def.Array) { '[]' } else { '' }))
        foreach ($f in $fields) {
            $line = '  ' + $f.Name.PadRight($nameW) + '  ' + $f.Type.PadRight($typeW)
            if ($f.Note) { $line += '  ' + $f.Note }
            $lines += $line.TrimEnd()
        }
        $lines -join "`n"
    }

    # Strip a leading run of registered type names (and | , / separators, and a trailing - or :)
    # from the .OUTPUTS prose, leaving only the extra human note (e.g. 'one per matching line').
    function Get-OutputsNote {
        param([string]$Text)
        $t = ($Text -replace '\s+', ' ').Trim()
        if ($typeAlt) {
            $t = [regex]::Replace($t, "^($typeAlt)(\s*[|,/]\s*($typeAlt))*", '')
            $t = $t -replace '^\s*[-:]\s*', ''
        }
        $t = $t.Trim()
        if ($t) { $t = $t.Substring(0, 1).ToUpper() + $t.Substring(1) }
        $t
    }

    # Render reference-table text one font size down. <small> is the semantic "one step smaller"
    # element and, unlike <sub>, does not shift the baseline; markdown inside it still renders.
    function Format-Small { param([string]$Text) "<small>$Text</small>" }

    # Common parameters Get-Help lists without descriptions; supply our own so the table is complete.
    $commonDesc = @{
        WhatIf  = 'Preview the operation and report what would change, without modifying anything.'
        Confirm = 'Prompt for confirmation before each change.'
    }

    $sb = [System.Text.StringBuilder]::new()
    $emittedBy = @{}   # type name -> @(command names) that declare it via [OutputType]
    $nsLabel = @{ 'DotnetMove.Core' = '.NET and PowerShell'; 'DotnetMove.Unity' = 'Unity'; 'DotnetMove.Native' = 'native C++ (Windows)' }

    # Table of contents, grouped by namespace: each command links to its detail entry, with a
    # one-sentence blurb from the synopsis.
    foreach ($m in $docModules) {
        $label = if ($nsLabel.ContainsKey($m)) { $nsLabel[$m] } else { $m }
        [void]$sb.AppendLine("**$label**")
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('| ' + (Format-Small 'Command') + ' | ' + (Format-Small 'What it does') + ' |')
        [void]$sb.AppendLine('|:---|:---|')
        foreach ($c in (Get-Command -Module $m -CommandType Function | Sort-Object Name)) {
            $h = Get-Help $c.Name -Full | Where-Object { $_.Name -eq $c.Name } | Select-Object -First 1
            $blurb = ("$($h.Synopsis)" -replace '\s+', ' ').Trim()
            if ($blurb -match '^(.*?[.])(\s|$)') { $blurb = $matches[1] }
            $link = Format-Small ('[' + $c.Name + '](#' + $c.Name.ToLower() + ')')
            $blurbCell = Format-Small ((ConvertTo-MdText $blurb).Replace('|', '\|'))
            [void]$sb.AppendLine('| ' + $link + ' | ' + $blurbCell + ' |')
        }
        [void]$sb.AppendLine()
    }

    # Per-command detail (flat; the TOC above provides the namespace grouping).
    foreach ($m in $docModules) {
        foreach ($c in (Get-Command -Module $m -CommandType Function | Sort-Object Name)) {
            # Get-Help treats the name as a pattern, so 'Move-Dotnet' also matches Move-Dotnet*;
            # keep the exact match.
            $h = Get-Help $c.Name -Full | Where-Object { $_.Name -eq $c.Name } | Select-Object -First 1
            [void]$sb.AppendLine("### $($c.Name)")
            [void]$sb.AppendLine()
            $syn = "$($h.Synopsis)".Trim()
            if ($syn) { [void]$sb.AppendLine((ConvertTo-MdText $syn)); [void]$sb.AppendLine() }

            [void]$sb.AppendLine('**Syntax**')
            [void]$sb.AppendLine()
            [void]$sb.AppendLine('```powershell')
            [void]$sb.AppendLine((Get-Command $c.Name -Syntax).Trim())
            [void]$sb.AppendLine('```')
            [void]$sb.AppendLine()

            $desc = Format-HelpText $h.description
            if ($desc) { [void]$sb.AppendLine((ConvertTo-MdText $desc)); [void]$sb.AppendLine() }

            $params = @($h.parameters.parameter | Where-Object { $_.name })
            if ($params.Count) {
                [void]$sb.AppendLine('**Parameters**')
                [void]$sb.AppendLine()
                $hdr = @('Name', 'Type', 'Required', 'Pipeline', 'Description') | ForEach-Object { Format-Small $_ }
                [void]$sb.AppendLine('| ' + ($hdr -join ' | ') + ' |')
                [void]$sb.AppendLine('|:---|:---|:---|:---|:---|')
                foreach ($p in $params) {
                    $pdText = (Format-HelpText $p.description) -replace '\r?\n', ' '
                    if (-not $pdText -and $commonDesc.ContainsKey($p.name)) { $pdText = $commonDesc[$p.name] }
                    $pd = (ConvertTo-MdText $pdText).Replace('|', '\|')
                    # Use a non-breaking hyphen (U+2011) for the leading dash so the renderer cannot
                    # break the line after it (a plain '-Name' wraps at the hyphen); backtick it too.
                    $pname = '`' + [char]0x2011 + $p.name + '`'
                    $cells = @($pname, "$($p.type.name)", "$($p.required)", "$($p.pipelineInput)", $pd) | ForEach-Object { Format-Small $_ }
                    [void]$sb.AppendLine('| ' + ($cells -join ' | ') + ' |')
                }
                [void]$sb.AppendLine()
            }

            # Reconstruct the raw .OUTPUTS prose (Get-Help splits it unpredictably across type.name
            # and description), then take the type(s) from the structured [OutputType] attribute.
            $outRaw = (@($h.returnValues.returnValue | ForEach-Object { ("$($_.type.name) " + (Format-HelpText $_.description)).Trim() }) -join ' ').Trim()
            $outNote = Get-OutputsNote $outRaw
            $typeNames = @((Get-Command $c.Name).OutputType | ForEach-Object { $_.Name } | Where-Object { $_ })
            $registered = @($typeNames | Where-Object { $typeDefs.ContainsKey($_) })
            foreach ($t in $registered) { $emittedBy[$t] = @($emittedBy[$t]) + $c.Name | Where-Object { $_ } }

            if ($registered.Count -or $outRaw) {
                [void]$sb.AppendLine('**Output**')
                [void]$sb.AppendLine()
                if ($dispatchDiagrams.ContainsKey($c.Name)) {
                    # Routes by extension/type: show the mapping as a diagram, not a sentence.
                    [void]$sb.AppendLine('```text')
                    [void]$sb.AppendLine($dispatchDiagrams[$c.Name].TrimEnd())
                    [void]$sb.AppendLine('```')
                } elseif ($registered.Count -eq 1) {
                    $t = $registered[0]; $def = $typeDefs[$t]
                    $lead = if ($def.Array) {
                        "Returns zero or more $(Format-TypeLink $t), collected as an array" + $(if ($def.EmptyIsNull) { ' (`$null` when none)' } else { '' }) + '.'
                    } else {
                        "Returns a single $(Format-TypeLink $t)."
                    }
                    [void]$sb.AppendLine($lead)
                    if ($outNote) { [void]$sb.AppendLine((ConvertTo-MdText $outNote)) }
                    [void]$sb.AppendLine()
                    [void]$sb.AppendLine('```text')
                    [void]$sb.AppendLine((Format-TypeCodeView $t $def))
                    [void]$sb.AppendLine('```')
                } elseif ($registered.Count -gt 1) {
                    [void]$sb.AppendLine((ConvertTo-MdText ($(if ($outNote) { $outNote } else { 'The result object from the command it routes to; the concrete type varies.' }))))
                    [void]$sb.AppendLine()
                    foreach ($t in $registered) { [void]$sb.AppendLine("- $(Format-TypeLink $t)") }
                } else {
                    # No registered typedef (e.g. a plain string, or None) - render the prose as-is.
                    [void]$sb.AppendLine((ConvertTo-MdText $outRaw))
                }
                # When a command emits several types, say whether they are related or heterogeneous.
                if ($registered.Count -gt 1) {
                    $common = @(Get-CommonFields $registered)
                    [void]$sb.AppendLine()
                    if ($common.Count) {
                        $shared = ($common | ForEach-Object { $_.Name }) -join ', '
                        [void]$sb.AppendLine("These share a common shape ($shared) and each adds its own fields; they are plain pscustomobjects with no shared base type. See [Type reference](#type-reference).")
                    } else {
                        [void]$sb.AppendLine('These result types are heterogeneous - they share no common fields. See [Type reference](#type-reference).')
                    }
                }
                [void]$sb.AppendLine()
            }

            $examples = @($h.examples.example | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace("$($_.code)") })
            if ($examples.Count) {
                [void]$sb.AppendLine('**Examples**')
                [void]$sb.AppendLine()
                foreach ($e in $examples) {
                    [void]$sb.AppendLine('```powershell')
                    [void]$sb.AppendLine(("$($e.code)").Trim())
                    [void]$sb.AppendLine('```')
                    $rem = Format-HelpText $e.remarks
                    if ($rem) { [void]$sb.AppendLine(); [void]$sb.AppendLine((ConvertTo-MdText $rem)) }
                    [void]$sb.AppendLine()
                }
            }
        }
    }

    # Type reference: its own top-level section (a sibling of the command reference), one entry per
    # typedef with the same code-view the commands link to. Back-references (which commands emit it,
    # which types nest it) sit as a callout right under each type name. A type that is only nested
    # in another (never emitted directly) is still listed so its link resolves.
    $nestedIn = @{}
    foreach ($name in $typeDefs.Keys) {
        foreach ($f in @($typeDefs[$name].Fields)) {
            $ft = $f.Type -replace '[\[\]?]', ''
            if ($typeDefs.ContainsKey($ft)) { $nestedIn[$ft] = @($nestedIn[$ft]) + $name | Where-Object { $_ } }
        }
    }
    [void]$sb.AppendLine('## Type reference')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('The shapes the commands return. Each is a single `pscustomobject`; a trailing `[]` on the type line means a command emits zero or more of them (a collection, `$null` when empty) - the object itself is not an array. In a field, `type[]` is an array-valued field, `type?` may be `$null`, and a `DotnetMove.*` field is itself one of these types.')
    [void]$sb.AppendLine()
    $sortedTypes = @($typeDefs.Keys | Sort-Object)
    [void]$sb.AppendLine('| ' + (Format-Small 'Type') + ' | ' + (Format-Small 'Represents') + ' |')
    [void]$sb.AppendLine('|:---|:---|')
    foreach ($name in $sortedTypes) {
        $sm = (ConvertTo-MdText ("$($typeDefs[$name].Summary)")).Replace('|', '\|')
        [void]$sb.AppendLine('| ' + (Format-Small (Format-TypeLink $name)) + ' | ' + (Format-Small $sm) + ' |')
    }
    [void]$sb.AppendLine()
    foreach ($name in $sortedTypes) {
        $def = $typeDefs[$name]
        [void]$sb.AppendLine("### $name")
        [void]$sb.AppendLine()
        $refs = @()
        if ($emittedBy[$name]) { $refs += 'emitted by ' + ((@($emittedBy[$name]) | Sort-Object -Unique | ForEach-Object { "[$_](#$($_.ToLower()))" }) -join ', ') }
        if ($nestedIn[$name]) { $refs += 'nested in ' + ((@($nestedIn[$name]) | Sort-Object -Unique | ForEach-Object { Format-TypeLink $_ }) -join ', ') }
        if ($refs.Count) { [void]$sb.AppendLine('(' + ($refs -join '; ') + ')'); [void]$sb.AppendLine() }
        if ($def.Summary) { [void]$sb.AppendLine((ConvertTo-MdText $def.Summary)); [void]$sb.AppendLine() }
        [void]$sb.AppendLine('```text')
        [void]$sb.AppendLine((Format-TypeCodeView $name $def))
        [void]$sb.AppendLine('```')
        [void]$sb.AppendLine()
    }

    # Inject into the marked section of README.md (replacing it in place, or appending the
    # section if the markers are not present yet).
    $begin = '<!-- BEGIN GENERATED REFERENCE -->'
    $end = '<!-- END GENERATED REFERENCE -->'
    $note = "<!-- Regenerate with ./build.ps1 -Task Docs. Generated from the cmdlets' comment-based help in src/; do not hand-edit between these markers. -->"
    $section = "$begin`n$note`n`n" + $sb.ToString().TrimEnd() + "`n`n$end"

    $readmePath = [System.IO.Path]::Combine($root, 'README.md')
    $readme = [System.IO.File]::ReadAllText($readmePath)
    $pattern = [regex]::Escape($begin) + '[\s\S]*?' + [regex]::Escape($end)
    if ([regex]::IsMatch($readme, $pattern)) {
        # MatchEvaluator so $ tokens in the generated text are not treated as replacements.
        $readme = [regex]::Replace($readme, $pattern, { param($mm) $section })
    } else {
        $readme = $readme.TrimEnd() + "`n`n## Reference`n`n" + $section + "`n"
    }
    [System.IO.File]::WriteAllText($readmePath, $readme, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Wrote the Command reference section of README.md ($((Get-Command -Module $docModules -CommandType Function).Count) cmdlets)." -ForegroundColor Green
}

function Invoke-ReleaseTask {
    # The single source of truth for a release: stamp $Version into every manifest so the
    # installed module's ModuleVersion always equals the git tag, then (with -Publish) tag and
    # release it. GitHub releases / tags are the "available version"; ModuleVersion is the
    # "installed version"; this task is what keeps the two in lockstep.
    if (-not $Version) { throw "Release needs -Version, e.g. ./build.ps1 -Task Release -Version 1.1.0" }
    if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Version must be semver (x.y.z): '$Version'" }

    $manifests = foreach ($m in ($modules + $umbrella)) { Join-Path $root (Join-Path 'src' (Join-Path $m "$m.psd1")) }
    foreach ($mf in $manifests) {
        $text = [System.IO.File]::ReadAllText($mf)
        $new = [regex]::Replace($text, "(?m)^(\s*ModuleVersion\s*=\s*')[^']*(')", "`${1}$Version`$2")
        if ($new -cne $text) {
            [System.IO.File]::WriteAllText($mf, $new)
            Write-Host "Stamped $Version into $(Split-Path -Leaf $mf)" -ForegroundColor Green
        } else {
            Write-Warning "No ModuleVersion change in $(Split-Path -Leaf $mf) (already $Version?)"
        }
    }

    # Static analysis is a hard release gate: it must be installed AND clean (unlike the everyday
    # Analyze task, a release will not silently skip when PSScriptAnalyzer is absent).
    Write-Host 'Static analysis (release prerequisite)...' -ForegroundColor Cyan
    if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
        throw 'Release requires PSScriptAnalyzer. Install it: Install-Module PSScriptAnalyzer -Scope CurrentUser'
    }
    Invoke-AnalyzeTask   # throws on any finding

    Write-Host 'Running the test suite before release...' -ForegroundColor Cyan
    Invoke-TestTask

    if (-not $Publish) {
        Write-Host "Manifests stamped to $Version. Review, then re-run with -Publish to tag + release." -ForegroundColor Yellow
        return
    }

    $tag = "v$Version"
    & git -C $root add (($modules + $umbrella) | ForEach-Object { "src/$_/$_.psd1" })
    & git -C $root commit -m "release: $tag"
    if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }
    & git -C $root tag -a $tag -m "DotnetMove $Version"
    if ($LASTEXITCODE -ne 0) { throw "git tag $tag failed" }
    & git -C $root push
    & git -C $root push origin $tag
    & gh release create $tag --title "DotnetMove $Version" --generate-notes
    Write-Host "Released $tag." -ForegroundColor Green
}

function Invoke-PublishTask {
    # Assemble the SINGLE bundled DotnetMove package and publish it to the PowerShell Gallery. The
    # shipped package is one module folder: the umbrella at the root, with Shared + each engine as
    # subfolders the umbrella's RootModule loads (-Global; native only on Windows, best-effort). No
    # separate Shared/Core/Unity/Native packages. Without -ApiKey this only stages + validates.
    $stage = Join-Path ([System.IO.Path]::GetTempPath()) ("dotnetmove_pkg_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $pkg = Join-Path $stage 'DotnetMove'
    New-Item -ItemType Directory -Path $pkg -Force | Out-Null

    # Umbrella files (manifest + RootModule) at the package root...
    Copy-Item -Path (Join-Path $root (Join-Path 'src' (Join-Path 'DotnetMove' '*'))) -Destination $pkg -Recurse -Force
    # ...then Shared + the engines as subfolders the umbrella loads.
    foreach ($name in 'DotnetMove.Shared', 'DotnetMove.Core', 'DotnetMove.Unity', 'DotnetMove.Native') {
        Copy-Item -Path (Join-Path $root (Join-Path 'src' $name)) -Destination (Join-Path $pkg $name) -Recurse -Force
    }

    $manifest = Join-Path $pkg 'DotnetMove.psd1'
    Write-Host "Validating bundled manifest: $manifest" -ForegroundColor Cyan
    $null = Test-ModuleManifest -Path $manifest

    # Smoke-import in a clean child pwsh to prove the single package self-loads with no separate
    # modules on the path (this is what catches missing-bundle / load-order bugs).
    Write-Host 'Smoke-importing the bundled package in a clean session...' -ForegroundColor Cyan
    & pwsh -NoProfile -Command "Import-Module '$manifest' -Force; if (-not (Get-Command Move-Dotnet -ErrorAction SilentlyContinue)) { throw 'Move-Dotnet was not surfaced by the bundled package.' }; 'bundled import OK'"
    if ($LASTEXITCODE -ne 0) { throw 'The bundled package failed to import in a clean session.' }

    Write-Host "Staged single package at: $pkg" -ForegroundColor Green
    if (-not $ApiKey) {
        Write-Host 'No -ApiKey given: staged + validated only (dry run). Re-run with -ApiKey to publish.' -ForegroundColor Yellow
        return
    }
    Publish-Module -Path $pkg -NuGetApiKey $ApiKey -Repository PSGallery
    Write-Host 'Published DotnetMove to the PowerShell Gallery.' -ForegroundColor Green
}

switch ($Task) {
    'Test' { Invoke-TestTask }
    'Analyze' { Invoke-AnalyzeTask }
    'Install' { Invoke-InstallTask }
    'Docs' { Invoke-DocsTask }
    'Release' { Invoke-ReleaseTask }
    'Publish' { Invoke-PublishTask }
}
