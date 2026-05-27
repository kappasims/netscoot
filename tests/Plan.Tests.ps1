#requires -Modules Pester

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Core' ('Netscoot.Core.psd1'))))) -Force
}

Describe 'Invoke-MovePlan (transaction engine)' {
    It 'detaches all items, then moves, then reattaches - in that order' {
        InModuleScope Netscoot.Shared {
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
        InModuleScope Netscoot.Shared {
            $seen = [System.Collections.Generic.List[string]]::new()
            $sb = { param($a, $b) $seen.Add("$a|$b") }.GetNewClosure()
            $items = @( New-MoveItem -Description 'X' -Reattach $sb -ReattachArgs @('one', 'two') )
            Invoke-MovePlan -Caption 't' -Items $items -Move { } | Out-Null
            $seen[0] | Should -Be 'one|two'
        }
    }

    It 'runs the move even with no reconciliation items' {
        InModuleScope Netscoot.Shared {
            $ran = [ref]$false
            $r = Invoke-MovePlan -Caption 't' -Items @() -Move ({ $ran.Value = $true }.GetNewClosure())
            $ran.Value | Should -BeTrue
            $r.Applied | Should -Be 0
        }
    }
}
