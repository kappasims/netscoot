# The dotnet executable netscoot runs: the stored path when one is set, otherwise the one on PATH.

function Get-NetscootSettingFile {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return [System.IO.Path]::Combine((Get-MoveJournalAppDataRoot), 'netscoot', 'settings.json')
}

function Get-StoredDotnetPath {
    # Returns $null when no path is stored.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $file = Get-NetscootSettingFile
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    $settings = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json
    $stored = $settings.PSObject.Properties['dotnetPath']
    if (-not $stored) { return $null }
    return [string]$stored.Value
}

function Save-StoredDotnetPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $file = Get-NetscootSettingFile
    $folder = Split-Path -Parent $file
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $json = [pscustomobject]@{ dotnetPath = $Path } | ConvertTo-Json
    [System.IO.File]::WriteAllText($file, $json, [System.Text.UTF8Encoding]::new($false))
}

function Remove-StoredDotnetPath {
    [CmdletBinding()]
    param()
    $file = Get-NetscootSettingFile
    if (Test-Path -LiteralPath $file -PathType Leaf) { Remove-Item -LiteralPath $file -Force }
}

function Get-ExternalToolVersion {
    # First line of the tool's version output, or $null when the probe fails (a dotnet host with no SDK).
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    # Ignore keeps Windows PowerShell 5.1 from recording the probe's stderr as an error, and the exit code decides.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Ignore'
    try { $out = @(& $Path --version 2>$null) }
    finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0) { return $null }
    return "$($out | Select-Object -First 1)".Trim()
}

function Resolve-DotnetCommand {
    # Returns { Path; Source } with Source 'Stored' or 'Path', or $null when neither gives a dotnet.
    [CmdletBinding()]
    param()
    $stored = Get-StoredDotnetPath
    if ($stored) {
        if (-not (Test-Path -LiteralPath $stored -PathType Leaf)) {
            throw "The stored dotnet path '$stored' does not exist. Store the one to use with Set-NetscootDotnetPath, or remove the stored path with Clear-NetscootDotnetPath."
        }
        return [pscustomobject]@{ Path = $stored; Source = 'Stored' }
    }
    $onPath = Get-Command dotnet -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { return [pscustomobject]@{ Path = $onPath.Source; Source = 'Path' } }
    return $null
}

function Find-DotnetInstall {
    # The .NET SDK installs on this machine, read from where an install records or documents itself, newest first.
    [CmdletBinding()]
    param()
    $onWindows = Test-IsWindowsHost
    $candidates = [System.Collections.Generic.List[object]]::new()

    foreach ($name in 'DOTNET_ROOT', 'DOTNET_ROOT(x86)') {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { $candidates.Add([pscustomobject]@{ Folder = $value; FoundIn = $name }) }
    }

    if ($onWindows) {
        foreach ($key in 'HKLM:\SOFTWARE\dotnet\Setup\InstalledVersions', 'HKLM:\SOFTWARE\WOW6432Node\dotnet\Setup\InstalledVersions') {
            if (-not (Test-Path -LiteralPath $key)) { continue }
            foreach ($arch in (Get-ChildItem -LiteralPath $key)) {
                $location = $arch.GetValue('InstallLocation')
                if ($location) { $candidates.Add([pscustomobject]@{ Folder = [string]$location; FoundIn = 'Registry' }) }
            }
        }
        foreach ($folder in @(
                $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'dotnet' }),
                $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'dotnet' }),
                $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA (Join-Path 'Microsoft' 'dotnet') }))) {
            if ($folder) { $candidates.Add([pscustomobject]@{ Folder = $folder; FoundIn = 'DefaultFolder' }) }
        }
    } else {
        if (Test-Path -LiteralPath '/etc/dotnet' -PathType Container) {
            foreach ($record in (Get-ChildItem -LiteralPath '/etc/dotnet' -Filter 'install_location*' -File)) {
                $location = Get-Content -LiteralPath $record.FullName -TotalCount 1
                if ($location) { $candidates.Add([pscustomobject]@{ Folder = "$location".Trim(); FoundIn = $record.Name }) }
            }
        }
        foreach ($folder in '/usr/local/share/dotnet', '/usr/share/dotnet', '/usr/lib/dotnet', '/usr/lib64/dotnet', (Join-Path $HOME '.dotnet')) {
            $candidates.Add([pscustomobject]@{ Folder = $folder; FoundIn = 'DefaultFolder' })
        }
    }

    $leaf = if ($onWindows) { 'dotnet.exe' } else { 'dotnet' }
    $seen = [System.Collections.Generic.List[string]]::new()
    $installs = foreach ($candidate in $candidates) {
        $exe = [System.IO.Path]::GetFullPath((Join-Path $candidate.Folder $leaf))
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { continue }
        if (Test-PathInList -Path $exe -List $seen) { continue }
        $seen.Add($exe)
        $version = Get-ExternalToolVersion -Path $exe
        if (-not $version) { continue }
        [pscustomobject]@{ PSTypeName = 'Netscoot.DotnetInstall'; Version = $version; Path = $exe; FoundIn = $candidate.FoundIn }
    }
    @($installs) | Sort-Object -Descending -Property { [version]($_.Version -replace '-.*$', '') }
}

