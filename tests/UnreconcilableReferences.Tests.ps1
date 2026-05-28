#requires -Modules Pester

# Regression: under Set-StrictMode -Version Latest (which every netscoot module sets),
# Get-UnreconcilableReferences returned a bare scalar when a project had exactly ONE
# non-literal/conditional ProjectReference, so the `(Get-UnreconcilableReferences ...).Count`
# check in Write-UnreconcilableReferenceWarning threw "property 'Count' cannot be found" -
# aborting Move-DotnetProject before ShouldProcess. The call site now wraps with @(...).

BeforeAll {
    Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'src', 'NetscootShared', 'NetscootShared.psd1')) -Force
}

Describe 'Unreconcilable references (StrictMode .Count guard)' {
    It 'does not throw when a non-moved project has a single conditional ProjectReference' {
        InModuleScope NetscootShared {
            $root = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'nr_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Path ([System.IO.Path]::Combine($root, 'A')) -Force | Out-Null
            New-Item -ItemType Directory -Path ([System.IO.Path]::Combine($root, 'B')) -Force | Out-Null
            $a = [System.IO.Path]::Combine($root, 'A', 'A.csproj')
            $b = [System.IO.Path]::Combine($root, 'B', 'B.csproj')
            '<Project Sdk="Microsoft.NET.Sdk"></Project>' | Set-Content -LiteralPath $a
            # Exactly one ProjectReference, made unreconcilable by a Condition (single element ->
            # this is what used to unwrap to a scalar and break .Count).
            @'
<Project Sdk="Microsoft.NET.Sdk">
  <ItemGroup>
    <ProjectReference Include="..\A\A.csproj" Condition="'$(Flag)' == 'on'" />
  </ItemGroup>
</Project>
'@ | Set-Content -LiteralPath $b
            try {
                {
                    Write-UnreconcilableReferenceWarning -MovedProject $a `
                        -AllProjects @([pscustomobject]@{ FullName = $b }) `
                        -LiteralConsumers @() -WarningAction SilentlyContinue
                } | Should -Not -Throw
            } finally {
                Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
            }
        }
    }
}
