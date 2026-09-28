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

    It 'ships the plugin icon as a square PNG of at least 128px' {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:repoRoot 'src/.claude-plugin/icon.png'))
        [System.BitConverter]::ToString($bytes, 0, 8) | Should -Be '89-50-4E-47-0D-0A-1A-0A' -Because 'the file must be a PNG'
        $width = ([int]$bytes[16] -shl 24) -bor ([int]$bytes[17] -shl 16) -bor ([int]$bytes[18] -shl 8) -bor [int]$bytes[19]
        $height = ([int]$bytes[20] -shl 24) -bor ([int]$bytes[21] -shl 16) -bor ([int]$bytes[22] -shl 8) -bor [int]$bytes[23]
        $height | Should -Be $width -Because 'the directory requires a square icon'
        $width | Should -BeGreaterOrEqual 128 -Because 'the directory requires at least 128px'
    }

    It 'keeps the README title icon free of what the directory rejects' {
        $svg = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'docs/icon-title.svg'))
        $svg | Should -Not -Match $script:rejected
    }
}
