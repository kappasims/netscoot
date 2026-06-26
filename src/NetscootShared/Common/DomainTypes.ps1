# Typed domain model (3.0). Real .NET DTO classes for every result/report object netscoot emits,
# replacing the former `[pscustomobject]@{ PSTypeName = 'Netscoot.X'; ... }` property bags. A real
# type fixes the property-order fragility of pscustomobject + PSTypeName (the historical scrambled-
# order bug) and gives callers a concrete [Netscoot.X] to type-check and tab-complete against.
#
# Defined via Add-Type (compiled once into the AppDomain) rather than a PowerShell `class`: a `class`
# is only resolvable as a type literal within its own module, but these types are constructed across
# the sibling engine modules (Core/Native/Unity). Same proven pattern as PathInputTransform. Public
# FIELDS (not properties) keep the C# terse and match the old property-bag semantics; PowerShell's
# `[Netscoot.X]@{ ... }` hashtable construction and `New-Object -Property` both populate them.
#
# 5.1 constraint: this compiles under Windows PowerShell 5.1's older C# too, so no records, no
# init-only setters, no nullable reference types - plain classes, public fields, and Nullable<bool>.
#
# Netscoot.Format.ps1xml already keys its views on these exact type names, so a real object of the
# same name inherits the existing table/list views with no XML change. Netscoot.JournalEntry is
# deliberately NOT here: it is a JSON-serialized on-disk record (lowercase fields, round-tripped
# through ConvertTo/ConvertFrom-Json), so it stays a pscustomobject. The guard makes a re-import
# (-Force) a no-op.

if (-not ('Netscoot.MoveResult' -as [type])) {
    Add-Type -TypeDefinition @'
using System;

namespace Netscoot
{
    // ---- Move results: FLAT classes, NOT a base + derived hierarchy. PowerShell enumerates a
    // derived type's own fields before the inherited base fields, which would scramble the
    // documented "uniform base shape (Engine/Source/Destination/Performed/SkippedCount) first, then
    // engine-specific extras in written order" contract. Declaring all fields in one class fixes the
    // enumeration order deterministically. Source/Destination are ABSOLUTE paths.
    public class MoveResult                  // dotnet project
    {
        public string Engine;
        public string Source;
        public string Destination;
        public bool   Performed;
        public int    SkippedCount;
        public string[]       Solutions;
        public int            ConsumerCount;
        public int            OwnRefCount;
        public Nullable<bool> Built;
    }

    public class TreeMoveResult              // dotnet folder/tree
    {
        public string Engine;
        public string Source;
        public string Destination;
        public bool   Performed;
        public int    SkippedCount;
        public int            ProjectsMoved;
        public int            ConsumerCount;
        public Nullable<bool> Built;
    }

    public class SolutionMoveResult          // .sln/.slnx file
    {
        public string Engine;
        public string Source;
        public string Destination;
        public bool   Performed;
        public int    SkippedCount;
        public int ProjectsRebased;
    }

    public class ImportMoveResult            // .props/.targets
    {
        public string Engine;
        public string Source;
        public string Destination;
        public bool   Performed;
        public int    SkippedCount;
        public int  ImportersFixed;
        public int  OwnImportsFixed;
        public bool AutoImported;
    }

    public class ScriptMoveResult            // .ps1 script
    {
        public string Engine;
        public string Source;
        public string Destination;
        public bool   Performed;
        public int    SkippedCount;
        public int ReferencersFixed;
        public int OwnRefsFixed;
        public int UnresolvedRefs;
    }

    public class PSModuleMoveResult          // PowerShell module
    {
        public string Engine;
        public string Source;
        public string Destination;
        public bool   Performed;
        public int    SkippedCount;
        public string Manifest;
    }

    public class NativeMoveResult            // .vcxproj
    {
        public string Engine;
        public string Source;
        public string Destination;
        public bool   Performed;
        public int    SkippedCount;
        public string[]        Solutions;
        public NativeSetting[] UnreconciledSettings;
        public bool            HadFilters;
    }

    public class UnityMoveResult             // Unity asset
    {
        public string Engine;
        public string Source;
        public string Destination;
        public bool   Performed;
        public int    SkippedCount;
        public bool     MetaMoved;
        public bool     IsAsmdef;
        public string[] ReferencedBy;
    }

    // ---- Report / inventory / analysis objects (repository-relative paths where applicable) ----
    public class NativeSetting
    {
        public string Kind;
        public string Value;
    }

    // Note: Netscoot.Solution and Netscoot.Workspace are intentionally NOT typed here. They are
    // internal solution-enumeration bags (no Format.ps1xml view), mutated and lazily extended after
    // construction (Projects/Folders/Items/Consumers set later, FullName/Name added via Add-Member),
    // which a rigid DTO would fight. They stay pscustomobject.

    public class Capability
    {
        public string Platform;
        public string PSEdition;
        public object Git;       // @{ Present; Version; Path } or null
        public object Dotnet;    // @{ Present; Version; Path } or null
        public bool   DotnetSupportsSlnx;
    }

    public class PathReference
    {
        public string File;
        public int    Line;
        public string Confidence;
        public string Text;
    }

    public class SolutionItem
    {
        public string Solution;
        public object Kind;      // a Netscoot.SolutionItemKind value (typed object to avoid a
                                 // compile-time dependency on the Core-defined enum)
        public string Type;
        public string Name;
        public string Path;
    }

    public class ConsistencyResult
    {
        public string   Project;
        public string[] PresentIn;
        public string[] AbsentFrom;
    }

    public class RepairResult
    {
        public string Kind;
        public string Resolution;
        public string Missing;
        public string NewPath;
        public string Container;
        public string MissingAbs;
        public object Candidates;
    }

    public class SyncResult
    {
        public string Solution;
        public string Added;
    }

    public class MetaIntegrity
    {
        public string Kind;
        public string Path;
    }

    public class EditorSolutionGuard
    {
        public string Check;
        public string Severity;
        public string Detail;
    }

    public class GitAlias
    {
        public string Alias;
        public string Scope;
        public string Forwarder;
        public string Command;
    }

    public class UpdatePolicy
    {
        public string State;
        public string Source;
        public string Value;
    }

    public class UpdateChannel
    {
        public string Channel;
        public string Source;
        public string Value;
    }
}
'@
}
