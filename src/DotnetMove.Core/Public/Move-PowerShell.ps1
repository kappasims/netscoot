function Move-PowerShell {
    <#
    .SYNOPSIS
        Move a PowerShell item and reconcile references, routing by type to the right
        specialist. The front door for PowerShell moves.

    .DESCRIPTION
        Dispatches by target type:
          - a .ps1 -> Move-PowerShellScript (fixes dot-source/call references, AST-based)
          - a .psd1 or module folder -> Move-PowerShellModule (reconciles the manifest)
        -WhatIf/-Confirm/-Verbose propagate to the specialist; -Force is forwarded, and
        -RepoRoot is forwarded to the script specialist (the module specialist has no RepoRoot).

    .PARAMETER Path
        The PowerShell item to move: a .ps1 script, a .psd1 manifest, or a module folder.
        Accepts pipeline input.

    .PARAMETER Destination
        New path - passed through to the specialist.

    .PARAMETER RepoRoot
        Repo root scanned for referencing scripts. Defaults to the enclosing git repo root.
        Forwarded to the script specialist only (the module specialist has no RepoRoot).

    .PARAMETER Force
        Proceed with a plain file move when git is unavailable instead of aborting. A plain
        move does not preserve git history.

    .OUTPUTS
        A single result object: a DotnetMove.ScriptMoveResult (.ps1) or DotnetMove.ModuleMoveResult
        (module); see Move-PowerShellScript / Move-PowerShellModule for the exact shape.

    .EXAMPLE
        Move-PowerShell -Path ./tools/Mayo -Destination ./modules/Mayo -WhatIf

        Detects a module folder and previews moving it, reconciling the .psd1 manifest.
    #>

    # SupportsShouldProcess so -WhatIf/-Confirm bind and propagate to the specialist; this
    # dispatcher only routes (the specialist calls ShouldProcess), so suppress the rule here.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Delegates to a specialist cmdlet that calls ShouldProcess')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName', 'PSPath')]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Destination,

        [string]$RepoRoot,
        [switch]$Force
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
            if ($PSBoundParameters.ContainsKey('RepoRoot')) { $fwd.RepoRoot = $RepoRoot }
            if ($Force) { $fwd.Force = $true }
            Write-Verbose 'Routing .ps1 -> Move-PowerShellScript'
            Move-PowerShellScript -Path $full @fwd
        }
        elseif ($isContainer -or $ext -eq '.psd1') {
            $fwd = @{ Destination = $Destination }
            if ($Force) { $fwd.Force = $true }
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
