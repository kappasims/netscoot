#requires -Modules Pester

BeforeAll {
    Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'src', 'NetscootShared', 'NetscootShared.psd1')) -Force
}

Describe 'ConvertFrom-Jsonc' {
    It 'parses plain JSON unchanged' {
        $o = ConvertFrom-Jsonc -Text '{ "a": 1, "b": "two" }'
        $o.a | Should -Be 1
        $o.b | Should -Be 'two'
    }

    It 'strips // line comments' {
        $o = ConvertFrom-Jsonc -Text "{ `"a`": 1 // trailing line comment`n}"
        $o.a | Should -Be 1
    }

    It 'strips /* block */ comments' {
        $o = ConvertFrom-Jsonc -Text '{ /* lead */ "a": 1 /* tail */ }'
        $o.a | Should -Be 1
    }

    It 'does NOT treat // inside a string value as a comment' {
        $o = ConvertFrom-Jsonc -Text '{ "url": "https://example.com/path" }'
        $o.url | Should -Be 'https://example.com/path'
    }

    It 'does NOT treat /* inside a string value as a comment' {
        $o = ConvertFrom-Jsonc -Text '{ "glob": "src/**/*.cs" }'
        $o.glob | Should -Be 'src/**/*.cs'
    }

    It 'respects an escaped quote inside a string (does not end the string early)' {
        $o = ConvertFrom-Jsonc -Text '{ "q": "a \" b // not a comment" }'
        $o.q | Should -Be 'a " b // not a comment'
    }

    It 'removes a trailing comma before a closing brace' {
        $o = ConvertFrom-Jsonc -Text '{ "a": 1, "b": 2, }'
        $o.b | Should -Be 2
    }

    It 'removes a trailing comma before a closing bracket' {
        $o = ConvertFrom-Jsonc -Text '{ "list": [1, 2, 3,] }'
        @($o.list).Count | Should -Be 3
    }

    It 'handles comments and trailing commas together' {
        $jsonc = @'
{
  // comment
  "a": 1,
  /* block */
  "nested": { "x": 1, },
  "arr": [ "y", ],
}
'@
        $o = ConvertFrom-Jsonc -Text $jsonc
        $o.a | Should -Be 1
        $o.nested.x | Should -Be 1
        @($o.arr).Count | Should -Be 1
    }

    It 'returns $null for empty or whitespace input' {
        ConvertFrom-Jsonc -Text '' | Should -BeNullOrEmpty
        ConvertFrom-Jsonc -Text "   `n  " | Should -BeNullOrEmpty
    }

    It 'throws on text that is still invalid JSON after comment stripping' {
        { ConvertFrom-Jsonc -Text '{ "a": }' } | Should -Throw
    }
}
