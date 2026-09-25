#requires -Modules Pester

# Guards the pipeline-input gate on the MUTATING move cmdlets (the [Netscoot.PathInputTransform()]
# attribute that replaced ValueFromPipelineByPropertyName + [Alias('FullName','Path','PSPath')]).
#
# Acceptable pipeline input is positively defined: a path STRING, or a Get-ChildItem/Get-Item item
# (System.IO.FileSystemInfo). Any other object (notably a read-only audit/result object) must throw a
# ParameterArgumentTransformationError instead of silently binding row-by-row and attempting moves.

# Decided at DISCOVERY time so the per-test -Skip below sees it: the native engine is Windows-only.
$script:IsWindowsHost = ($PSVersionTable.PSEdition -eq 'Desktop') -or
    ((Test-Path Variable:\IsWindows) -and (Get-Variable -Name IsWindows -ValueOnly))

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Core' ('Netscoot.Core.psd1'))))) -Force
    Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Unity' ('Netscoot.Unity.psd1'))))) -Force
    $onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or
        ((Test-Path Variable:\IsWindows) -and (Get-Variable -Name IsWindows -ValueOnly))
    if ($onWindows) {
        Import-Module (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'src' (Join-Path 'Netscoot.Native' ('Netscoot.Native.psd1'))))) -Force
    }

    function Assert-MoverBindsPipedString {
        param([string]$Name)
        $errs = $null
        './does/not/exist' | & $Name -Destination './elsewhere' -WhatIf -ErrorAction SilentlyContinue -ErrorVariable errs
        @($errs | Where-Object { $_.FullyQualifiedErrorId -like 'ParameterArgumentTransformationError*' }).Count |
            Should -Be 0 -Because 'a string path must bind'
    }

    function Assert-MoverRejectsPipedObject {
        param([string]$Name)
        $rec = [pscustomobject]@{ Project = 'p'; Path = 'p'; AssetPath = 'p'; ModulePath = 'p' }
        { $rec | & $Name -Destination './x' -WhatIf -ErrorAction Stop } |
            Should -Throw -ErrorId "ParameterArgumentTransformationError,$Name"
    }

    function Assert-GatedRejectsPipedObject {
        param([string]$Name)
        $rec = [pscustomobject]@{ PSTypeName = 'Netscoot.SolutionItem'; Path = 'src/Lib/Lib.csproj'; Project = 'src/Lib/Lib.csproj' }
        { $rec | & $Name -ErrorAction Stop } |
            Should -Throw -ErrorId "ParameterArgumentTransformationError,$Name"
    }

    function Assert-GatedBindsPipedString {
        param([string]$Name)
        # A string must BIND. The cmdlet may then fail downstream on the fake path (not found),
        # which is NOT a binding/transformation failure - the only thing this gate is about. So we
        # tolerate a terminating downstream error and assert only that it is not a transform error.
        $errs = $null; $caught = $null
        try {
            './does/not/exist' | & $Name -ErrorAction SilentlyContinue -ErrorVariable errs -WarningAction SilentlyContinue
        } catch { $caught = $_ }
        @($errs | Where-Object { $_.FullyQualifiedErrorId -like 'ParameterArgumentTransformationError*' }).Count |
            Should -Be 0 -Because 'a string path must bind'
        if ($caught) { $caught.FullyQualifiedErrorId | Should -Not -BeLike 'ParameterArgumentTransformationError*' }
    }
}

