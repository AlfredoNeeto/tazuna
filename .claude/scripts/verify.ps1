<#
.SYNOPSIS
    Canonical verification for this repository: the harness self-test.

.DESCRIPTION
    Runs the project's verification steps in order and fails on the first one
    that reports a non-zero exit code. Prints VERIFICATION PASSED or
    VERIFICATION FAILED and exits non-zero on failure.

    When the sources are unchanged since the last full pass, it reports that
    pass instead of repeating it.

    ---------------------------------------------------------------------
    THIS FILE MUST BE COMPLETED FOR THIS PROJECT.

    Fill in $VerificationSteps below with the real build and test commands.
    Until you do, the script fails on purpose: a verifier that passes without
    verifying anything is worse than no verifier at all, because it produces
    false confidence.
    ---------------------------------------------------------------------

.PARAMETER SkipTests
    Skip steps marked with IsTest = $true.

.PARAMETER Force
    Run every step even when the sources already passed.

.EXAMPLE
    .\.claude\scripts\verify.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipTests,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# Invoke-Verification and Invoke-Step live here, beside this script, so the
# project stays self-contained after being cloned somewhere the harness is absent.
Import-Module (Join-Path $PSScriptRoot "VerifyCommon.psm1") -Force

# ---------------------------------------------------------------------------
# Define the verification steps for this project.
#
# Each step runs a native command. The step fails when the command exits
# non-zero. Order matters: put the cheapest, most likely to fail first.
#
# Examples:
#   @{ Name = "npm ci";        Command = { npm ci } }
#   @{ Name = "npm run build"; Command = { npm run build } }
#   @{ Name = "npm test";      Command = { npm test }; IsTest = $true }
#
#   @{ Name = "cargo build";   Command = { cargo build --locked } }
#   @{ Name = "cargo test";    Command = { cargo test };  IsTest = $true }
#
#   @{ Name = "make";          Command = { make } }
#   @{ Name = "pytest";        Command = { python -m pytest }; IsTest = $true }
# ---------------------------------------------------------------------------
$VerificationSteps = @(
    @{
        Name    = "harness self-test"
        Command = {
            & powershell -NoProfile -ExecutionPolicy Bypass `
                -File (Join-Path $PSScriptRoot "..\..\scripts\test-harness.ps1")
        }
        IsTest  = $true
    }
)

function Get-DetectedSteps {
    <#
        Works out how to build and test this project from what is on disk.

        The verification gate is only as useful as the verifier behind it. A
        project with no steps gets a gate that can never be satisfied, which is
        not a safety mechanism - it is an obstruction, and obstructions get
        switched off.

        Deliberately conservative: build and test commands only, never install
        or provisioning ones. A verifier that quietly runs `npm ci` is changing
        the thing it is measuring.
    #>
    param([Parameter(Mandatory = $true)][string]$Root)

    $steps = @()

    function Test-RootFile {
        param([string]$Pattern)
        return @(Get-ChildItem -LiteralPath $Root -Filter $Pattern -File -ErrorAction SilentlyContinue).Count -gt 0
    }

    if ((Test-RootFile "*.sln") -or (Test-RootFile "*.slnx") -or (Test-RootFile "*.csproj") -or
        (Test-RootFile "*.fsproj") -or (Test-RootFile "*.vbproj")) {

        $steps += @{ Name = "dotnet build"; Command = { dotnet build --configuration Release } }
        $steps += @{ Name = "dotnet test";  Command = { dotnet test --configuration Release --no-build }; IsTest = $true }
    }

    $packageJson = Join-Path $Root "package.json"

    if (Test-Path -LiteralPath $packageJson) {

        try {
            $scripts = (Get-Content -LiteralPath $packageJson -Raw | ConvertFrom-Json).scripts
        }
        catch {
            $scripts = $null
        }

        if ($scripts) {

            foreach ($name in @("typecheck", "lint", "build")) {

                if ($scripts.PSObject.Properties[$name]) {
                    $steps += @{ Name = "npm run $name"; Command = [scriptblock]::Create("npm run $name") }
                }
            }

            # `npm init` writes a "test" script that exits 1 with a message.
            # Running it would fail verification for every project that has no
            # tests yet, which is how people learn to pass -SkipTests.
            if ($scripts.PSObject.Properties["test"] -and
                ([string]$scripts.test -notlike "*no test specified*")) {

                $steps += @{ Name = "npm test"; Command = { npm test }; IsTest = $true }
            }
        }
    }

    if ((Test-RootFile "pyproject.toml") -or (Test-RootFile "setup.py") -or (Test-RootFile "requirements.txt")) {

        if ((Test-Path -LiteralPath (Join-Path $Root "tests")) -or (Test-RootFile "test_*.py")) {
            $steps += @{ Name = "pytest"; Command = { python -m pytest }; IsTest = $true }
        }
    }

    if (Test-RootFile "go.mod") {
        $steps += @{ Name = "go build"; Command = { go build ./... } }
        $steps += @{ Name = "go test";  Command = { go test ./... }; IsTest = $true }
    }

    if (Test-RootFile "Cargo.toml") {
        $steps += @{ Name = "cargo build"; Command = { cargo build --locked } }
        $steps += @{ Name = "cargo test";  Command = { cargo test }; IsTest = $true }
    }

    if (Test-RootFile "pom.xml") {
        $steps += @{ Name = "mvn verify"; Command = { mvn -B verify }; IsTest = $true }
    }
    elseif ((Test-RootFile "build.gradle") -or (Test-RootFile "build.gradle.kts")) {
        $steps += @{ Name = "gradle build"; Command = { gradle build }; IsTest = $true }
    }

    # Make last, and only alone: a Makefile beside a package.json is usually a
    # wrapper around the commands already detected.
    if (($steps.Count -eq 0) -and (Test-RootFile "Makefile")) {
        $steps += @{ Name = "make"; Command = { make } }
    }

    return $steps
}

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

exit (Invoke-Verification -ProjectRoot $projectRoot -Parameters $PSBoundParameters -Body {

    if ($VerificationSteps.Count -eq 0) {

        $VerificationSteps = @(Get-DetectedSteps -Root $projectRoot)

        if ($VerificationSteps.Count -gt 0) {
            Write-Host ("Detected: " + (($VerificationSteps | ForEach-Object { $_.Name }) -join ", "))
        }
    }

    if ($VerificationSteps.Count -eq 0) {
        throw ("Nothing to verify: no build or test commands were found for this project. " +
               "Edit .claude\scripts\verify.ps1 and populate `$VerificationSteps with " +
               "the commands that prove this project works.")
    }

    foreach ($step in $VerificationSteps) {

        if ($step.ContainsKey("IsTest") -and [bool]$step.IsTest -and $SkipTests) {
            Write-Host ""
            Write-Host "SKIP: $($step.Name) (-SkipTests)"
            continue
        }

        Invoke-Step -Name $step.Name -Action $step.Command
    }
})
