function Register-ScootGitAlias {
    <#
    .SYNOPSIS
        Opt-in: register a `git netscoot` alias pointing at Netscoot's forwarder. Sets a single
        reversible git-config line - it never edits PATH or installs anything.

    .DESCRIPTION
        Adds `alias.netscoot = !pwsh -NoProfile -File <forwarder>` to git config so
        `git netscoot <src> <dst>` works. "dotnet" is the .NET-platform umbrella: the verb
        branches by target type to the right engine - the .NET project model
        (csproj/sln/props), Unity (.meta/.asmdef), PowerShell (.ps1/.psd1), or native C++
        (.vcxproj). Scope is your choice (repository-local or global). Undo with
        Unregister-ScootGitAlias. Use -WhatIf to see the exact `git config` command.

    .PARAMETER Scope
        'Local' (this repository, default) or 'Global' (~/.gitconfig).

    .OUTPUTS
        Netscoot.GitAlias

    .EXAMPLE
        # Preview the exact git config command (changes nothing)
        Register-ScootGitAlias -Scope Global -WhatIf
        # Register for this repository only (default scope is Local)
        Register-ScootGitAlias
        # Register globally, in ~/.gitconfig
        Register-ScootGitAlias -Scope Global
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType('Netscoot.GitAlias')]
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
    $forwarder = [System.IO.Path]::Combine($moduleRoot, 'tools', 'git-netscoot.ps1')
    if (-not (Test-Path -LiteralPath $forwarder)) {
        $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                [System.IO.FileNotFoundException]::new("Forwarder script not found: $forwarder"),
                'ForwarderMissing', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $forwarder))
        return
    }

    # Forward-slash path is safe for git's sh, on every OS.
    $aliasValue = "!pwsh -NoProfile -File `"$($forwarder -replace '\\', '/')`""
    $scopeFlag = if ($Scope -eq 'Global') { '--global' } else { '--local' }
    $display = "git config $scopeFlag alias.netscoot '$aliasValue'"

    if ($PSCmdlet.ShouldProcess("git config ($Scope)", "set alias.netscoot -> $forwarder")) {
        & git config $scopeFlag alias.netscoot $aliasValue
        if ($LASTEXITCODE -ne 0) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new("git config failed (exit $LASTEXITCODE). For -Scope Local you must be inside a git repository."),
                    'GitConfigFailed', [System.Management.Automation.ErrorCategory]::InvalidOperation, $display))
            return
        }
        Write-Verbose "Registered: $display"
        Write-Host "Registered 'git netscoot' ($Scope). Try: git netscoot <src> <dst> --whatif   |  undo: Unregister-ScootGitAlias -Scope $Scope" -ForegroundColor Green
    }

    [pscustomobject]@{
        PSTypeName = 'Netscoot.GitAlias'
        Alias      = 'netscoot'
        Scope      = $Scope
        Forwarder  = $forwarder
        Command    = $display
    }
}
