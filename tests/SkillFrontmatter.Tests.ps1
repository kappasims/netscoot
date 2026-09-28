#requires -Modules Pester

# A skill whose frontmatter does not parse as YAML loads with its description silently dropped, so the
# agent never sees its triggers. A plain scalar breaks on text such as "code: moving", so every
# description is a folded block scalar, where no punctuation in the text can end the value.

BeforeAll {
    $script:skillRoot = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')) 'src/skills'
}

Describe 'Skill frontmatter' {
    It 'writes every skill description as a folded block scalar' {
        $plain = foreach ($file in Get-ChildItem -LiteralPath $script:skillRoot -Recurse -Filter 'SKILL.md') {
            $text = [System.IO.File]::ReadAllText($file.FullName) -replace "`r`n", "`n"
            if ($text -notmatch '(?s)\A---\nname: [a-z0-9-]+\ndescription: >-\n  \S[^\n]*\n---\n') {
                $file.Directory.Name
            }
        }
        @($plain).Count | Should -Be 0 -Because "these skills need 'description: >-' frontmatter: $(@($plain) -join ', ')"
    }
}
