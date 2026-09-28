#requires -Modules Pester

# The plugin directory rejects an SVG icon with a style block, script, event handler, foreignObject,
# animation or external reference, so neither icon file may contain one.

BeforeAll {
    $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:rejected = '(?i)<style|<script|\son[a-z]+\s*=|<foreignObject|<animate|<set\b|href\s*=\s*"(?!#)'
}

Describe 'Icon files' {
    It 'keeps the plugin icon free of what the directory rejects' {
        $svg = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'src/.claude-plugin/icon.svg'))
        $svg | Should -Not -Match $script:rejected
    }

    It 'keeps the README title icon free of what the directory rejects' {
        $svg = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'docs/icon-title.svg'))
        $svg | Should -Not -Match $script:rejected
    }
}
