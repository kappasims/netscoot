# The Kind of a Get-SolutionInventory item, surfaced as a real .NET enum so callers get
# tab-completion ([Netscoot.SolutionItemKind]::<Tab>) and a discoverable, type-safe sum type
# instead of bare strings. It still compares equal to its name (e.g. -eq 'UnreferencedProject'),
# so existing string filters keep working.
#
# Add-Type (not the PowerShell 'enum' keyword) on purpose: a keyword enum defined in a module is
# only visible to code that does 'using module', not to a normal Import-Module consumer, so it
# would not tab-complete at the prompt. A compiled type is loaded into the session and does.
# Guarded so re-importing in the same session does not throw "type already exists".
if (-not ('Netscoot.SolutionItemKind' -as [type])) {
    Add-Type -TypeDefinition @'
namespace Netscoot {
    public enum SolutionItemKind {
        Project,
        SolutionFolder,
        SolutionItem,
        UnreferencedProject
    }
}
'@
}
