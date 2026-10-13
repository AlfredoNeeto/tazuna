<#
.SYNOPSIS
    PreToolUse hook: refuses a git push in any spelling, a destructive git command
    behind a global option, and a commit that would include a secret.

.DESCRIPTION
    Reads the hook payload from stdin and looks only at the git calls in the
    command.

    Push. Publishing is the owner's decision. Permission rules match a command by
    its first words, so `git -C . push` is not a `git push`: measured with
    claude -p on 2026-10-13, it went through the deny rule and published. This
    hook skips git's global options (-C, -c, --git-dir, --work-tree, ...) and
    denies push however it is spelled.

    Destructive commands. The same spelling slipped past the deny rules for
    reset --hard, clean and the rest of them. Behind a global option they are
    denied here; without one, the permission rules already hold.

    Commit. A commit behind a global option asks, as a plain commit does through
    the permission rules. Every commit is scanned for secrets: the staged
    changes, and the working tree too when the same command stages it (git add,
    commit -a), because this hook runs before the command and would otherwise see
    nothing staged.

    Why scan when permissions already deny reading .env: a deny rule on
    Read(.env) stops Claude opening the file, but it does not stop
    `git add . && git commit`, because the secret never passes through a Read
    call. Committing a credential is irreversible once pushed, so this is the one
    place a deterministic check earns its cost.

    Exit codes:
      0  allow, or ask through the JSON written to stdout
      2  block; stderr is fed back to Claude as the reason

    It fails OPEN on its own errors. A hook that blocks every commit because git
    was momentarily unavailable would be disabled within a day, and a disabled
    hook protects nothing.

    Under Cursor (-Agent cursor, as beforeShellExecution) the command arrives as
    `command`, and every answer is also a {"permission": ...} object on stdout.
#>
[CmdletBinding()]
param(
    [string]$Agent
)

$ErrorActionPreference = "Stop"

$script:cursor = ($Agent -eq "cursor")

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

# invariant: git is found by its program word - quoted or not, bare or at the end of a path, in any
# case, since Windows runs GIT and git.EXE alike. When the next word is the subcommand, it decides.
# When the next word is a global option, nothing after it is parsed as shell: a value written as
# a\ b, a` b, $(...) or "x y" cannot hide what follows, so the words below are looked for in the rest
# of the command. A rare false positive, such as git -C . stash push, is the price of that.
$gitProgram = '(?<![\w.-])["'']?(?:[^\s;&|"'']*[\\/])?git(?:\.exe)?["'']?(?=\s)'
$firstWord = '^\s+["'']?(?<word>[^\s"'']+)'

function Test-GitWord {
    # True when Word stands alone in Text, quoted or bare; --grep=push or push-all do not count.
    param([string]$Text, [string]$Word)
    return ($Text -match ('(?<![\w=/.\\-])["'']?' + [regex]::Escape($Word) + '["'']?(?![\w-])'))
}

# invariant: the subcommands user/settings.json denies besides push, looked for anywhere after a global option.
$destructivePatterns = @(
    '(?<![\w-])reset\b.*\s--hard\b',
    '(?<![\w=/.\\-])clean(?![\w-])',
    '(?<![\w-])branch\b.*\s(-d|-D|--delete)\b',
    '(?<![\w-])filter-branch\b',
    '(?<![\w-])filter-repo\b',
    '(?<![\w-])reflog\s+(delete|expire)\b',
    '(?<![\w-])update-ref\b.*\s-d\b',
    '(?<![\w-])worktree\s+remove\b',
    '(?<![\w-])remote\s+(remove|set-url)\b'
)
function Exit-Allow {
    if ($script:cursor) { [Console]::Out.Write('{"permission":"allow"}') }
    exit 0
}

function Exit-Block {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Reasons,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Advice
    )

    $message = @($Title, "")

    foreach ($reason in $Reasons) {
        $message += "  - $reason"
    }

    $message += ""
    $message += $Advice

    $text = ($message -join [Environment]::NewLine)

    if ($script:cursor) {
        [Console]::Out.Write((@{ permission = "deny"; user_message = $Title; agent_message = $text } | ConvertTo-Json -Compress))
        exit 2
    }

    [Console]::Error.Write($text)
    exit 2
}

