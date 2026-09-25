@{
    RootModule           = 'Netscoot.psm1'
    ModuleVersion        = '2.6.7'
    GUID                 = '917ef9d9-9117-4ee4-a07f-eb1c1902b9d6'
    Author               = 'kappasims'
    Description          = 'Move/restructure .NET projects (and PowerShell, Unity, native C++) from the command line without breaking references. A single bundled package: Import-Module Netscoot loads the .NET/PowerShell and Unity engines everywhere, and the native C++ (.vcxproj) engine on Windows. Independent community project; not affiliated with or endorsed by Microsoft.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Core', 'Desktop')
    # Single bundled package: the RootModule loads Shared -Global and imports each engine nested,
    # re-exporting its cmdlets (native only on Windows, best-effort). This list is the export filter
    # for those re-exported cmdlets, and the PowerShell Gallery indexes it to list the cmdlets by name.
    # tests/UmbrellaSurface.Tests.ps1 checks it against the engines' exports (Shared plumbing excluded).
    # Move-NativeProject is Windows-only at runtime but part of the package.
    FunctionsToExport    = @(
        'Clear-NetscootJournal',
        'Find-PathReference',
        'Get-NetscootCapability',
        'Get-NetscootUpdatePolicy',
        'Get-SolutionInventory',
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
        'Repair-SolutionReferences',
        'Resolve-MoveEngine',
        'Set-NetscootJournal',
        'Set-NetscootUpdatePolicy',
        'Sync-Solution',
        'Test-EditorSolutionGuard',
        'Test-NetscootUpdate',
        'Test-SolutionConsistency',
        'Test-UnityMetaIntegrity',
        'Undo-Netscoot',
        'Unregister-NetscootGitAlias',
        'Update-Netscoot'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @('Scoot')
    PrivateData          = @{
        PSData = @{
            # OS tags (Windows/Linux/macOS) surface the platform badges on the Gallery; PowerShellGet
            # adds PSEdition_Core/PSEdition_Desktop from CompatiblePSEditions. The rest aid discovery.
            Tags         = @('dotnet', 'powershell', 'unity', 'native', 'refactoring', 'restructure', 'cross-platform', 'solution', 'msbuild', 'csproj', 'slnx', 'migration', 'Windows', 'Linux', 'macOS')
            ProjectUri   = 'https://github.com/kappasims/netscoot'
            LicenseUri   = 'https://github.com/kappasims/netscoot/blob/master/LICENSE'
            ReleaseNotes = 'See https://github.com/kappasims/netscoot/releases'
        }
    }
}
