function Invoke-Netscoot {
    <#
    .SYNOPSIS
        Move any supported item and reconcile references, routing by detected type to the right
        per-namespace front door. The single top-level entry point (the `git netscoot` alias
        calls this).

    .DESCRIPTION
        Classifies the target with Resolve-MoveEngine, then dispatches to the namespace front door
        that performs the appropriate file/folder move (see Output for the routing). It loads
        Netscoot.Unity or Netscoot.Native on demand for a Unity or native C++ target.

        "dotnet" here is the .NET-platform umbrella (CLR/CoreCLR), not just the dotnet CLI - the
        verb spans every engine. Each engine's behavior lives in its own cmdlet; this only routes.
        -WhatIf/-Confirm/-Verbose propagate; -Force/-RepositoryRoot/-NoBuild are forwarded where the
        target's engine accepts them.

    .PARAMETER Path
        The item to move (file or folder). Accepts pipeline input (a path string or a
        Get-ChildItem/Get-Item item; other object types are rejected).

    .PARAMETER Destination
        New path (file or folder), following `git mv` rules; passed through to the engine.

    .PARAMETER RepositoryRoot
        Repository root the engine scans for references. Defaults to the enclosing git repository root.
        Not used for a PowerShell module folder.

    .PARAMETER NoBuild
        Skip the verifying 'dotnet build'. Only the .NET engine builds; ignored by the others.

    .PARAMETER Force
        When git is not installed, move with a plain PowerShell `Move-Item` without asking first.
        Without -Force it asks before falling back. The plain move does not preserve git history.
        Forwarded to the engine.

    .PARAMETER NoJournal
        Skip recording this move in the undo journal for this call (forwarded to the engine), even
        when journaling is enabled.

    .OUTPUTS
        The result object from the engine it routes to; the concrete type varies by engine.

    .EXAMPLE
        # Preview any move - detects the engine, changes nothing
        Invoke-Netscoot -Path ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon -WhatIf
        # Rename: ./libs/Tarragon does not exist yet, so src/Tarragon becomes libs/Tarragon
        Invoke-Netscoot -Path ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon
        # Move into an existing folder: ./libs exists, so it lands at ./libs/Tarragon
        Invoke-Netscoot -Path ./src/Tarragon/Tarragon.csproj -Destination ./libs
        # Any supported type routes through the same call (here a PowerShell module folder)
        Invoke-Netscoot -Path ./tools/Mayo -Destination ./modules/Mayo
        # git not installed? -Force falls back to a plain Move-Item without asking (history not preserved)
        Invoke-Netscoot -Path ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon -Force
    #>

    # SupportsShouldProcess so -WhatIf/-Confirm bind and propagate to the engine; this dispatcher
    # only routes (the engine cmdlet calls ShouldProcess), so suppress the rule here.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Delegates to an engine cmdlet that calls ShouldProcess')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Netscoot.MoveResult', 'Netscoot.TreeMoveResult', 'Netscoot.SolutionMoveResult', 'Netscoot.ImportMoveResult', 'Netscoot.ScriptMoveResult', 'Netscoot.PSModuleMoveResult', 'Netscoot.NativeMoveResult', 'Netscoot.UnityMoveResult')]
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
        if (-not (Test-Path -LiteralPath $full)) {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.IO.FileNotFoundException]::new("Path not found: $Path"),
                    'PathNotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $Path))
            return
        }

        if ([System.IO.Path]::GetExtension($full).ToLowerInvariant() -eq '.vcproj') {
            $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                    [System.NotSupportedException]::new("'$Path' is a legacy Visual C++ project (.vcproj, pre-VS2010). It predates MSBuild, so neither the dotnet CLI nor netscoot can process it. Convert it to .vcxproj (open it in Visual Studio 2010 or later, which upgrades it), then move it with Move-NativeProject."),
                    'LegacyVcprojNotSupported', [System.Management.Automation.ErrorCategory]::NotImplemented, $Path))
            return
        }

        $isContainer = Test-Path -LiteralPath $full -PathType Container
        $engine = Resolve-MoveEngine $full

        # Per-engine forwarding via New-ForwardArgs: every dispatcher's bound param flows through to
        # the specialist by default. -Drop strips things the target cmdlet does not accept (e.g.
        # NoBuild for the PowerShell, Unity and native movers); -Add substitutes the
        # resolved $full for the dispatcher's raw -Path and renames the path-parameter where the
        # specialist uses a different name (Project / ModulePath / AssetPath). Forwarding -WhatIf
        # /-Confirm /-Verbose /-Debug is automatic because they appear in $PSBoundParameters when bound;
        # this matters because $ConfirmPreference / $WhatIfPreference do not reliably inherit into
        # cmdlets in the sibling engine modules (Unity / Native), and $PSCmdlet.WriteVerbose inside
        # Write-MovePlan honors the cmdlet's bound -Verbose more strictly than ambient preference.
        # Each arm emits a "Routing -> <target>" trace matching the inner dispatchers, so the
        # verbose chain reads uniformly: Invoke-Netscoot -> Move-DotnetFile -> Move-DotnetProject.
        switch ($engine) {
            'dotnet' {
                $fwd = New-ForwardArgs $PSBoundParameters -Add @{ Path = $full }
                if ($isContainer) {
                    Write-Verbose 'Routing -> Move-DotnetFolder'
                    Move-DotnetFolder @fwd
                } else {
                    Write-Verbose 'Routing -> Move-DotnetFile'
                    Move-DotnetFile @fwd
                }
            }
            { $_ -in 'ps-script', 'ps-module' } {
                # Move-PowerShell does not accept NoBuild.
                $fwd = New-ForwardArgs $PSBoundParameters -Drop 'NoBuild' -Add @{ Path = $full }
                Write-Verbose 'Routing -> Move-PowerShell'
                Move-PowerShell @fwd
            }
            'unity' {
                if (-not (Import-MoveEngine -Name 'Netscoot.Unity')) {
                    $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                            [System.InvalidOperationException]::new('The Unity engine needs Netscoot.Unity, which is not available. Install or enable it, then retry.'),
                            'UnityEngineUnavailable', [System.Management.Automation.ErrorCategory]::NotInstalled, $full))
                    return
                }
                # Move-UnityAsset uses -AssetPath and does not accept -NoBuild.
                $fwd = New-ForwardArgs $PSBoundParameters -Drop 'Path', 'NoBuild' -Add @{ AssetPath = $full }
                Write-Verbose 'Routing -> Move-UnityAsset'
                Move-UnityAsset @fwd
            }
            'native' {
                if (-not (Import-MoveEngine -Name 'Netscoot.Native')) {
                    $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                            [System.InvalidOperationException]::new('The native C++ engine needs Netscoot.Native (Windows only), which is not available. Install or enable it, then retry.'),
                            'NativeEngineUnavailable', [System.Management.Automation.ErrorCategory]::NotInstalled, $full))
                    return
                }
                # Move-NativeProject uses -Project and does not accept -NoBuild.
                $fwd = New-ForwardArgs $PSBoundParameters -Drop 'Path', 'NoBuild' -Add @{ Project = $full }
                Write-Verbose 'Routing -> Move-NativeProject'
                Move-NativeProject @fwd
            }
            default {
                $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                        [System.NotSupportedException]::new("Could not determine an engine for: $Path. Supported: .NET (.csproj/.fsproj/.vbproj/.sln/.slnx/.props/.targets), PowerShell (.ps1/.psd1), Unity (Assets/.meta/.asmdef), native (.vcxproj)."),
                        'UnknownEngine', [System.Management.Automation.ErrorCategory]::InvalidArgument, $Path))
            }
        }
    }
}
