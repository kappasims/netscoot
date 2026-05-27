#requires -Version 7.0
<#
.SYNOPSIS
    Render a human-readable transcript of Netscoot's command-line UX across representative
    scenarios, so a person can read it and judge whether the output is friendly.

.DESCRIPTION
    Builds small throwaway fixtures (real `dotnet new` projects/solutions) and runs the actual
    commands against them, capturing every user-facing stream - status (Write-Host), warnings,
    errors, tables, returned objects, and -WhatIf previews - in the order they appear, using
    *>&1 so stream identity and chronology are preserved. The result is written as a Markdown
    document: one section per scenario showing the command and its captured output.

    This is a manual review aid, not a CI test; it needs dotnet and git on PATH.

.PARAMETER OutFile
    Where to write the Markdown transcript. Defaults to tools/ux-flow.md.

.PARAMETER PassThru
    Also emit the rendered Markdown to the pipeline.

.EXAMPLE
    ./tools/Show-CommandUx.ps1
    Writes tools/ux-flow.md; open it and read the flow.
#>
[CmdletBinding()]
param(
    [string]$OutFile = (Join-Path $PSScriptRoot 'ux-flow.md'),
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module ([System.IO.Path]::Combine($repoRoot, 'src', 'Netscoot.Core', 'Netscoot.Core.psd1')) -Force

# --- rendering -------------------------------------------------------------------------------

function Format-CapturedRecord {
    # Turn one record from a *>&1 capture into tagged transcript lines, preserving the stream so
    # a reader sees what the user would see (and which channel it came on).
    param([Parameter(Mandatory)]$Record)
    switch ($Record.GetType().Name) {
        'WarningRecord' { return ,("WARNING  $($Record.Message)") }
        'ErrorRecord' { return ,("ERROR    $($Record.Exception.Message)") }
        'VerboseRecord' { return ,("VERBOSE  $($Record.Message)") }
        'InformationRecord' {
            # Write-Host arrives here; MessageData is a HostInformationMessage with the colour.
            $data = $Record.MessageData
            $text = if ($data.PSObject.Properties.Name -contains 'Message') { $data.Message } else { "$data" }
            $colour = if ($data.PSObject.Properties.Name -contains 'ForegroundColor' -and $data.ForegroundColor) { $data.ForegroundColor } else { $null }
            $lines = ($text -split "`r?`n")
            return $lines | ForEach-Object { if ($colour) { ('{0,-8} {1}' -f $colour, $_) } else { "         $_" } }
        }
        default {
            # Skip internal formatting records (if a command formatted its own output upstream).
            if ($Record.GetType().FullName -like 'Microsoft.PowerShell.Commands.Internal.Format.*') { return @() }
            # A returned object (e.g. the result record). Show it the way an uncaptured caller sees it.
            return (($Record | Format-List | Out-String) -split "`r?`n" | Where-Object { $_ -ne '' } | ForEach-Object { "         $_" })
        }
    }
}

$script:sb = [System.Text.StringBuilder]::new()
function Add-Line { param([string]$Text = '') [void]$script:sb.AppendLine($Text) }

function Add-Scenario {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Narrative,
        [Parameter(Mandatory)][string]$CommandText,
        [Parameter(Mandatory)][scriptblock]$Command
    )
    Write-Host "  scenario: $Title" -ForegroundColor DarkGray
    $records = & { & $Command } *>&1
    $lines = foreach ($r in $records) { Format-CapturedRecord -Record $r }

    Add-Line "## $Title"
    Add-Line
    Add-Line $Narrative
    Add-Line
    Add-Line '```console'
    Add-Line "PS> $CommandText"
    foreach ($l in $lines) { Add-Line $l }
    Add-Line '```'
    Add-Line
}

# --- fixtures --------------------------------------------------------------------------------

function New-Sandbox {
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ("uxflow_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $d | Out-Null
    return $d
}
function New-AppLibRepo {
    # App -> Lib in a slnx, committed. Returns the repo root.
    $root = New-Sandbox
    Push-Location $root
    try {
        & git init -q
        & dotnet new classlib -n Lib -o (Join-Path $root (Join-Path 'src' 'Lib')) | Out-Null
        & dotnet new console -n App -o (Join-Path $root (Join-Path 'src' 'App')) | Out-Null
        & dotnet add (Join-Path $root (Join-Path 'src' (Join-Path 'App' 'App.csproj'))) reference (Join-Path $root (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))) | Out-Null
        & dotnet new sln -n Demo --format slnx | Out-Null
        & dotnet sln Demo.slnx add (Join-Path $root (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))) (Join-Path $root (Join-Path 'src' (Join-Path 'App' 'App.csproj'))) | Out-Null
        & git add -A; & git commit -qm fixture | Out-Null
    } finally { Pop-Location }
    return $root
}

# --- scenarios -------------------------------------------------------------------------------

