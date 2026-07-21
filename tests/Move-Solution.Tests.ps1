#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot TestHelpers.ps1)
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Core' ('Netscoot.Core.psd1'))))) -Force

    function New-SlnFixture {
        param([ValidateSet('sln', 'slnx')][string]$Format = 'slnx')
        Copy-FixtureTemplate -Key "movesln-$Format" -Prefix 'netscoot_sln' -Build {
            $root = New-TempRoot -Prefix 'netscoot_sln'
            Push-Location $root
            try {
                & git init -q
                New-ClassLibProject -Name Lib -Directory (Join-Path $root (Join-Path 'src' ('Lib'))) | Out-Null
                & dotnet new sln -n Demo --format $Format | Out-Null
                $sln = (Get-ChildItem -LiteralPath $root -File | Where-Object { $_.Extension -in '.sln', '.slnx' }).FullName
                & dotnet sln $sln add (Join-Path $root (Join-Path 'src' (Join-Path 'Lib' ('Lib.csproj')))) | Out-Null
                & git add -A; & git commit -qm fixture | Out-Null
            } finally { Pop-Location }
            return $root
        }
    }
}

Describe 'Move-Solution' {
    It 'rebases project paths when a <Format> solution moves into a subfolder' -ForEach @(
        @{ Format = 'slnx' }, @{ Format = 'sln' }
    ) {
        $root = New-SlnFixture -Format $Format
        try {
            $sln = (Get-ChildItem -LiteralPath $root -File | Where-Object { $_.Extension -in '.sln', '.slnx' }).FullName
            $dest = Join-Path (Join-Path $root 'build') (Split-Path -Leaf $sln)

            $r = Move-Solution -Path $sln -Destination $dest -Confirm:$false -WarningAction SilentlyContinue
            $r.ProjectsRebased | Should -Be 1
            $dest | Should -Exist
            $sln | Should -Not -Exist

            # The moved solution still resolves its project. `dotnet sln list` is what would fail if
            # the rebase produced a wrong relative path; the build smoke is covered by
            # Move-DotnetProject.Tests.ps1's slnx variant, so we skip the per-format build here
            # (saves ~3s per format = ~6s total across both ForEach iterations).
            $listed = & dotnet sln $dest list
            ($listed -join "`n") | Should -Match 'Lib\.csproj'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
