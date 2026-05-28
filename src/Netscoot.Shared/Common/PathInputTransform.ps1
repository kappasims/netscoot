# Pipeline-input gate for every cmdlet that takes a path/root from the pipeline - the MUTATING movers
# and reconcilers (Move-*, Repair-SolutionReferences, Sync-Solution) and the read-only analysis
# cmdlets (Test-SolutionConsistency, Get-SolutionInventory, Test-UnityMetaIntegrity, Find-PathReference,
# Resolve-MoveEngine), so the whole module shares ONE pipeline contract.
#
# Each accepts its target as a [string] path bound ByValue from the pipeline. We also want to accept a
# Get-ChildItem/Get-Item item (System.IO.FileSystemInfo) by taking its .FullName - but we must NOT bind
# arbitrary objects' like-named properties. The old design used ValueFromPipelineByPropertyName + an
# [Alias('FullName','PSPath','Path')], which made read-only audit outputs (e.g. a row's .Project /
# .Path) silently bind row-by-row into the mutators and attempt moves. That is the hazard this closes.
#
# This ArgumentTransformationAttribute positively defines acceptable input: a path string passes
# through, a FileSystemInfo becomes its FullName, and ANY other object type throws a clear error so
# a report/result object piped into a mover fails loudly instead of binding.
#
# Defined as a compiled .NET type via Add-Type (not a PowerShell `class`): a PowerShell class is
# only resolvable as a type literal within its own module scope, but this attribute is referenced in
# param blocks across three sibling engine modules (Core/Native/Unity). A real .NET type registered
# in the AppDomain is visible to all of them. Guarded so re-importing the module (-Force) is a no-op.

if (-not ('Netscoot.PathInputTransformAttribute' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Management.Automation;

namespace Netscoot
{
    // Accept a path string or a Get-Item/Get-ChildItem item; reject everything else.
    [AttributeUsage(AttributeTargets.Property | AttributeTargets.Field | AttributeTargets.Parameter, AllowMultiple = false)]
    public sealed class PathInputTransformAttribute : ArgumentTransformationAttribute
    {
        public override object Transform(EngineIntrinsics engineIntrinsics, object inputData)
        {
            object item = inputData;

            PSObject pso = item as PSObject;
            if (pso != null) { item = pso.BaseObject; }

            // A path string binds as-is (named, positional, or ByValue from the pipeline).
            if (item is string) { return item; }

            // A Get-Item/Get-ChildItem result (FileInfo/DirectoryInfo) binds via its full path.
            FileSystemInfo fsi = item as FileSystemInfo;
            if (fsi != null) { return fsi.FullName; }

            string actual = (item == null) ? "null" : item.GetType().FullName;
            throw new ArgumentTransformationMetadataException(
                "Unsupported pipeline input: expected a path string or a file/directory item " +
                "(System.IO.FileSystemInfo from Get-ChildItem/Get-Item), but got [" + actual + "]. " +
                "Pipe a path string or a Get-Item result - not a report/result object such as the " +
                "output of Test-SolutionConsistency, Get-SolutionInventory, or Test-UnityMetaIntegrity.");
        }
    }
}
'@
}
