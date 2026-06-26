function Test-EditorSolutionGuard {
    <#
    .SYNOPSIS
        Check that a repository's editor configuration will keep a .slnx consolidation durable -
        i.e. that VS Code's C# Dev Kit will not silently re-mint a legacy .sln next to it.

    .DESCRIPTION
        Consolidating to a single .slnx is not durable on its own. VS Code's C# Dev Kit
        AUTO-GENERATES a legacy .sln next to a .slnx on folder open unless
        'dotnet.automaticallyCreateSolutionInWorkspace' is false, so a regenerated .sln reappears and
        drifts (the exact stale-duplicate that Test-NetscootSolutionConsistency detects after the fact).
        When at least one .slnx exists in the repository, this inspects the repository-root editor
        config and reports whether the guards that keep the consolidation durable are in place:

          AutoCreateGuard  .vscode/settings.json must set
                           'dotnet.automaticallyCreateSolutionInWorkspace' to false (else Dev Kit
                           re-mints the .sln).
          DefaultSolution  'dotnet.defaultSolution' should point at a real, existing solution (ideally
                           the .slnx). Missing, or pointing at a deleted/nonexistent file, means Dev
                           Kit chooses which solution loads - possibly a stray .sln.
          GitignoreGuard   .gitignore should ignore *.sln so a regenerated one cannot be committed.

        Read-only: it never edits settings, .gitignore, or any solution. It emits one result object
        per check and surfaces findings through the standard streams so behavior follows invocation:
        by default it writes a Warning for each failed guard; -Strict escalates each Warning-level
        finding to a non-terminating error (honoring -ErrorAction). Info-level findings (e.g. a
        missing .gitignore guard) are emitted as objects and shown under -Verbose, never as warnings.

        This is editor-specific (VS Code C# Dev Kit) because that is what governs solution drift in
        practice; the checks only run when the repository actually contains a .slnx.

    .PARAMETER RepositoryRoot
        Root to inspect. Accepts pipeline input: a path string, or a file/directory item from
        Get-Item / Get-ChildItem. Defaults to the enclosing git repository root.

    .PARAMETER Strict
        Escalate each Warning-level guard finding to a non-terminating error (for CI gating).

    .OUTPUTS
        Netscoot.EditorSolutionGuard - one per check performed.

    .EXAMPLE
        # Check the current repository's editor guards
        Test-EditorSolutionGuard
        # Gate CI on the consolidation being durable
        Test-EditorSolutionGuard -RepositoryRoot . -Strict
        # Inspect a specific repository from the pipeline
        Get-Item ./repo | Test-EditorSolutionGuard

    .LINK
        Test-NetscootSolutionConsistency

    .LINK
        Get-NetscootSolutionInventory
    #>
    [CmdletBinding()]
    [OutputType('Netscoot.EditorSolutionGuard')]
    param(
        [Parameter(Position = 0, ValueFromPipeline)]
        [Netscoot.PathInputTransform()]
        [string]$RepositoryRoot,
        [switch]$Strict
    )

    process {
        if (-not $RepositoryRoot) { $RepositoryRoot = Get-RepositoryRoot -StartPath (Get-Location).Path }
        $root = (Resolve-FullPath $RepositoryRoot).TrimEnd('\', '/')

        # The guard only applies when a .slnx is (or is becoming) the source of truth.
        $slnx = @(Find-Solutions -Root $root | Where-Object { $_.Extension -eq '.slnx' })
        if (-not $slnx.Count) {
            Write-Verbose "No .slnx under $root; the editor solution guard only applies when a .slnx is the source of truth."
            return
        }

        # Records accumulate in this list (mutated in-place by _emit, which reads it from the
        # enclosing scope - no variable reassignment, so no scope quirk). The list also drives the
        # final "all good" decision, so no separate counter is needed.
        $records = [System.Collections.Generic.List[object]]::new()
        function _emit([string]$Check, [string]$Severity, [string]$Detail) {
            $record = [Netscoot.EditorSolutionGuard]@{
                Check      = $Check
                Severity   = $Severity
                Detail     = $Detail
            }
            switch ($Severity) {
                'Warning' {
                    if ($Strict) {
                        Write-Error -Message $Detail -Category InvalidData -TargetObject $record -ErrorId "EditorGuard$Check"
                    } else {
                        Write-Warning $Detail
                    }
                }
                'Info' { Write-Verbose "${Check}: $Detail" }
            }
            $records.Add($record)
            $record   # emit to the pipeline so it is capturable/filterable
        }

        $settingsPath = [System.IO.Path]::Combine($root, '.vscode', 'settings.json')
        $settings = $null
        if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
            try { $settings = ConvertFrom-Jsonc -Text (Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8) }
            catch {
                _emit 'AutoCreateGuard' 'Warning' ".vscode/settings.json exists but could not be parsed as JSON ($($_.Exception.Message)); cannot confirm the Dev Kit auto-create guard."
                # Without parseable settings, the remaining settings-based checks cannot run.
                $settings = $null
            }
        }

        # --- AutoCreateGuard ---
        if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
            _emit 'AutoCreateGuard' 'Info' "No .vscode/settings.json. If this repository is opened in VS Code with the C# Dev Kit, it will auto-create a legacy .sln next to the .slnx unless 'dotnet.automaticallyCreateSolutionInWorkspace' is set to false."
        } elseif ($null -ne $settings) {
            $autoProp = $settings.PSObject.Properties['dotnet.automaticallyCreateSolutionInWorkspace']
            if (-not $autoProp) {
                _emit 'AutoCreateGuard' 'Warning' "'dotnet.automaticallyCreateSolutionInWorkspace' is not set in .vscode/settings.json. VS Code's C# Dev Kit will regenerate a legacy .sln next to your .slnx; set it to false to keep the consolidation durable."
            } elseif ($autoProp.Value -eq $true) {
                _emit 'AutoCreateGuard' 'Warning' "'dotnet.automaticallyCreateSolutionInWorkspace' is true in .vscode/settings.json. Set it to false so the C# Dev Kit does not regenerate a legacy .sln next to your .slnx."
            } else {
                _emit 'AutoCreateGuard' 'OK' "'dotnet.automaticallyCreateSolutionInWorkspace' is false; the C# Dev Kit will not regenerate a .sln."
            }
        }

        # --- DefaultSolution ---
        if ($null -ne $settings) {
            $defProp = $settings.PSObject.Properties['dotnet.defaultSolution']
            if (-not $defProp) {
                _emit 'DefaultSolution' 'Warning' "'dotnet.defaultSolution' is not set in .vscode/settings.json. The C# Dev Kit will choose which solution loads, which may be a stray .sln. Point it at your .slnx."
            } elseif ("$($defProp.Value)" -eq 'disable') {
                _emit 'DefaultSolution' 'OK' "'dotnet.defaultSolution' is 'disable'; the C# Dev Kit will not auto-load a solution."
            } else {
                $defVal = "$($defProp.Value)"
                $defAbs = [System.IO.Path]::GetFullPath((Join-Path $root ($defVal.Replace('/', [System.IO.Path]::DirectorySeparatorChar).Replace('\', [System.IO.Path]::DirectorySeparatorChar))))
                if (-not (Test-Path -LiteralPath $defAbs -PathType Leaf)) {
                    _emit 'DefaultSolution' 'Warning' "'dotnet.defaultSolution' points at '$defVal', which does not exist. Point it at an existing .slnx."
                } elseif ([System.IO.Path]::GetExtension($defAbs) -ieq '.sln') {
                    _emit 'DefaultSolution' 'Info' "'dotnet.defaultSolution' points at a legacy .sln ('$defVal'), not your .slnx. Repoint it at the .slnx so the consolidated solution is the one that loads."
                } else {
                    _emit 'DefaultSolution' 'OK' "'dotnet.defaultSolution' points at an existing solution ('$defVal')."
                }
            }
        }

        # --- GitignoreGuard ---
        $gitignorePath = [System.IO.Path]::Combine($root, '.gitignore')
        $hasSlnGuard = $false
        if (Test-Path -LiteralPath $gitignorePath -PathType Leaf) {
            foreach ($line in (Get-Content -LiteralPath $gitignorePath -ErrorAction SilentlyContinue)) {
                $t = $line.Trim()
                if (-not $t -or $t.StartsWith('#')) { continue }
                if ($t -match '^/?(\*\*/)?\*\.sln$') { $hasSlnGuard = $true; break }
            }
        }
        if (-not $hasSlnGuard) {
            _emit 'GitignoreGuard' 'Info' "No '*.sln' rule in .gitignore. With a .slnx as the source of truth, ignore '*.sln' so a regenerated legacy solution cannot be committed."
        } else {
            _emit 'GitignoreGuard' 'OK' ".gitignore ignores '*.sln'; a regenerated legacy solution cannot be committed."
        }

        if (-not @($records | Where-Object { $_.Severity -eq 'Warning' }).Count) {
            Write-Host "Editor solution guards look good - the .slnx consolidation is durable." -ForegroundColor Green
        }
    }
}
