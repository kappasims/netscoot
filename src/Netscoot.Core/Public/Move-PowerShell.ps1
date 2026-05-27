function Move-PowerShell {
    <#
    .SYNOPSIS
        Move a PowerShell item and reconcile references, routing by type to the right
        specialist. The front door for PowerShell moves.

    .DESCRIPTION
        Dispatches a PowerShell item to the right specialist by type (see Output for the routing):
        the script specialist fixes dot-source/call references (AST-based), the module specialist
        reconciles the manifest. -WhatIf/-Confirm/-Verbose propagate to the specialist; -Force is
        forwarded, and -RepositoryRoot is forwarded to the script specialist (the module specialist has
        no RepositoryRoot).

    .PARAMETER Path
        The PowerShell item to move: a .ps1 script, a .psd1 manifest, or a module folder.
        Accepts pipeline input.

    .PARAMETER Destination
        New path - passed through to the specialist.

    .PARAMETER RepositoryRoot
        Repository root scanned for referencing scripts. Defaults to the enclosing git repository root.
        Forwarded to the script specialist only (the module specialist has no RepositoryRoot).

    .PARAMETER Force
        Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.

    .PARAMETER NoJournal
        Skip recording this move in the undo journal for this call (forwarded to the specialist),
        even when journaling is enabled.

    .OUTPUTS
        The result object from the PowerShell specialist it routes to, by item type.

    .EXAMPLE
        # A .ps1 routes to the script mover (fixes dot-source/call references)
        Move-PowerShell -Path ./lib/helpers.ps1 -Destination ./shared/helpers.ps1 -WhatIf
        # A module folder (or its .psd1) routes to the module mover (reconciles the manifest)
        Move-PowerShell -Path ./tools/Mayo -Destination ./modules/Mayo
        # Destination is an existing folder -> the script lands at ./shared/helpers.ps1
        Move-PowerShell -Path ./lib/helpers.ps1 -Destination ./shared
    #>

    # SupportsShouldProcess so -WhatIf/-Confirm bind and propagate to the specialist; this
    # dispatcher only routes (the specialist calls ShouldProcess), so suppress the rule here.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Delegates to a specialist cmdlet that calls ShouldProcess')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Netscoot.ScriptMoveResult', 'Netscoot.PSModuleMoveResult')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName', 'PSPath')]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Destination,

        [string]$RepositoryRoot,
        [switch]$Force,
        [switch]$NoJournal
    )

    process {
        $full = Resolve-FullPath $Path
        if (-not (Test-Path -LiteralPath $full)) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.IO.FileNotFoundException]::new("Path not found: $Path"),
                    'PathNotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $Path))
            return
        }

        $isContainer = Test-Path -LiteralPath $full -PathType Container
        $ext = ([System.IO.Path]::GetExtension($full)).ToLowerInvariant()

        if (-not $isContainer -and $ext -eq '.ps1') {
            $fwd = @{ Destination = $Destination }
            if ($PSBoundParameters.ContainsKey('RepositoryRoot')) { $fwd.RepositoryRoot = $RepositoryRoot }
            if ($Force) { $fwd.Force = $true }
            if ($NoJournal) { $fwd.NoJournal = $true }
            Write-Verbose 'Routing .ps1 -> Move-PowerShellScript'
            Move-PowerShellScript -Path $full @fwd
        }
        elseif ($isContainer -or $ext -eq '.psd1') {
            $fwd = @{ Destination = $Destination }
            if ($Force) { $fwd.Force = $true }
            if ($NoJournal) { $fwd.NoJournal = $true }
            Write-Verbose 'Routing module -> Move-PowerShellModule'
            Move-PowerShellModule -ModulePath $full @fwd
        }
        else {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.NotSupportedException]::new("Not a PowerShell item: $Path. Expected a .ps1 script, a .psd1 manifest, or a module folder."),
                    'NotAPowerShellItem', [System.Management.Automation.ErrorCategory]::InvalidArgument, $Path))
        }
    }
}
