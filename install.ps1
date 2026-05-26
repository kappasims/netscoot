#requires -Version 5.1
<#
.SYNOPSIS
    Install or update DotnetMove from GitHub, no clone or git required. Re-run to update.

.DESCRIPTION
    Downloads a release's source zip, extracts it, and copies the modules onto your PowerShell
    module path (edition-aware), so `Import-Module DotnetMove` works by name. Running it again
    overwrites the installed copy with the chosen version - install and update are the same gesture.

    Designed to run straight from the web:
        irm https://raw.githubusercontent.com/kappasims/dotnet-move/master/install.ps1 | iex

    Not on the PowerShell Gallery yet; when it is, `Install-Module`/`Update-Module` replaces this.

.PARAMETER Version
    Semver to install (e.g. 1.1.0). Defaults to the latest GitHub release.

.PARAMETER InstallPath
    Target modules directory. Defaults to the CurrentUser module path for the running edition.

.PARAMETER Repository
    owner/name of the GitHub repository. Defaults to the project repository.

.EXAMPLE
    ./install.ps1
    Installs (or updates to) the latest release.

.EXAMPLE
    ./install.ps1 -Version 1.1.0
    Installs a specific version.
#>
[CmdletBinding()]
param(
    [string]$Version,
    [string]$InstallPath,
    [string]$Repository = 'kappasims/dotnet-move'
)

$ErrorActionPreference = 'Stop'
$headers = @{ 'User-Agent' = 'DotnetMove-Installer' }

function Test-IsWindowsHost {
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return $true }
    if (Test-Path Variable:\IsWindows) { return [bool](Get-Variable -Name IsWindows -ValueOnly) }
    return $false
}

# Resolve the tag: explicit -Version, else the latest release.
if ($Version) {
    $tag = 'v' + ($Version -replace '^v', '')
} else {
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/latest" -Headers $headers
    $tag = "$($rel.tag_name)"
    if (-not $tag) { throw "No releases found for $Repository." }
}
Write-Host "Installing DotnetMove $tag..." -ForegroundColor Cyan

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("dotnetmove_install_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $zip = Join-Path $tmp 'src.zip'
    Invoke-WebRequest -Uri "https://github.com/$Repository/archive/refs/tags/$tag.zip" -OutFile $zip -Headers $headers
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    $extracted = Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1   # <repo>-<version>/
    $srcRoot = Join-Path $extracted.FullName 'src'
    if (-not (Test-Path -LiteralPath $srcRoot)) { throw "Downloaded archive has no src/ folder: $srcRoot" }

    if (-not $InstallPath) {
        $InstallPath = if (Test-IsWindowsHost) {
            $editionDir = if ($PSVersionTable.PSEdition -eq 'Core') { 'PowerShell' } else { 'WindowsPowerShell' }
            Join-Path ([Environment]::GetFolderPath('MyDocuments')) (Join-Path $editionDir 'Modules')
        } else {
            Join-Path $HOME '.local/share/powershell/Modules'
        }
    }
    New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null

    # DotnetMove.Shared is the required dependency of the engines; install it alongside them.
    foreach ($name in 'DotnetMove.Shared', 'DotnetMove.Core', 'DotnetMove.Unity', 'DotnetMove.Native', 'DotnetMove') {
        $dest = Join-Path $InstallPath $name
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        Copy-Item -LiteralPath (Join-Path $srcRoot $name) -Destination $dest -Recurse -Force
    }
    Write-Host "Installed DotnetMove $tag to $InstallPath" -ForegroundColor Green
    Write-Host "    Import-Module DotnetMove" -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
