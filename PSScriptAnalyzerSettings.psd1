@{
    # Rules excluded for this project, each with a deliberate rationale. Everything else
    # (incl. PSUseApprovedVerbs, parse/correctness rules) stays enforced - see build.ps1 Analyze + CI.
    ExcludeRules = @(
        # Colored console output is an intentional part of the UX: red capability/abort
        # guidance, green status, and the Repair table. Not diagnostic logging.
        'PSAvoidUsingWriteHost'

        # Public state-changing cmdlets DO implement ShouldProcess (enforced by review). This
        # rule also fires on internal builder/writer helpers (New-MoveItem/New-MoveResult/
        # New-DotnetReferenceItems/Set-Raw*) and the delegating dispatchers, which are not
        # user-facing cmdlets.
        'PSUseShouldProcessForStateChangingFunctions'

        # Several internal helpers legitimately return collections (Find-Solutions,
        # Get-ImportPaths, Get-AsmdefReferencers, ...) and Repair-NetscootSolutionReferences is an
        # established plural name. Pluralization here is intentional.
        'PSUseSingularNouns'

        # OutputType is declared on the public cmdlets; internal helpers omit it by design.
        'PSUseOutputTypeCorrectly'

        # Internal calls to our own Invoke-Dotnet (ValueFromRemainingArguments) are positional
        # on purpose - that wrapper exists precisely to pass dotnet args through positionally.
        'PSAvoidUsingPositionalParameters'

        # False positive: some functions use a param only inside a nested helper via closure
        # (which the analyzer does not see as a use), and ShouldProcess-only params.
        'PSReviewUnusedParameter'
    )
}
