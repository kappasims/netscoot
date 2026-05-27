@{
    # Output-type registry (typedefs) for the generated README reference.
    #
    # Each cmdlet declares the type(s) it emits via [OutputType('Netscoot.X')]; the Docs task
    # (build.ps1 -Task Docs) looks the name up here and renders, in the command's Output section,
    # a link to the type's entry plus a terse code-view of its structure. The same entries are
    # collected into the generated "Output types" section. This is the single source of truth for
    # output shapes; do not restate field lists in a cmdlet's .OUTPUTS prose.
    #
    # Per type:
    #   Summary    - one line describing what one instance represents.
    #   Array      - $true when commands emit zero or more (collected as an array).
    #   EmptyIsNull- $true when an empty result means a collecting variable is $null (array types).
    #   Fields     - ordered list of @{ Name; Type; Note }. Type uses code-view shorthand:
    #                  string  int  bool  version  object   scalar types
    #                  string[]                     array of that type
    #                  bool?                        nullable (may be $null)
    #                  Netscoot.X                 a nested typedef (also in this registry)
    #                Note is an optional terse qualifier (allowed values, when-$null, meaning).

    'Netscoot.PathReference' = @{
        Summary = 'One build/CI/hook/container line that hardcodes a moved path and that no first-party tool reconciles.'
        Array   = $true
        EmptyIsNull = $true
        Fields  = @(
            @{ Name = 'File';       Type = 'string'; Note = 'repository-relative file containing the line' }
            @{ Name = 'Line';       Type = 'int';    Note = '1-based line number' }
            @{ Name = 'Confidence'; Type = 'string'; Note = 'High | Low' }
            @{ Name = 'Text';       Type = 'string'; Note = 'the matching line' }
        )
    }

    'Netscoot.Capability' = @{
        Summary = "Netscoot's resolved external-tool capabilities and platform - the 'what can I do here' probe."
        Array   = $false
        Fields  = @(
            @{ Name = 'Platform';           Type = 'string';              Note = '' }
            @{ Name = 'PSEdition';          Type = 'string';              Note = '' }
            @{ Name = 'DotnetSupportsSlnx'; Type = 'bool';                Note = '' }
            @{ Name = 'Git';                Type = 'Netscoot.ToolInfo'; Note = '' }
            @{ Name = 'Dotnet';             Type = 'Netscoot.ToolInfo'; Note = '' }
        )
    }

    'Netscoot.ToolInfo' = @{
        Summary = 'Presence and version of one external tool (git or dotnet).'
        Array   = $false
        Fields  = @(
            @{ Name = 'Present'; Type = 'bool';   Note = 'found on PATH' }
            @{ Name = 'Version'; Type = 'string'; Note = '' }
            @{ Name = 'Path';    Type = 'string'; Note = '' }
        )
    }

    'Netscoot.SolutionItem' = @{
        Summary = 'One entry in the full contents of a solution (or a project on disk that no solution references).'
        Array   = $true
        EmptyIsNull = $false
        Fields  = @(
            @{ Name = 'Solution'; Type = 'string';                       Note = "repository-relative, or '(none)' for an unreferenced project" }
            @{ Name = 'Kind';     Type = 'Netscoot.SolutionItemKind'; Note = 'enum: Project | SolutionFolder | SolutionItem | UnreferencedProject' }
            @{ Name = 'Type';     Type = 'string'; Note = 'project extension without the dot, else empty' }
            @{ Name = 'Name';     Type = 'string'; Note = '' }
            @{ Name = 'Path';     Type = 'string'; Note = 'as stored in the solution, or repository-relative' }
        )
    }

    'Netscoot.MoveResult' = @{
        Summary = 'Result of moving a .NET project folder and reconciling solutions and project references.'
        Array   = $false
        Fields  = @(
            @{ Name = 'Engine';        Type = 'string';   Note = '' }
            @{ Name = 'Source';        Type = 'string';   Note = '' }
            @{ Name = 'Destination';   Type = 'string';   Note = '' }
            @{ Name = 'Performed';     Type = 'bool';     Note = 'false under -WhatIf' }
            @{ Name = 'SkippedCount';  Type = 'int';      Note = '' }
            @{ Name = 'ConsumerCount'; Type = 'int';      Note = 'external references repointed' }
            @{ Name = 'OwnRefCount';   Type = 'int';      Note = "the moved project's own references rebased" }
            @{ Name = 'Solutions';     Type = 'string[]'; Note = 'solution names updated' }
            @{ Name = 'Built';         Type = 'bool?';    Note = '$null with -NoBuild' }
        )
    }

    'Netscoot.TreeMoveResult' = @{
        Summary = 'Result of moving a folder of one or more .NET projects in one operation.'
        Array   = $false
        Fields  = @(
            @{ Name = 'Engine';        Type = 'string'; Note = '' }
            @{ Name = 'Source';        Type = 'string'; Note = '' }
            @{ Name = 'Destination';   Type = 'string'; Note = '' }
            @{ Name = 'Performed';     Type = 'bool';   Note = 'false under -WhatIf' }
            @{ Name = 'SkippedCount';  Type = 'int';    Note = '' }
            @{ Name = 'ProjectsMoved'; Type = 'int';    Note = '' }
            @{ Name = 'ConsumerCount'; Type = 'int';    Note = 'external references repointed' }
            @{ Name = 'Built';         Type = 'bool?';  Note = '$null with -NoBuild' }
        )
    }

    'Netscoot.ImportMoveResult' = @{
        Summary = 'Result of moving a shared MSBuild .props/.targets file and fixing its importers.'
        Array   = $false
        Fields  = @(
            @{ Name = 'Engine';         Type = 'string'; Note = '' }
            @{ Name = 'Source';         Type = 'string'; Note = '' }
            @{ Name = 'Destination';    Type = 'string'; Note = '' }
            @{ Name = 'Performed';      Type = 'bool';   Note = 'false under -WhatIf' }
            @{ Name = 'SkippedCount';   Type = 'int';    Note = '' }
            @{ Name = 'ImportersFixed'; Type = 'int';    Note = 'files whose <Import> was rewritten' }
            @{ Name = 'OwnImportsFixed';Type = 'int';    Note = "the moved file's own imports rewritten" }
            @{ Name = 'AutoImported';   Type = 'bool';   Note = 'true for a by-location import (e.g. Directory.Build.props) whose inheritance scope changed' }
        )
    }

    'Netscoot.PSModuleMoveResult' = @{
        Summary = 'Result of moving a PowerShell module folder and reconciling its manifest.'
        Array   = $false
        Fields  = @(
            @{ Name = 'Engine';       Type = 'string'; Note = '' }
            @{ Name = 'Source';       Type = 'string'; Note = '' }
            @{ Name = 'Destination';  Type = 'string'; Note = '' }
            @{ Name = 'Performed';    Type = 'bool';   Note = 'false under -WhatIf' }
            @{ Name = 'SkippedCount'; Type = 'int';    Note = '' }
            @{ Name = 'Manifest';     Type = 'string'; Note = 'the manifest file name' }
        )
    }

    'Netscoot.ScriptMoveResult' = @{
        Summary = 'Result of moving a standalone .ps1 and fixing dot-source/call paths.'
        Array   = $false
        Fields  = @(
            @{ Name = 'Engine';          Type = 'string'; Note = '' }
            @{ Name = 'Source';          Type = 'string'; Note = '' }
            @{ Name = 'Destination';     Type = 'string'; Note = '' }
            @{ Name = 'Performed';       Type = 'bool';   Note = 'false under -WhatIf' }
            @{ Name = 'SkippedCount';    Type = 'int';    Note = '' }
            @{ Name = 'ReferencersFixed';Type = 'int';    Note = 'scripts whose path to the moved file was rewritten' }
            @{ Name = 'OwnRefsFixed';    Type = 'int';    Note = "the moved script's own paths rewritten" }
            @{ Name = 'UnresolvedRefs';  Type = 'int';    Note = 'count of possible dynamic references to verify, not a list' }
        )
    }

    'Netscoot.SolutionMoveResult' = @{
        Summary = 'Result of moving a solution file and rebasing the relative project paths it stores.'
        Array   = $false
        Fields  = @(
            @{ Name = 'Engine';          Type = 'string'; Note = '' }
            @{ Name = 'Source';          Type = 'string'; Note = '' }
            @{ Name = 'Destination';     Type = 'string'; Note = '' }
            @{ Name = 'Performed';       Type = 'bool';   Note = 'false under -WhatIf' }
            @{ Name = 'SkippedCount';    Type = 'int';    Note = '' }
            @{ Name = 'ProjectsRebased'; Type = 'int';    Note = 'stored paths rewritten' }
        )
    }

    'Netscoot.NativeMoveResult' = @{
        Summary = 'Result of moving a native / C++/CLI project (.vcxproj).'
        Array   = $false
        Fields  = @(
            @{ Name = 'Engine';               Type = 'string';   Note = '' }
            @{ Name = 'Source';               Type = 'string';   Note = '' }
            @{ Name = 'Destination';          Type = 'string';   Note = '' }
            @{ Name = 'Performed';            Type = 'bool';     Note = 'false under -WhatIf' }
            @{ Name = 'SkippedCount';         Type = 'int';      Note = '' }
            @{ Name = 'HadFilters';           Type = 'bool';     Note = 'a paired .vcxproj.filters moved too' }
            @{ Name = 'Solutions';            Type = 'string[]'; Note = 'solution names updated' }
            @{ Name = 'UnreconciledSettings'; Type = 'object[]'; Note = 'one per native path setting to verify by hand; each has the setting name and value' }
        )
    }

    'Netscoot.UnityMoveResult' = @{
        Summary = 'Result of moving a Unity asset/folder while keeping its paired .meta file(s).'
        Array   = $false
        Fields  = @(
            @{ Name = 'Engine';       Type = 'string';   Note = '' }
            @{ Name = 'Source';       Type = 'string';   Note = '' }
            @{ Name = 'Destination';  Type = 'string';   Note = '' }
            @{ Name = 'Performed';    Type = 'bool';     Note = 'false under -WhatIf' }
            @{ Name = 'SkippedCount'; Type = 'int';      Note = '' }
            @{ Name = 'MetaMoved';    Type = 'bool';     Note = 'the paired .meta moved too' }
            @{ Name = 'IsAsmdef';     Type = 'bool';     Note = 'the moved asset is an .asmdef' }
            @{ Name = 'ReferencedBy'; Type = 'string[]'; Note = 'asmdefs that reference a moved .asmdef; informational, refs are by name/GUID and survive' }
        )
    }

    'Netscoot.GitAlias' = @{
        Summary = 'The git netscoot alias registration (or what would be registered).'
        Array   = $false
        Fields  = @(
            @{ Name = 'Alias';     Type = 'string'; Note = '' }
            @{ Name = 'Scope';     Type = 'string'; Note = '' }
            @{ Name = 'Forwarder'; Type = 'string'; Note = '' }
            @{ Name = 'Command';   Type = 'string'; Note = 'the git config command that was/would be run' }
        )
    }

    'Netscoot.RepairResult' = @{
        Summary = 'One dangling solution-membership or ProjectReference entry that was (or would be) repaired.'
        Array   = $true
        EmptyIsNull = $true
        Fields  = @(
            @{ Name = 'Kind';       Type = 'string';   Note = '' }
            @{ Name = 'Resolution'; Type = 'string';   Note = '' }
            @{ Name = 'Missing';    Type = 'string';   Note = '' }
            @{ Name = 'NewPath';    Type = 'string';   Note = '' }
            @{ Name = 'Container';  Type = 'string';   Note = '' }
            @{ Name = 'MissingAbs'; Type = 'string';   Note = '' }
            @{ Name = 'Candidates'; Type = 'string[]'; Note = 'same-named project files found, used to resolve NewPath' }
        )
    }

    'Netscoot.SyncResult' = @{
        Summary = 'One project added to a solution that was missing it, to resolve membership divergence.'
        Array   = $true
        EmptyIsNull = $true
        Fields  = @(
            @{ Name = 'Solution'; Type = 'string'; Note = 'repository-relative' }
            @{ Name = 'Added';    Type = 'string'; Note = 'repository-relative project path' }
        )
    }

    'Netscoot.ConsistencyResult' = @{
        Summary = 'One project whose solution membership diverges across the repository.'
        Array   = $true
        EmptyIsNull = $true
        Fields  = @(
            @{ Name = 'Project';    Type = 'string';   Note = '' }
            @{ Name = 'PresentIn';  Type = 'string[]'; Note = 'solution paths that list it' }
            @{ Name = 'AbsentFrom'; Type = 'string[]'; Note = 'solution paths that do not' }
        )
    }

    'Netscoot.Update' = @{
        Summary = 'Whether the installed Netscoot is behind the latest GitHub release.'
        Array   = $false
        Fields  = @(
            @{ Name = 'Installed';       Type = 'version';  Note = 'a [version], e.g. 2.1.0 (compares numerically)' }
            @{ Name = 'Latest';          Type = 'version?'; Note = 'a [version], $null if the tag could not be parsed' }
            @{ Name = 'Tag';             Type = 'string';   Note = '' }
            @{ Name = 'UpdateAvailable'; Type = 'bool';     Note = '' }
            @{ Name = 'Url';             Type = 'string';   Note = '' }
        )
    }

    'Netscoot.UpdatePolicy' = @{
        Summary = 'The effective auto-update policy and where it was resolved from.'
        Array   = $false
        Fields  = @(
            @{ Name = 'State';  Type = 'string'; Note = 'Enabled | Disabled | Manual' }
            @{ Name = 'Source'; Type = 'string'; Note = 'Process | User | Machine | Default' }
            @{ Name = 'Value';  Type = 'string'; Note = 'the raw NETSCOOT_AUTOUPDATE value, or $null' }
        )
    }

    'Netscoot.MetaIntegrity' = @{
        Summary = 'One Unity .meta integrity problem: An asset missing a .meta, or an orphan .meta.'
        Array   = $true
        EmptyIsNull = $true
        Fields  = @(
            @{ Name = 'Kind'; Type = 'string'; Note = 'MissingMeta | OrphanMeta' }
            @{ Name = 'Path'; Type = 'string'; Note = '' }
        )
    }
}
