@{
    RootModule           = 'Netscoot.psm1'
    ModuleVersion        = '3.0.0'
    GUID                 = '917ef9d9-9117-4ee4-a07f-eb1c1902b9d6'
    Author               = 'kappasims'
    Description          = 'Move/restructure .NET projects (and PowerShell, Unity, native C++) from the command line without breaking references. A single bundled package: Import-Module Netscoot loads the .NET/PowerShell and Unity engines everywhere, and the native C++ (.vcxproj) engine on Windows. Independent community project; not affiliated with or endorsed by Microsoft.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Core', 'Desktop')
    # Single bundled package: the RootModule loads the bundled Shared + engine modules -Global, so
    # commands are surfaced by one Import-Module (native only on Windows, best-effort). This list is
    # METADATA-ONLY: at runtime, PowerShell would only filter functions defined IN THIS PSM1, but the
    # engine cmdlets come from the nested modules loaded -Global - PowerShell doesn't filter those
    # through the umbrella manifest. The list exists so the PowerShell Gallery lists the cmdlets by
    # name (Gallery indexes the manifest, not the runtime surface).
    # The hand-sync of this list with the engines' actual exports (Shared plumbing intentionally
    # excluded) is enforced by tests/UmbrellaSurface.Tests.ps1; do not edit blindly.
    # Move-NativeProject is Windows-only at runtime but part of the package.
    FunctionsToExport    = @(
        'Clear-NetscootJournal',
        'Find-NetscootPathReference',
        'Get-NetscootCapability',
        'Get-NetscootSolutionInventory',
        'Get-NetscootUpdateChannel',
        'Get-NetscootUpdatePolicy',
        'Invoke-Netscoot',
        'Move-DotnetFile',
        'Move-DotnetFolder',
        'Move-DotnetProject',
        'Move-DotnetProjectTree',
        'Move-MSBuildImport',
        'Move-NativeProject',
        'Move-PowerShell',
        'Move-PowerShellModule',
        'Move-PowerShellScript',
        'Move-Solution',
        'Move-UnityAsset',
        'Register-NetscootGitAlias',
        'Repair-NetscootJournal',
        'Repair-NetscootSolutionReferences',
        'Resolve-MoveEngine',
        'Set-NetscootJournal',
        'Set-NetscootUpdateChannel',
        'Set-NetscootUpdatePolicy',
        'Sync-NetscootSolution',
        'Test-EditorSolutionGuard',
        'Test-NetscootSolutionConsistency',
        'Test-NetscootUpdate',
        'Test-UnityMetaIntegrity',
        'Undo-Netscoot',
        'Unregister-NetscootGitAlias',
        'Update-Netscoot'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @(
        'Find-PathReference',
        'Get-SolutionInventory',
        'Repair-SolutionReferences',
        'Scoot',
        'Sync-Solution',
        'Test-SolutionConsistency'
    )
    PrivateData          = @{
        PSData = @{
            # OS tags (Windows/Linux/macOS) surface the platform badges on the Gallery; PowerShellGet
            # adds PSEdition_Core/PSEdition_Desktop from CompatiblePSEditions. The rest aid discovery.
            Tags         = @('dotnet', 'powershell', 'unity', 'native', 'refactoring', 'restructure', 'cross-platform', 'solution', 'msbuild', 'csproj', 'slnx', 'migration', 'Windows', 'Linux', 'macOS')
            ProjectUri   = 'https://github.com/kappasims/netscoot'
            LicenseUri   = 'https://github.com/kappasims/netscoot/blob/master/LICENSE'
            ReleaseNotes = 'See https://github.com/kappasims/netscoot/releases'
            # 3.0 ships as an opt-in PRERELEASE while it is stress-tested: `Install-Module Netscoot`
            # stays on 2.6.x stable; `-AllowPrerelease` opts into this build. Remove this line to
            # promote 3.0.0 to stable. (ModuleVersion stays 3.0.0; the Gallery shows 3.0.0-beta1.)
            Prerelease   = 'beta1'
        }
    }
}
