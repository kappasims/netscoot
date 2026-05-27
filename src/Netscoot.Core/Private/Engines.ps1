function Import-MoveEngine {
    # Load an optional engine module (Netscoot.Unity / Netscoot.Native) on demand: prefer an
    # already-loaded or installed module, else the sibling source manifest next to Netscoot.Core.
    # Returns $true if the module is available afterward. [IO.Path]::Combine (not multi-arg
    # Join-Path) keeps this working on Windows PowerShell 5.1.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name)

    if (Get-Module -Name $Name) { return $true }
    $sibling = [System.IO.Path]::Combine($PSScriptRoot, '..', '..', $Name, "$Name.psd1")
    if (Test-Path -LiteralPath $sibling) { Import-Module $sibling -Force -Global; return $true }
    if (Get-Module -ListAvailable -Name $Name) { Import-Module $Name -Global; return $true }
    return $false
}
