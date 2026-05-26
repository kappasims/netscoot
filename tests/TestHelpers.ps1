# Shared test fixtures. `dotnet new classlib/console` dominates suite time (template engine +
# restore, ~1-2s each), so these write the equivalent minimal SDK projects as text instantly.
# They build and behave identically for `dotnet sln add` / `dotnet add reference` / `dotnet build`.
# Mirrors `dotnet new <tmpl> -n <Name> -o <Directory>`: creates <Directory>/<Name>.csproj and
# returns that path.

# The engine modules declare DotnetMove.Shared in RequiredModules; load it (by path) up front so a
# test that imports an engine from src can resolve that dependency. Dot-source this helper before
# importing any engine module.
Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'src', 'DotnetMove.Shared', 'DotnetMove.Shared.psd1')) -Force -Global

function New-TempRoot {
    # Create a throwaway temp directory and return its CANONICAL path. On macOS the temp root
    # /var/folders/... is a symlink to /private/var/folders/...; if a fixture used the /var form,
    # git and `dotnet sln` (which canonicalize) would store cross-boundary relative paths and the
    # reconciliation would mismatch. Resolving it up front keeps every path in one form.
    param([string]$Prefix = 'dotnetmove')
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ($Prefix + '_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $d | Out-Null
    if (($PSVersionTable.PSEdition -eq 'Core') -and -not $IsWindows) {
        $real = (& realpath $d 2>$null)
        if ($LASTEXITCODE -eq 0 -and $real) { return ("$real").Trim() }
    }
    return $d
}

function New-StubClassLib {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Directory)
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $csproj = Join-Path $Directory "$Name.csproj"
    Set-Content -LiteralPath $csproj -Encoding UTF8 -Value @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
  </PropertyGroup>
</Project>
'@
    Set-Content -LiteralPath (Join-Path $Directory 'Class1.cs') -Encoding UTF8 -Value "namespace $Name { public class Class1 { } }"
    return $csproj
}

function New-StubConsole {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Directory)
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $csproj = Join-Path $Directory "$Name.csproj"
    Set-Content -LiteralPath $csproj -Encoding UTF8 -Value @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
  </PropertyGroup>
</Project>
'@
    Set-Content -LiteralPath (Join-Path $Directory 'Program.cs') -Encoding UTF8 -Value 'System.Console.WriteLine("ok");'
    return $csproj
}
