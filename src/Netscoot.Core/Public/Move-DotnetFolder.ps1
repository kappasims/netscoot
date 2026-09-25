function Move-DotnetFolder {
    <#
    .SYNOPSIS
        Move a folder of managed .NET projects, reconciling references. The front door for
        folder moves in the .NET family; delegates to Move-DotnetProjectTree (which handles a
        single project or many).

    .DESCRIPTION
        A folder move always goes through Move-DotnetProjectTree: It treats every managed
        project under the folder as one co-moving set and reconciles only the references that
        cross the folder boundary (internal references ride along unchanged). If the folder
        contains no managed projects, that specialist reports it. A .vcxproj in the folder moves
        with it without its references being updated, and the move warns. -WhatIf/-Confirm/-Verbose
        propagate; -Force/-RepositoryRoot/-NoBuild are forwarded.

    .PARAMETER Path
        The folder to move. Accepts pipeline input (a path string or a Get-ChildItem/Get-Item item; other object types are rejected).

    .PARAMETER Destination
        New folder path, following `git mv` rules (an existing directory means move into it,
        otherwise it is the new path); passed through to Move-DotnetProjectTree.

    .PARAMETER RepositoryRoot
        Repository root scanned for references. Defaults to the enclosing git repository root.

    .PARAMETER NoBuild
        Skip the verifying 'dotnet build' (forwarded to Move-DotnetProjectTree).

    .PARAMETER Force
        When git is not installed, move with a plain PowerShell `Move-Item` without asking first.
        Without -Force it asks before falling back. The plain move does not preserve git history.

    .PARAMETER NoJournal
        Skip recording this move in the undo journal for this call (forwarded to the specialist),
        even when journaling is enabled.

    .OUTPUTS
        Netscoot.TreeMoveResult - from Move-DotnetProjectTree.

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
    [OutputType('Netscoot.TreeMoveResult')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [Netscoot.PathInputTransform()]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Destination,

        [string]$RepositoryRoot,
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
        # Move-DotnetProjectTree takes -Path; just substitute the resolved $full for the raw input.
        $fwd = New-ForwardArgs $PSBoundParameters -Add @{ Path = $full }
        Write-Verbose "Routing folder -> Move-DotnetProjectTree"
        Move-DotnetProjectTree @fwd
    }
}
