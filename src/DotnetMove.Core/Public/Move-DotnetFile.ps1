function Move-DotnetFile {
    <#
    .SYNOPSIS
        Move a single managed .NET file and reconcile references, routing by extension to the
        right specialist. The front door for file moves in the .NET family.

    .DESCRIPTION
        Dispatches by extension: .csproj/.fsproj/.vbproj to Move-DotnetProject, .sln/.slnx to
        Move-Solution, and .props/.targets to Move-MSBuildImport.
        Native (.vcxproj), PowerShell (.ps1/.psd1) and Unity assets are deliberately not
        handled here - use Move-NativeProject / Move-PowerShellScript / Move-PowerShellModule /
        Move-UnityAsset. -WhatIf/-Confirm/-Verbose propagate to the specialist; -Force and
        -RepoRoot/-NoBuild are forwarded where the specialist accepts them.

    .PARAMETER Path
        The .NET file to move. Accepts pipeline input.

    .PARAMETER Destination
        New path (file or folder) - passed through to the specialist.

    .PARAMETER RepoRoot
        Repo root the specialist scans for references. Defaults to the enclosing git repo root.

    .PARAMETER NoBuild
        Skip the verifying 'dotnet build' (forwarded to the project/import specialist).

    .PARAMETER Force
        Proceed with a plain file move when git is unavailable instead of aborting. A plain
        move does not preserve git history.

    .OUTPUTS
        A single result object from the .NET specialist it routes to: a DotnetMove.MoveResult,
        DotnetMove.SolutionMoveResult, or DotnetMove.ImportMoveResult (see Move-DotnetProject,
        Move-Solution, or Move-MSBuildImport for the exact shape).

    .EXAMPLE
        Move-DotnetFile -Path ./Demo.slnx -Destination ./build/Demo.slnx

        Routes the .slnx to Move-Solution and rebases its stored project paths.
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
        [switch]$NoBuild,
        [switch]$Force
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
                if ($PSBoundParameters.ContainsKey('RepoRoot')) { $fwd.RepoRoot = $RepoRoot }
                if ($Force) { $fwd.Force = $true }
                if ($NoBuild) { $fwd.NoBuild = $true }
                Write-Verbose "Routing $ext -> Move-DotnetProject"
                Move-DotnetProject -Project $full @fwd
            }
            '\.slnx?$' {
                $fwd = @{ Destination = $Destination }
                if ($Force) { $fwd.Force = $true }
                Write-Verbose "Routing $ext -> Move-Solution"
                Move-Solution -Path $full @fwd
            }
            '\.(props|targets)$' {
                $fwd = @{ Destination = $Destination }
                if ($PSBoundParameters.ContainsKey('RepoRoot')) { $fwd.RepoRoot = $RepoRoot }
                if ($Force) { $fwd.Force = $true }
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
