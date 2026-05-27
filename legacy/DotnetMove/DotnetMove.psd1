@{
    # Deprecation pointer for the renamed package. Keeps the original DotnetMove GUID so the Gallery
    # accepts it as a newer version of the existing package; this becomes the only listed DotnetMove
    # version (older ones are unlisted), so anyone who finds DotnetMove is sent to Netscoot.
    RootModule           = 'DotnetMove.psm1'
    ModuleVersion        = '1.3.3'
    GUID                 = 'e5b2d8a3-7c41-49f6-bd0e-9a3c2f6b1e57'
    Author               = 'kappasims'
    Description          = 'DEPRECATED: DotnetMove has been renamed to Netscoot. Install the replacement with: Install-Module Netscoot. This package does nothing else.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Core', 'Desktop')
    FunctionsToExport    = @()
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags         = @('deprecated', 'renamed', 'netscoot', 'dotnet', 'restructure')
            ProjectUri   = 'https://github.com/kappasims/netscoot'
            ReleaseNotes = 'DotnetMove has been renamed to Netscoot. Run: Install-Module Netscoot. See https://github.com/kappasims/netscoot'
        }
    }
}
