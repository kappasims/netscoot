#requires -Modules Pester

# Regression: under Set-StrictMode -Version Latest (which every netscoot module sets),
# Get-UnreconcilableReferences returned a bare scalar when a project had exactly ONE
# non-literal/conditional ProjectReference, so the `(Get-UnreconcilableReferences ...).Count`
# check in Write-UnreconcilableReferenceWarning threw "property 'Count' cannot be found" -
# aborting Move-DotnetProject before ShouldProcess. The call site now wraps with @(...).

BeforeAll {
    . (Join-Path $PSScriptRoot TestHelpers.ps1)
    Import-Module ([System.IO.Path]::Combine($PSScriptRoot, '..', 'src', 'NetscootShared', 'NetscootShared.psd1')) -Force
}

Describe 'Unreconcilable references (StrictMode .Count guard)' {
    It 'does not throw when a non-moved project has a single conditional ProjectReference' {
        $root = New-TempRoot -Prefix 'netscoot_nr'
        try {
            New-Item -ItemType Directory -Path (Join-Path $root 'A') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $root 'B') -Force | Out-Null
            $a = Join-Path $root (Join-Path 'A' 'A.csproj')
            $b = Join-Path $root (Join-Path 'B' 'B.csproj')
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
            InModuleScope NetscootShared -Parameters @{ A = $a; B = $b } {
                param($A, $B)
                {
                    Write-UnreconcilableReferenceWarning -MovedProject $A `
                        -AllProjects @([pscustomobject]@{ FullName = $B }) `
                        -LiteralConsumers @() -WarningAction SilentlyContinue
                } | Should -Not -Throw
            }
        } finally {
            Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
        }
    }
}
