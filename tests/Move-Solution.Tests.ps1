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

Describe 'Move-Solution' -Tag 'Integration' {
    It 'rebases project paths when a .slnx solution moves into a subfolder' {
        $root = New-SlnFixture -Format slnx
        try {
            $sln = (Get-ChildItem -LiteralPath $root -File | Where-Object { $_.Extension -in '.sln', '.slnx' }).FullName
            $dest = Join-Path (Join-Path $root 'build') (Split-Path -Leaf $sln)

            $r = Move-Solution -Path $sln -Destination $dest -Confirm:$false -WarningAction SilentlyContinue
            $r.ProjectsRebased | Should -Be 1
            $dest | Should -Exist
            $sln | Should -Not -Exist

            # A wrong rebased path fails the listing. The build smoke lives in Move-DotnetProject.Tests.ps1.
            $listed = & dotnet sln $dest list
            ($listed -join "`n") | Should -Match 'Lib\.csproj'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rebases project paths when a .sln solution moves into a subfolder' {
        $root = New-SlnFixture -Format sln
        try {
            $sln = (Get-ChildItem -LiteralPath $root -File | Where-Object { $_.Extension -in '.sln', '.slnx' }).FullName
            $dest = Join-Path (Join-Path $root 'build') (Split-Path -Leaf $sln)

            $r = Move-Solution -Path $sln -Destination $dest -Confirm:$false -WarningAction SilentlyContinue
            $r.ProjectsRebased | Should -Be 1
            $dest | Should -Exist
            $sln | Should -Not -Exist

            # A wrong rebased path fails the listing. The build smoke lives in Move-DotnetProject.Tests.ps1.
            $listed = & dotnet sln $dest list
            ($listed -join "`n") | Should -Match 'Lib\.csproj'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rebases solution items and other project types in a .sln' {
        $root = New-TempRoot -Prefix 'netscoot_sln'
        try {
            $sln = Join-Path $root 'Demo.sln'
            $text = @(
                'Microsoft Visual Studio Solution File, Format Version 12.00'
                'Project("{00D1A9C2-B5F0-4AF3-8072-F6C62B433612}") = "Db", "db\Db.sqlproj", "{11111111-1111-1111-1111-111111111111}"'
                'EndProject'
                'Project("{2150E333-8FDC-42A3-9474-1A3956D46DE8}") = "Solution Items", "Solution Items", "{22222222-2222-2222-2222-222222222222}"'
                "`tProjectSection(SolutionItems) = preProject"
                "`t`tREADME.md = README.md"
                "`tEndProjectSection"
                'EndProject'
            ) -join "`r`n"
            Set-Content -LiteralPath $sln -Value $text -NoNewline
            $r = Move-Solution -Path $sln -Destination (Join-Path $root (Join-Path 'build' 'Demo.sln')) -Force -Confirm:$false -NoJournal -WarningAction SilentlyContinue
            $r.ProjectsRebased | Should -Be 1
            $r.ItemsRebased | Should -Be 1
            $moved = Get-Content -LiteralPath (Join-Path $root (Join-Path 'build' 'Demo.sln')) -Raw
            $moved | Should -Match '"\.\.\\db\\Db\.sqlproj"'
            $moved | Should -Match '\t\t\.\.\\README\.md = \.\.\\README\.md\r\n'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rebases solution items and other project types in a .slnx' {
        $root = New-TempRoot -Prefix 'netscoot_sln'
        try {
            $slnx = Join-Path $root 'Demo.slnx'
            Set-Content -LiteralPath $slnx -Value '<Solution><Folder Name="/Solution Items/"><File Path="README.md" /></Folder><Project Path="db/Db.sqlproj" /></Solution>'
            $r = Move-Solution -Path $slnx -Destination (Join-Path $root (Join-Path 'build' 'Demo.slnx')) -Force -Confirm:$false -NoJournal -WarningAction SilentlyContinue
            $r.ProjectsRebased | Should -Be 1
            $r.ItemsRebased | Should -Be 1
            $moved = Get-Content -LiteralPath (Join-Path $root (Join-Path 'build' 'Demo.slnx')) -Raw
            $moved | Should -Match '<File Path="\.\./README\.md" />'
            $moved | Should -Match '<Project Path="\.\./db/Db\.sqlproj" />'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
