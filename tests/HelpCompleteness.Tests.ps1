#requires -Modules Pester

# PowerShell silently drops a whole comment-based help block it cannot parse (for example a wrapped
# line that starts with '.word'), and the generated README reference then loses that cmdlet's help.

BeforeAll {
    . (Join-Path $PSScriptRoot TestHelpers.ps1)
    Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'src', 'Netscoot', 'Netscoot.psd1')) -Force
}

Describe 'Comment-based help' {
    It 'parses for every exported cmdlet, with a synopsis and a description for every parameter' {
        $common = [System.Management.Automation.PSCmdlet]::CommonParameters + [System.Management.Automation.PSCmdlet]::OptionalCommonParameters
        $problems = foreach ($cmd in (Get-Command -Module Netscoot -CommandType Function)) {
            $help = Get-Help $cmd.Name -Full
            $synopsis = "$($help.Synopsis)".Trim()
            if (-not $synopsis -or $synopsis.StartsWith($cmd.Name)) { "$($cmd.Name): no synopsis (the help block did not parse)"; continue }
            foreach ($name in $cmd.Parameters.Keys) {
                if ($name -in $common) { continue }
                $p = @($help.parameters.parameter | Where-Object { $_.name -eq $name })
                if (-not $p.Count -or -not "$($p[0].description.Text)".Trim()) { "$($cmd.Name) -$($name): no description" }
            }
        }
        @($problems) | Should -BeNullOrEmpty
    }
}
