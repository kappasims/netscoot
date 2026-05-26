function Register-DotnetMvGitAlias {
    <#
    .SYNOPSIS
        Opt-in: register a `git dotnetmv` alias pointing at DotnetMove's forwarder. Sets a single
        reversible git-config line - it never edits PATH or installs anything.

    .DESCRIPTION
        Adds `alias.dotnetmv = !pwsh -NoProfile -File <forwarder>` to git config so
        `git dotnetmv <src> <dst>` works. "dotnet" is the .NET-platform umbrella: the verb
        branches by target type to the right engine - the .NET project model
        (csproj/sln/props), Unity (.meta/.asmdef), PowerShell (.ps1/.psd1), or native C++
        (.vcxproj). Scope is your choice (repo-local or global). Undo with
        Unregister-DotnetMvGitAlias. Use -WhatIf to see the exact `git config` command.

    .PARAMETER Scope
        'Local' (this repo, default) or 'Global' (~/.gitconfig).

    .OUTPUTS
        A single DotnetMove.GitAlias object: Alias, Scope, Forwarder, and Command (all strings; the
        last is the git config command that was/would be run).

    .EXAMPLE
        Register-DotnetMvGitAlias -Scope Global -WhatIf

        Prints the exact git config command it would run, without changing anything.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [ValidateSet('Local', 'Global')]
        [string]$Scope = 'Local'
    )

    if (-not (Test-GitAvailable)) {
        Write-CapabilityGuidance -Tool git
        $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new('git is required to register a git alias but was not found.'),
                'GitMissing', [System.Management.Automation.ErrorCategory]::NotInstalled, $null))
        return
    }

    $moduleRoot = Split-Path -Parent $PSScriptRoot
    $forwarder = [System.IO.Path]::Combine($moduleRoot, 'tools', 'git-dotnetmv.ps1')
    if (-not (Test-Path -LiteralPath $forwarder)) {
        $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                [System.IO.FileNotFoundException]::new("Forwarder script not found: $forwarder"),
                'ForwarderMissing', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $forwarder))
        return
    }

    # Forward-slash path is safe for git's sh, on every OS.
    $aliasValue = "!pwsh -NoProfile -File `"$($forwarder -replace '\\', '/')`""
    $scopeFlag = if ($Scope -eq 'Global') { '--global' } else { '--local' }
    $display = "git config $scopeFlag alias.dotnetmv '$aliasValue'"

    if ($PSCmdlet.ShouldProcess("git config ($Scope)", "set alias.dotnetmv -> $forwarder")) {
        & git config $scopeFlag alias.dotnetmv $aliasValue
        if ($LASTEXITCODE -ne 0) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new("git config failed (exit $LASTEXITCODE). For -Scope Local you must be inside a git repo."),
                    'GitConfigFailed', [System.Management.Automation.ErrorCategory]::InvalidOperation, $display))
            return
        }
        Write-Verbose "Registered: $display"
        Write-Host "Registered 'git dotnetmv' ($Scope). Try: git dotnetmv <src> <dst> --whatif   |  undo: Unregister-DotnetMvGitAlias -Scope $Scope" -ForegroundColor Green
    }

    [pscustomobject]@{
        PSTypeName = 'DotnetMove.GitAlias'
        Alias      = 'dotnetmv'
        Scope      = $Scope
        Forwarder  = $forwarder
        Command    = $display
    }
}
