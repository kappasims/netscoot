#requires -Version 5.1
<#
.SYNOPSIS
    Build entry point for netscoot: run tests, lint, or install the modules.

.DESCRIPTION
    Tasks:
      Test    (default) - import the modules and run the Pester suite (validates they load).
                          Non-zero exit on failure (for CI).
      Analyze           - run PSScriptAnalyzer over src/ if it is available.
      Install           - copy all modules (Shared, the engines, and the netscoot umbrella) into
                          a PowerShell module path so `Import-Module Netscoot` works by name.
      Docs              - regenerate the "Command reference" section of README.md from the
                          cmdlets' comment-based help.
      CheckDocs         - gate the docs: fail if the README reference is stale (someone edited
                          cmdlet help without regenerating) or if README/skills carry an old-brand
                          token or name a cmdlet that no longer exists. Part of the Release gate.
      Release -Version  - run from develop. Without -Publish (prepare): stamp the semver into every
                          manifest, gate on static analysis (required + clean) and the tests, then
                          commit `release: vX.Y.Z` and push develop so CI runs on it. With -Publish
                          (finalize, after CI is green on all platforms): fast-forward master to that
                          commit, tag, push, and create the GitHub release. master is protected, so it
                          only ever receives a CI-passed commit; ModuleVersion stays equal to the tag.
      Publish           - assemble the single bundled netscoot package, validate and smoke-import
                          it, then Publish-Module to the PowerShell Gallery (dry run without -ApiKey).

.EXAMPLE
    ./build.ps1                       # run the tests
    ./build.ps1 -Task Analyze
    ./build.ps1 -Task Install         # into the per-user module path
    ./build.ps1 -Task Install -InstallPath D:\Modules
    ./build.ps1 -Task Docs            # regenerate the README Command reference section
    ./build.ps1 -Task Release -Version 1.2.0           # prepare on develop: stamp, gate, commit + push
    ./build.ps1 -Task Release -Version 1.2.0 -Publish  # finalize (after CI green): fast-forward master, tag, release
