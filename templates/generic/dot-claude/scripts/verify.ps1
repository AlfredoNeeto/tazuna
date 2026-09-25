<#
.SYNOPSIS
    Canonical verification for this repository.

.DESCRIPTION
    Runs the project's verification steps in order and fails on the first one
    that reports a non-zero exit code. Prints VERIFICATION PASSED or
    VERIFICATION FAILED and exits non-zero on failure.

    ---------------------------------------------------------------------
    THIS FILE MUST BE COMPLETED FOR THIS PROJECT.

    Fill in $VerificationSteps below with the real build and test commands.
    Until you do, the script fails on purpose: a verifier that passes without
    verifying anything is worse than no verifier at all, because it produces
    false confidence.
    ---------------------------------------------------------------------

.PARAMETER SkipTests
    Skip steps marked with IsTest = $true.

.EXAMPLE
    .\.claude\scripts\verify.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipTests
)

$ErrorActionPreference = "Stop"

# Invoke-Step, Test-GitWorkTree, Get-SourceFingerprint and
# Get-VerificationStateFile live here, beside this script, so the project
# stays self-contained after being cloned somewhere the harness is absent.
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
    # Leave this empty to use detection below. Fill it when the project's real
    # commands are not what detection would guess - a monorepo, a custom script,
    # a suite that needs a flag. An explicit list always wins.
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

Push-Location $projectRoot

try {
    Write-Host ""
    Write-Host "Verification Harness"
    Write-Host "===================="
    Write-Host ""
    Write-Host "Project root: $projectRoot"

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

        $isTest = $false

        if ($step.ContainsKey("IsTest")) {
            $isTest = [bool]$step.IsTest
        }

        if ($isTest -and $SkipTests) {
            Write-Host ""
            Write-Host "SKIP: $($step.Name) (-SkipTests)"
            continue
        }

        Invoke-Step -Name $step.Name -Action $step.Command
    }

    if ((Get-Command git -ErrorAction SilentlyContinue) -and (Test-GitWorkTree -Path $projectRoot)) {

        Invoke-Step -Name "git diff --check" -Action {
            git diff --check
        }

        Write-Host ""
        Write-Host "Working tree:"
        Write-Host ""

        git status --short
    }
    else {
        Write-Host ""
        Write-Host "SKIP: git checks (not a git work tree)"
    }

    # Record that this exact set of sources passed, so a Stop hook can tell
    # "verified" from "never run". -SkipTests is recorded honestly: a partial
    # run must not satisfy a gate that means "the tests pass".
    $stateFile = Get-VerificationStateFile -ProjectRoot $projectRoot
    $stateDirectory = Split-Path -Parent $stateFile

    if (-not (Test-Path -LiteralPath $stateDirectory)) {
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    }

    $state = [PSCustomObject]@{
        fingerprint = Get-SourceFingerprint -ProjectRoot $projectRoot
        target      = "VerificationSteps"
        testsRan    = (-not $SkipTests)
        completedAt = (Get-Date).ToString("o")
    }

    $state | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8

    Write-Host ""
    Write-Host "===================="
    Write-Host "VERIFICATION PASSED"
    Write-Host "===================="
    Write-Host ""
}
catch {
    Write-Host ""
    Write-Host "===================="
    Write-Host "VERIFICATION FAILED"
    Write-Host "===================="
    Write-Host ""
    Write-Host $_.Exception.Message
    Write-Host ""

    exit 1
}
finally {
    Pop-Location
}

exit 0
