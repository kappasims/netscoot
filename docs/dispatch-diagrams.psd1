@{
    # Dispatch diagrams for the generated README reference.
    #
    # Some cmdlets route an input to a specialist by file extension / detected type. That routing
    # is a mapping, not prose, so the Docs task (build.ps1 -Task Docs) renders the diagram below as
    # a monospaced code block in the command's Output section instead of a sentence. Keep the
    # columns aligned by hand; '->' is the routing arrow. This is content, not generated - edit it
    # here when routing changes (and keep it in step with Resolve-MoveEngine / the dispatchers).

    'Invoke-Scoot' = @'
.csproj  .fsproj  .vbproj  ->  Netscoot.MoveResult
folder of .NET projects    ->  Netscoot.TreeMoveResult
.sln  .slnx                ->  Netscoot.SolutionMoveResult
.props  .targets           ->  Netscoot.ImportMoveResult
.ps1                       ->  Netscoot.ScriptMoveResult
.psd1  module folder       ->  Netscoot.PSModuleMoveResult
.vcxproj                   ->  Netscoot.NativeMoveResult
Unity asset  .meta         ->  Netscoot.UnityMoveResult
'@

    'Move-DotnetFile' = @'
.csproj  .fsproj  .vbproj  ->  Move-DotnetProject   ->  Netscoot.MoveResult
.sln  .slnx                ->  Move-Solution        ->  Netscoot.SolutionMoveResult
.props  .targets           ->  Move-MSBuildImport   ->  Netscoot.ImportMoveResult
'@

    'Move-PowerShell' = @'
.ps1                   ->  Move-PowerShellScript  ->  Netscoot.ScriptMoveResult
.psd1  module folder   ->  Move-PowerShellModule  ->  Netscoot.PSModuleMoveResult
'@

    'Resolve-MoveEngine' = @'
.vcxproj                                            ->  native
.asmdef  .asmref  *.meta  (or under Assets/)        ->  unity
.ps1                                                ->  ps-script
.psd1                                               ->  ps-module
.csproj .fsproj .vbproj .sln .slnx .props .targets  ->  dotnet
folder containing a .NET project                    ->  dotnet
folder containing a .psd1                           ->  ps-module
anything else                                       ->  unknown
'@
}
