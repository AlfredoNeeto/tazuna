<#
.SYNOPSIS
    Stop hook: refuses to end a turn that changed code without a passing verification.

.DESCRIPTION
    This is the mechanism behind the claim that verification defines "done".
    Without it, that claim is a sentence in AGENTS.md and rests entirely on the
    model remembering to act on it.

    Two gates, evaluated independently and reported together:

    Verification. Blocks only when all of these hold:
      - the project has a verifier (.claude/scripts/verify.ps1);
      - the source fingerprint changed since the session started;
      - no recorded verification matches the current sources with tests run.

    Verifier report. Blocks when a report a tlc-* skill's Verifier wrote in this
    session is rejected by that skill's own completion validator (see
    Get-ReportGateFailure). No python, or the skill not installed: not checked.

    Exit codes:
      0  allow the turn to end
      2  block; stderr is fed back to Claude as the reason

    Deliberate restraint:

      * It blocks ONCE. When `stop_hook_active` is set, Claude is already
        continuing because of this hook, so it steps aside and lets the agent
        decide. Claude Code independently caps consecutive blocks at 8; relying
        on that cap instead of stopping voluntarily would burn eight turns.
        Because it blocks once, both gates are evaluated before blocking: a
        block spent on one must not hide the other.

      * It fails OPEN on every error, on a missing verifier, on a missing
        baseline, and on an unchanged fingerprint. A gate that fires on sessions
        which changed nothing gets removed, and a removed gate guarantees
        nothing. Each gate fails open on its own, so an error in one does not
        switch the other off.

      * A run with -SkipTests does not satisfy it. A partial verification must
        not answer a question that means "the tests pass".
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function Exit-Allow {
    exit 0
}

function Exit-Block {
    param(
        # AllowEmptyString is required: a mandatory [string[]] rejects empty
        # elements, and these messages use blank lines for readability. Without
        # it the call throws, the outer catch fails open, and the gate silently
        # never fires.
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string[]]$Lines
    )

    [Console]::Error.Write(($Lines -join [Environment]::NewLine))
    exit 2
}

function Find-Python {
    # On Windows `python3` is often the Microsoft Store alias, which exists on
    # PATH and runs nothing. Only an interpreter that answers --version counts.
    foreach ($candidate in @(@("python3"), @("python"), @("py", "-3"))) {

        if (-not (Get-Command $candidate[0] -CommandType Application -ErrorAction SilentlyContinue)) { continue }

        # The Store alias writes to stderr; under 'Stop' that would throw.
        $previous = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $global:LASTEXITCODE = 0

        try {
            & $candidate[0] @($candidate | Select-Object -Skip 1) --version *> $null
            $code = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previous
        }

        if ($code -eq 0) { return , $candidate }
    }

    return $null
}

function Get-ReportGateFailure {
    <#
        Both spec skills end the same way: "the completion gate is a script,
        not a feeling". Upstream leaves running that script to the model. This
        runs it whenever a Verifier report was written in this session, so a
        feature cannot be declared done on a report its own validator rejects.
        The idea is harness-toolkit's ship gate; the code is not.

        tlc-implement is not here: it ships no validator for its
        .checks/<feature>.verified.md, and inventing one would be a second,
        unvalidated opinion of what its report must contain.

        Returns the rejecting validators' output, else $null.
    #>
    param(
        [string]$ProjectRoot,
        [datetime]$Since
    )

    $features = Join-Path $ProjectRoot (Join-Path ".specs" "features")
    if (-not (Test-Path -LiteralPath $features)) { return $null }

    # Both skills keep features under .specs/features/. checks.md marks a
    # spec-lean feature; spec-driven writes validation.md instead.
    $gates = @(
        @{ Skill = "tlc-spec-lean"; Report = "verification.md"; Marker = "checks.md"; Validator = "validate_verification.py" },
        @{ Skill = "tlc-spec-driven"; Report = "validation.md"; Marker = $null; Validator = "validate_state.py" }
    )

    $configDir = $env:CLAUDE_CONFIG_DIR
    if (-not $configDir) { $configDir = Join-Path $HOME ".claude" }

    $python = $null
    $rejected = @()

    foreach ($gate in $gates) {

        $reports = @(Get-ChildItem -LiteralPath $features -Directory | Where-Object {
                $report = Join-Path $_.FullName $gate.Report
                (Test-Path -LiteralPath $report) -and
                ((-not $gate.Marker) -or (Test-Path -LiteralPath (Join-Path $_.FullName $gate.Marker))) -and
                ((Get-Item -LiteralPath $report).LastWriteTime -ge $Since)
            })

        if ($reports.Count -eq 0) { continue }

        $relative = Join-Path "skills" (Join-Path $gate.Skill (Join-Path "scripts" $gate.Validator))
        $validator = @((Join-Path $ProjectRoot (Join-Path ".claude" $relative)), (Join-Path $configDir $relative)) |
            Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

        if (-not $validator) { continue }

        if (-not $python) { $python = Find-Python }
        if (-not $python) { return $null }

        foreach ($feature in $reports) {

            # Native stderr under 'Stop' would throw on the expected exit 1.
            $previous = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            $global:LASTEXITCODE = 0

            try {
                $output = @(& $python[0] @($python | Select-Object -Skip 1) $validator $feature.Name --root $ProjectRoot 2>&1 | ForEach-Object { "$_" })
                $code = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $previous
            }

            # 1 is "not done". 2 is a usage error: the gate's fault, not the work's.
            if ($code -eq 1) {
                $rejected += @("$($gate.Skill) / $($feature.Name) - $($gate.Validator):") + @($output | Select-Object -First 40) + @("")
            }
        }
    }

    if ($rejected.Count -eq 0) { return $null }
    return $rejected
}

