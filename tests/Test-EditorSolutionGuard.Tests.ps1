#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot TestHelpers.ps1)
    Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'src', 'Netscoot.Core', 'Netscoot.Core.psd1')) -Force

    # Build a repo with a .slnx and, optionally, raw .vscode/settings.json text and a .gitignore.
    # settings.json is written as RAW TEXT (not ConvertTo-Json) so tests can exercise JSONC.
    function New-GuardRepo {
        param([string]$SettingsJson, [string]$Gitignore, [switch]$NoSlnx)
        $root = New-TempRoot -Prefix 'netscoot_guard'
        & git -C $root init -q
        if (-not $NoSlnx) { Set-Content -LiteralPath (Join-Path $root 'App.slnx') -Value '<Solution></Solution>' -Encoding UTF8 }
        if ($PSBoundParameters.ContainsKey('SettingsJson')) {
            New-Item -ItemType Directory -Path (Join-Path $root '.vscode') | Out-Null
            Set-Content -LiteralPath (Join-Path $root (Join-Path '.vscode' 'settings.json')) -Value $SettingsJson -Encoding UTF8
        }
        if ($PSBoundParameters.ContainsKey('Gitignore')) {
            Set-Content -LiteralPath (Join-Path $root '.gitignore') -Value $Gitignore -Encoding UTF8
        }
        return $root
    }

    function _check($records, [string]$name) { @($records | Where-Object { $_.Check -eq $name })[0] }
}

