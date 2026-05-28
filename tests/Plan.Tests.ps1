#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Core' ('Netscoot.Core.psd1'))))) -Force
}

Describe 'Invoke-MovePlan (transaction engine)' {
    It 'detaches all items, then moves, then reattaches - in that order' {
        InModuleScope NetscootShared {
            $log = [System.Collections.Generic.List[string]]::new()
            $items = @(
                New-MoveItem -Description 'A' -Detach ({ $log.Add('detachA') }.GetNewClosure()) -Reattach ({ $log.Add('reattachA') }.GetNewClosure())
                New-MoveItem -Description 'B' -Detach ({ $log.Add('detachB') }.GetNewClosure()) -Reattach ({ $log.Add('reattachB') }.GetNewClosure())
            )
            $r = Invoke-MovePlan -Caption 't' -Items $items -Move { $log.Add('move') }
            $r.Applied | Should -Be 2
            $r.Skipped | Should -Be 0
            ($log -join ',') | Should -Be 'detachA,detachB,move,reattachA,reattachB'
        }
    }

    It 'passes per-item args by splat (not as a single array argument)' {
        InModuleScope NetscootShared {
            $seen = [System.Collections.Generic.List[string]]::new()
            $sb = { param($a, $b) $seen.Add("$a|$b") }.GetNewClosure()
            $items = @( New-MoveItem -Description 'X' -Reattach $sb -ReattachArgs @('one', 'two') )
            Invoke-MovePlan -Caption 't' -Items $items -Move { } | Out-Null
            $seen[0] | Should -Be 'one|two'
        }
    }

    It 'runs the move even with no reconciliation items' {
        InModuleScope NetscootShared {
            $ran = [ref]$false
            $r = Invoke-MovePlan -Caption 't' -Items @() -Move ({ $ran.Value = $true }.GetNewClosure())
            $ran.Value | Should -BeTrue
            $r.Applied | Should -Be 0
        }
    }
}

Describe 'New-MoveResult' {
    It 'keeps the engine-specific extras in the order the caller wrote them' {
        InModuleScope NetscootShared {
            # An [ordered] -Extra must preserve insertion order so the emitted shape matches the
            # documented one (docs/output-types.psd1). A plain [hashtable] would enumerate by hash.
            $r = New-MoveResult -TypeName 'Netscoot.MoveResult' -Engine 'dotnet' -Source 'a' -Destination 'b' `
                -Performed $true -Extra ([ordered]@{ Solutions = @('S'); ConsumerCount = 1; OwnRefCount = 2; Built = $true })
            ($r.PSObject.Properties.Name -join ',') |
                Should -Be 'Engine,Source,Destination,Performed,SkippedCount,Solutions,ConsumerCount,OwnRefCount,Built'
            $r.PSObject.TypeNames[0] | Should -Be 'Netscoot.MoveResult'
        }
    }

    It 'always emits the uniform base shape first' {
        InModuleScope NetscootShared {
            $r = New-MoveResult -TypeName 'Netscoot.SolutionMoveResult' -Engine 'dotnet' -Source 'a' -Destination 'b' `
                -Performed $false -SkippedCount 3 -Extra ([ordered]@{ ProjectsRebased = 4 })
            $names = $r.PSObject.Properties.Name
            $names[0..4] | Should -Be @('Engine', 'Source', 'Destination', 'Performed', 'SkippedCount')
            $r.SkippedCount | Should -Be 3
        }
    }
}
