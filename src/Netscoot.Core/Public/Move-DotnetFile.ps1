function Move-DotnetFile {
    <#
    .SYNOPSIS
        Move a single managed .NET file and reconcile references, routing by extension to the
        right specialist. The front door for file moves in the .NET family.

    .DESCRIPTION
        Dispatches a managed .NET file to the right specialist by extension (see Output for the
        routing). Native (.vcxproj), PowerShell (.ps1/.psd1) and Unity assets are deliberately not
        handled here - use Move-NativeProject / Move-PowerShellScript / Move-PowerShellModule /
        Move-UnityAsset. -WhatIf/-Confirm/-Verbose propagate to the specialist; -Force and
        -RepositoryRoot/-NoBuild are forwarded where the specialist accepts them.

    .PARAMETER Path
        The .NET file to move. Accepts pipeline input (a path string or a Get-ChildItem/Get-Item item; other object types are rejected).

    .PARAMETER Destination
        New path (file or folder) - passed through to the specialist.

    .PARAMETER RepositoryRoot
        Repository root the specialist scans for references. Defaults to the enclosing git repository root.

    .PARAMETER NoBuild
        Skip the verifying 'dotnet build' (forwarded to the project/import specialist).

    .PARAMETER Force
        Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history.

    .PARAMETER NoJournal
        Skip recording this move in the undo journal for this call (forwarded to the specialist),
        even when journaling is enabled.

    .OUTPUTS
        The result object from the .NET specialist it routes to, by file extension.

    .EXAMPLE
        # A project file routes to Move-DotnetProject
        Move-DotnetFile -Path ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon
        # A solution routes to Move-Solution (rebases stored project paths)
        Move-DotnetFile -Path ./Demo.slnx -Destination ./build/Demo.slnx
        # A shared import routes to Move-MSBuildImport (fixes <Import> in consumers)
        Move-DotnetFile -Path ./Shared.props -Destination ./build/Shared.props
    #>

    # SupportsShouldProcess so -WhatIf/-Confirm bind and propagate to the specialist; this
    # dispatcher only routes (the specialist calls ShouldProcess), so suppress the rule here.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Delegates to a specialist cmdlet that calls ShouldProcess')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Netscoot.MoveResult', 'Netscoot.SolutionMoveResult', 'Netscoot.ImportMoveResult')]
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
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.IO.FileNotFoundException]::new("File not found: $Path"),
                    'FileNotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $Path))
            return
        }
        $ext = ([System.IO.Path]::GetExtension($full)).ToLowerInvariant()

        switch -regex ($ext) {
            '\.(cs|fs|vb)proj$' {
                $fwd = @{ Destination = $Destination }
                if ($PSBoundParameters.ContainsKey('RepositoryRoot')) { $fwd.RepositoryRoot = $RepositoryRoot }
                if ($Force) { $fwd.Force = $true }
                if ($NoBuild) { $fwd.NoBuild = $true }
                if ($NoJournal) { $fwd.NoJournal = $true }
                Write-Verbose "Routing $ext -> Move-DotnetProject"
                Move-DotnetProject -Project $full @fwd
            }
            '\.slnx?$' {
                $fwd = @{ Destination = $Destination }
                if ($Force) { $fwd.Force = $true }
                if ($NoJournal) { $fwd.NoJournal = $true }
                Write-Verbose "Routing $ext -> Move-Solution"
                Move-Solution -Path $full @fwd
            }
            '\.(props|targets)$' {
                $fwd = @{ Destination = $Destination }
                if ($PSBoundParameters.ContainsKey('RepositoryRoot')) { $fwd.RepositoryRoot = $RepositoryRoot }
                if ($Force) { $fwd.Force = $true }
                if ($NoJournal) { $fwd.NoJournal = $true }
                Write-Verbose "Routing $ext -> Move-MSBuildImport"
                Move-MSBuildImport -Path $full @fwd
            }
            default {
                $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                        [System.NotSupportedException]::new("Not a managed .NET file: $Path. Use Move-NativeProject (.vcxproj), Move-PowerShellScript (.ps1), Move-PowerShellModule (.psd1), or Move-UnityAsset."),
                        'NotADotnetFile', [System.Management.Automation.ErrorCategory]::InvalidArgument, $Path))
            }
        }
    }
}
