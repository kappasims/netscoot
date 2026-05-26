@{
    RootModule           = 'DotnetMove.psm1'
    ModuleVersion        = '1.3.1'
    GUID                 = 'e5b2d8a3-7c41-49f6-bd0e-9a3c2f6b1e57'
    Author               = 'kappasims'
    Description          = 'Move/restructure .NET projects (and PowerShell, Unity, native C++) from the command line without breaking references. A single bundled package: Import-Module DotnetMove loads the .NET/PowerShell and Unity engines everywhere, and the native C++ (.vcxproj) engine on Windows. Independent community project; not affiliated with or endorsed by Microsoft.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Core', 'Desktop')
    # Single bundled package: the RootModule loads the bundled Shared + engine modules -Global
    # (native only on Windows, best-effort), so commands are surfaced by one Import-Module. The
    # engines do the actual exporting at load; this list is the public, user-facing surface declared
    # for discoverability so the PowerShell Gallery lists the cmdlets (it reads the manifest, not the
    # runtime -Global imports). Keep it in sync with the engines' public exports (Shared plumbing is
    # intentionally excluded). Move-NativeProject is Windows-only at runtime but part of the package.
    FunctionsToExport    = @(
        'Clear-DotnetMoveJournal',
        'Find-PathReference',
        'Get-DotnetMoveCapability',
        'Get-SolutionInventory',
        'Move-Dotnet',
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
        'Register-DotnetMvGitAlias',
        'Repair-SolutionReferences',
        'Resolve-MoveEngine',
        'Set-DotnetMoveJournal',
        'Sync-Solution',
        'Test-DotnetMoveUpdate',
        'Test-SolutionConsistency',
        'Test-UnityMetaIntegrity',
        'Undo-DotnetMove',
        'Unregister-DotnetMvGitAlias',
        'Update-DotnetMove'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags         = @('dotnet', 'powershell', 'unity', 'native', 'refactoring', 'restructure', 'cross-platform')
            ProjectUri   = 'https://github.com/kappasims/dotnet-move'
            LicenseUri   = 'https://github.com/kappasims/dotnet-move/blob/master/LICENSE'
            ReleaseNotes = 'See https://github.com/kappasims/dotnet-move/releases'
        }
    }
}
