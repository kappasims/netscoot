#requires -Modules Pester

# Guards against agent-discovery drift: every cmdlet the umbrella manifest advertises must appear in
# at least one .claude/skills/*/SKILL.md file. Otherwise an AI agent reading the repo's skill set
# can't discover the cmdlet through the skill body once the skill activates, and the cmdlet is
# effectively invisible to skill-driven workflows even though it ships and works.
#
# This is the same disease as the umbrella manifest drift that UmbrellaSurface.Tests.ps1 catches:
# declared vs delivered surface, no gate, hand-sync at release time. Closing it here.
#
# Description-level matching would be stronger (agents discover skills via descriptions, not bodies)
# but is too strict in practice - infrequent admin cmdlets live in a skill body without their own
# trigger. The realistic contract: every cmdlet must be FINDABLE in some skill (body or
# description), so once an agent activates the right skill it can pick the cmdlet out of the
# instructions. Use of the cmdlet name (not the verb-suffix-only form like "Move") is required.

BeforeAll {
    $script:repo = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:psd  = Join-Path $script:repo 'src/Netscoot/Netscoot.psd1'
    $script:skillRoot = Join-Path $script:repo '.claude/skills'
}

Describe 'Every exported cmdlet appears in at least one SKILL.md' {
    It 'has skill coverage for every name in Netscoot.psd1 FunctionsToExport' {
        $exported = @((Import-PowerShellDataFile -LiteralPath $script:psd).FunctionsToExport) | Sort-Object
        $skillText = (Get-ChildItem -LiteralPath $script:skillRoot -Recurse -Filter 'SKILL.md' |
            Get-Content -Raw) -join "`n"
        # `Move-Dotnet*` etc. patterns would let a skill mention "Move-Dotnet*" and silently cover the
        # whole family without naming any specific cmdlet, which defeats the discovery purpose. We
        # require the EXACT name (followed by a non-identifier char or end of string).
        $missing = foreach ($cmd in $exported) {
            if ($skillText -notmatch ('(?<![\w-])' + [regex]::Escape($cmd) + '(?![\w-])')) { $cmd }
        }
        @($missing).Count | Should -Be 0 -Because "the following exported cmdlets have no SKILL.md mention (agent-invisible): $((@($missing) -join ', '))"
    }
}