function Test-InteractiveSession {
    # False when nobody can answer a prompt: a service, a redirected input, or a host started non-interactive.
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not [Environment]::UserInteractive) { return $false }
    if ([Console]::IsInputRedirected) { return $false }
    foreach ($argument in [Environment]::GetCommandLineArgs()) {
        if ($argument -match '^[-/]noni') { return $false }
    }
    return $true
}

function Read-DotnetInstallChoice {
    # Asks which install to use. Returns the chosen install, or $null when the user declines.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet,
        [Parameter(Mandatory)][object[]]$Installs
    )
    $afterwards = "netscoot stores the path you choose and uses it for every later command.`n" +
        "Set-NetscootDotnetPath changes it, and Clear-NetscootDotnetPath removes it."
    $choices = [System.Collections.ObjectModel.Collection[System.Management.Automation.Host.ChoiceDescription]]::new()

    if ($Installs.Count -eq 1) {
        $only = $Installs[0]
        $message = "Moving a .NET project needs the .NET SDK. netscoot found one install:`n`n" +
            "  .NET SDK $($only.Version)   $($only.Path)`n`n" +
            "$afterwards`n`nUse this install?"
        $choices.Add([System.Management.Automation.Host.ChoiceDescription]::new('&Yes', 'Use this install and store its path.'))
        $choices.Add([System.Management.Automation.Host.ChoiceDescription]::new('&No', 'Stop the move and store nothing.'))
        $answer = $Cmdlet.Host.UI.PromptForChoice('dotnet is not on PATH', $message, $choices, 0)
        if ($answer -eq 0) { return $only }
        return $null
    }

    $lines = for ($i = 0; $i -lt $Installs.Count; $i++) {
        "[$($i + 1)] .NET SDK $($Installs[$i].Version)   $($Installs[$i].Path)"
        $choices.Add([System.Management.Automation.Host.ChoiceDescription]::new("&$($i + 1)", $Installs[$i].Path))
    }
    $choices.Add([System.Management.Automation.Host.ChoiceDescription]::new('&None of these', 'Stop the move and store nothing.'))
    $message = "Moving a .NET project needs the .NET SDK. netscoot found these installs:`n`n" +
        "$($lines -join "`n")`n`n" +
        "$afterwards`n`nWhich install should netscoot use?"
    $answer = $Cmdlet.Host.UI.PromptForChoice('dotnet is not on PATH', $message, $choices, -1)
    if ($answer -ge 0 -and $answer -lt $Installs.Count) { return $Installs[$answer] }
    return $null
}
