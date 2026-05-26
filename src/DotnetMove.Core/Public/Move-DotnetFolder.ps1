function Move-DotnetFolder {
    <#
    .SYNOPSIS
        Move a folder of managed .NET projects, reconciling references. The front door for
        folder moves in the .NET family; delegates to Move-DotnetProjectTree (which handles a
        single project or many).

    .DESCRIPTION
        A folder move always goes through Move-DotnetProjectTree: it treats every managed
        project under the folder as one co-moving set and reconciles only the references that
        cross the folder boundary (internal references ride along unchanged). If the folder
        contains no managed projects, that specialist reports it. -WhatIf/-Confirm/-Verbose
        propagate; -Force/-RepoRoot/-NoBuild are forwarded.

    .PARAMETER Path
        The folder to move. Accepts pipeline input.

    .PARAMETER Destination
        New folder path.

    .PARAMETER RepoRoot
        Repository root scanned for references. Defaults to the enclosing git repository root.

    .PARAMETER NoBuild
        Skip the verifying 'dotnet build' (forwarded to Move-DotnetProjectTree).

    .PARAMETER Force
        Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.

    .PARAMETER NoJournal
        Skip recording this move in the undo journal for this call (forwarded to the specialist),
        even when journaling is enabled.

    .OUTPUTS
        DotnetMove.TreeMoveResult - from Move-DotnetProjectTree.

    .EXAMPLE
        # Preview moving a folder of .NET projects (delegates to the tree mover)
        Move-DotnetFolder -Path ./src/Group -Destination ./libs/Group -WhatIf
        # Move into an existing folder (lands at ./libs/Group)
        Move-DotnetFolder -Path ./src/Group -Destination ./libs
    #>

    # SupportsShouldProcess so -WhatIf/-Confirm bind and propagate to the specialist; this
    # dispatcher only routes (the specialist calls ShouldProcess), so suppress the rule here.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Delegates to a specialist cmdlet that calls ShouldProcess')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('DotnetMove.TreeMoveResult')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName', 'PSPath')]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Destination,

        [string]$RepoRoot,
        [switch]$NoBuild,
        [switch]$Force,
        [switch]$NoJournal
    )

    process {
        $full = Resolve-FullPath $Path
        if (-not (Test-Path -LiteralPath $full -PathType Container)) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.IO.DirectoryNotFoundException]::new("Folder not found: $Path"),
                    'FolderNotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $Path))
            return
        }
        $fwd = @{ Destination = $Destination }
        if ($PSBoundParameters.ContainsKey('RepoRoot')) { $fwd.RepoRoot = $RepoRoot }
        if ($Force) { $fwd.Force = $true }
        if ($NoBuild) { $fwd.NoBuild = $true }
        if ($NoJournal) { $fwd.NoJournal = $true }
        Write-Verbose "Routing folder -> Move-DotnetProjectTree"
        Move-DotnetProjectTree -Path $full @fwd
    }
}
