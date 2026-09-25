#requires -Modules Pester

# Drift monitor for the project's declared contract: moves never hand-WRITE solution/project
# files where first-party tooling works (dotnet sln / dotnet reference / git mv). The only
# sanctioned exceptions are formats no working tool reconciles - a solution's stored project paths,
# <Import> paths, native .vcxproj entries and references, and script paths - which are rewritten
# in place through Netscoot.StoredPath. This test fails when a NEW file starts writing file content
# or a NEW cmdlet rewrites stored paths, forcing a conscious review rather than silent drift.
# (Reads parse files freely; the contract is about writes.)

BeforeAll {
    $srcRoot = [System.IO.Path]::Combine($PSScriptRoot, '..', 'src')
    $script:srcFiles = Get-ChildItem -LiteralPath $srcRoot -Recurse -File -Filter *.ps1
}

Describe 'First-party tooling drift monitor' {
    It 'raw file-content writes live only in Netscoot.StoredPath and the journal' {
        $writePattern = 'WriteAllText|WriteAllLines|Set-Content|Add-Content|Out-File|\.Save\('
        # Files allowed to write content directly:
        #   StoredPath.ps1 - IS the sanctioned in-place path rewriter.
        #   Journal.ps1    - writes the per-user undo journal; a tool sidecar, never a solution/project file.
        $sanctioned = @('StoredPath.ps1', 'Journal.ps1')
        $offenders = $srcFiles |
            Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match $writePattern } |
            Where-Object { $sanctioned -notcontains $_.Name } |
            ForEach-Object { $_.Name }
        $offenders | Should -BeNullOrEmpty -Because 'a new hand-write must use first-party tooling, or be added here with a rationale'
    }

    It 'only the sanctioned move cmdlets rewrite stored paths' {
        $callers = $srcFiles |
            Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match '\.(PointAt|FollowFile)\(' } |
            ForEach-Object { $_.Name } | Sort-Object
        $expected = @('Move-MSBuildImport.ps1', 'Move-NativeProject.ps1', 'Move-PowerShellModule.ps1', 'Move-PowerShellScript.ps1', 'Move-Solution.ps1') | Sort-Object
        $callers | Should -Be $expected -Because 'a new caller is new in-place rewriting; confirm no first-party tool covers it'
    }
}
