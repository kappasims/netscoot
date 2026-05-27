function Invoke-Netscoot {
    <#
    .SYNOPSIS
        Move any supported item and reconcile references, routing by detected type to the right
        per-namespace front door. The single top-level entry point (the `git netscoot` alias
        calls this).

    .DESCRIPTION
        Classifies the target with Resolve-MoveEngine, then dispatches to the namespace front door
        that performs the appropriate file/folder move (see Output for the routing). The Unity and
        native C++ front doors load Netscoot.Unity / Netscoot.Native on demand.

        "dotnet" here is the .NET-platform umbrella (CLR/CoreCLR), not just the dotnet CLI - the
        verb spans every engine. Each engine's behavior lives in its own cmdlet; this only routes.
        -WhatIf/-Confirm/-Verbose propagate; -Force/-RepositoryRoot/-NoBuild are forwarded where the
        target's engine accepts them.

    .PARAMETER Path
        The item to move (file or folder). Accepts pipeline input.

    .PARAMETER Destination
        New path - passed through to the engine.

    .PARAMETER RepositoryRoot
        Repository root the engine scans for references. Defaults to the enclosing git repository root.
        Not used by the Unity engine.

    .PARAMETER NoBuild
        Skip the verifying 'dotnet build'. Only the .NET engine builds; ignored by the others.

    .PARAMETER Force
        Proceed with a plain file move when git is unavailable instead of aborting. The plain move is a PowerShell `Move-Item` (same on every platform) and does not preserve git history. Forwarded to the engine.

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
        # No git in the repository? -Force falls back to a plain Move-Item (history not preserved)
        Invoke-Netscoot -Path ./src/Tarragon/Tarragon.csproj -Destination ./libs/Tarragon -Force
    #>

    # SupportsShouldProcess so -WhatIf/-Confirm bind and propagate to the engine; this dispatcher
    # only routes (the engine cmdlet calls ShouldProcess), so suppress the rule here.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Delegates to an engine cmdlet that calls ShouldProcess')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Netscoot.MoveResult', 'Netscoot.TreeMoveResult', 'Netscoot.SolutionMoveResult', 'Netscoot.ImportMoveResult', 'Netscoot.ScriptMoveResult', 'Netscoot.PSModuleMoveResult', 'Netscoot.NativeMoveResult', 'Netscoot.UnityMoveResult')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName', 'PSPath')]
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

        # Common forwardables; an engine that lacks a parameter simply isn't given it.
        $common = @{ Destination = $Destination }
        if ($Force) { $common.Force = $true }
        if ($NoJournal) { $common.NoJournal = $true }
        if ($PSBoundParameters.ContainsKey('RepositoryRoot')) { $common.RepositoryRoot = $RepositoryRoot }
        # Forward -WhatIf/-Confirm explicitly: $ConfirmPreference/$WhatIfPreference do not reliably
        # inherit into cmdlets in the sibling engine modules (Unity/Native), so an unforwarded
        # High-impact ShouldProcess would prompt - and hang a non-interactive caller such as the
        # git alias, which passes -Confirm:$false.
        foreach ($sw in 'WhatIf', 'Confirm') {
            if ($PSBoundParameters.ContainsKey($sw)) { $common[$sw] = $PSBoundParameters[$sw] }
        }

        Write-Verbose "Invoke-Netscoot: engine=$engine container=$isContainer target=$full"
        switch ($engine) {
            'dotnet' {
                if ($NoBuild) { $common.NoBuild = $true }
                if ($isContainer) { Move-DotnetFolder -Path $full @common } else { Move-DotnetFile -Path $full @common }
            }
            { $_ -in 'ps-script', 'ps-module' } {
                Move-PowerShell -Path $full @common
            }
            'unity' {
                if (-not (Import-MoveEngine -Name 'Netscoot.Unity')) {
                    $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                            [System.InvalidOperationException]::new('The Unity engine needs Netscoot.Unity, which is not available. Install or enable it, then retry.'),
                            'UnityEngineUnavailable', [System.Management.Automation.ErrorCategory]::NotInstalled, $full))
                    return
                }
                # Move-UnityAsset handles file and folder; it has no -RepositoryRoot/-NoBuild.
                $u = @{ Destination = $Destination }
                if ($Force) { $u.Force = $true }
                if ($NoJournal) { $u.NoJournal = $true }
                foreach ($sw in 'WhatIf', 'Confirm') { if ($common.ContainsKey($sw)) { $u[$sw] = $common[$sw] } }
                Move-UnityAsset -AssetPath $full @u
            }
            'native' {
                if (-not (Import-MoveEngine -Name 'Netscoot.Native')) {
                    $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                            [System.InvalidOperationException]::new('The native C++ engine needs Netscoot.Native (Windows only), which is not available. Install or enable it, then retry.'),
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