function Exit-Ask {
    param([Parameter(Mandatory = $true)][string]$Reason)

    if ($script:cursor) {
        [Console]::Out.Write((@{ permission = "ask"; user_message = $Reason; agent_message = $Reason } | ConvertTo-Json -Compress))
        exit 0
    }

    $answer = @{ hookSpecificOutput = @{ hookEventName = "PreToolUse"; permissionDecision = "ask"; permissionDecisionReason = $Reason } }
    [Console]::Out.Write(($answer | ConvertTo-Json -Compress -Depth 4))
    exit 0
}

function Get-GitOutput {
    param([string]$Repository, [string[]]$Arguments)

    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $global:LASTEXITCODE = 0

    try {
        # why: stderr is discarded under Continue; under Stop each line would become a terminating NativeCommandError.
        $lines = @(& git -C $Repository @Arguments 2>$null)
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }

    # invariant: a failed git call contributes nothing; the hook fails open, never on a guess.
    if ($code -ne 0) { return }
    return $lines
}

function Get-SecretReason {
    param([string]$Repository, [bool]$WorkingTree)

    $files = @(Get-GitOutput -Repository $Repository -Arguments @("diff", "--cached", "--name-only"))
    $lines = @(Get-GitOutput -Repository $Repository -Arguments @("diff", "--cached", "--unified=0"))

    # why: this hook runs before the command, so whatever `git add` or `commit -a` will stage is still in the working tree.
    if ($WorkingTree) {
        $files += @(Get-GitOutput -Repository $Repository -Arguments @("diff", "HEAD", "--name-only"))
        $lines += @(Get-GitOutput -Repository $Repository -Arguments @("diff", "HEAD", "--unified=0"))

        foreach ($untracked in @(Get-GitOutput -Repository $Repository -Arguments @("ls-files", "--others", "--exclude-standard"))) {

            if (-not $untracked) { continue }
            $files += $untracked

            $info = New-Object System.IO.FileInfo (Join-Path $Repository $untracked)

            # why: a new file is the likeliest place for a pasted key; the size cap keeps a stray dump from stalling every commit.
            if ($info.Exists -and ($info.Length -le 1048576)) {
                $lines += @([System.IO.File]::ReadAllLines($info.FullName) | ForEach-Object { "+" + $_ })
            }
        }
    }

    $reasons = @()

    foreach ($file in @($files | Where-Object { $_ } | Select-Object -Unique)) {

        $leaf = Split-Path -Leaf $file

        foreach ($pattern in $secretFilePatterns) {
            if ($leaf -like $pattern) {
                $reasons += "$file is a secret-bearing file (matches '$pattern')"
                break
            }
        }
    }

    $addedLines = @($lines | Where-Object { $_ -like "+*" -and $_ -notlike "+++*" })

    foreach ($entry in $secretContentPatterns) {
        if ($addedLines | Where-Object { $_ -match $entry.Pattern } | Select-Object -First 1) {
            $reasons += "the commit would contain what looks like a $($entry.Name)"
        }
    }

    return $reasons
}