#>
[CmdletBinding()]
param(
    [ValidateSet('Test', 'Analyze', 'Install', 'Docs', 'CheckDocs', 'Release', 'Publish')]
    [string]$Task = 'Test',
    [string]$InstallPath,
    # Publish: PowerShell Gallery NuGet API key. Without it, Publish only stages + validates the
    # bundled package (dry run) - it does not publish.
    [string]$ApiKey,
    # Release: the semver to stamp into every module manifest (keeps ModuleVersion == the tag).
    [string]$Version,
    # Release: also commit, tag vX.Y.Z, push, and create the GitHub release. Without it, Release
    # only stamps the manifests locally so you can review the bump before publishing.
    [switch]$Publish,
    # Test: split the test files into -ShardCount slices and run only the -ShardIndex'th (1-based).
    # Used by CI to run the suite as parallel jobs (separate processes - the tests share process-
    # global state, so they cannot be parallelized in-process). The default runs the whole suite.
    [int]$ShardIndex = 0,
    [int]$ShardCount = 1
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
# Shared first: the engines call its helpers, so it must import/install before them.
$modules = 'Netscoot.Shared', 'Netscoot.Core', 'Netscoot.Native', 'Netscoot.Unity'
# The umbrella bootstrap imports the engines above; it ships but is not in the per-engine
# import/test loop (importing it would pull the engines in a second time).
$umbrella = 'Netscoot'

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

    # Import Shared first, then the engines (mirrors how the umbrella loads them) before tests run.
    foreach ($m in $modules) {
        Import-Module ([System.IO.Path]::Combine($root, 'src', $m, "$m.psd1")) -Force
    }
    Write-Host "Imported: $((Get-Command -Module $modules).Count) cmdlets across $($modules.Count) modules." -ForegroundColor Green

    $cfg = New-PesterConfiguration
    $cfg.Run.Exit = $true          # non-zero exit on failure (CI)
    $cfg.Output.Verbosity = 'Detailed'

    if ($ShardCount -gt 1) {
        # Round-robin the sorted test files into ShardCount slices and run this one. Each shard runs
        # in its own CI job (process), so there is no shared-state contention between shards.
        $idx = if ($ShardIndex -lt 1) { 1 } else { $ShardIndex }
        $all = @(Get-ChildItem -Path (Join-Path $root 'tests') -Recurse -File -Filter '*.Tests.ps1' | Sort-Object FullName)
        $mine = @(for ($i = 0; $i -lt $all.Count; $i++) { if (($i % $ShardCount) -eq ($idx - 1)) { $all[$i] } })
        if (-not $mine.Count) {
            Write-Host "Shard ${idx}/${ShardCount} has no test files; nothing to run." -ForegroundColor Yellow
            return
        }
        Write-Host "Shard ${idx}/${ShardCount}: running $($mine.Count) of $($all.Count) test files." -ForegroundColor Cyan
        $cfg.Run.Path = $mine.FullName
    } else {
        $cfg.Run.Path = Join-Path $root 'tests'
    }
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
    Write-Host "Installed netscoot (all engines + Shared) to: $InstallPath" -ForegroundColor Green

    $sep = [System.IO.Path]::PathSeparator
    $onPath = ($env:PSModulePath -split $sep) | Where-Object { $_.TrimEnd('\', '/') -ieq $InstallPath.TrimEnd('\', '/') }
    if ($onPath) {
        Write-Host 'Ready. Import it by name:' -ForegroundColor Green
        Write-Host '    Import-Module Netscoot          # all engines'
        Write-Host '    Register-NetscootGitAlias -Scope Global   # optional: enable `git netscoot`'
    } else {
        Write-Host "That folder is NOT on `$env:PSModulePath. Add it for this session with:" -ForegroundColor Yellow
        Write-Host "    `$env:PSModulePath = '$InstallPath' + '$sep' + `$env:PSModulePath"
        Write-Host '    Import-Module Netscoot'
    }
}

function Invoke-DocsTask {
    foreach ($m in $modules) {
        Import-Module ([System.IO.Path]::Combine($root, 'src', $m, "$m.psd1")) -Force
    }
    # Document only the public engine modules. Netscoot.Shared is internal infrastructure (its
    # helpers are not part of the user-facing API), so it is imported above but not listed here.
    $docModules = @($modules | Where-Object { $_ -ne 'Netscoot.Shared' })

    function Format-HelpText { param($Field) (($Field | ForEach-Object { $_.Text }) -join "`n").Trim() }

    # Space out a commented-one-liner example: a blank line before each comment that follows a code
    # line, so the block reads as comment / code / gap / comment / code rather than a dense wall.
    # (Source .EXAMPLE blocks can't carry the blanks themselves - Get-Help would split the example
    # into code + remarks at the first blank line.)
    function Format-ExampleCode {
        param([string]$Code)
        $out = [System.Collections.Generic.List[string]]::new()
        foreach ($line in (($Code -replace "`r", '') -split "`n")) {
            $prev = if ($out.Count) { $out[$out.Count - 1] } else { '' }
            if ($line -match '^\s*#' -and $prev.Trim() -and $prev -notmatch '^\s*#') { $out.Add('') }
            $out.Add($line)
        }
        ($out -join "`n").Trim()
    }
    # Escape characters that markdown would otherwise eat in prose: '<...>' renders as an HTML
    # tag, and '$...$' as math. Applied to help prose only, never to fenced code blocks.
    function ConvertTo-MdText {
        param([string]$Text)
        # Transform prose only; leave existing `backtick code spans` verbatim. Inside a span, < >
        # already render literally and tokens must not be re-backticked (nesting backticks would
        # break the span and the entities would show raw).
        $prose = {
            param([string]$s)
            # Wrap $(...) / $var tokens in backticks so no renderer treats them as math (\$ escaping
            # is honored inconsistently).
            $s = [regex]::Replace($s, '\$\([^)]*\)|\$\w+', { param($mm) '`' + $mm.Value + '`' })
            # Backtick bare parameter references (-Name). Uppercase-first skips hyphenated words
            # (non-terminating, cross-boundary); the lookbehind skips cmdlet names (Move-Item).
            $s = [regex]::Replace($s, '(?<![\w`-])(-[A-Z][A-Za-z]+)\b', '`$1`')
            # Escape < > so they are not read as HTML tags.
            $s.Replace('<', '&lt;').Replace('>', '&gt;')
        }
        $sb = [System.Text.StringBuilder]::new()
        $pos = 0
        foreach ($m in [regex]::Matches($Text, '`[^`]*`')) {
            if ($m.Index -gt $pos) { [void]$sb.Append((& $prose $Text.Substring($pos, $m.Index - $pos))) }
            [void]$sb.Append($m.Value)   # code span, verbatim
            $pos = $m.Index + $m.Length
        }
        if ($pos -lt $Text.Length) { [void]$sb.Append((& $prose $Text.Substring($pos))) }
        $sb.ToString()
    }

    # Output-type registry (typedefs). Each cmdlet declares the type(s) it emits via
    # [OutputType('Netscoot.X')]; we look the name up here to render a link + a terse code-view
    # of its structure, and to build the "Output types" section. Single source of truth for shapes.
    $typeDefs = Import-PowerShellDataFile ([System.IO.Path]::Combine($root, 'docs', 'output-types.psd1'))
    $typeAlt = ($typeDefs.Keys | ForEach-Object { [regex]::Escape($_) }) -join '|'

    # Dispatch diagrams (cmdlet name -> ASCII routing map). Rendered as a monospaced block in the
    # Output section for cmdlets that route by extension/type, in place of a prose description.
    $dispatchDiagrams = Import-PowerShellDataFile ([System.IO.Path]::Combine($root, 'docs', 'dispatch-diagrams.psd1'))

    # Functional taxonomy for the Command-reference index (Move / Inspect / Manage, with sub-tables).
    # Single source of truth; the coverage check in Assert-DocsNotStale fails on any command that is
    # missing from, or duplicated across, this map (so a new cmdlet must be categorized to ship).
    $commandCategories = Import-PowerShellDataFile ([System.IO.Path]::Combine($root, 'docs', 'command-categories.psd1'))

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
    # (so 'Netscoot.PathReference' -> 'netscootpathreference').
    function Get-TypeAnchor { param([string]$Name) (($Name.ToLower() -replace '[^a-z0-9 -]', '') -replace ' ', '-') }
    function Format-TypeLink { param([string]$Name) "[$Name](#$(Get-TypeAnchor $Name))" }

    # Terse, monospaced rendering of a type's structure: a header line (the type name) then one
    # aligned line per field: name, type, optional note. The header is always the singular object;
    # whether a command returns one or many is a per-command fact, stated in that command's Output.
    function Format-TypeCodeView {
        param([string]$Name, [hashtable]$Def)
        $fields = @($Def.Fields)
        $nameW = ($fields | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
        $typeW = ($fields | ForEach-Object { $_.Type.Length } | Measure-Object -Maximum).Maximum
        $lines = @($Name)
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

    # Two subsections under the hand-written "# Reference": the commands, then the output types.
    [void]$sb.AppendLine('## Command reference')
    [void]$sb.AppendLine()

    # One-sentence "what it does" blurb per command, from its synopsis (first sentence). Built once
    # so the category tables below can look any command up regardless of which module declares it.
    $blurbs = @{}
    foreach ($m in $docModules) {
        foreach ($c in (Get-Command -Module $m -CommandType Function)) {
            $h = Get-Help $c.Name -Full | Where-Object { $_.Name -eq $c.Name } | Select-Object -First 1
            $b = ("$($h.Synopsis)" -replace '\s+', ' ').Trim()
            if ($b -match '^(.*?[.])(\s|$)') { $b = $matches[1] }
            $blurbs[$c.Name] = $b
        }
    }

    # Render one index table (link + blurb) for a list of command names, in the order given by the
    # taxonomy map. Names are emitted verbatim; the coverage gate guarantees each one exists.
    function Add-IndexTable {
        param([string[]]$Commands)
        [void]$sb.AppendLine('| ' + (Format-Small 'Command') + ' | ' + (Format-Small 'What it does') + ' |')
        [void]$sb.AppendLine('|:---|:---|')
        foreach ($name in $Commands) {
            $link = Format-Small ('[' + $name + '](#' + $name.ToLower() + ')')
            $blurbCell = Format-Small ((ConvertTo-MdText ("$($blurbs[$name])")).Replace('|', '\|'))
            [void]$sb.AppendLine('| ' + $link + ' | ' + $blurbCell + ' |')
        }
        [void]$sb.AppendLine()
    }

    # Table of contents, grouped by function (Move / Inspect / Manage). Each category opens with a
    # bold name and a blurb paragraph, then a command table; Manage splits into italic-headed
    # sub-tables (Reconcile, Undo & journal, ...). Driven by docs/command-categories.psd1.
    foreach ($cat in $commandCategories.Categories) {
        [void]$sb.AppendLine("**$($cat.Name)**")
        [void]$sb.AppendLine()
        if ($cat.Blurb) { [void]$sb.AppendLine((ConvertTo-MdText $cat.Blurb)); [void]$sb.AppendLine() }
        if ($cat.Commands) {
            Add-IndexTable -Commands $cat.Commands
        }
        if ($cat.Subcategories) {
            foreach ($sub in $cat.Subcategories) {
                [void]$sb.AppendLine("*$($sub.Name)*")
                [void]$sb.AppendLine()
                Add-IndexTable -Commands $sub.Commands
            }
        }
    }

    # Per-command detail (flat; the TOC above provides the namespace grouping).
    foreach ($m in $docModules) {
        foreach ($c in (Get-Command -Module $m -CommandType Function | Sort-Object Name)) {
            # Get-Help treats the name as a pattern, so 'Invoke-Netscoot' also matches Invoke-Netscoot*;
            # keep the exact match.
            $h = Get-Help $c.Name -Full | Where-Object { $_.Name -eq $c.Name } | Select-Object -First 1
            # Horizontal rule before each command so the entries read as distinct blocks.
            [void]$sb.AppendLine('---')
            [void]$sb.AppendLine()
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
                        [void]$sb.AppendLine("These share a common shape ($shared) and each adds its own fields; they are plain pscustomobjects with no shared base type. See [Output types](#output-types).")
                    } else {
                        [void]$sb.AppendLine('These result types are heterogeneous - they share no common fields. See [Output types](#output-types).')
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
                    [void]$sb.AppendLine((Format-ExampleCode "$($e.code)"))
                    [void]$sb.AppendLine('```')
                    $rem = Format-HelpText $e.remarks
                    if ($rem) { [void]$sb.AppendLine(); [void]$sb.AppendLine((ConvertTo-MdText $rem)) }
                    [void]$sb.AppendLine()
                }
            }

            # Back-link to the index, so a reader who jumped to one command can return without
            # scrolling. Anchor matches the "## Command reference" heading.
            [void]$sb.AppendLine((Format-Small '[Back to Command reference](#command-reference)'))
            [void]$sb.AppendLine()
        }
    }

    # Output types: the second subsection under "# Reference", one entry per typedef with the same
    # code-view the commands link to. Back-references (which commands emit it, which types nest it)
    # sit as a callout right under each type name. A type that is only nested in another (never
    # emitted directly, e.g. Netscoot.ToolInfo inside Capability) is still listed so its link
    # resolves; every type here appears in command output, directly or nested.
    $nestedIn = @{}
    foreach ($name in $typeDefs.Keys) {
        foreach ($f in @($typeDefs[$name].Fields)) {
            $ft = $f.Type -replace '[\[\]?]', ''
            if ($typeDefs.ContainsKey($ft)) { $nestedIn[$ft] = @($nestedIn[$ft]) + $name | Where-Object { $_ } }
        }
    }
    [void]$sb.AppendLine('## Output types')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('Each type below is one `pscustomobject` with the fields shown. A command may return a single one or several (and some types are also used as a field on another); whether a given command returns one or a collection is stated in that command''s Output. In a field, `type[]` is array-valued, `type?` may be `$null`, and a `Netscoot.*` field is itself one of these types.')
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
        # Cross-references as a compact bracketed list (no label), one font size down. The link
        # text - a command name or a Netscoot.* type - is self-describing.
        $refs = @()
        if ($emittedBy[$name]) { $refs += @(@($emittedBy[$name]) | Sort-Object -Unique | ForEach-Object { "[$_](#$($_.ToLower()))" }) }
        if ($nestedIn[$name]) { $refs += @(@($nestedIn[$name]) | Sort-Object -Unique | ForEach-Object { Format-TypeLink $_ }) }
        if ($refs.Count) { [void]$sb.AppendLine((Format-Small ('[ ' + ($refs -join ' | ') + ' ]'))); [void]$sb.AppendLine() }
        if ($def.Summary) { [void]$sb.AppendLine((ConvertTo-MdText $def.Summary)); [void]$sb.AppendLine() }
        [void]$sb.AppendLine('```text')
        [void]$sb.AppendLine((Format-TypeCodeView $name $def))
        [void]$sb.AppendLine('```')
        [void]$sb.AppendLine()
        # Back-link to the types index, mirroring the per-command one. Anchor matches "## Output types".
        [void]$sb.AppendLine((Format-Small '[Back to Output types](#output-types)'))
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

function Assert-DocsNotStale {
    # Release gate: fail if the docs have drifted from the code. Two checks (run with a clean tree):
    #   1. Stale README - regenerating the Command reference must be a no-op. If it changes, someone
    #      edited cmdlet help without running -Task Docs.
    #   2. Stale README + skills - no leftover old-brand tokens, and every product cmdlet the docs name
    #      must still be exported (catches a rename/removal the docs did not follow).
    Write-Host 'Checking docs are current (README reference + brand/command references)...' -ForegroundColor Cyan

    # (1) README reference drift. Save the current content, regenerate, compare (ignoring EOL), then
    # restore the saved content. File save/restore - never `git checkout` - so this never discards
    # uncommitted README work even if run on a dirty tree.
    $readmePath = [System.IO.Path]::Combine($root, 'README.md')
    $before = [System.IO.File]::ReadAllText($readmePath)
    Invoke-DocsTask | Out-Null
    $after = [System.IO.File]::ReadAllText($readmePath)
    [System.IO.File]::WriteAllText($readmePath, $before, [System.Text.UTF8Encoding]::new($false))
    if (($before -replace "`r`n", "`n") -ne ($after -replace "`r`n", "`n")) {
        throw 'README is stale: its generated Command reference does not match the cmdlet help. Run ./build.ps1 -Task Docs and commit.'
    }

    $docFiles = @([System.IO.Path]::Combine($root, 'README.md'))
    $docFiles += @(Get-ChildItem -Path (Join-Path $root '.claude/skills') -Recurse -Filter '*.md' -ErrorAction SilentlyContinue | ForEach-Object FullName)

    # (2a) Leftover old-brand tokens (an incomplete rebrand).
    foreach ($f in $docFiles) {
        $text = [System.IO.File]::ReadAllText($f)
        foreach ($bad in 'DotnetMove', 'dotnet-move', 'DOTNETMOVE', 'dotnetmv') {
            if ($text.Contains($bad)) { throw "Stale brand token '$bad' in $(Split-Path -Leaf $f); update it to the current brand." }
        }
        if ($text -cmatch '\bMove-Dotnet\b') { throw "Stale 'Move-Dotnet' (the umbrella is now Invoke-Netscoot) in $(Split-Path -Leaf $f)." }
    }

    # (2b) Every product cmdlet the docs name must be exported (a distinctive-noun match avoids
    # flagging generic PowerShell/dotnet commands that legitimately appear in examples).
    foreach ($m in $modules) { Import-Module ([System.IO.Path]::Combine($root, 'src', $m, "$m.psd1")) -Force }
    $exported = @(Get-Command -Module $modules -CommandType Function | ForEach-Object Name)
    $stem = 'Netscoot|Dotnet|PowerShell|Native|Unity|MSBuild|MoveEngine|SolutionReferences|SolutionConsistency|SolutionInventory|PathReference'
    foreach ($f in $docFiles) {
        $text = [System.IO.File]::ReadAllText($f)
        foreach ($mch in [regex]::Matches($text, "\b[A-Z][a-z]+-($stem)\w*\b")) {
            if ($mch.Value -notin $exported) { throw "Docs name a cmdlet that does not exist: '$($mch.Value)' in $(Split-Path -Leaf $f) (renamed or removed?). Update the docs." }
        }
    }

    # (2c) Category-map coverage. Every documented (public engine) cmdlet must appear in the
    # functional taxonomy exactly once, and the map must name no command that is not exported. This
    # is what forces a new cmdlet to be categorized before it can ship (the index is generated from
    # this map, so an uncategorized command would otherwise just be silently absent from the index).
    $documented = @(Get-Command -Module ($modules | Where-Object { $_ -ne 'Netscoot.Shared' }) -CommandType Function | ForEach-Object Name)
    $categories = Import-PowerShellDataFile ([System.IO.Path]::Combine($root, 'docs', 'command-categories.psd1'))
    $mapped = foreach ($cat in $categories.Categories) {
        if ($cat.Commands) { $cat.Commands }
        foreach ($sub in $cat.Subcategories) { $sub.Commands }
    }
    $mapped = @($mapped | Where-Object { $_ })
    $dupes = @($mapped | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
    if ($dupes.Count) { throw "command-categories.psd1 lists these command(s) more than once: $($dupes -join ', '). Each command must be categorized exactly once." }
    $uncategorized = @($documented | Where-Object { $_ -notin $mapped })
    if ($uncategorized.Count) { throw "These exported cmdlet(s) are not in command-categories.psd1: $($uncategorized -join ', '). Add each to a category so it appears in the Command reference." }
    $ghosts = @($mapped | Where-Object { $_ -notin $documented })
    if ($ghosts.Count) { throw "command-categories.psd1 names cmdlet(s) that are not exported: $($ghosts -join ', '). Remove or rename them." }

    Write-Host 'Docs are current.' -ForegroundColor Green
}

function Invoke-ReleaseTask {
    # Releases are cut from master, which is branch-protected: the CI checks are required and enforced
    # for admins, so master may only ever receive a commit that already passed CI. This task therefore
    # PREPARES the release on develop (stamp + commit + push, so CI runs on that exact commit), and
    # -Publish then FINALIZES by fast-forwarding master to that green commit and tagging it. Two phases,
    # both run from develop:
    #   ./build.ps1 -Task Release -Version X.Y.Z            # prepare: stamp, gate, commit + push develop
    #   (wait for CI green on all platforms)
    #   ./build.ps1 -Task Release -Version X.Y.Z -Publish   # finalize: fast-forward master, tag, release
    # ModuleVersion in every manifest is kept equal to the tag, so installed version == released tag.
    if (-not $Version) { throw "Release needs -Version, e.g. ./build.ps1 -Task Release -Version 1.2.0" }
    if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Version must be semver (x.y.z): '$Version'" }
    $tag = "v$Version"

    $branch = "$(& git -C $root rev-parse --abbrev-ref HEAD)".Trim()
    if ($branch -ne 'develop') { throw "Run Release from develop (currently on '$branch'); master is fast-forwarded from develop." }

    if (-not $Publish) {
        # PREPARE on develop: stamp, gate locally, commit the bump, push so CI runs on that commit.
        if (& git -C $root status --porcelain) { throw 'Working tree is not clean; commit or stash first so the release commit is only the version bump.' }

        # Gate: docs must not be stale (README reference current; README + skills reference no removed
        # brand/cmdlets). Run while the tree is clean, before stamping.
        Assert-DocsNotStale

        $manifests = foreach ($m in ($modules + $umbrella)) { Join-Path $root (Join-Path 'src' (Join-Path $m "$m.psd1")) }
        $changed = $false
        foreach ($mf in $manifests) {
            $text = [System.IO.File]::ReadAllText($mf)
            $new = [regex]::Replace($text, "(?m)^(\s*ModuleVersion\s*=\s*')[^']*(')", "`${1}$Version`$2")
            if ($new -cne $text) { [System.IO.File]::WriteAllText($mf, $new); $changed = $true; Write-Host "Stamped $Version into $(Split-Path -Leaf $mf)" -ForegroundColor Green }
        }
        if (-not $changed) { throw "No manifest changed - already at $Version?" }

        # Static analysis is a hard gate here (must be installed AND clean), then the full suite.
        Write-Host 'Static analysis (release prerequisite)...' -ForegroundColor Cyan
        if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) { throw 'Release requires PSScriptAnalyzer. Install: Install-Module PSScriptAnalyzer -Scope CurrentUser' }
        Invoke-AnalyzeTask
        Write-Host 'Running the test suite before release...' -ForegroundColor Cyan
        Invoke-TestTask

        & git -C $root add (($modules + $umbrella) | ForEach-Object { "src/$_/$_.psd1" })
        & git -C $root commit -m "release: $tag"
        if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }
        & git -C $root push origin develop
        if ($LASTEXITCODE -ne 0) { throw 'git push develop failed' }
        Write-Host "Prepared $tag on develop and pushed. Now wait for CI to pass on all platforms:" -ForegroundColor Yellow
        Write-Host '  - ci.yml (Windows, Windows PowerShell 5.1, PSScriptAnalyzer) runs on the push' -ForegroundColor Yellow
        Write-Host '  - run platforms.yml for Linux + macOS (tools/Invoke-PlatformCI.ps1)' -ForegroundColor Yellow
        Write-Host "Then finalize:  ./build.ps1 -Task Release -Version $Version -Publish" -ForegroundColor Yellow
        return
    }

    # FINALIZE: develop HEAD must be the prepared release commit; fast-forward master to it. The
    # protected push to master is accepted only because the required CI checks passed on this commit.
    $headSubject = "$(& git -C $root log -1 --format=%s)".Trim()
    if ($headSubject -ne "release: $tag") { throw "develop HEAD is '$headSubject', not 'release: $tag'. Run the prepare phase first (without -Publish)." }

    & git -C $root fetch -q origin
    & git -C $root checkout master
    if ($LASTEXITCODE -ne 0) { throw 'git checkout master failed' }
    & git -C $root merge --ff-only develop
    if ($LASTEXITCODE -ne 0) { & git -C $root checkout develop; throw 'master could not fast-forward to develop (diverged?). Resolve, then re-run -Publish.' }
    & git -C $root push origin master
    if ($LASTEXITCODE -ne 0) { & git -C $root checkout develop; throw "Pushing master was rejected - the required CI checks are likely not green yet on $tag. Wait for CI, then re-run -Publish." }
    & git -C $root tag -a $tag -m "netscoot $Version"
    & git -C $root push origin $tag
    & gh release create $tag --title "netscoot $Version" --generate-notes
    & git -C $root checkout develop
    Write-Host "Released $tag from master; back on develop." -ForegroundColor Green
}

function Invoke-PublishTask {
    # Assemble the SINGLE bundled netscoot package and publish it to the PowerShell Gallery. The
    # shipped package is one module folder: the umbrella at the root, with Shared + each engine as
    # subfolders the umbrella's RootModule loads (-Global; native only on Windows, best-effort). No
    # separate Shared/Core/Unity/Native packages. Without -ApiKey this only stages + validates.
    $stage = Join-Path ([System.IO.Path]::GetTempPath()) ("netscoot_pkg_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $pkg = Join-Path $stage 'Netscoot'
    New-Item -ItemType Directory -Path $pkg -Force | Out-Null

    # Umbrella files (manifest + RootModule) at the package root...
    Copy-Item -Path (Join-Path $root (Join-Path 'src' (Join-Path 'Netscoot' '*'))) -Destination $pkg -Recurse -Force
    # ...then Shared + the engines as subfolders the umbrella loads.
    foreach ($name in 'Netscoot.Shared', 'Netscoot.Core', 'Netscoot.Unity', 'Netscoot.Native') {
        Copy-Item -Path (Join-Path $root (Join-Path 'src' $name)) -Destination (Join-Path $pkg $name) -Recurse -Force
    }

    $manifest = Join-Path $pkg 'Netscoot.psd1'
    Write-Host "Validating bundled manifest: $manifest" -ForegroundColor Cyan
    $null = Test-ModuleManifest -Path $manifest

    # Smoke-import in a clean child pwsh to prove the single package self-loads with no separate
    # modules on the path (this is what catches missing-bundle / load-order bugs).
    Write-Host 'Smoke-importing the bundled package in a clean session...' -ForegroundColor Cyan
    & pwsh -NoProfile -Command "Import-Module '$manifest' -Force; if (-not (Get-Command Invoke-Netscoot -ErrorAction SilentlyContinue)) { throw 'Invoke-Netscoot was not surfaced by the bundled package.' }; 'bundled import OK'"
    if ($LASTEXITCODE -ne 0) { throw 'The bundled package failed to import in a clean session.' }

    Write-Host "Staged single package at: $pkg" -ForegroundColor Green
    if (-not $ApiKey) {
        Write-Host 'No -ApiKey given: staged + validated only (dry run). Re-run with -ApiKey to publish.' -ForegroundColor Yellow
        return
    }
    Publish-Module -Path $pkg -NuGetApiKey $ApiKey -Repository PSGallery
    Write-Host 'Published netscoot to the PowerShell Gallery.' -ForegroundColor Green
}

switch ($Task) {
    'Test' { Invoke-TestTask }
    'Analyze' { Invoke-AnalyzeTask }
    'Install' { Invoke-InstallTask }
    'Docs' { Invoke-DocsTask }
    'CheckDocs' { Assert-DocsNotStale }
    'Release' { Invoke-ReleaseTask }
    'Publish' { Invoke-PublishTask }
}
