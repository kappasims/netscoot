function Resolve-MoveEngine {
    <#
    .SYNOPSIS
        Classify a path to the reconciliation engine that should move it: dotnet, native,
        unity, ps-script, ps-module, or unknown. Used by Invoke-Netscoot (and so `git netscoot`)
        and available for introspection.

    .DESCRIPTION
        Classification is by target type (extension + location + .meta pairing), not by content
        beyond a folder's project/manifest scan. A path is unity when it is an .asmdef/.asmref,
        has a sibling .meta, or sits under the Assets/ or Packages/ folder of a Unity project (one
        with ProjectSettings/ beside it). A folder is dotnet when a managed project is anywhere
        under it, and ps-module when a .psd1 is directly in it. The path need not exist
        (extension-based cases classify regardless). Folder cases require the directory.

    .PARAMETER Path
        The item to classify. Accepts pipeline input: a path string, or a file/directory item from
        Get-Item / Get-ChildItem.

    .OUTPUTS
        A single [string], one of: dotnet, native, unity, ps-script, ps-module, unknown.

    .EXAMPLE
        # A managed project classifies as 'dotnet'
        Resolve-MoveEngine ./src/Tarragon/Tarragon.csproj
        # Anything under a Unity project's Assets/ or Packages/, or paired with a .meta, is 'unity'
        Resolve-MoveEngine ./Assets/Art/logo.png
        # A .ps1 is 'ps-script'; a module folder or .psd1 is 'ps-module'
        Resolve-MoveEngine ./tools/build.ps1
        # A .vcxproj is 'native'; an unrecognized path is 'unknown'
        Resolve-MoveEngine ./Aleppo/Aleppo.vcxproj
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [Netscoot.PathInputTransform()]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )
    process {
        $full = Resolve-FullPath $Path
        $ext = ([System.IO.Path]::GetExtension($full)).ToLowerInvariant()
        $isContainer = Test-Path -LiteralPath $full -PathType Container
        # An Assets/ or Packages/ folder counts when it belongs to a Unity project (ProjectSettings/
        # beside it), so a NuGet packages/ or a web assets/ folder does not. A folder that does not
        # exist on disk cannot be checked, so its name decides.
        $underUnityTree = $false
        foreach ($m in [regex]::Matches($full, '[\\/](Assets|Packages)(?=[\\/])')) {
            $projectDir = $full.Substring(0, $m.Index)
            $unityDir = $full.Substring(0, $m.Index + $m.Length)
            if (-not (Test-Path -LiteralPath $unityDir -PathType Container) -or
                (Test-Path -LiteralPath (Join-Path $projectDir 'ProjectSettings') -PathType Container)) {
                $underUnityTree = $true
                break
            }
        }
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
