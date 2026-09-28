#requires -Modules Pester

# The README heading shows docs/icon-title.svg, a 40px copy of the plugin icon. Markdown cannot size an
# image, so the copy exists only to change the size, and every other byte must match the plugin icon.

BeforeAll {
    $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
}

Describe 'Icon copies' {
    It 'keeps the README title icon identical to the plugin icon apart from its size' {
        $icon = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'src/.claude-plugin/icon.svg'))
        $title = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'docs/icon-title.svg'))
        $expected = $icon.Replace('width="128" height="128" viewBox', 'width="40" height="40" viewBox')
        $expected | Should -Not -BeExactly $icon -Because 'the plugin icon must declare width="128" height="128"'
        $title | Should -BeExactly $expected -Because 'docs/icon-title.svg is the plugin icon at 40px. Regenerate it from src/.claude-plugin/icon.svg'
    }
}
