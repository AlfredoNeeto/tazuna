<#
.SYNOPSIS
    Canonical verification for this repository.

.DESCRIPTION
    Runs the project's build, analysis and test steps and fails on the first
    one that reports a non-zero exit code, then checks the working tree diff for
    whitespace damage. Prints VERIFICATION PASSED or VERIFICATION FAILED and
    exits non-zero on failure.

    The steps are detected from the files in the repository, wherever they
    sit: .NET (the dotnet CLI, or Visual Studio's MSBuild and vstest.console
    for .NET Framework), Flutter and Dart, Node (npm, pnpm, yarn or bun, by
    lockfile), Python, Go, Rust, Maven, Gradle and Make. A step whose tool is
    not installed is skipped by name.

    When the sources are unchanged since the last full pass with the same
    arguments, it reports that pass instead of repeating it.

.PARAMETER Target
    .NET solution or project to verify. Discovered automatically when omitted.

.PARAMETER Configuration
    .NET configuration: Debug (default) or Release.

.PARAMETER SkipRestore
    Build .NET projects with --no-restore.

.PARAMETER SkipTests
    Skip the test steps. Use only when explicitly verifying a build-only change.

.PARAMETER Force
    Run every step even when the sources already passed.

.EXAMPLE
    .\.claude\scripts\verify.ps1

.EXAMPLE
    .\.claude\scripts\verify.ps1 -Configuration Release -Target .\src\MyApi\MyApi.csproj
#>
[CmdletBinding()]
param(
    [string]$Target,

    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug",

    [switch]$SkipRestore,

    [switch]$SkipTests,

    [switch]$Force
)

$ErrorActionPreference = "Stop"

# Detection and the runner live here, beside this script, so the project stays
# self-contained after being cloned somewhere the harness is absent - and a fix
# to detection arrives with `tazuna init`, which replaces the module but never this file.
Import-Module (Join-Path $PSScriptRoot "VerifyCommon.psm1") -Force

# ---------------------------------------------------------------------------
# Leave this empty to use detection. Fill it when the project's real commands
# are not what detection finds - a custom script, a suite that needs a flag, a
# stack it does not know. An explicit list always wins.
#
# Each step runs a native command and fails when it exits non-zero:
#   @{ Name = "npm run build"; Command = { npm run build } }
#   @{ Name = "npm test";      Command = { npm test }; IsTest = $true }
# ---------------------------------------------------------------------------
$VerificationSteps = @(
)

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

exit (Invoke-Verification -ProjectRoot $projectRoot -Parameters $PSBoundParameters -Body {

    if ($VerificationSteps.Count -eq 0) {

        $VerificationSteps = @(Get-DetectedStep -ProjectRoot $projectRoot -Target $Target -Configuration $Configuration -SkipRestore:$SkipRestore)

        if ($VerificationSteps.Count -gt 0) {
            Write-Host ("Detected: " + (($VerificationSteps | ForEach-Object { $_.Name + " @ " + $_.Directory }) -join ", "))
        }
    }

    Invoke-StepList -ProjectRoot $projectRoot -Step $VerificationSteps -SkipTests:$SkipTests
})
