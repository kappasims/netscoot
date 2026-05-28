Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared, cross-cutting helpers consumed by the engine modules (Core/Unity/Native); the umbrella
# loads this -Global before them. Split into Common (platform/paths/git/plan/capability) and Dotnet
# (the .NET/MSBuild helpers). Every function defined here is exported so the engines can call it.
# [IO.Path]::Combine (not multi-arg Join-Path) so this loads on Windows PowerShell 5.1 too.
$loaded = foreach ($tier in 'Common', 'Dotnet') {
    foreach ($f in (Get-ChildItem -Path ([System.IO.Path]::Combine($PSScriptRoot, $tier)) -Filter '*.ps1' -ErrorAction SilentlyContinue)) {
        . $f.FullName
        $f
    }
}

# Export every function the dot-sourced files defined.
$names = $loaded | ForEach-Object {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$null)
    $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) | ForEach-Object { $_.Name }
}
Export-ModuleMember -Function $names