try {
    $raw = [Console]::In.ReadToEnd()

    if (-not $raw) {
        Exit-Allow
    }

    $payload = $raw | ConvertFrom-Json

    # invariant: only the .cursor/hooks.json entry acts on a Cursor payload; the
    # imported .claude/settings.json copy exits silently.
    if ($payload.PSObject.Properties["workspace_roots"] -and (-not $script:cursor)) {
        exit 0
    }

    $command = ""

    if ($payload.PSObject.Properties["tool_input"] -and $payload.tool_input -and $payload.tool_input.command) {
        $command = [string]$payload.tool_input.command
    }
    elseif ($script:cursor -and $payload.PSObject.Properties["command"] -and $payload.command) {
        $command = [string]$payload.command
    }

    if (-not $command) {
        Exit-Allow
    }

    $calls = @([regex]::Matches($command, $gitProgram, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase))

    if ($calls.Count -eq 0) {
        Exit-Allow
    }

    $workingDirectory = $null
    if ($payload.PSObject.Properties["cwd"]) { $workingDirectory = [string]$payload.cwd }

    if (-not $workingDirectory -or -not (Test-Path -LiteralPath $workingDirectory)) {
        $workingDirectory = (Get-Location).Path
    }

    $commits = @()
    $stagesAll = $false

    foreach ($call in $calls) {

        $after = $command.Substring($call.Index + $call.Length)
        if ($after -notmatch $firstWord) { continue }
        $word = $Matches["word"]

        if (-not $word.StartsWith("-")) {

            $words = ($after -split '[;&|\r\n]')[0].Trim()

            if ($word -eq "push") {
                Exit-Block -Title "Refusing to push: publishing is the owner's decision." `
                    -Reasons @("git push is denied, however git is called: $($call.Value.Trim()) $words") `
                    -Advice @("Leave the push to the owner and say what is ready to publish.")
            }

            if ($word -eq "add") { $stagesAll = $true }
            if ($word -eq "commit") { $commits += [PSCustomObject]@{ Global = $false; Words = $words } }
            continue
        }

        if (Test-GitWord -Text $after -Word "push") {
            Exit-Block -Title "Refusing to push: publishing is the owner's decision." `
                -Reasons @("a git command with a global option names push:$after") `
                -Advice @("Leave the push to the owner and say what is ready to publish.")
        }

        foreach ($pattern in $destructivePatterns) {
            if ($after -match $pattern) {
                Exit-Block -Title "Refusing a destructive git command written with a global option." `
                    -Reasons @("git$after matches $pattern, a command the user settings deny") `
                    -Advice @("Ask the owner to run it if it is really needed.")
            }
        }

        if (Test-GitWord -Text $after -Word "add") { $stagesAll = $true }
        if (Test-GitWord -Text $after -Word "commit") { $commits += [PSCustomObject]@{ Global = $true; Words = $after.Trim() } }
    }

    if ($commits.Count -eq 0) {
        Exit-Allow
    }

    $repository = $workingDirectory
    $first = $commits[0]

    # why: `git -C <path> commit` commits in <path>; a path the hook cannot read leaves the working directory.
    if ($first.Global -and ($first.Words -match '^-C\s+(?<path>"[^"]*"|''[^'']*''|\S+)')) {
        $target = $Matches["path"].Trim('"', "'")
        if (-not [System.IO.Path]::IsPathRooted($target)) { $target = Join-Path $workingDirectory $target }
        if (Test-Path -LiteralPath $target) { $repository = $target }
    }

    if (@($commits | Where-Object { $_.Words -match '(^|\s)(--all|-[A-Za-z]*a[A-Za-z]*)(?=\s|$)' }).Count -gt 0) {
        $stagesAll = $true
    }
    # Confirm we are inside a work tree before invoking git. Outside one, git
    # falls back to --no-index mode and prints its entire usage text to stderr,
    # which would appear as noise on every unrelated commit-shaped command.
    $module = Join-Path $PSScriptRoot (Join-Path ".." (Join-Path "scripts" "VerifyCommon.psm1"))

    if ((Test-Path -LiteralPath $module) -and (Test-Path -LiteralPath $repository)) {

        Import-Module $module -Force

        if (Test-GitWorkTree -Path $repository) {

            $reasons = @(Get-SecretReason -Repository $repository -WorkingTree $stagesAll)

            if ($reasons.Count -gt 0) {
                Exit-Block -Title "Refusing this commit: it would commit secrets." -Reasons $reasons `
                    -Advice @("Unstage them (git restore --staged <path>), add them to .gitignore,",
                              "and move the value into a local, uncommitted configuration file.")
            }
        }
    }

    if (@($commits | Where-Object { $_.Global }).Count -gt 0) {
        Exit-Ask -Reason "A git commit written with a global option skips the permission rule that asks before every commit."
    }

    Exit-Allow
}
catch {
    # Fail open: never block work because the hook itself broke.
    Exit-Allow
}
