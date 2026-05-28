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
}

Describe 'Pipeline-input gate (PathInputTransform)' {

    Context 'the attribute type is registered' {
        It 'exposes Netscoot.PathInputTransformAttribute as a real .NET type' {
            ('Netscoot.PathInputTransformAttribute' -as [type]) | Should -Not -BeNullOrEmpty
        }
    }

    Context 'accepts a path STRING from the pipeline' {
        # A string must BIND. The cmdlet may then emit a non-terminating "not found" error from its
        # process block (the path is fake), but that is NOT a binding/transformation failure - which
        # is the only thing this gate is responsible for. So we assert no transformation error fires.
        It '<Name> binds a piped path string (no transformation error)' -ForEach @(
            @{ Name = 'Move-DotnetProject' }, @{ Name = 'Move-PowerShell' }, @{ Name = 'Move-UnityAsset' }
            @{ Name = 'Move-Solution' }, @{ Name = 'Move-DotnetFile' }
        ) {
            $errs = $null
            './does/not/exist' | & $Name -Destination './elsewhere' -WhatIf -ErrorAction SilentlyContinue -ErrorVariable errs
            @($errs | Where-Object { $_.FullyQualifiedErrorId -like 'ParameterArgumentTransformationError*' }).Count |
                Should -Be 0 -Because 'a string path must bind'
        }
    }

    Context 'accepts a Get-ChildItem / Get-Item item (FileSystemInfo)' {
        It 'Get-ChildItem *.csproj | Move-DotnetProject works (real move)' {
            $root = New-TempRoot -Prefix 'gate'
            Push-Location $root
            try {
                & git init -q
                $lib = New-StubClassLib -Name Lib -Directory (Join-Path $root (Join-Path 'src' 'Lib'))
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
        $movers = @(
            @{ Name = 'Move-DotnetFile' }, @{ Name = 'Move-DotnetFolder' }, @{ Name = 'Move-DotnetProject' }
            @{ Name = 'Move-DotnetProjectTree' }, @{ Name = 'Move-MSBuildImport' }, @{ Name = 'Move-PowerShell' }
            @{ Name = 'Move-PowerShellModule' }, @{ Name = 'Move-PowerShellScript' }, @{ Name = 'Move-Solution' }
            @{ Name = 'Move-UnityAsset' }, @{ Name = 'Invoke-Netscoot' }
        )
        It '<Name> throws a transformation error on a piped result object' -ForEach $movers {
            $rec = [pscustomobject]@{ Project = 'p'; Path = 'p'; AssetPath = 'p'; ModulePath = 'p' }
            { $rec | & $Name -Destination './x' -WhatIf -ErrorAction Stop } |
                Should -Throw -ErrorId "ParameterArgumentTransformationError,$Name"
        }
    }

    Context 'reconcilers and analysis cmdlets share the same gate' {
        # The two non-move MUTATORS (Repair/Sync) and the read-only analysis cmdlets all take their
        # root/path ByValue through the same transform: a string or a FileSystemInfo binds, any other
        # object throws. This closes the report->reconciler dual-context and gives one pipeline contract.
        $gated = @(
            @{ Name = 'Repair-SolutionReferences' }, @{ Name = 'Sync-Solution' }
            @{ Name = 'Test-SolutionConsistency' }, @{ Name = 'Get-SolutionInventory' }
            @{ Name = 'Find-PathReference' }, @{ Name = 'Resolve-MoveEngine' }
            @{ Name = 'Test-UnityMetaIntegrity' }
        )
        It '<Name> rejects a piped result object' -ForEach $gated {
            $rec = [pscustomobject]@{ PSTypeName = 'Netscoot.SolutionItem'; Path = 'src/Lib/Lib.csproj'; Project = 'src/Lib/Lib.csproj' }
            { $rec | & $Name -ErrorAction Stop } |
                Should -Throw -ErrorId "ParameterArgumentTransformationError,$Name"
        }
        It '<Name> binds a piped path string (no transformation error)' -ForEach $gated {
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