function Get-VerificationFailure {
    <#
        The original gate. Returns the reason to block, or $null to allow.
    #>
    param([string]$ProjectRoot)

    $scriptsDirectory = Join-Path $ProjectRoot (Join-Path ".claude" "scripts")
    $verifyScript = Join-Path $scriptsDirectory "verify.ps1"
    $module = Join-Path $scriptsDirectory "VerifyCommon.psm1"

    # No verifier means nothing to enforce. Not this hook's business.
    if (-not (Test-Path -LiteralPath $verifyScript)) { return $null }
    if (-not (Test-Path -LiteralPath $module)) { return $null }

    Import-Module $module -Force

    $baselineFile = Join-Path $ProjectRoot (Join-Path ".claude" (Join-Path "state" "session-baseline.json"))

    # Without a baseline there is no way to know whether this session changed
    # anything, and guessing would mean blocking read-only sessions.
    if (-not (Test-Path -LiteralPath $baselineFile)) { return $null }

    $baseline = Get-Content -LiteralPath $baselineFile -Raw | ConvertFrom-Json
    $current = Get-SourceFingerprint -ProjectRoot $ProjectRoot

    # Nothing changed: there is nothing to verify.
    if ($current -eq $baseline.fingerprint) { return $null }

    $stateFile = Get-VerificationStateFile -ProjectRoot $ProjectRoot

    if (Test-Path -LiteralPath $stateFile) {

        $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json

        if ($state.fingerprint -eq $current) {

            if ($state.testsRan) { return $null }

            return @(
                "The code changed in this session and the last verification skipped the tests.",
                "",
                "Run the full verification before finishing:",
                "",
                "  .\.claude\scripts\verify.ps1",
                "",
                "-SkipTests does not satisfy this gate. If the tests cannot run, say so",
                "explicitly rather than reporting the work as complete."
            )
        }

        return @(
            "The code changed since the last passing verification.",
            "",
            "Run it again before finishing:",
            "",
            "  .\.claude\scripts\verify.ps1",
            "",
            "If it fails for reasons outside this task's scope, say so and name the",
            "failures. Do not weaken a test or narrow the verification to make it pass."
        )
    }

    return @(
        "This session changed code, and the verification has not been run.",
        "",
        "Run it before finishing:",
        "",
        "  .\.claude\scripts\verify.ps1",
        "",
        "A task is not complete while its verification is failing or unrun. If you",
        "believe verification does not apply here, say why rather than skipping it",
        "silently."
    )
}

try {
    $raw = [Console]::In.ReadToEnd()

    $projectRoot = $env:CLAUDE_PROJECT_DIR
    $stopHookActive = $false

    if ($raw) {
        $payload = $raw | ConvertFrom-Json

        if ($payload.cwd) {
            $projectRoot = [string]$payload.cwd
        }

        if ($payload.PSObject.Properties["stop_hook_active"]) {
            $stopHookActive = [bool]$payload.stop_hook_active
        }
    }

    # Already nudged once this turn. Saying it again would only repeat itself.
    if ($stopHookActive) {
        Exit-Allow
    }

    if (-not $projectRoot -or -not (Test-Path -LiteralPath $projectRoot)) {
        Exit-Allow
    }

    $block = @()

    # Each gate fails open on its own: an error in one must not switch off the other.
    try {
        $sessionBaseline = Join-Path $projectRoot (Join-Path ".claude" (Join-Path "state" "session-baseline.json"))

        if (Test-Path -LiteralPath $sessionBaseline) {

            $since = [datetime]::Parse((Get-Content -LiteralPath $sessionBaseline -Raw | ConvertFrom-Json).recordedAt)
            $rejected = Get-ReportGateFailure -ProjectRoot $projectRoot -Since $since

            if ($rejected) {
                $block += @(
                    "A Verifier report written in this session does not pass its skill's",
                    "completion gate, so the feature is not done:",
                    ""
                ) + $rejected + @(
                    "Fix what it names and re-run the Verifier. If the feature is genuinely",
                    "unfinished, say so plainly instead of reporting it complete."
                )
            }
        }
    }
    catch { }

    try {
        $unverified = Get-VerificationFailure -ProjectRoot $projectRoot

        if ($unverified) {
            if ($block.Count -gt 0) { $block += @("", "Also:", "") }
            $block += $unverified
        }
    }
    catch { }

    if ($block.Count -gt 0) {
        Exit-Block -Lines $block
    }

    Exit-Allow
}
catch {
    # Fail open: never block work because the gate itself broke.
    Exit-Allow
}
