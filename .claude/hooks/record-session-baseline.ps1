<#
.SYNOPSIS
    SessionStart hook: records the source fingerprint the session began with.

.DESCRIPTION
    Writes .claude/state/session-baseline.json so the Stop hook can tell
    "this session changed code" from "this repository was already dirty when
    the session started".

    Without this baseline the Stop gate would have to block on any dirty tree,
    which would fire on sessions that only read or answered a question. A gate
    that cries wolf gets removed, and a removed gate guarantees nothing.

    Always exits 0. This hook only observes.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

try {
    $raw = [Console]::In.ReadToEnd()

    $projectRoot = $env:CLAUDE_PROJECT_DIR

    if ($raw) {
        $payload = $raw | ConvertFrom-Json

        if ($payload.cwd) {
            $projectRoot = [string]$payload.cwd
        }
    }

    if (-not $projectRoot -or -not (Test-Path -LiteralPath $projectRoot)) {
        exit 0
    }

    $module = Join-Path $PSScriptRoot (Join-Path ".." (Join-Path "scripts" "VerifyCommon.psm1"))

    if (-not (Test-Path -LiteralPath $module)) {
        exit 0
    }

    Import-Module $module -Force

    $stateFile = Join-Path $projectRoot (Join-Path ".claude" (Join-Path "state" "session-baseline.json"))
    $stateDirectory = Split-Path -Parent $stateFile

    if (-not (Test-Path -LiteralPath $stateDirectory)) {
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    }

    $baseline = [PSCustomObject]@{
        fingerprint = Get-SourceFingerprint -ProjectRoot $projectRoot
        recordedAt  = (Get-Date).ToString("o")
    }

    $baseline | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8

    exit 0
}
catch {
    # Observation only: never let this interfere with starting a session.
    exit 0
}
