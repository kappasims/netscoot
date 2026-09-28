Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared helpers come from the NetscootShared module, which the umbrella loads (-Global) before
# this engine; this engine loads only its own Private helpers and Public cmdlets.
# [IO.Path]::Combine (not multi-arg Join-Path) so this loads on Windows PowerShell 5.1 too.
foreach ($f in (Get-ChildItem -Path ([System.IO.Path]::Combine($PSScriptRoot, 'Private')) -Filter '*.ps1')) { . $f.FullName }

$public = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1')
foreach ($f in $public) { . $f.FullName }

Export-ModuleMember -Function $public.BaseName
