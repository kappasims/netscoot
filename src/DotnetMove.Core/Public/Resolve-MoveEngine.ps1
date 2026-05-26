function Resolve-MoveEngine {
    <#
    .SYNOPSIS
        Classify a path to the reconciliation engine that should move it: dotnet, native,
        unity, ps-script, ps-module, or unknown. Used by the `git dotnetmv` forwarder and
        available for introspection.

    .DESCRIPTION
        Classification is by target type (extension + location + .meta pairing), not by content
        beyond a folder's project/manifest scan. The path need not exist (extension-based cases
        classify regardless); folder cases require the directory.

    .PARAMETER Path
        The item to classify. Accepts pipeline input.

    .OUTPUTS
        A single [string], one of: dotnet, native, unity, ps-script, ps-module, unknown.

    .EXAMPLE
        Resolve-MoveEngine ./src/Tarragon/Tarragon.csproj      # -> dotnet
        Resolve-MoveEngine ./Assets/Art/logo.png     # -> unity
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName', 'PSPath')]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )
    process {
        $full = Resolve-FullPath $Path
        $ext = ([System.IO.Path]::GetExtension($full)).ToLowerInvariant()
        $isContainer = Test-Path -LiteralPath $full -PathType Container
        $underUnityTree = ($full -match '[\\/](Assets|Packages)[\\/]')
        $hasMeta = (-not $isContainer) -and (Test-Path -LiteralPath "$full.meta")

        if ($ext -eq '.vcxproj') { return 'native' }
        if ($ext -in '.asmdef', '.asmref' -or $underUnityTree -or $hasMeta) { return 'unity' }
        if ($ext -eq '.ps1') { return 'ps-script' }
        if ($ext -eq '.psd1') { return 'ps-module' }
        if ($ext -in '.csproj', '.fsproj', '.vbproj', '.sln', '.slnx', '.props', '.targets') { return 'dotnet' }
        if ($isContainer) {
            if ($underUnityTree) { return 'unity' }
            if (Get-ChildItem -LiteralPath $full -Recurse -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -in '.csproj', '.fsproj', '.vbproj' } | Select-Object -First 1) { return 'dotnet' }
            if (Get-ChildItem -LiteralPath $full -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -eq '.psd1' } | Select-Object -First 1) { return 'ps-module' }
            return 'unknown'
        }
        return 'unknown'
    }
}