Add-Line "# netscoot command-line UX flow"
Add-Line
Add-Line "Generated by ``tools/Show-CommandUx.ps1`` on $(Get-Date -Format 'yyyy-MM-dd'). Each block shows a"
Add-Line "real command run against a throwaway fixture, with every output stream captured in order"
Add-Line "(the first column tags Write-Host colour / WARNING / ERROR). Read it and flag anything unfriendly."
Add-Line

$sandboxes = [System.Collections.Generic.List[string]]::new()
try {
    # 1. Capability probe
    Add-Scenario -Title 'Capability probe' `
        -Narrative 'What a user runs first to see whether their machine can do anything.' `
        -CommandText 'Get-ScootCapability' `
        -Command { Get-ScootCapability }

    # 2. Dry-run a move
    $r1 = New-AppLibRepo; $sandboxes.Add($r1)
    Add-Scenario -Title 'Preview a project move (-WhatIf)' `
        -Narrative 'The safe first step: see what a move would touch without changing anything.' `
        -CommandText 'Invoke-Scoot -Path ./src/Lib/Lib.csproj -Destination ./libs/Lib -WhatIf' `
        -Command {
            Invoke-Scoot -Path (Join-Path $r1 (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))) `
                -Destination (Join-Path $r1 (Join-Path 'libs' 'Lib')) -RepoRoot $r1 -WhatIf
        }

    # 3. Perform a move
    $r2 = New-AppLibRepo; $sandboxes.Add($r2)
    Add-Scenario -Title 'Perform the move' `
        -Narrative 'The real move: reconciles the solution and the consumer reference, then builds.' `
        -CommandText 'Invoke-Scoot -Path ./src/Lib/Lib.csproj -Destination ./libs/Lib' `
        -Command {
            Invoke-Scoot -Path (Join-Path $r2 (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))) `
                -Destination (Join-Path $r2 (Join-Path 'libs' 'Lib')) -RepoRoot $r2 -Confirm:$false
        }

    # 4. Error: missing project
    Add-Scenario -Title 'Error: project does not exist' `
        -Narrative 'How a bad path reads back to the user.' `
        -CommandText 'Invoke-Scoot -Path ./nope/Ghost.csproj -Destination ./libs/Ghost' `
        -Command {
            Invoke-Scoot -Path (Join-Path (New-Sandbox) 'Ghost.csproj') -Destination 'X:/libs/Ghost' -ErrorAction Continue
        }

    # 5. Error: destination overlaps source
    $r3 = New-AppLibRepo; $sandboxes.Add($r3)
    Add-Scenario -Title 'Error: destination inside the source' `
        -Narrative 'The overlap guard that refuses a move into its own subtree before changing anything.' `
        -CommandText 'Invoke-Scoot -Path ./src/Lib/Lib.csproj -Destination ./src/Lib/nested' `
        -Command {
            Invoke-Scoot -Path (Join-Path $r3 (Join-Path 'src' (Join-Path 'Lib' 'Lib.csproj'))) `
                -Destination (Join-Path $r3 (Join-Path 'src' (Join-Path 'Lib' 'nested'))) -RepoRoot $r3 -Confirm:$false -ErrorAction Continue
        }

    # 6. Inspect: consistency (clean)
    $r4 = New-AppLibRepo; $sandboxes.Add($r4)
    Add-Scenario -Title 'Inspect: solution consistency' `
        -Narrative 'Read-only check across solutions.' `
        -CommandText 'Test-SolutionConsistency -RepoRoot .' `
        -Command { Test-SolutionConsistency -RepoRoot $r4 }

    # 7. Repair: report-only on a hand-moved project
    $r5 = New-AppLibRepo; $sandboxes.Add($r5)
    New-Item -ItemType Directory -Path (Join-Path $r5 'libs') | Out-Null
    Move-Item -LiteralPath (Join-Path $r5 (Join-Path 'src' 'Lib')) -Destination (Join-Path $r5 (Join-Path 'libs' 'Lib'))
    Add-Scenario -Title 'Repair: report dangling entries' `
        -Narrative 'Someone moved Lib by hand; this shows what netscoot found, read-only.' `
        -CommandText 'Repair-SolutionReferences -RepoRoot .' `
        -Command { Repair-SolutionReferences -RepoRoot $r5 }

    Add-Scenario -Title 'Repair: fix them' `
        -Narrative 'The same repo, now repaired with -Fix.' `
        -CommandText 'Repair-SolutionReferences -RepoRoot . -Fix' `
        -Command { Repair-SolutionReferences -RepoRoot $r5 -Fix -Confirm:$false }

    $rendered = $script:sb.ToString()
    Set-Content -LiteralPath $OutFile -Value $rendered -Encoding UTF8
    Write-Host "Wrote UX transcript to $OutFile" -ForegroundColor Green
    if ($PassThru) { $rendered }
} finally {
    foreach ($s in $sandboxes) { Remove-Item -LiteralPath $s -Recurse -Force -ErrorAction SilentlyContinue }
}