Describe 'Pipeline-input gate (PathInputTransform)' -Tag 'Integration' {

    Context 'the attribute type is registered' {
        It 'exposes Netscoot.PathInputTransformAttribute as a real .NET type' {
            ('Netscoot.PathInputTransformAttribute' -as [type]) | Should -Not -BeNullOrEmpty
        }
    }

    Context 'accepts a path STRING from the pipeline' {
        # A string must BIND. The cmdlet may then emit a non-terminating "not found" error from its
        # process block (the path is fake), but that is NOT a binding/transformation failure - which
        # is the only thing this gate is responsible for. So we assert no transformation error fires.
        It 'Move-DotnetProject binds a piped path string (no transformation error)' {
            Assert-MoverBindsPipedString -Name 'Move-DotnetProject'
        }
        It 'Move-PowerShell binds a piped path string (no transformation error)' {
            Assert-MoverBindsPipedString -Name 'Move-PowerShell'
        }
        It 'Move-UnityAsset binds a piped path string (no transformation error)' {
            Assert-MoverBindsPipedString -Name 'Move-UnityAsset'
        }
        It 'Move-Solution binds a piped path string (no transformation error)' {
            Assert-MoverBindsPipedString -Name 'Move-Solution'
        }
        It 'Move-DotnetFile binds a piped path string (no transformation error)' {
            Assert-MoverBindsPipedString -Name 'Move-DotnetFile'
        }
    }

    Context 'accepts a Get-ChildItem / Get-Item item (FileSystemInfo)' {
        It 'Get-ChildItem *.csproj | Move-DotnetProject works (real move)' {
            $root = New-TempRoot -Prefix 'gate'
            Push-Location $root
            try {
                & git init -q
                $lib = New-ClassLibProject -Name Lib -Directory (Join-Path $root (Join-Path 'src' 'Lib'))
                & dotnet new sln -n Demo --format slnx | Out-Null
                $sln = (Get-ChildItem -LiteralPath $root -File -Include '*.slnx').FullName
                & dotnet sln $sln add $lib | Out-Null
                & git add -A; & git commit -qm fixture | Out-Null

                $dest = Join-Path $root (Join-Path 'libs' 'Lib')
                # Pipe the FileInfo from Get-ChildItem; the transform takes its .FullName.
                Get-ChildItem -LiteralPath (Join-Path $root (Join-Path 'src' 'Lib')) -Filter '*.csproj' |
                    Move-DotnetProject -Destination $dest -RepositoryRoot $root -NoBuild -Confirm:$false

                Join-Path $dest 'Lib.csproj' | Should -Exist
            } finally { Pop-Location }
        }

        It 'Get-Item ./x.ps1 | Move-PowerShell works (real move)' {
            $root = New-TempRoot -Prefix 'gate'
            Push-Location $root
            try {
                & git init -q
                $script = Join-Path $root 'helper.ps1'
                Set-Content -LiteralPath $script -Value '# helper' -Encoding UTF8
                & git add -A; & git commit -qm fixture | Out-Null

                $dest = Join-Path $root (Join-Path 'shared' 'helper.ps1')
                Get-Item -LiteralPath $script | Move-PowerShell -Destination $dest -Confirm:$false

                $dest | Should -Exist
            } finally { Pop-Location }
        }
    }

    Context 'REJECTS read-only audit/result objects (the hazard)' {
        # These objects carry a .Project or .Path property that ByPropertyName used to bind. The
        # transform must throw on the whole-object input rather than bind its property.

        It 'Test-SolutionConsistency output does NOT bind into Move-DotnetProject' {
            $rec = [pscustomobject]@{ PSTypeName = 'Netscoot.ConsistencyResult'; Project = 'src/Lib/Lib.csproj'; Severity = 'Warning' }
            { $rec | Move-DotnetProject -Destination './x' -WhatIf -ErrorAction Stop } |
                Should -Throw -ErrorId 'ParameterArgumentTransformationError,Move-DotnetProject'
        }

        It 'Get-SolutionInventory output does NOT bind into Move-DotnetProject' {
            $rec = [pscustomobject]@{ PSTypeName = 'Netscoot.SolutionItem'; Solution = 'Demo.slnx'; Name = 'Lib'; Path = 'src/Lib/Lib.csproj' }
            { $rec | Move-DotnetProject -Destination './x' -WhatIf -ErrorAction Stop } |
                Should -Throw -ErrorId 'ParameterArgumentTransformationError,Move-DotnetProject'
        }

        It 'Test-UnityMetaIntegrity output does NOT bind into Move-UnityAsset' {
            $rec = [pscustomobject]@{ PSTypeName = 'Netscoot.MetaIntegrity'; Kind = 'OrphanMeta'; Path = 'Assets/Foo/Bar.cs.meta' }
            { $rec | Move-UnityAsset -Destination './Assets/x' -WhatIf -ErrorAction Stop } |
                Should -Throw -ErrorId 'ParameterArgumentTransformationError,Move-UnityAsset'
        }

        It 'the rejection message names the offending type and the supported shapes' {
            $rec = [pscustomobject]@{ Path = 'whatever' }
            $msg = $null
            try { $rec | Move-Solution -Destination './x' -WhatIf -ErrorAction Stop } catch { $msg = $_.Exception.Message }
            $msg | Should -Match 'Unsupported pipeline input'
            $msg | Should -Match 'FileSystemInfo'
        }
    }

    Context 'every mutator rejects an arbitrary object' {
        # One assertion per mover so a regression in any single param block is caught.
        It 'Move-DotnetFile throws a transformation error on a piped result object' {
            Assert-MoverRejectsPipedObject -Name 'Move-DotnetFile'
        }
        It 'Move-DotnetFolder throws a transformation error on a piped result object' {
            Assert-MoverRejectsPipedObject -Name 'Move-DotnetFolder'
        }
        It 'Move-DotnetProject throws a transformation error on a piped result object' {
            Assert-MoverRejectsPipedObject -Name 'Move-DotnetProject'
        }
        It 'Move-DotnetProjectTree throws a transformation error on a piped result object' {
            Assert-MoverRejectsPipedObject -Name 'Move-DotnetProjectTree'
        }
        It 'Move-MSBuildImport throws a transformation error on a piped result object' {
            Assert-MoverRejectsPipedObject -Name 'Move-MSBuildImport'
        }
        It 'Move-PowerShell throws a transformation error on a piped result object' {
            Assert-MoverRejectsPipedObject -Name 'Move-PowerShell'
        }
        It 'Move-PowerShellModule throws a transformation error on a piped result object' {
            Assert-MoverRejectsPipedObject -Name 'Move-PowerShellModule'
        }
        It 'Move-PowerShellScript throws a transformation error on a piped result object' {
            Assert-MoverRejectsPipedObject -Name 'Move-PowerShellScript'
        }
        It 'Move-Solution throws a transformation error on a piped result object' {
            Assert-MoverRejectsPipedObject -Name 'Move-Solution'
        }
        It 'Move-UnityAsset throws a transformation error on a piped result object' {
            Assert-MoverRejectsPipedObject -Name 'Move-UnityAsset'
        }
        It 'Invoke-Netscoot throws a transformation error on a piped result object' {
            Assert-MoverRejectsPipedObject -Name 'Invoke-Netscoot'
        }
    }

    Context 'reconcilers and analysis cmdlets share the same gate' {
        # The two non-move MUTATORS (Repair/Sync) and the read-only analysis cmdlets all take their
        # root/path ByValue through the same transform: a string or a FileSystemInfo binds, any other
        # object throws. This closes the report->reconciler dual-context and gives one pipeline contract.
        It 'Repair-SolutionReferences rejects a piped result object' {
            Assert-GatedRejectsPipedObject -Name 'Repair-SolutionReferences'
        }
        It 'Sync-Solution rejects a piped result object' {
            Assert-GatedRejectsPipedObject -Name 'Sync-Solution'
        }
        It 'Test-SolutionConsistency rejects a piped result object' {
            Assert-GatedRejectsPipedObject -Name 'Test-SolutionConsistency'
        }
        It 'Get-SolutionInventory rejects a piped result object' {
            Assert-GatedRejectsPipedObject -Name 'Get-SolutionInventory'
        }
        It 'Find-PathReference rejects a piped result object' {
            Assert-GatedRejectsPipedObject -Name 'Find-PathReference'
        }
        It 'Resolve-MoveEngine rejects a piped result object' {
            Assert-GatedRejectsPipedObject -Name 'Resolve-MoveEngine'
        }
        It 'Test-UnityMetaIntegrity rejects a piped result object' {
            Assert-GatedRejectsPipedObject -Name 'Test-UnityMetaIntegrity'
        }
        It 'Test-EditorSolutionGuard rejects a piped result object' {
            Assert-GatedRejectsPipedObject -Name 'Test-EditorSolutionGuard'
        }
        It 'Repair-SolutionReferences binds a piped path string (no transformation error)' {
            Assert-GatedBindsPipedString -Name 'Repair-SolutionReferences'
        }
        It 'Sync-Solution binds a piped path string (no transformation error)' {
            Assert-GatedBindsPipedString -Name 'Sync-Solution'
        }
        It 'Test-SolutionConsistency binds a piped path string (no transformation error)' {
            Assert-GatedBindsPipedString -Name 'Test-SolutionConsistency'
        }
        It 'Get-SolutionInventory binds a piped path string (no transformation error)' {
            Assert-GatedBindsPipedString -Name 'Get-SolutionInventory'
        }
        It 'Find-PathReference binds a piped path string (no transformation error)' {
            Assert-GatedBindsPipedString -Name 'Find-PathReference'
        }
        It 'Resolve-MoveEngine binds a piped path string (no transformation error)' {
            Assert-GatedBindsPipedString -Name 'Resolve-MoveEngine'
        }
        It 'Test-UnityMetaIntegrity binds a piped path string (no transformation error)' {
            Assert-GatedBindsPipedString -Name 'Test-UnityMetaIntegrity'
        }
        It 'Test-EditorSolutionGuard binds a piped path string (no transformation error)' {
            Assert-GatedBindsPipedString -Name 'Test-EditorSolutionGuard'
        }
        It 'Get-Item <dir> | Test-SolutionConsistency binds the directory item (no transformation error)' {
            $root = New-TempRoot -Prefix 'gate'
            $errs = $null
            Get-Item -LiteralPath $root | Test-SolutionConsistency -ErrorAction SilentlyContinue -ErrorVariable errs -WarningAction SilentlyContinue
            @($errs | Where-Object { $_.FullyQualifiedErrorId -like 'ParameterArgumentTransformationError*' }).Count |
                Should -Be 0 -Because 'a Get-Item directory must bind via its FullName'
        }
    }

    Context 'native mover (Windows-only)' {
        It 'Move-NativeProject rejects a piped result object' -Skip:(-not $script:IsWindowsHost) {
            $rec = [pscustomobject]@{ Project = 'src/Native/Native.vcxproj' }
            { $rec | Move-NativeProject -Destination './x' -WhatIf -ErrorAction Stop } |
                Should -Throw -ErrorId 'ParameterArgumentTransformationError,Move-NativeProject'
        }
        It 'Move-NativeProject binds a piped string (no transformation error)' -Skip:(-not $script:IsWindowsHost) {
            $errs = $null
            './does/not/exist.vcxproj' | Move-NativeProject -Destination './elsewhere' -WhatIf -ErrorAction SilentlyContinue -ErrorVariable errs
            @($errs | Where-Object { $_.FullyQualifiedErrorId -like 'ParameterArgumentTransformationError*' }).Count |
                Should -Be 0 -Because 'a string path must bind'
        }
    }
}