Describe 'Test-EditorSolutionGuard' {
    It 'reports nothing when the repository has no .slnx (guard does not apply)' {
        $root = New-GuardRepo -NoSlnx
        try {
            @(Test-EditorSolutionGuard -RepositoryRoot $root -WarningAction SilentlyContinue).Count | Should -Be 0
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'all three checks pass when every guard is in place' {
        $json = '{ "dotnet.automaticallyCreateSolutionInWorkspace": false, "dotnet.defaultSolution": "App.slnx" }'
        $root = New-GuardRepo -SettingsJson $json -Gitignore "*.sln`n"
        try {
            $r = Test-EditorSolutionGuard -RepositoryRoot $root -WarningVariable w -WarningAction SilentlyContinue
            (_check $r 'AutoCreateGuard').Severity | Should -Be 'OK'
            (_check $r 'DefaultSolution').Severity | Should -Be 'OK'
            (_check $r 'GitignoreGuard').Severity  | Should -Be 'OK'
            $w | Should -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'warns when the auto-create guard is missing from settings.json' {
        $root = New-GuardRepo -SettingsJson '{ "editor.fontSize": 14 }' -Gitignore '*.sln'
        try {
            $r = Test-EditorSolutionGuard -RepositoryRoot $root -WarningAction SilentlyContinue
            (_check $r 'AutoCreateGuard').Severity | Should -Be 'Warning'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'warns when the auto-create guard is explicitly true' {
        $root = New-GuardRepo -SettingsJson '{ "dotnet.automaticallyCreateSolutionInWorkspace": true }' -Gitignore '*.sln'
        try {
            $r = Test-EditorSolutionGuard -RepositoryRoot $root -WarningAction SilentlyContinue
            (_check $r 'AutoCreateGuard').Severity | Should -Be 'Warning'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'treats a missing .vscode/settings.json as Info (cannot confirm VS Code usage), not Warning' {
        $root = New-GuardRepo -Gitignore '*.sln'   # no SettingsJson -> no .vscode dir
        try {
            $r = Test-EditorSolutionGuard -RepositoryRoot $root -WarningAction SilentlyContinue
            (_check $r 'AutoCreateGuard').Severity | Should -Be 'Info'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'warns when dotnet.defaultSolution points at a deleted/nonexistent file' {
        $json = '{ "dotnet.automaticallyCreateSolutionInWorkspace": false, "dotnet.defaultSolution": "Gone.slnx" }'
        $root = New-GuardRepo -SettingsJson $json -Gitignore '*.sln'
        try {
            $r = Test-EditorSolutionGuard -RepositoryRoot $root -WarningAction SilentlyContinue
            $d = _check $r 'DefaultSolution'
            $d.Severity | Should -Be 'Warning'
            $d.Detail | Should -Match 'Gone\.slnx'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'accepts dotnet.defaultSolution = "disable" as OK' {
        $json = '{ "dotnet.automaticallyCreateSolutionInWorkspace": false, "dotnet.defaultSolution": "disable" }'
        $root = New-GuardRepo -SettingsJson $json -Gitignore '*.sln'
        try {
            (_check (Test-EditorSolutionGuard -RepositoryRoot $root -WarningAction SilentlyContinue) 'DefaultSolution').Severity | Should -Be 'OK'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'flags a default that points at a legacy .sln as Info (repoint at the .slnx)' {
        $json = '{ "dotnet.automaticallyCreateSolutionInWorkspace": false, "dotnet.defaultSolution": "Legacy.sln" }'
        $root = New-GuardRepo -SettingsJson $json -Gitignore '*.sln'
        try {
            Set-Content -LiteralPath (Join-Path $root 'Legacy.sln') -Value 'Microsoft Visual Studio Solution File' -Encoding UTF8
            (_check (Test-EditorSolutionGuard -RepositoryRoot $root -WarningAction SilentlyContinue) 'DefaultSolution').Severity | Should -Be 'Info'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'emits GitignoreGuard Info when .gitignore lacks a *.sln rule, OK when present' {
        $json = '{ "dotnet.automaticallyCreateSolutionInWorkspace": false, "dotnet.defaultSolution": "App.slnx" }'
        $noGuard = New-GuardRepo -SettingsJson $json -Gitignore "bin/`nobj/`n"
        try { (_check (Test-EditorSolutionGuard -RepositoryRoot $noGuard -WarningAction SilentlyContinue) 'GitignoreGuard').Severity | Should -Be 'Info' }
        finally { Remove-Item -LiteralPath $noGuard -Recurse -Force -ErrorAction SilentlyContinue }

        $withGuard = New-GuardRepo -SettingsJson $json -Gitignore "bin/`n*.sln`n"
        try { (_check (Test-EditorSolutionGuard -RepositoryRoot $withGuard -WarningAction SilentlyContinue) 'GitignoreGuard').Severity | Should -Be 'OK' }
        finally { Remove-Item -LiteralPath $withGuard -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'parses JSONC settings (comments + trailing commas) rather than failing on them' {
        $jsonc = @'
{
  // keep the Dev Kit from re-minting a .sln
  "dotnet.automaticallyCreateSolutionInWorkspace": false,
  "dotnet.defaultSolution": "App.slnx", // the consolidated solution
}
'@
        $root = New-GuardRepo -SettingsJson $jsonc -Gitignore '*.sln'
        try {
            $r = Test-EditorSolutionGuard -RepositoryRoot $root -WarningVariable w -WarningAction SilentlyContinue
            (_check $r 'AutoCreateGuard').Severity | Should -Be 'OK'
            (_check $r 'DefaultSolution').Severity | Should -Be 'OK'
            $w | Should -BeNullOrEmpty
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'escalates Warning-level findings to non-terminating errors under -Strict' {
        $root = New-GuardRepo -SettingsJson '{ "dotnet.automaticallyCreateSolutionInWorkspace": true }' -Gitignore 'bin/'
        try {
            Test-EditorSolutionGuard -RepositoryRoot $root -Strict -ErrorVariable errs -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
            $errs | Should -Not -BeNullOrEmpty
            ($errs.FullyQualifiedErrorId -join ',') | Should -Match 'EditorGuard'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'accepts RepositoryRoot from the pipeline (Get-Item)' {
        $json = '{ "dotnet.automaticallyCreateSolutionInWorkspace": false, "dotnet.defaultSolution": "App.slnx" }'
        $root = New-GuardRepo -SettingsJson $json -Gitignore '*.sln'
        try {
            $r = Get-Item $root | Test-EditorSolutionGuard -WarningAction SilentlyContinue
            @($r).Count | Should -Be 3
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
