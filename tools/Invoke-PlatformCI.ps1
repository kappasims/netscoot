#requires -Version 7.0
<#
.SYNOPSIS
    Trigger and watch the on-demand Linux + macOS test workflow (.github/workflows/platforms.yml).

.DESCRIPTION
    Linux and macOS are not in per-push CI (which runs Windows + Windows PowerShell 5.1); run this
    before a release to confirm them. It dispatches the workflow_dispatch run, waits for it to
    register, then streams it to completion. Needs the GitHub CLI (gh) authenticated for this repo.
    Exits non-zero if the run fails.

.PARAMETER Ref
    Branch or tag to run against. Defaults to the current branch.

.PARAMETER NoWatch
    Dispatch the run and return immediately without streaming it.

.EXAMPLE
    ./tools/Invoke-PlatformCI.ps1
    Runs the Linux + macOS tests against the current branch and waits for the result.

.EXAMPLE
    ./tools/Invoke-PlatformCI.ps1 -Ref master -NoWatch
    Kicks off a run on master and returns without waiting.
#>
[CmdletBinding()]
param(
    [string] $Ref,
    [switch] $NoWatch
)

$ErrorActionPreference = 'Stop'
$workflow = 'platforms.yml'

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) not found on PATH. Install it (https://cli.github.com) and run 'gh auth login'."
}

if (-not $Ref) {
    $Ref = (git rev-parse --abbrev-ref HEAD).Trim()
}

Write-Host "Dispatching $workflow on ref '$Ref'..." -ForegroundColor Cyan
# Record the newest run id before dispatch so we can identify the one we just created.
$before = (gh run list --workflow $workflow --limit 1 --json databaseId --jq '.[0].databaseId') 2>$null

gh workflow run $workflow --ref $Ref | Out-Null

# The new run takes a moment to appear in the list; poll briefly for an id newer than $before.
$runId = $null
foreach ($attempt in 1..15) {
    Start-Sleep -Seconds 2
    $latest = (gh run list --workflow $workflow --limit 1 --json databaseId --jq '.[0].databaseId') 2>$null
    if ($latest -and $latest -ne $before) { $runId = $latest; break }
}

if (-not $runId) {
    throw "Dispatched, but the new run did not appear within 30s. Check: gh run list --workflow $workflow"
}

Write-Host "Started run $runId." -ForegroundColor Green
if ($NoWatch) {
    Write-Host "Watch it with: gh run watch $runId"
    return
}

gh run watch $runId --exit-status
