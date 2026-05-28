Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared helpers come from the NetscootShared module, which the umbrella loads (-Global) before
# this engine; this engine loads only its own Private helpers and Public cmdlets.
# [IO.Path]::Combine (not multi-arg Join-Path) so this loads on Windows PowerShell 5.1 too.
foreach ($f in (Get-ChildItem -Path ([System.IO.Path]::Combine($PSScriptRoot, 'Private')) -Filter '*.ps1' -ErrorAction SilentlyContinue)) { . $f.FullName }

$public = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -ErrorAction SilentlyContinue)
foreach ($f in $public) { . $f.FullName }

# `Scoot` is the cheeky shorthand for the umbrella mover (aliases skip the approved-verb rule, so
# this gives `scoot <src> -Destination <dst>` while Invoke-Netscoot stays the convention-clean cmdlet).
Set-Alias -Name Scoot -Value Invoke-Netscoot
Export-ModuleMember -Function $public.BaseName -Alias Scoot
