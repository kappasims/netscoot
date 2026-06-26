# Generator for the "Command reference" section of README.md - a ~470-line markdown compiler that
# turns every public cmdlet's comment-based help (synopsis, syntax, parameters, output types,
# examples, related links) and the output-type registry into the reference tables and per-command
# entries. Extracted from build.ps1 (which was 55% this one function) so the build script stays a
# thin task dispatcher.
#
# DOT-SOURCED by build.ps1, never run as a child script: it defines Invoke-DocsTask in build.ps1's
# scope and relies on that scope's $root, $modules, and $umbrella. The CheckDocs gate
# (Assert-DocsNotStale) verifies the generated output is byte-stable, so this extraction is
# behavior-preserving by construction - a drift would fail CI.

function Invoke-DocsTask {
    foreach ($m in $modules) {
        Import-Module ([System.IO.Path]::Combine($root, 'src', $m, "$m.psd1")) -Force
    }
    # Document only the public engine modules. NetscootShared is internal infrastructure (its
    # helpers are not part of the user-facing API), so it is imported above but not listed here.
    $docModules = @($modules | Where-Object { $_ -ne 'NetscootShared' })

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
            # Wrap $(...) / $scope:var / $var tokens in backticks so no renderer treats them as math
            # (\$ escaping is honored inconsistently). The $scope:var alternative comes first so a
            # whole `$env:NETSCOOT_JOURNAL` is captured, not just the `$env` prefix.
            $s = [regex]::Replace($s, '\$\([^)]*\)|\$\w+:\w+|\$\w+', { param($mm) '`' + $mm.Value + '`' })
            # Backtick bare parameter references (-Name). Uppercase-first skips hyphenated words
            # (non-terminating, cross-boundary); the lookbehind skips cmdlet names (Move-Item).
            $s = [regex]::Replace($s, '(?<![\w`-])(-[A-Z][A-Za-z]+)\b', '`$1`')
            # Linkify documented cmdlet names to their section anchor. Only names known to the
            # generator (see $blurbs, populated below) are linkified, so an unrelated Verb-Noun in
            # prose is left alone. The lookbehind skips a leading '[' (already a link), '`' (code
            # span), and word/hyphen chars (so 'Move-DotnetProject' doesn't match inside a longer
            # composite). Self-references on the cmdlet's own page stay plain to avoid noise.
            $s = [regex]::Replace($s, '(?<![\w`\[/-])([A-Z][a-zA-Z]+-[A-Z][a-zA-Z]+)\b', {
                    param($mm)
                    $n = $mm.Value
                    if ($blurbs.ContainsKey($n) -and $n -ne $script:CurrentCmdlet) {
                        '[' + $n + '](#' + $n.ToLower() + ')'
                    } else { $n }
                })
            # Backtick file paths / filenames that carry a known extension (with optional path
            # segments), then bare leading-dot extensions, so paths in prose render as code. The
            # backtick and '/' in the lookbehinds stop a second pass from re-matching inside a span
            # already produced (e.g. the '.targets' in a just-wrapped `.props/.targets`).
            $bt = [char]96
            $ext = 'csproj|fsproj|vbproj|sln|slnx|props|targets|ps1|psd1|psm1|vcxproj|meta'
            $s = [regex]::Replace($s, '(?<![\w' + $bt + './-])\.?[\w][\w./-]*\.(' + $ext + ')\b', { param($mm) '`' + $mm.Value + '`' })
            $s = [regex]::Replace($s, '(?<![\w' + $bt + './])\.(' + $ext + ')\b', { param($mm) '`' + $mm.Value + '`' })
            # A literal backslash immediately before a backtick we just inserted (e.g. a Windows
            # path "$dir\x.ps1" -> `$dir`\`x.ps1`) reads as a markdown-escaped backtick, which
            # unbalances code-span pairing for the rest of the paragraph (a phantom MD038). Double
            # the backslash so it stays literal and the backtick keeps its delimiter role.
            $s = $s -replace '\\(?=`)', '\\'
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

    # Re-wrap prose to <= $Width columns so generated lines satisfy markdownlint MD013. Markdown
    # links ([text](url)) and inline code spans (`code`) are treated as atomic tokens, so a wrap
    # never lands inside one (a break in [Output types] or a URL would corrupt the link). Existing
    # newlines (paragraph structure, blank lines) are preserved; only overlong lines re-flow, and a
    # soft break renders as a space, so the output reads identically to the unwrapped text.
    function Format-Wrap {
        param([string]$Text, [int]$Width = 120)
        # A "word" is a maximal run of non-space characters, except whitespace inside a markdown
        # link ([text](url)) or a code span (`code`) does not split it - so punctuation that abuts a
        # span (`-Force`).) stays attached and no spurious space is introduced when words rejoin.
        $tokenRe = [regex]'(?:\[[^\]]*\]\([^)]*\)|`[^`]*`|\S)+'
        $out = [System.Collections.Generic.List[string]]::new()
        foreach ($line in ($Text -split "`n", -1)) {
            if ($line.Length -le $Width) { $out.Add($line); continue }
            $cur = ''
            foreach ($m in $tokenRe.Matches($line)) {
                $tok = $m.Value
                if (-not $cur) { $cur = $tok }
                elseif (($cur.Length + 1 + $tok.Length) -le $Width) { $cur = $cur + ' ' + $tok }
                else { $out.Add($cur); $cur = $tok }
            }
            if ($cur) { $out.Add($cur) }
        }
        $out -join "`n"
    }

    # Output-type registry (typedefs). Each cmdlet declares the type(s) it emits via
    # [OutputType('Netscoot.X')]; we look the name up here to render a link + a terse code-view
    # of its structure, and to build the "Output types" section. Single source of truth for shapes.
    $typeDefs = Import-PowerShellDataFile ([System.IO.Path]::Combine($root, 'docs', 'output-types.psd1'))
    # Longest-first so a name that is a prefix of another (Netscoot.Update vs Netscoot.UpdatePolicy)
    # does not win the alternation and strip only its prefix. Also makes the order deterministic
    # (hashtable key enumeration is not), so the generated docs are stable across runs.
    $typeAlt = ($typeDefs.Keys | Sort-Object { $_.Length } -Descending | ForEach-Object { [regex]::Escape($_) }) -join '|'

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
        # Case-sensitive name match: a field named 'Engine' (e.g. MoveResult) and one named 'engine'
        # (e.g. JournalEntry) are not the same property on the returned object - $r.Engine and $r.engine
        # are distinct in code, and the page-rendered "common shape" line lists the *displayed* casing,
        # so collapsing them would mislead a reader of Undo-Netscoot's docs.
        @($defs[0].Fields) | Where-Object {
            $f = $_
            -not ($rest | Where-Object { -not (@($_.Fields) | Where-Object { $_.Name -ceq $f.Name -and $_.Type -ceq $f.Type }) })
        }
    }

    # GitHub heading anchor for a type entry: lowercase, drop all but [a-z0-9 -], spaces to dashes
    # (so 'Netscoot.PathReference' -> 'netscootpathreference').
    function Get-TypeAnchor { param([string]$Name) (($Name.ToLower() -replace '[^a-z0-9 -]', '') -replace ' ', '-') }
    function Format-TypeLink { param([string]$Name) "[$Name](#$(Get-TypeAnchor $Name))" }

    # Terse, monospaced rendering of a type's structure: a header line (the type name) then one
    # aligned line per field: name, type, and an optional '# note'. A field whose type is itself a
    # registered Netscoot.* type is expanded inline, indented, so the whole shape is visible in one
    # view. $Ancestors is the chain on the current path (not a global seen-set), so a type used in
    # two sibling fields (e.g. Capability's Git and Dotnet, both Netscoot.ToolInfo) expands under
    # each, while a genuine cycle stops. The header is the singular object; whether a command returns
    # one or many is a per-command fact, stated in that command's Output.
    function Format-TypeCodeView {
        param([string]$Name, [hashtable]$Def, [int]$Indent = 0, [string[]]$Ancestors = @())
        $fields = @($Def.Fields)
        $nameW = ($fields | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
        $typeW = ($fields | ForEach-Object { $_.Type.Length } | Measure-Object -Maximum).Maximum
        $pad = ' ' * $Indent
        $ancestorsNow = @($Ancestors) + $Name
        $lines = @()
        if ($Indent -eq 0) { $lines += $Name }   # top-level header; nested types are named by their field line
        for ($i = 0; $i -lt $fields.Count; $i++) {
            $f = $fields[$i]
            $prefix = $pad + '  ' + $f.Name.PadRight($nameW) + '  ' + $f.Type.PadRight($typeW)
            if ($f.Note) { $lines += ($prefix + '  # ' + $f.Note) }
            else { $lines += $prefix.TrimEnd() }
            # Expand a nested registered type inline (strip [] and ? decorations); stop on a cycle.
            # Indent so the nested type's property names sit one step PAST its type name - the same
            # offset the parent's own properties sit at under its header - so each level reads alike.
            $bare = $f.Type -replace '[\[\]?]', ''
            if ($typeDefs.ContainsKey($bare) -and ($bare -notin $ancestorsNow)) {
                $lines += (Format-TypeCodeView -Name $bare -Def $typeDefs[$bare] -Indent ($Indent + $nameW + 4) -Ancestors $ancestorsNow)
            }
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

    # Pass-through: the reference tables used to wrap cells in <small>, but that is inline HTML
    # (markdownlint MD033) and we keep the docs HTML-free, so cells render at normal size.
    function Format-Small { param([string]$Text) $Text }

    # Common parameters Get-Help lists without descriptions; supply our own so the table is complete.
    $commonDesc = @{
        WhatIf  = 'Preview the operation and report what would change, without modifying anything.'
        Confirm = 'Prompt for confirmation before each change.'
    }

    $sb = [System.Text.StringBuilder]::new()
    $emittedBy = @{}   # type name -> @(command names) that declare it via [OutputType]

    # Two subsections under the hand-written "# Reference": the commands, then the output types.
    [void]$sb.AppendLine('### Command reference')
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
        [void]$sb.AppendLine('| :--- | :--- |')
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
        [void]$sb.AppendLine("#### $($cat.Name)")
        [void]$sb.AppendLine()
        if ($cat.Blurb) { [void]$sb.AppendLine((Format-Wrap (ConvertTo-MdText $cat.Blurb))); [void]$sb.AppendLine() }
        if ($cat.Commands) {
            Add-IndexTable -Commands $cat.Commands
        }
        if ($cat.Subcategories) {
            foreach ($sub in $cat.Subcategories) {
                [void]$sb.AppendLine("##### $($sub.Name)")
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
            [void]$sb.AppendLine("#### $($c.Name)")
            [void]$sb.AppendLine()
            # Track the current cmdlet so ConvertTo-MdText skips self-references when linkifying.
            $script:CurrentCmdlet = $c.Name
            $syn = "$($h.Synopsis)".Trim()
            if ($syn) { [void]$sb.AppendLine((Format-Wrap (ConvertTo-MdText $syn))); [void]$sb.AppendLine() }

            [void]$sb.AppendLine('##### Syntax')
            [void]$sb.AppendLine()
            [void]$sb.AppendLine('```powershell')
            [void]$sb.AppendLine((Get-Command $c.Name -Syntax).Trim())
            [void]$sb.AppendLine('```')
            [void]$sb.AppendLine()

            $desc = Format-HelpText $h.description
            if ($desc) { [void]$sb.AppendLine((Format-Wrap (ConvertTo-MdText $desc))); [void]$sb.AppendLine() }

            $params = @($h.parameters.parameter | Where-Object { $_.name })
            if ($params.Count) {
                [void]$sb.AppendLine('##### Parameters')
                [void]$sb.AppendLine()
                $hdr = @('Name', 'Type', 'Required', 'Pipeline', 'Description') | ForEach-Object { Format-Small $_ }
                [void]$sb.AppendLine('| ' + ($hdr -join ' | ') + ' |')
                [void]$sb.AppendLine('| :--- | :--- | :--- | :--- | :--- |')
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
                [void]$sb.AppendLine('##### Output')
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
                    [void]$sb.AppendLine((Format-Wrap $lead))
                    if ($outNote) { [void]$sb.AppendLine((Format-Wrap (ConvertTo-MdText $outNote))) }
                    [void]$sb.AppendLine()
                    [void]$sb.AppendLine('```text')
                    [void]$sb.AppendLine((Format-TypeCodeView $t $def))
                    [void]$sb.AppendLine('```')
                } elseif ($registered.Count -gt 1) {
                    [void]$sb.AppendLine((Format-Wrap (ConvertTo-MdText ($(if ($outNote) { $outNote } else { 'The result object from the command it routes to; the concrete type varies.' })))))
                    [void]$sb.AppendLine()
                    foreach ($t in $registered) { [void]$sb.AppendLine("- $(Format-TypeLink $t)") }
                } else {
                    # No registered typedef (e.g. a plain string, or None) - render the prose as-is.
                    [void]$sb.AppendLine((Format-Wrap (ConvertTo-MdText $outRaw)))
                }
                # When a command emits several types, say whether they are related or heterogeneous.
                if ($registered.Count -gt 1) {
                    $common = @(Get-CommonFields $registered)
                    [void]$sb.AppendLine()
                    if ($common.Count) {
                        $shared = ($common | ForEach-Object { $_.Name }) -join ', '
                        [void]$sb.AppendLine((Format-Wrap "These share a common shape ($shared) and each adds its own fields; they are plain pscustomobjects with no shared base type. See [Output types](#output-types)."))
                    } else {
                        [void]$sb.AppendLine((Format-Wrap 'These result types are heterogeneous - they share no common fields. See [Output types](#output-types).'))
                    }
                }
                [void]$sb.AppendLine()
            }

            $examples = @($h.examples.example | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace("$($_.code)") })
            if ($examples.Count) {
                [void]$sb.AppendLine('##### Examples')
                [void]$sb.AppendLine()
                foreach ($e in $examples) {
                    [void]$sb.AppendLine('```powershell')
                    [void]$sb.AppendLine((Format-ExampleCode "$($e.code)"))
                    [void]$sb.AppendLine('```')
                    $rem = Format-HelpText $e.remarks
                    if ($rem) { [void]$sb.AppendLine(); [void]$sb.AppendLine((Format-Wrap (ConvertTo-MdText $rem))) }
                    [void]$sb.AppendLine()
                }
            }

            # Related cmdlets (from .LINK blocks). Only emit when at least one link points at a
            # documented cmdlet in $blurbs (so a stray external .LINK target is dropped quietly
            # instead of producing a broken anchor). Renders one font size down as a compact
            # bracketed list, matching the type-page cross-ref style.
            $related = @()
            foreach ($l in @($h.relatedLinks.navigationLink)) {
                $name = ("$($l.linkText)").Trim()
                if ($name -and $blurbs.ContainsKey($name) -and $name -ne $c.Name) { $related += $name }
            }
            if ($related.Count) {
                [void]$sb.AppendLine('##### Related')
                [void]$sb.AppendLine()
                $links = $related | ForEach-Object { '[' + $_ + '](#' + $_.ToLower() + ')' }
                # Format-Wrap breaks at the pipe-space boundaries when the line exceeds 120 chars
                # (a 4-way cluster does), keeping each [text](url) atomic so links never split.
                [void]$sb.AppendLine((Format-Wrap (Format-Small ('[ ' + ($links -join ' | ') + ' ]'))))
                [void]$sb.AppendLine()
            }

            # Back-link to the index, so a reader who jumped to one command can return without
            # scrolling. Anchor matches the "## Command reference" heading.
            [void]$sb.AppendLine((Format-Small '[Back to Command reference](#command-reference)'))
            [void]$sb.AppendLine()
        }
    }
    # Trailing rule so the last command is closed by a separator too, matching the leading rule
    # each command opens with.
    [void]$sb.AppendLine('---')
    [void]$sb.AppendLine()

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
    [void]$sb.AppendLine('### Output types')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine((Format-Wrap 'Each type below is one `pscustomobject` with the fields shown. A command may return a single one or several (and some types are also used as a field on another); whether a given command returns one or a collection is stated in that command''s Output. In a field, `type[]` is array-valued, `type?` may be `$null`, and a `Netscoot.*` field is itself one of these types.'))
    [void]$sb.AppendLine()
    $sortedTypes = @($typeDefs.Keys | Sort-Object)
    [void]$sb.AppendLine('| ' + (Format-Small 'Type') + ' | ' + (Format-Small 'Represents') + ' |')
    [void]$sb.AppendLine('| :--- | :--- |')
    foreach ($name in $sortedTypes) {
        $sm = (ConvertTo-MdText ("$($typeDefs[$name].Summary)")).Replace('|', '\|')
        [void]$sb.AppendLine('| ' + (Format-Small (Format-TypeLink $name)) + ' | ' + (Format-Small $sm) + ' |')
    }
    [void]$sb.AppendLine()
    foreach ($name in $sortedTypes) {
        $def = $typeDefs[$name]
        # Horizontal rule before each type so the entries read as distinct blocks, mirroring the
        # per-command detail above.
        [void]$sb.AppendLine('---')
        [void]$sb.AppendLine()
        [void]$sb.AppendLine("#### $name")
        [void]$sb.AppendLine()
        # Cross-references as a compact bracketed list (no label), one font size down. The link
        # text - a command name or a Netscoot.* type - is self-describing.
        $refs = @()
        if ($emittedBy[$name]) { $refs += @(@($emittedBy[$name]) | Sort-Object -Unique | ForEach-Object { "[$_](#$($_.ToLower()))" }) }
        if ($nestedIn[$name]) { $refs += @(@($nestedIn[$name]) | Sort-Object -Unique | ForEach-Object { Format-TypeLink $_ }) }
        if ($refs.Count) { [void]$sb.AppendLine((Format-Wrap ('[ ' + ($refs -join ' | ') + ' ]'))); [void]$sb.AppendLine() }
        if ($def.Summary) { [void]$sb.AppendLine((Format-Wrap (ConvertTo-MdText $def.Summary))); [void]$sb.AppendLine() }
        [void]$sb.AppendLine('```text')
        [void]$sb.AppendLine((Format-TypeCodeView $name $def))
        [void]$sb.AppendLine('```')
        [void]$sb.AppendLine()
        # Back-link to the types index, mirroring the per-command one. Anchor matches "## Output types".
        [void]$sb.AppendLine((Format-Small '[Back to Output types](#output-types)'))
        [void]$sb.AppendLine()
    }
    # Trailing rule so the last type is closed by a separator too, matching the leading rule.
    [void]$sb.AppendLine('---')
    [void]$sb.AppendLine()

    # Inject into the marked section of README.md (replacing it in place, or appending the
    # section if the markers are not present yet).
    $begin = '<!-- BEGIN GENERATED REFERENCE -->'
    $end = '<!-- END GENERATED REFERENCE -->'
    # Split across two lines so the comment itself stays within the MD013 line-length budget.
    $note = "<!-- Regenerate with ./build.ps1 -Task Docs. Generated from the cmdlets' comment-based`n" +
            'help in src/; do not hand-edit between these markers. -->'
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

