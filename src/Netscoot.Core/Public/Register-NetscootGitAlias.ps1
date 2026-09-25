function Register-NetscootGitAlias {
    <#
    .SYNOPSIS
        Opt-in: register a `git netscoot` alias pointing at Netscoot's forwarder. Sets a single
        reversible git-config line - it never edits PATH or installs anything.

    .DESCRIPTION
        Adds `alias.netscoot = !pwsh -NoProfile -File <forwarder>` to git config so
        `git netscoot <src> <dst>` works. The forwarder calls Invoke-Netscoot, which routes by
        target type to the right engine: the .NET project model (csproj/sln/props), Unity
        (.meta/.asmdef), PowerShell (.ps1/.psd1), or native C++ (.vcxproj). The alias runs
        `pwsh`, so it needs PowerShell 7 on PATH. Scope is your choice (repository-local or
        global). Undo with Unregister-NetscootGitAlias. The returned object's Command property
        holds the exact `git config` command, and -WhatIf previews the change.

    .PARAMETER Scope
        'Local' (this repository, default) or 'Global' (~/.gitconfig).

    .OUTPUTS
        Netscoot.GitAlias

    .EXAMPLE
        # Preview the change (changes nothing)
        Register-NetscootGitAlias -Scope Global -WhatIf
        # Register for this repository only (default scope is Local)
        Register-NetscootGitAlias
        # Register globally, in ~/.gitconfig
        Register-NetscootGitAlias -Scope Global

    .LINK
        Unregister-NetscootGitAlias
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
        try { Invoke-Git -Arguments @('config', $scopeFlag, 'alias.netscoot', $aliasValue) }
        catch {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new("git config failed (exit $LASTEXITCODE). For -Scope Local you must be inside a git repository."),
                    'GitConfigFailed', [System.Management.Automation.ErrorCategory]::InvalidOperation, $display))
            return
        }
        Write-Verbose "Registered: $display"
        Write-Host "Registered 'git netscoot' ($Scope). Try: git netscoot <src> <dst> --whatif   |  undo: Unregister-NetscootGitAlias -Scope $Scope" -ForegroundColor Green
    }

    [Netscoot.GitAlias]@{
        Alias      = 'netscoot'
        Scope      = $Scope
        Forwarder  = $forwarder
        Command    = $display
    }
}
