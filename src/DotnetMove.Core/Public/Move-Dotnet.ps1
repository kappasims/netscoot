function Move-Dotnet {
    <#
    .SYNOPSIS
        Move any supported item and reconcile references, routing by detected type to the right
        per-namespace front door. The single top-level entry point (the `git dotnetmv` alias
        calls this).

    .DESCRIPTION
        Classifies the target with Resolve-MoveEngine, then dispatches to the namespace front
        door, which performs the appropriate file/folder move:
          - managed .NET (.csproj/.fsproj/.vbproj/.sln/.slnx/.props/.targets, or a folder of
            them) -> Move-DotnetFile / Move-DotnetFolder
          - PowerShell (.ps1/.psd1/module folder) -> Move-PowerShell
          - Unity (under Assets/Packages, .meta-paired, .asmdef/.asmref) -> Move-UnityAsset
            (loads DotnetMove.Unity on demand)
          - native C++ (.vcxproj) -> Move-NativeProject (loads DotnetMove.Native on demand)

        "dotnet" here is the .NET-platform umbrella (CLR/CoreCLR), not just the dotnet CLI - the
        verb spans every engine. Each engine's behavior lives in its own cmdlet; this only routes.
        -WhatIf/-Confirm/-Verbose propagate; -Force/-RepoRoot/-NoBuild are forwarded where the
        target's engine accepts them.

    .PARAMETER Path
        The item to move (file or folder). Accepts pipeline input.

    .PARAMETER Destination
        New path - passed through to the engine.

    .PARAMETER RepoRoot
        Repo root the engine scans for references. Defaults to the enclosing git repo root.
        Not used by the Unity engine.

    .PARAMETER NoBuild
        Skip the verifying 'dotnet build'. Only the .NET engine builds; ignored by the others.

    .PARAMETER Force
        Proceed with a plain file move when git is unavailable instead of aborting. A plain
        move does not preserve git history. Forwarded to the engine.

    .OUTPUTS
        A single move-result object from the engine it routes to (its concrete type and properties
        vary by engine; see that engine's command for the exact shape).

    .EXAMPLE
        Move-Dotnet -Path ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon -WhatIf

        Detects the .NET engine and previews moving Tarragon into libs/; nothing changes.
    #>

    # SupportsShouldProcess so -WhatIf/-Confirm bind and propagate to the engine; this dispatcher
    # only routes (the engine cmdlet calls ShouldProcess), so suppress the rule here.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Delegates to an engine cmdlet that calls ShouldProcess')]
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
        if (-not (Test-Path -LiteralPath $full)) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.IO.FileNotFoundException]::new("Path not found: $Path"),
                    'PathNotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $Path))
            return
        }

        $isContainer = Test-Path -LiteralPath $full -PathType Container
        $engine = Resolve-MoveEngine $full

        # Common forwardables; an engine that lacks a parameter simply isn't given it.
        $common = @{ Destination = $Destination }
        if ($Force) { $common.Force = $true }
        if ($PSBoundParameters.ContainsKey('RepoRoot')) { $common.RepoRoot = $RepoRoot }
        # Forward -WhatIf/-Confirm explicitly: $ConfirmPreference/$WhatIfPreference do not reliably
        # inherit into cmdlets in the sibling engine modules (Unity/Native), so an unforwarded
        # High-impact ShouldProcess would prompt - and hang a non-interactive caller such as the
        # git alias, which passes -Confirm:$false.
        foreach ($sw in 'WhatIf', 'Confirm') {
            if ($PSBoundParameters.ContainsKey($sw)) { $common[$sw] = $PSBoundParameters[$sw] }
        }

        Write-Verbose "Move-Dotnet: engine=$engine container=$isContainer target=$full"
        switch ($engine) {
            'dotnet' {
                if ($NoBuild) { $common.NoBuild = $true }
                if ($isContainer) { Move-DotnetFolder -Path $full @common } else { Move-DotnetFile -Path $full @common }
            }
            { $_ -in 'ps-script', 'ps-module' } {
                Move-PowerShell -Path $full @common
            }
            'unity' {
                if (-not (Import-MoveEngine -Name 'DotnetMove.Unity')) {
                    $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                            [System.InvalidOperationException]::new('The Unity engine needs DotnetMove.Unity, which is not available. Install or enable it, then retry.'),
                            'UnityEngineUnavailable', [System.Management.Automation.ErrorCategory]::NotInstalled, $full))
                    return
                }
                # Move-UnityAsset handles file and folder; it has no -RepoRoot/-NoBuild.
                $u = @{ Destination = $Destination }
                if ($Force) { $u.Force = $true }
                foreach ($sw in 'WhatIf', 'Confirm') { if ($common.ContainsKey($sw)) { $u[$sw] = $common[$sw] } }
                Move-UnityAsset -AssetPath $full @u
            }
            'native' {
                if (-not (Import-MoveEngine -Name 'DotnetMove.Native')) {
                    $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                            [System.InvalidOperationException]::new('The native C++ engine needs DotnetMove.Native (Windows only), which is not available. Install or enable it, then retry.'),
                            'NativeEngineUnavailable', [System.Management.Automation.ErrorCategory]::NotInstalled, $full))
                    return
                }
                Move-NativeProject -Project $full @common
            }
            default {
                $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                        [System.NotSupportedException]::new("Could not determine an engine for: $Path. Supported: .NET (.csproj/.fsproj/.vbproj/.sln/.slnx/.props/.targets), PowerShell (.ps1/.psd1), Unity (Assets/.meta/.asmdef), native (.vcxproj)."),
                        'UnknownEngine', [System.Management.Automation.ErrorCategory]::InvalidArgument, $Path))
            }
        }
    }
}
