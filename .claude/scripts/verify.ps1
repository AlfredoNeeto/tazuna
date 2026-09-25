<#
.SYNOPSIS
    Canonical verification for this repository: the harness self-test.

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
    @{
        Name    = "harness self-test"
        Command = {
            & powershell -NoProfile -ExecutionPolicy Bypass `
                -File (Join-Path $PSScriptRoot "..\..\scripts\test-harness.ps1")
        }
        IsTest  = $true
    }
)

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

Push-Location $projectRoot

try {
    Write-Host ""
    Write-Host "Verification Harness"
    Write-Host "===================="
    Write-Host ""
    Write-Host "Project root: $projectRoot"

    if ($VerificationSteps.Count -eq 0) {
        throw ("No verification steps are defined. Edit " +
               ".claude\scripts\verify.ps1 and populate `$VerificationSteps " +
               "with this project's build and test commands.")
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
