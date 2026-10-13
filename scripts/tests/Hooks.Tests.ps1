[CmdletBinding()]
param([switch]$SkipSlow, [string]$Only)

. (Join-Path $PSScriptRoot "TestKit.ps1")

Start-Section "Git helpers"

$statusRepo = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-status-" + [guid]::NewGuid().ToString("N").Substring(0, 8))

try {
    New-Item -ItemType Directory -Path $statusRepo -Force | Out-Null
    $null = Invoke-GitCommand -RepositoryPath $statusRepo -Arguments @("init", "-q") -AllowFailure

    Set-Content -LiteralPath (Join-Path $statusRepo "tracked.txt") -Value "v1" -NoNewline
    $null = Invoke-GitCommand -RepositoryPath $statusRepo -Arguments @("add", "-A") -AllowFailure
    $null = Invoke-GitCommand -RepositoryPath $statusRepo `
        -Arguments @("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init") -AllowFailure

    Set-Content -LiteralPath (Join-Path $statusRepo "tracked.txt") -Value "v2" -NoNewline
    Set-Content -LiteralPath (Join-Path $statusRepo "new.txt") -Value "new" -NoNewline

    Test-Case -Name "status separates tracked changes from untracked files" -Check {

        $summary = Get-GitStatusSummary -RepositoryPath $statusRepo

        if ($summary.TrackedChanges -ne 1) { return "tracked = $($summary.TrackedChanges), expected 1" }
        if ($summary.UntrackedFiles -ne 1) { return "untracked = $($summary.UntrackedFiles), expected 1" }
        if ($summary.IsClean) { return "reported clean with pending changes" }

        return $true
    }

    Test-Case -Name "status reports a clean tree as clean" -Check {

        $null = Invoke-GitCommand -RepositoryPath $statusRepo -Arguments @("checkout", "--", "tracked.txt") -AllowFailure
        Remove-Item -LiteralPath (Join-Path $statusRepo "new.txt") -Force

        $summary = Get-GitStatusSummary -RepositoryPath $statusRepo

        if ($summary.IsClean) { return $true }
        return "reported dirty with nothing pending"
    }
}
finally {
    if (Test-Path -LiteralPath $statusRepo) {
        Remove-Item -LiteralPath $statusRepo -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Start-Section "Secret-commit hook"

# Run against an installed project: the hook imports VerifyCommon.psm1 from
# .claude/scripts, which only sits beside it after installation.
$hookRepo = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-hook-" + [guid]::NewGuid().ToString("N").Substring(0, 8))

try {
    New-Item -ItemType Directory -Path $hookRepo -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $hookRepo "App.csproj") -Value "<Project />" -NoNewline

    & (Join-Path $scriptsRoot "init-project.ps1") -Type dotnet -Path $hookRepo -NoTrust 6>$null | Out-Null

    $hookScript = Join-Path $hookRepo (Join-Path ".claude" (Join-Path "hooks" "block-secret-commit.ps1"))

    $null = Invoke-GitCommand -RepositoryPath $hookRepo -Arguments @("init", "-q") -AllowFailure

    function Invoke-Hook {
        param([string]$Command, [string]$WorkingDirectory)

        $payload = @{
            tool_name  = "Bash"
            cwd        = $WorkingDirectory
            tool_input = @{ command = $Command }
        } | ConvertTo-Json -Compress

        $previous = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $global:LASTEXITCODE = 0

        # Redirect the child's stderr: the hook writes its refusal there, and a
        # caller running under $ErrorActionPreference = 'Stop' would otherwise
        # see a NativeCommandError and treat this self-test as failed.
        $payload | & powershell -NoProfile -ExecutionPolicy Bypass -File $hookScript 2>$null | Out-Null
        $code = $LASTEXITCODE

        $ErrorActionPreference = $previous
        return $code
    }

    Test-Case -Name "hook allows a non-git command" -Check {
        $code = Invoke-Hook -Command "dotnet build" -WorkingDirectory $hookRepo
        if ($code -eq 0) { return $true }
        return "exit $code, expected 0"
    }

    Test-Case -Name "hook blocks a staged .env" -Check {

        Set-Content -LiteralPath (Join-Path $hookRepo ".env") -Value "TOKEN=abc" -NoNewline
        $null = Invoke-GitCommand -RepositoryPath $hookRepo -Arguments @("add", "-f", ".env") -AllowFailure

        $code = Invoke-Hook -Command "git commit -m wip" -WorkingDirectory $hookRepo

        $null = Invoke-GitCommand -RepositoryPath $hookRepo -Arguments @("rm", "--cached", ".env") -AllowFailure
        Remove-Item -LiteralPath (Join-Path $hookRepo ".env") -Force -ErrorAction SilentlyContinue

        if ($code -eq 2) { return $true }
        return "exit $code, expected 2"
    }

    Test-Case -Name "hook fails open outside a repository" -Check {
        $code = Invoke-Hook -Command "git commit -m wip" -WorkingDirectory ([System.IO.Path]::GetTempPath())
        if ($code -eq 0) { return $true }
        return "exit $code, expected 0"
    }
}
finally {
    if (Test-Path -LiteralPath $hookRepo) {
        Remove-Item -LiteralPath $hookRepo -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Start-Section "Verification gate"

# The gate is the mechanism behind "verification defines done". It once failed
# silently because a mandatory [string[]] parameter rejects empty strings, the
# resulting exception hit the fail-open catch, and the gate never fired. These
# cases exist so that cannot happen again unnoticed.
$gateProject = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-gate-" + [guid]::NewGuid().ToString("N").Substring(0, 8))

try {
    New-Item -ItemType Directory -Path $gateProject -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $gateProject "Program.cs") -Value "class P { }" -NoNewline
    Set-Content -LiteralPath (Join-Path $gateProject "App.csproj") -Value "<Project />" -NoNewline

    & (Join-Path $scriptsRoot "init-project.ps1") -Type dotnet -Path $gateProject -NoTrust 6>$null | Out-Null

    $hookDirectory = Join-Path $gateProject (Join-Path ".claude" "hooks")
    $stopHook = Join-Path $hookDirectory "require-verification.ps1"
    $baselineHook = Join-Path $hookDirectory "record-session-baseline.ps1"

    function Invoke-GateHook {
        param([string]$HookPath, [switch]$StopHookActive)

        $payload = @{ cwd = $gateProject }

        if ($StopHookActive) {
            $payload["stop_hook_active"] = $true
        }

        $json = $payload | ConvertTo-Json -Compress

        $previous = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $global:LASTEXITCODE = 0

        $json | & powershell -NoProfile -ExecutionPolicy Bypass -File $HookPath 2>$null | Out-Null
        $code = $LASTEXITCODE

        $ErrorActionPreference = $previous
        return $code
    }

    Test-Case -Name "gate allows when no baseline was recorded" -Check {
        $code = Invoke-GateHook -HookPath $stopHook
        if ($code -eq 0) { return $true }
        return "exit $code, expected 0"
    }

    Test-Case -Name "session baseline is recorded" -Check {
        $null = Invoke-GateHook -HookPath $baselineHook
        $baselineFile = Join-Path $gateProject (Join-Path ".claude" (Join-Path "state" "session-baseline.json"))
        if (Test-Path -LiteralPath $baselineFile) { return $true }
        return "no baseline file was written"
    }

    Test-Case -Name "gate allows when nothing changed" -Check {
        $code = Invoke-GateHook -HookPath $stopHook
        if ($code -eq 0) { return $true }
        return "exit $code, expected 0"
    }

    Test-Case -Name "gate BLOCKS an unverified change" -Check {

        Add-Content -LiteralPath (Join-Path $gateProject "Program.cs") -Value "// changed"

        $code = Invoke-GateHook -HookPath $stopHook
        if ($code -eq 2) { return $true }
        return "exit $code, expected 2 - the gate is not firing"
    }

    Test-Case -Name "gate blocks only once per turn" -Check {
        $code = Invoke-GateHook -HookPath $stopHook -StopHookActive
        if ($code -eq 0) { return $true }
        return "exit $code, expected 0 when stop_hook_active is set"
    }

    Test-Case -Name "gate allows after a recorded passing verification" -Check {

        Import-Module (Join-Path $gateProject (Join-Path ".claude" (Join-Path "scripts" "VerifyCommon.psm1"))) -Force

        $stateFile = Get-VerificationStateFile -ProjectRoot $gateProject

        $state = [PSCustomObject]@{
            fingerprint = Get-SourceFingerprint -ProjectRoot $gateProject
            testsRan    = $true
            completedAt = (Get-Date).ToString("o")
        }

        $state | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8

        $code = Invoke-GateHook -HookPath $stopHook
        if ($code -eq 0) { return $true }
        return "exit $code, expected 0"
    }

    Test-Case -Name "gate rejects a verification that skipped tests" -Check {

        $stateFile = Get-VerificationStateFile -ProjectRoot $gateProject

        $state = [PSCustomObject]@{
            fingerprint = Get-SourceFingerprint -ProjectRoot $gateProject
            testsRan    = $false
            completedAt = (Get-Date).ToString("o")
        }

        $state | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8

        $code = Invoke-GateHook -HookPath $stopHook
        if ($code -eq 2) { return $true }
        return "exit $code, expected 2 - a partial verification must not satisfy the gate"
    }

    # The spec-lean completion gate. Its input is upstream's own fixture set -
    # a complete report that passes at `standard` - so the case exercises the
    # real validator, not a stand-in. Each case first records a passing
    # verification for the current sources, so a block can only come from the
    # report check.
    # Same proof the hook uses: an interpreter that runs, not one on PATH. The
    # Store alias is on PATH, runs nothing, and would turn these cases red for
    # a reason that has nothing to do with the gate.
    $pythonFound = $false
    foreach ($candidate in @(@("python3"), @("python"), @("py", "-3"))) {

        if ($pythonFound) { break }
        if (-not (Get-Command $candidate[0] -CommandType Application -ErrorAction SilentlyContinue)) { continue }

        $previous = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $global:LASTEXITCODE = 0
        & $candidate[0] @($candidate | Select-Object -Skip 1) --version *> $null
        $pythonFound = ($LASTEXITCODE -eq 0)
        $ErrorActionPreference = $previous
    }

    # The skills come from the agent-skills CLI now, so the real validators are
    # the installed ones.
    $installedSkills = Join-Path (Get-ClaudeConfigDir) "skills"

    if (-not $pythonFound) {
        Skip-Case -Name "gate checks Verifier reports" -Reason "no python that runs"
    }
    elseif (-not ((Test-Path -LiteralPath (Join-Path $installedSkills "tlc-spec-lean\scripts")) -and
                  (Test-Path -LiteralPath (Join-Path $installedSkills "tlc-spec-driven\scripts")))) {
        Skip-Case -Name "gate checks Verifier reports" -Reason "tlc-spec-lean/tlc-spec-driven not installed - tazuna setup"
    }
    else {
        $skillCopy = Join-Path $gateProject (Join-Path ".claude" (Join-Path "skills" "tlc-spec-lean"))
        Copy-Item -LiteralPath (Join-Path $installedSkills "tlc-spec-lean") -Destination $skillCopy -Recurse -Force

        $feature = Join-Path $gateProject (Join-Path ".specs" (Join-Path "features" "probe"))
        New-Item -ItemType Directory -Path $feature -Force | Out-Null
        Copy-Item -Path (Join-Path $skillCopy (Join-Path "scripts" (Join-Path "fixtures" "*.md"))) -Destination $feature

        $report = Join-Path $feature "verification.md"

        # Copy-Item keeps the source's timestamp, which predates the session
        # baseline; left alone, the first case would pass without the validator
        # ever running.
        (Get-Item -LiteralPath $report).LastWriteTime = Get-Date

        function Set-PassingVerification {
            $state = [PSCustomObject]@{
                fingerprint = Get-SourceFingerprint -ProjectRoot $gateProject
                testsRan    = $true
                completedAt = (Get-Date).ToString("o")
            }
            $state | ConvertTo-Json | Set-Content -LiteralPath (Get-VerificationStateFile -ProjectRoot $gateProject) -Encoding UTF8
        }

        Test-Case -Name "gate allows a spec-lean report its validator accepts" -Check {
            Set-PassingVerification
            $code = Invoke-GateHook -HookPath $stopHook
            if ($code -eq 0) { return $true }
            return "exit $code, expected 0 - upstream's passing fixture was rejected"
        }

        Test-Case -Name "gate BLOCKS a spec-lean report its validator rejects" -Check {
            $text = (Get-Content -LiteralPath $report -Raw).Replace("**Verdict**: PASS", "**Verdict**: FAIL")
            Set-Content -LiteralPath $report -Value $text -Encoding UTF8 -NoNewline
            Set-PassingVerification

            $code = Invoke-GateHook -HookPath $stopHook
            if ($code -eq 2) { return $true }
            return "exit $code, expected 2 - a FAIL report written this session was accepted"
        }

        Test-Case -Name "gate ignores a rejected report older than the session" -Check {
            (Get-Item -LiteralPath $report).LastWriteTime = (Get-Date).AddDays(-1)
            Set-PassingVerification

            $code = Invoke-GateHook -HookPath $stopHook
            if ($code -eq 0) { return $true }
            return "exit $code, expected 0 - a report from an earlier session blocked this one"
        }

        Test-Case -Name "gate reports an unverified change and a rejected report together" -Check {

            # The hook blocks once per turn. When both gates fired, the report
            # gate once spent that block and the verification gate never spoke.
            (Get-Item -LiteralPath $report).LastWriteTime = Get-Date
            Add-Content -LiteralPath (Join-Path $gateProject "Program.cs") -Value "// changed again"

            $errorFile = [System.IO.Path]::GetTempFileName()

            try {
                $previous = $ErrorActionPreference
                $ErrorActionPreference = "Continue"
                $global:LASTEXITCODE = 0
                (@{ cwd = $gateProject } | ConvertTo-Json -Compress) | & powershell -NoProfile -ExecutionPolicy Bypass -File $stopHook 2> $errorFile | Out-Null
                $code = $LASTEXITCODE
                $ErrorActionPreference = $previous

                $reason = Get-Content -LiteralPath $errorFile -Raw
            }
            finally {
                Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
            }

            if ($code -ne 2) { return "exit $code, expected 2" }
            if ($reason -notmatch "Verifier report") { return "the report gate's reason is missing" }
            if ($reason -notmatch "verify\.ps1") { return "the verification gate's reason is missing" }
            return $true
        }

        # tlc-spec-driven, with the validator found where an installation puts
        # it - the configuration directory - rather than inside the project.
        $configDir = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-gate-config-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
        $previousConfigDir = $env:CLAUDE_CONFIG_DIR

        try {
            New-Item -ItemType Directory -Path (Join-Path $configDir "skills") -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $installedSkills "tlc-spec-driven") -Destination (Join-Path $configDir "skills") -Recurse -Force
            $env:CLAUDE_CONFIG_DIR = $configDir

            # Retire the spec-lean report so only spec-driven is in play.
            (Get-Item -LiteralPath $report).LastWriteTime = (Get-Date).AddDays(-1)

            $legacy = Join-Path $gateProject (Join-Path ".specs" (Join-Path "features" "legacy"))
            New-Item -ItemType Directory -Path $legacy -Force | Out-Null
            $validation = Join-Path $legacy "validation.md"

            Test-Case -Name "gate BLOCKS a spec-driven report its validator rejects" -Check {
                Set-Content -LiteralPath $validation -Value "## Validation`n`n**Result**: FAIL`n" -Encoding UTF8
                Set-PassingVerification

                $code = Invoke-GateHook -HookPath $stopHook
                if ($code -eq 2) { return $true }
                return "exit $code, expected 2 - a FAIL validation.md written this session was accepted"
            }

            Test-Case -Name "gate allows a spec-driven report its validator accepts" -Check {
                Set-Content -LiteralPath $validation -Value "## Validation`n`n**Result**: PASS`n`nEvidence: src/Export.cs:42`n" -Encoding UTF8
                Set-PassingVerification

                $code = Invoke-GateHook -HookPath $stopHook
                if ($code -eq 0) { return $true }
                return "exit $code, expected 0 - a PASS validation.md with evidence was rejected"
            }
        }
        finally {
            $env:CLAUDE_CONFIG_DIR = $previousConfigDir
            Remove-Item -LiteralPath $configDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
finally {
    if (Test-Path -LiteralPath $gateProject) {
        Remove-Item -LiteralPath $gateProject -Recurse -Force -ErrorAction SilentlyContinue
    }
}


Complete-TestFile
