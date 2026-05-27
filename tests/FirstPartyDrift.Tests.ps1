#requires -Modules Pester

# Drift monitor for the project's declared contract: moves never hand-WRITE solution/project
# files; every path/GUID mutation goes through first-party tooling (dotnet sln / dotnet reference /
# git mv / Update-ModuleManifest). The only sanctioned exceptions are formats no first-party tool
# reconciles - a solution's stored project paths, <Import> paths, and a script's dot-source paths -
# which are rewritten through the BOM-preserving Set-Raw* helpers. This test fails when a NEW file
# starts writing file content or a NEW cmdlet calls the raw writers, forcing a conscious review
# rather than silent drift. (Reads parse files freely; the contract is about writes.)

BeforeAll {
    $srcRoot = [System.IO.Path]::Combine($PSScriptRoot, '..', 'src')
    $script:srcFiles = Get-ChildItem -LiteralPath $srcRoot -Recurse -File -Filter *.ps1
}

Describe 'First-party tooling drift monitor' {
    It 'raw file-content writes live only in the sanctioned Set-Raw* helpers' {
        $writePattern = 'WriteAllText|WriteAllLines|Set-Content|Add-Content|Out-File|\.Save\('
        # Files allowed to write content directly:
        #   MSBuildImports.ps1 - IS the Set-Raw* helpers (the sanctioned solution/<Import>/script rewriters).
        #   Journal.ps1        - writes the repo-local undo journal and its self-.gitignore under
        #                        .netscoot/; a tool sidecar, never a solution/project file, so the
        #                        "no hand-writing project files" contract is unaffected.
        $sanctioned = @('MSBuildImports.ps1', 'Journal.ps1')
        $offenders = $srcFiles |
            Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match $writePattern } |
            Where-Object { $sanctioned -notcontains $_.Name } |
            ForEach-Object { $_.Name }
        $offenders | Should -BeNullOrEmpty -Because 'a new hand-write must use first-party tooling, or be added here with a rationale'
    }

    It 'only the sanctioned move cmdlets call the raw writers' {
        $callers = $srcFiles |
            Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'Set-Raw(ImportValue|FileReplacement)' } |
            ForEach-Object { $_.Name } | Sort-Object
        # MSBuildImports.ps1 defines them; the three movers below reconcile formats no CLI handles.
        $expected = @('MSBuildImports.ps1', 'Move-MSBuildImport.ps1', 'Move-PowerShellScript.ps1', 'Move-Solution.ps1') | Sort-Object
        $callers | Should -Be $expected -Because 'a new caller of the raw writers is new hand-writing; confirm no first-party tool covers it'
    }
}
