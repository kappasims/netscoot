function Import-MoveEngine {
    # Load an optional engine module (Netscoot.Unity / Netscoot.Native) on demand: an already-loaded
    # module, else the sibling manifest next to Netscoot.Core. Returns $true if the module is
    # available afterward. [IO.Path]::Combine (not multi-arg Join-Path) keeps this working on
    # Windows PowerShell 5.1.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name)

    if (Get-Module -Name $Name -All) { return $true }
    $sibling = [System.IO.Path]::Combine($PSScriptRoot, '..', '..', $Name, "$Name.psd1")
    if (Test-Path -LiteralPath $sibling) { Import-Module $sibling -Force -Global; return $true }
    return $false
}
