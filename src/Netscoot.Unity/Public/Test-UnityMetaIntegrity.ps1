function Test-UnityMetaIntegrity {
    <#
    .SYNOPSIS
        Report Unity .meta integrity problems under a root: Assets missing a .meta, and
        orphan .meta files whose asset is gone. These are the Unity analog of dangling
        references - both lead to broken/regenerated GUIDs.

    .DESCRIPTION
        Walks the tree and pairs every asset (file or folder) with its `<name>.meta`.
        Emits one object per problem and surfaces it through the standard streams so behavior
        follows invocation: By default it writes a Warning per problem; -Strict escalates each to
        a non-terminating error (honoring -ErrorAction). Objects are always emitted so results are
        capturable/filterable.

        Ignores Unity-hidden entries (names starting with '.', folders ending with '~')
        and the Library/Temp/obj caches.

    .PARAMETER Root
        Folder to scan (typically an 'Assets' folder). Accepts pipeline input. Defaults to
        the current directory.

    .PARAMETER Strict
        Escalate problems from warnings to non-terminating errors.

    .OUTPUTS
        Netscoot.MetaIntegrity - one per problem.

    .EXAMPLE
        Test-UnityMetaIntegrity -Root ./Assets -Strict

        Reports MissingMeta and OrphanMeta under Assets, one non-terminating error each.
    #>
    [CmdletBinding()]
    [OutputType('Netscoot.MetaIntegrity')]
    param(
        [Parameter(Position = 0, ValueFromPipeline)]
        [Netscoot.PathInputTransform()]
        [string]$Root,
        [switch]$Strict
    )

    process {
        if (-not $Root) { $Root = (Get-Location).Path }
        $Root = Resolve-FullPath $Root

        # Exclude Unity caches anchored at the scan root (not "Temp" anywhere - the OS temp
        # dir itself contains that segment), plus .git and Unity-hidden entries.
        $rootLen = $Root.TrimEnd('\', '/').Length
        $entries = Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object {
                $rel = $_.FullName.Substring($rootLen)
                $rel -notmatch '^[\\/](Library|Temp|obj)[\\/]' -and
                $_.FullName -notmatch '[\\/]\.git[\\/]' -and
                $_.Name -notlike '.*' -and $_.Name -notlike '*~'
            }

        foreach ($e in $entries) {
            if ($e.Name -like '*.meta') {
                # Orphan check: the asset this .meta describes should exist.
                $asset = $e.FullName.Substring(0, $e.FullName.Length - '.meta'.Length)
                if (-not (Test-Path -LiteralPath $asset)) {
                    $rec = [pscustomobject]@{ PSTypeName = 'Netscoot.MetaIntegrity'; Kind = 'OrphanMeta'; Path = $e.FullName }
                    $msg = "Orphan .meta (no matching asset): $($e.FullName)"
                    if ($Strict) { Write-Error -Message $msg -Category InvalidData -TargetObject $rec -ErrorId 'OrphanMeta' } else { Write-Warning $msg }
                    $rec
                }
            } else {
                # Missing-meta check: every asset/folder should have a sibling .meta.
                if (-not (Test-Path -LiteralPath "$($e.FullName).meta" -PathType Leaf)) {
                    $rec = [pscustomobject]@{ PSTypeName = 'Netscoot.MetaIntegrity'; Kind = 'MissingMeta'; Path = $e.FullName }
                    $msg = "Asset has no .meta (Unity will generate a new GUID): $($e.FullName)"
                    if ($Strict) { Write-Error -Message $msg -Category InvalidData -TargetObject $rec -ErrorId 'MissingMeta' } else { Write-Warning $msg }
                    $rec
                }
            }
        }
    }
}
