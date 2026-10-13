<#
.SYNOPSIS
    Self-test for the harness repository.

.DESCRIPTION
    Runs the checks that must hold for the harness to be trustworthy, and exits
    non-zero if any fails. This is the harness verifying itself: the same
    standard it asks of the projects it is installed into.

    The cases live in scripts\tests, one *.Tests.ps1 file per area. Every file
    runs in its own process, all at once, and the run fails when a file fails a
    case, crashes, prints no result, or exits contrary to its result.

    Everything that touches a configuration directory runs against a scratch
    directory, so the real ~/.claude is never the experiment.

.PARAMETER SkipSlow
    Skip the checks that shell out to Claude Code.

.PARAMETER Only
    Run only the cases whose name starts with this id and a space, e.g. -Only C12.
    Fails when no case ran, so a missing test cannot pass as green.

.EXAMPLE
    .\scripts\test-harness.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipSlow,
    [string]$Only
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "tests\Runner.ps1")

$files = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot "tests") -Filter *.Tests.ps1 -File | ForEach-Object { $_.FullName })

exit (Invoke-TestRun -Files $files -Only $Only -SkipSlow:$SkipSlow)
