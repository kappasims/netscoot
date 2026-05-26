function Test-GitAvailable {
    [CmdletBinding()] param()
    return [bool](Get-Command git -CommandType Application -ErrorAction SilentlyContinue)
}

function Test-DotnetAvailable {
    [CmdletBinding()] param()
    return [bool](Get-Command dotnet -CommandType Application -ErrorAction SilentlyContinue)
}

function Get-ExternalTool {
    # Presence + first --version line + resolved path for an external command.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { return [pscustomobject]@{ Present = $false; Version = $null; Path = $null } }
    $ver = $null
    try { $ver = (& $Name --version 2>$null | Select-Object -First 1) } catch { Write-Verbose "version probe failed for ${Name}: $_" }
    return [pscustomobject]@{ Present = $true; Version = "$ver".Trim(); Path = $cmd.Source }
}

function Write-CapabilityGuidance {
    # Red, copy-pasteable remediation. We never auto-install; this is guidance only.
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('git', 'dotnet')][string]$Tool)
    $lines = switch ($Tool) {
        'git' {
            @('git was not found on PATH. DotnetMove can fall back to a plain move (PowerShell `Move-Item`), but file',
              'history will not be preserved. To install git:',
              '  Windows : winget install Git.Git    (or: choco install git / scoop install git)',
              '  macOS   : brew install git',
              '  Linux   : sudo apt install git      (or your distro package manager)')
        }
        'dotnet' {
            @('The .NET SDK (dotnet) was not found on PATH. It is required for .NET project',
              'moves (DotnetMove delegates to dotnet sln / dotnet reference). To install:',
              '  Windows : winget install Microsoft.DotNet.SDK.10',
              '  macOS   : brew install --cask dotnet-sdk',
              '  Linux   : see https://learn.microsoft.com/dotnet/core/install/linux')
        }
    }
    foreach ($l in $lines) { Write-Host $l -ForegroundColor Red }
}

function Resolve-GitUsage {
    # Returns 'Git' (use git mv), 'Fallback' (plain move, confirmed), or 'Abort'.
    # On missing git: emit red guidance, then ShouldContinue unless -Force.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet,
        [switch]$Force
    )
    if (Test-GitAvailable) { return 'Git' }
    Write-CapabilityGuidance -Tool git
    if ($Force -or $Cmdlet.ShouldContinue(
            'Proceed with a plain move via Move-Item (file history will not be preserved)?',
            'git not found on PATH')) {
        return 'Fallback'
    }
    return 'Abort'
}

function Assert-DotnetAvailable {
    # Required tool: on missing, emit red guidance and write a terminating-style error
    # via the calling cmdlet. Returns $true if present, $false (and writes error) if not.
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet)
    if (Test-DotnetAvailable) { return $true }
    Write-CapabilityGuidance -Tool dotnet
    $Cmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new('The .NET SDK (dotnet) is required for this command but was not found on PATH.'),
            'DotnetMissing', [System.Management.Automation.ErrorCategory]::NotInstalled, $null))
    return $false
}
