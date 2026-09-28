function Test-GitAvailable {
    [CmdletBinding()] param()
    return [bool](Get-Command git -CommandType Application -ErrorAction SilentlyContinue)
}

function Test-DotnetAvailable {
    [CmdletBinding()] param()
    return [bool](Resolve-DotnetCommand)
}

function Get-ExternalTool {
    # Presence, version, path and source (Stored or Path) of an external command.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $found = if ($Name -eq 'dotnet') { Resolve-DotnetCommand } else {
        $onPath = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($onPath) { [pscustomobject]@{ Path = $onPath.Source; Source = 'Path' } }
    }
    if (-not $found) { return [pscustomobject]@{ Present = $false; Version = $null; Path = $null; Source = $null } }
    $version = Get-ExternalToolVersion -Path $found.Path
    if (-not $version) {
        # A dotnet host with no SDK installed is present but cannot report a version.
        Write-Warning "$Name was found at $($found.Path), but it could not report its version."
    }
    return [pscustomobject]@{ Present = $true; Version = "$version"; Path = $found.Path; Source = $found.Source }
}

function Write-CapabilityGuidance {
    # Red, copy-pasteable remediation. We never auto-install; this is guidance only.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('git', 'dotnet')][string]$Tool,
        # The dotnet installs found on the machine, when the tool is dotnet.
        [object[]]$Installs = @()
    )
    $lines = switch ($Tool) {
        'git' {
            @('git was not found on PATH. netscoot can fall back to a plain move (PowerShell `Move-Item`), but file',
              'history will not be preserved. To install git:',
              '  Windows : winget install Git.Git    (or: choco install git / scoop install git)',
              '  macOS   : brew install git',
              '  Linux   : sudo apt install git      (or your distro package manager)')
        }
        'dotnet' {
            if (@($Installs).Count) {
                @('dotnet is not on PATH. netscoot found these installs:', '') +
                @($Installs | ForEach-Object { "  .NET SDK $($_.Version)   $($_.Path)" }) +
                @('', 'Store the one to use, then run the command again:',
                  "  Set-NetscootDotnetPath -Path '$(if (@($Installs).Count -eq 1) { $Installs[0].Path } else { '<path>' })'")
            } else {
                @('The .NET SDK was not found. Moving a .NET project needs it.', '',
                  'To install it:',
                  '  Windows : winget install Microsoft.DotNet.SDK.10',
                  '  macOS   : brew install --cask dotnet-sdk',
                  '  Linux   : https://learn.microsoft.com/dotnet/core/install/linux', '',
                  'Already installed somewhere netscoot did not look?',
                  "  Set-NetscootDotnetPath -Path '<path to dotnet>'")
            }
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
    # Required tool. When dotnet is missing, a person at a terminal is asked which install to store.
    # Otherwise this prints guidance and writes an error. Returns $true when dotnet can be run.
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet)
    if (Test-DotnetAvailable) { return $true }
    $installs = @(Find-DotnetInstall)
    $bound = $Cmdlet.MyInvocation.BoundParameters
    $previewing = $bound.ContainsKey('WhatIf') -and [bool]$bound['WhatIf']
    if ($installs.Count -and (-not $previewing) -and (Test-InteractiveSession)) {
        $chosen = Read-DotnetInstallChoice -Cmdlet $Cmdlet -Installs $installs
        if ($chosen) {
            Save-StoredDotnetPath -Path $chosen.Path
            Write-Host "netscoot will use $($chosen.Path) from now on." -ForegroundColor DarkGray
            return $true
        }
    }
    Write-CapabilityGuidance -Tool dotnet -Installs $installs
    $Cmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new('The .NET SDK (dotnet) is required for this command, but it is not on PATH and no path to it is stored.'),
            'DotnetMissing', [System.Management.Automation.ErrorCategory]::NotInstalled, $null))
    return $false
}
