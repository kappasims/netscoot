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
    [ValidateSet('Test', 'Analyze', 'Install', 'Docs', 'Release')]
    [string]$Task = 'Test',
    [string]$InstallPath,
    # Release: the semver to stamp into every module manifest (keeps ModuleVersion == the tag).
    [string]$Version,
    # Release: also commit, tag vX.Y.Z, push, and create the GitHub release. Without it, Release
    # only stamps the manifests locally so you can review the bump before publishing.
    [switch]$Publish
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$modules = 'DotnetMove.Core', 'DotnetMove.Native', 'DotnetMove.Unity'
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
        Write-Host 'Installing Pester 5...' -ForegroundColor Cyan
        Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck
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
    # The modules dot-source ..\Shared, so Shared must sit beside them in the target.
    foreach ($name in ($modules + $umbrella + 'Shared')) {
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

    $sb = [System.Text.StringBuilder]::new()
    $nsLabel = @{ 'DotnetMove.Core' = '.NET and PowerShell'; 'DotnetMove.Unity' = 'Unity'; 'DotnetMove.Native' = 'native C++ (Windows)' }

    # Table of contents, grouped by namespace: each command links to its detail entry, with a
    # one-sentence blurb from the synopsis.
    foreach ($m in $modules) {
        $label = if ($nsLabel.ContainsKey($m)) { $nsLabel[$m] } else { $m }
        [void]$sb.AppendLine("**$label**")
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('| Command | What it does |')
        [void]$sb.AppendLine('|---|---|')
        foreach ($c in (Get-Command -Module $m -CommandType Function | Sort-Object Name)) {
            $h = Get-Help $c.Name -Full | Where-Object { $_.Name -eq $c.Name } | Select-Object -First 1
            $blurb = ("$($h.Synopsis)" -replace '\s+', ' ').Trim()
            if ($blurb -match '^(.*?[.])(\s|$)') { $blurb = $matches[1] }
            [void]$sb.AppendLine("| [$($c.Name)](#$($c.Name.ToLower())) | $((ConvertTo-MdText $blurb).Replace('|', '\|')) |")
        }
        [void]$sb.AppendLine()
    }

    # Per-command detail (flat; the TOC above provides the namespace grouping).
    foreach ($m in $modules) {
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
                [void]$sb.AppendLine('| Name | Type | Required | Pipeline | Description |')
                [void]$sb.AppendLine('|---|---|---|---|---|')
                foreach ($p in $params) {
                    $pd = (ConvertTo-MdText ((Format-HelpText $p.description) -replace '\r?\n', ' ')).Replace('|', '\|')
                    [void]$sb.AppendLine("| ``$($p.name)`` | $($p.type.name) | $($p.required) | $($p.pipelineInput) | $pd |")
                }
                [void]$sb.AppendLine()
            }

            $outputs = @($h.returnValues.returnValue | ForEach-Object { ("$($_.type.name) " + (Format-HelpText $_.description)).Trim() } | Where-Object { $_ })
            if ($outputs.Count) {
                [void]$sb.AppendLine('**Output**')
                [void]$sb.AppendLine()
                foreach ($out in $outputs) { [void]$sb.AppendLine((ConvertTo-MdText $out)) }
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
    Write-Host "Wrote the Command reference section of README.md ($((Get-Command -Module $modules -CommandType Function).Count) cmdlets)." -ForegroundColor Green
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

switch ($Task) {
    'Test' { Invoke-TestTask }
    'Analyze' { Invoke-AnalyzeTask }
    'Install' { Invoke-InstallTask }
    'Docs' { Invoke-DocsTask }
    'Release' { Invoke-ReleaseTask }
}
