<#
.SYNOPSIS
    PreToolUse hook: refuses a git commit that would stage a secret.

.DESCRIPTION
    Reads the hook payload from stdin. When the tool call is a `git commit`, it
    inspects the staged changes and blocks the commit if a secret-looking file
    or value is about to be committed.

    Why this exists when permissions already deny reading .env:
    a deny rule on Read(.env) stops Claude opening the file, but it does not
    stop `git add . && git commit`, because the secret never passes through a
    Read call. Committing a credential is irreversible once pushed, so this is
    the one place a deterministic check earns its cost.

    Exit codes:
      0  allow (also used whenever the check cannot run, to fail open)
      2  block; stderr is fed back to Claude as the reason

    It fails OPEN on its own errors. A hook that blocks every commit because
    git was momentarily unavailable would be disabled within a day, and a
    disabled hook protects nothing.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# Filenames that should never be committed.
$secretFilePatterns = @(
    "*.env", ".env", ".env.*",
    "*.pem", "*.key", "*.pfx", "*.p12",
    "id_rsa", "id_rsa.*", "id_ed25519", "id_ed25519.*",
    ".credentials.json", "*.secret", "*.secrets"
)

# High-signal content patterns. Deliberately narrow: a noisy blocker gets
# switched off, and then it protects nothing.
$secretContentPatterns = @(
    @{ Name = "private key block"; Pattern = "-----BEGIN [A-Z ]*PRIVATE KEY-----" },
    @{ Name = "AWS access key id";  Pattern = "AKIA[0-9A-Z]{16}" },
    @{ Name = "GitHub token";       Pattern = "gh[pousr]_[A-Za-z0-9]{36}" },
    @{ Name = "Slack token";        Pattern = "xox[baprs]-[A-Za-z0-9-]{10,}" },
    @{ Name = "Google API key";     Pattern = "AIza[0-9A-Za-z_\-]{35}" },
    @{ Name = "Anthropic API key";  Pattern = "sk-ant-[A-Za-z0-9_\-]{20,}" },
    @{ Name = "OpenAI API key";     Pattern = "sk-[A-Za-z0-9]{32,}" }
)

function Exit-Allow {
    exit 0
}

function Exit-Block {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string[]]$Reasons
    )

    $message = @()
    $message += "Refusing this commit: it would commit secrets."
    $message += ""

    foreach ($reason in $Reasons) {
        $message += "  - $reason"
    }

    $message += ""
    $message += "Unstage them (git restore --staged <path>), add them to .gitignore,"
    $message += "and move the value into a local, uncommitted configuration file."

    [Console]::Error.Write(($message -join [Environment]::NewLine))
    exit 2
}

try {
    $raw = [Console]::In.ReadToEnd()

    if (-not $raw) {
        Exit-Allow
    }

    $payload = $raw | ConvertFrom-Json

    $command = ""

    if ($payload.tool_input -and $payload.tool_input.command) {
        $command = [string]$payload.tool_input.command
    }

    if (-not $command) {
        Exit-Allow
    }

    # Only interested in the moment work becomes a commit.
    if ($command -notmatch "\bgit\b[^|;&]*\bcommit\b") {
        Exit-Allow
    }

    $workingDirectory = $payload.cwd

    if (-not $workingDirectory -or -not (Test-Path -LiteralPath $workingDirectory)) {
        $workingDirectory = (Get-Location).Path
    }

    # Confirm we are inside a work tree before invoking git. Outside one, git
    # falls back to --no-index mode and prints its entire usage text to stderr,
    # which would appear as noise on every unrelated commit-shaped command.
    $module = Join-Path $PSScriptRoot (Join-Path ".." (Join-Path "scripts" "VerifyCommon.psm1"))

    if (-not (Test-Path -LiteralPath $module)) {
        Exit-Allow
    }

    Import-Module $module -Force

    if (-not (Test-GitWorkTree -Path $workingDirectory)) {
        Exit-Allow
    }

    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    $global:LASTEXITCODE = 0
    $stagedFiles = & git -C $workingDirectory diff --cached --name-only
    $stagedExit = $LASTEXITCODE

    $ErrorActionPreference = $previous

    if ($stagedExit -ne 0) {
        # Not a repository, or git unavailable. Fail open.
        Exit-Allow
    }

    $files = @($stagedFiles | Where-Object { $_ -and $_.Trim() -ne "" })

    if ($files.Count -eq 0) {
        Exit-Allow
    }

    $reasons = @()

    foreach ($file in $files) {

        $leaf = Split-Path -Leaf $file

        foreach ($pattern in $secretFilePatterns) {

            if ($leaf -like $pattern) {
                $reasons += "$file is a secret-bearing file (matches '$pattern')"
                break
            }
        }
    }

    # Scan the staged content itself, so a key pasted into an ordinary source
    # file is caught too.
    $ErrorActionPreference = "Continue"
    $global:LASTEXITCODE = 0
    $stagedDiff = & git -C $workingDirectory diff --cached --unified=0
    $diffExit = $LASTEXITCODE
    $ErrorActionPreference = $previous

    if ($diffExit -eq 0 -and $stagedDiff) {

        $addedLines = @($stagedDiff | Where-Object { $_ -like "+*" -and $_ -notlike "+++*" })

        foreach ($entry in $secretContentPatterns) {

            $match = $addedLines | Where-Object { $_ -match $entry.Pattern } | Select-Object -First 1

            if ($match) {
                $reasons += "staged content contains what looks like a $($entry.Name)"
            }
        }
    }

    if ($reasons.Count -gt 0) {
        Exit-Block -Reasons $reasons
    }

    Exit-Allow
}
catch {
    # Fail open: never block work because the hook itself broke.
    Exit-Allow
}
