<#
.SYNOPSIS
    Self-test for the harness repository.

.DESCRIPTION
    Runs the checks that must hold for the harness to be trustworthy, and exits
    non-zero if any fails. This is the harness verifying itself: the same
    standard it asks of the projects it is installed into.

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

Import-Module (Join-Path $PSScriptRoot "lib\Paths.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Files.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Json.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Console.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Git.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Manifest.psm1") -Force

$repoRoot = Split-Path -Parent $PSScriptRoot

# invariant: the self-test never changes the persisted user PATH; V14 compares against this.
$userPathAtStart = [Environment]::GetEnvironmentVariable("PATH", "User")
# hazard: tazuna test runs this script in the caller's process, so the variable is put back at
# the end; left set, a later tazuna setup in that shell would skip the PATH step.
$skipPathAtStart = $env:TAZUNA_SKIP_PATH
$env:TAZUNA_SKIP_PATH = "1"

# invariant: the self-test never writes into the real ~/.cursor; a case that wants Cursor
# present points this at a scratch directory of its own. Put back at the end, like the PATH flag.
$cursorDirAtStart = $env:TAZUNA_CURSOR_DIR
$env:TAZUNA_CURSOR_DIR = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-no-cursor-" + [guid]::NewGuid().ToString("N").Substring(0, 8))

$script:passed = 0
$script:failed = 0
$script:skipped = 0

function Test-Case {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Check
    )

    if ($Only -and (-not $Name.StartsWith($Only + " "))) { return }

    try {
        $result = & $Check

        if ($result -eq $true) {
            $script:passed++
            Write-Status -Label "PASS" -Detail $Name
        }
        else {
            $script:failed++
            Write-Status -Label "FAIL" -Detail "$Name -> $result"
        }
    }
    catch {
        $script:failed++
        Write-Status -Label "FAIL" -Detail "$Name -> $($_.Exception.Message)"
    }
}

function Skip-Case {
    param([string]$Name, [string]$Reason)

    if ($Only) { return }

    $script:skipped++
    Write-Status -Label "SKIP" -Detail "$Name ($Reason)"
}

function Get-RepoFile {
    <#
        Returns repository files, optionally restricted to a set of extensions.
        Extensions are filtered explicitly rather than with -Include, which does
        not filter when combined with -LiteralPath and silently returns
        everything.
    #>
    param([string[]]$Extension)

    # Ask git what is in the repository rather than walking the disk. These
    # checks exist to keep things out of commits, and a file git ignores is not
    # in the repository: the machine-local harness pointer legitimately holds an
    # absolute path, and a backup directory is transient. Walking the disk
    # reported both as defects.
    $listed = @(& git -C $repoRoot ls-files --cached --others --exclude-standard)

    if ($LASTEXITCODE -ne 0) {
        throw "Could not list repository files; is this still a git work tree?"
    }

    $items = @()

    foreach ($relative in $listed) {

        if (-not $relative) { continue }

        $full = Join-Path $repoRoot ($relative.Replace("/", [string][char]92))

        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $items += (Get-Item -LiteralPath $full -Force)
        }
    }

    if ($Extension) {
        $items = $items | Where-Object { $Extension -contains $_.Extension }
    }

    return @($items)
}

Write-Host ""
Write-Host "Harness Self-Test"
Write-Host "================="
Write-Host ""
Write-Host "Repository: $repoRoot"
Write-Host ""
Write-Host "Scripts"
Write-Host "-------"

$scriptFiles = Get-RepoFile -Extension ".ps1", ".psm1"

foreach ($file in $scriptFiles) {

    $relative = Get-CompatibleRelativePath -BasePath $repoRoot -TargetPath $file.FullName

    Test-Case -Name "parses under Windows PowerShell 5.1: $relative" -Check {
        $parseErrors = $null
        $null = [System.Management.Automation.PSParser]::Tokenize(
            (Get-Content -LiteralPath $file.FullName -Raw), [ref]$parseErrors)

        if ($parseErrors.Count -eq 0) { return $true }
        return $parseErrors[0].Message
    }
}

Write-Host ""
Write-Host "PowerShell 5.1 compatibility"
Write-Host "----------------------------"

# Operator forms only, so that string literals such as the git porcelain
# untracked marker "??" are not mistaken for the PowerShell 7 operator.
$forbidden = @(
    @{ Name = "[System.IO.Path]::GetRelativePath"; Pattern = "GetRelativePath" },
    @{ Name = "-AsHashtable";                      Pattern = "-AsHashtable" },
    @{ Name = "Join-String";                       Pattern = "Join-String" },
    @{ Name = "-AsByteStream";                     Pattern = "-AsByteStream" },
    @{ Name = "null-coalescing ??";                Pattern = "\s\?\?\s" },
    @{ Name = "pipeline chain ||";                 Pattern = "\s\|\|\s" },
    @{ Name = "pipeline chain &&";                 Pattern = "\s&&\s" },
    @{ Name = "unicode escape";                    Pattern = "``u\{" }
)

foreach ($entry in $forbidden) {

    Test-Case -Name "no executable use of $($entry.Name)" -Check {

        $hits = @()

        # This file names the forbidden APIs as data, so scanning it for them
        # would always match.
        $scanned = $scriptFiles | Where-Object { $_.Name -ne "test-harness.ps1" }

        foreach ($file in $scanned) {

            $inBlockComment = $false
            $lineNumber = 0

            foreach ($line in (Get-Content -LiteralPath $file.FullName)) {

                $lineNumber++
                $trimmed = $line.Trim()

                if ($trimmed -match "^<#") { $inBlockComment = $true }

                if ($inBlockComment) {
                    if ($trimmed -match "#>") { $inBlockComment = $false }
                    continue
                }

                if ($trimmed.StartsWith("#")) { continue }

                if ($line -match $entry.Pattern) {
                    $hits += "$($file.Name):$lineNumber"
                }
            }
        }

        if ($hits.Count -eq 0) { return $true }
        return ($hits -join ", ")
    }
}

Write-Host ""
Write-Host "Repository hygiene"
Write-Host "------------------"

Test-Case -Name "no hardcoded user paths" -Check {

    $hits = @(Get-RepoFile |
        Select-String -Pattern "C:\\Users\\[a-zA-Z]" -List |
        ForEach-Object { $_.Filename })

    if ($hits.Count -eq 0) { return $true }
    return ($hits -join ", ")
}

Test-Case -Name "no literal tabs in markdown" -Check {

    # A stray tab in a .md file is how a mangled backslash escape shows up:
    # "scripts	est-harness.ps1" written through a careless escape becomes a
    # real tab. The control-character check allows tabs, so it cannot see this.
    $withTabs = @()

    foreach ($file in (Get-RepoFile -Extension ".md")) {
        if ([System.IO.File]::ReadAllText($file.FullName).Contains([char]9)) {
            $withTabs += $file.Name
        }
    }

    if ($withTabs.Count -eq 0) { return $true }
    return ($withTabs -join ", ")
}

Test-Case -Name "no stray control characters" -Check {

    $bad = @()

    foreach ($file in (Get-RepoFile -Extension ".ps1", ".psm1", ".md", ".json")) {

        $offenders = [System.IO.File]::ReadAllText($file.FullName).ToCharArray() |
            Where-Object {
                $code = [int]$_
                (($code -lt 32) -and ($code -ne 9) -and ($code -ne 10) -and ($code -ne 13)) -or ($code -eq 127)
            }

        if ($offenders.Count -gt 0) { $bad += $file.Name }
    }

    if ($bad.Count -eq 0) { return $true }
    return ($bad -join ", ")
}

foreach ($jsonFile in (Get-RepoFile -Extension ".json")) {

    $relative = Get-CompatibleRelativePath -BasePath $repoRoot -TargetPath $jsonFile.FullName

    Test-Case -Name "valid JSON: $relative" -Check {
        $parseError = $null
        if (Test-JsonFile -Path $jsonFile.FullName -ErrorMessage ([ref]$parseError)) { return $true }
        return $parseError
    }
}

Test-Case -Name "gitignore blocks credentials and machine state" -Check {

    $mustIgnore = @(
        ".credentials.json", ".claude.json", "history.jsonl", "settings.local.json",
        ".harness-backup/x", ".env", "secret.key", "cert.pfx", "id_rsa", "projects/x"
    )

    $notIgnored = @()

    foreach ($candidate in $mustIgnore) {

        $result = Invoke-GitCommand `
            -RepositoryPath $repoRoot `
            -Arguments @("check-ignore", "-q", $candidate) `
            -AllowFailure

        if ($result.ExitCode -ne 0) { $notIgnored += $candidate }
    }

    if ($notIgnored.Count -eq 0) { return $true }
    return ("not ignored: " + ($notIgnored -join ", "))
}

Write-Host ""
Write-Host "Permissions"
Write-Host "-----------"

Test-Case -Name "no blanket shell allow rule" -Check {

    $blanket = @()

    foreach ($settingsFile in (Get-RepoFile -Extension ".json" | Where-Object { $_.Name -eq "settings.json" })) {

        $settings = Get-Content -LiteralPath $settingsFile.FullName -Raw | ConvertFrom-Json

        if ($settings.permissions -and $settings.permissions.allow) {

            foreach ($rule in @($settings.permissions.allow)) {

                if (($rule -match "^\s*(Bash|PowerShell)\s*\(\s*\*") -or
                    ($rule -eq "*") -or
                    ($rule -match "^(Bash|PowerShell)$")) {
                    $blanket += "$($settingsFile.Name): $rule"
                }
            }
        }
    }

    if ($blanket.Count -eq 0) { return $true }
    return ($blanket -join ", ")
}

Test-Case -Name "user settings protect the gate from being disarmed" -Check {

    # A gate that the agent can edit is not a deterministic mechanism. These
    # rules are ./-anchored so they cover a project's own .claude/, not the
    # template sources, which live under templates/<type>/dot-claude/.
    $settings = Get-Content -LiteralPath (Join-Path $repoRoot "user\settings.json") -Raw | ConvertFrom-Json
    $deny = @($settings.permissions.deny)

    $required = @(
        "Edit(./.claude/state/**)",
        "Edit(./.claude/hooks/**)",
        "Edit(./.claude/scripts/**)",
        "Edit(./.claude/settings.json)"
    )

    $missing = @($required | Where-Object { $deny -notcontains $_ })

    if ($missing.Count -eq 0) { return $true }
    return ("missing gate-integrity deny rules: " + ($missing -join ", "))
}

Test-Case -Name "templates confine reads to the working directory" -Check {

    # The only isolation control Claude Code offers on Windows. The built-in
    # Bash sandbox is bwrap/socat based and has no Windows implementation, so
    # enabling `sandbox` here would be a setting that does nothing.
    $missing = @()

    foreach ($template in (Get-ChildItem -LiteralPath (Join-Path $repoRoot "templates") -Directory)) {

        if ($template.Name.StartsWith("_")) { continue }

        $settingsPath = Join-Path $template.FullName "dot-claude\settings.json"
        $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json

        if (-not $settings.permissions.blockReadsOutsideWorkingDirectories) {
            $missing += $template.Name
        }
    }

    if ($missing.Count -eq 0) { return $true }
    return ("blockReadsOutsideWorkingDirectories not set in: " + ($missing -join ", "))
}

Test-Case -Name "V13 the verification command is pre-approved and nothing else runs through -File *" -Check {

    # The gate demands verification. If running the verifier itself needs
    # approval, the gate creates a deadlock the agent cannot resolve.
    $incomplete = @()

    $settingsPaths = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot "templates") -Directory |
        Where-Object { -not $_.Name.StartsWith("_") } | ForEach-Object { Join-Path $_.FullName "dot-claude\settings.json" })
    $settingsPaths += Join-Path $repoRoot ".claude\settings.json"

    foreach ($settingsPath in $settingsPaths) {

        $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        $allow = @($settings.permissions.allow)

        if (@($allow | Where-Object { $_ -like "*verify.ps1*" }).Count -eq 0) {
            $incomplete += $settingsPath
        }

        # why: an allow ending in "-File *" lets any script run without approval, not just the verifier.
        $wildcard = @($allow | Where-Object { $_.EndsWith("-File *)") })
        if ($wildcard.Count -gt 0) { return ("$settingsPath allows " + ($wildcard -join ", ")) }
    }

    if ($incomplete.Count -eq 0) { return $true }
    return ("no allow rule for verify.ps1 in: " + ($incomplete -join ", "))
}

Test-Case -Name "the fingerprint selects by exclusion, not an extension allowlist" -Check {

    # An allowlist silently misses whatever it forgot, and a gate that cannot
    # see a change permits ending the turn without verifying it.
    $module = Join-Path $repoRoot "templates\_shared\dot-claude\scripts\VerifyCommon.psm1"
    $text = Get-Content -LiteralPath $module -Raw

    if ($text -match '\$Extension\s*=\s*@\(') {
        return "Get-SourceFingerprint still takes an extension allowlist"
    }

    if ($text -notmatch 'excludedExtensions') {
        return "no exclusion list found"
    }

    return $true
}

Test-Case -Name "user settings deny push and secret reads" -Check {

    $settings = Get-Content -LiteralPath (Join-Path $repoRoot "user\settings.json") -Raw | ConvertFrom-Json
    $deny = @($settings.permissions.deny)

    $required = @("Bash(git push:*)", "PowerShell(git push:*)", "Read(**/.env)", "Edit(**/.env)")
    $missing = @($required | Where-Object { $deny -notcontains $_ })

    if ($missing.Count -eq 0) { return $true }
    return ("missing deny rules: " + ($missing -join ", "))
}

Write-Host ""
Write-Host "Templates"
Write-Host "---------"

$sharedRoot = Join-Path $repoRoot (Join-Path "templates" "_shared")

Test-Case -Name "_shared carries the files common to every template" -Check {

    $missing = @()

    foreach ($required in @(
        "dot-claude\scripts\VerifyCommon.psm1",
        "dot-claude\hooks\block-secret-commit.ps1",
        "dot-claude\hooks\record-session-baseline.ps1",
        "dot-claude\hooks\require-verification.ps1")) {

        if (-not (Test-Path -LiteralPath (Join-Path $sharedRoot $required))) {
            $missing += $required
        }
    }

    if ($missing.Count -eq 0) { return $true }
    return ("missing from _shared: " + ($missing -join ", "))
}

foreach ($template in (Get-ChildItem -LiteralPath (Join-Path $repoRoot "templates") -Directory)) {

    # _shared is content every template receives, not a template itself.
    if ($template.Name.StartsWith("_")) { continue }

    $name = $template.Name

    Test-Case -Name "template '$name' is complete" -Check {

        $missing = @()

        foreach ($required in @("AGENTS.md", "dot-claude\settings.json", "dot-claude\scripts\verify.ps1")) {
            if (-not (Test-Path -LiteralPath (Join-Path $template.FullName $required))) {
                $missing += $required
            }
        }

        if ($missing.Count -eq 0) { return $true }
        return ("missing: " + ($missing -join ", "))
    }

    Test-Case -Name "template '$name' AGENTS.md points at verify.ps1" -Check {

        $agentsFile = Join-Path $template.FullName "AGENTS.md"
        $hits = @(Select-String -Path $agentsFile -Pattern "verify\.ps1")

        if ($hits.Count -gt 0) { return $true }
        return "AGENTS.md never mentions verify.ps1"
    }

    Test-Case -Name "template '$name' wires the verification gate" -Check {

        $settingsPath = Join-Path $template.FullName "dot-claude\settings.json"
        $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json

        if (-not $settings.hooks) { return "no hooks configured" }

        $events = $settings.hooks.PSObject.Properties.Name

        foreach ($required in @("SessionStart", "Stop", "PreToolUse")) {
            if ($events -notcontains $required) { return "missing $required hook" }
        }

        return $true
    }
}

Write-Host ""
Write-Host "Agents and skills"
Write-Host "-----------------"

foreach ($agentFile in (Get-ChildItem -LiteralPath (Join-Path $repoRoot "user\agents") -File -Filter *.md -ErrorAction SilentlyContinue)) {

    Test-Case -Name "agent frontmatter: $($agentFile.Name)" -Check {

        $lines = Get-Content -LiteralPath $agentFile.FullName

        if ($lines[0].Trim() -ne "---") { return "no opening frontmatter delimiter" }
        if (-not ($lines | Where-Object { $_ -match "^name:\s*\S" })) { return "no name" }
        if (-not ($lines | Where-Object { $_ -match "^description:\s*\S" })) { return "no description" }

        return $true
    }
}

foreach ($skillFile in (Get-ChildItem -LiteralPath (Join-Path $repoRoot "user\skills") -Recurse -Filter SKILL.md -ErrorAction SilentlyContinue)) {

    Test-Case -Name "skill frontmatter: $($skillFile.Directory.Name)" -Check {

        $lines = Get-Content -LiteralPath $skillFile.FullName

        if ($lines[0].Trim() -ne "---") { return "no opening frontmatter delimiter" }
        if (-not ($lines | Where-Object { $_ -match "^description:\s*\S" })) { return "no description" }

        return $true
    }
}

Test-Case -Name "templates let skills read their own folder" -Check {

    # blockReadsOutsideWorkingDirectories turns every read of a skill's
    # references/ into a permission prompt - measured: the tlc-* skills stop on
    # the first one. This allow rule is what keeps them running unattended.
    $missing = @()

    foreach ($template in @("generic", "dotnet")) {
        $settings = Get-Content -LiteralPath (Join-Path $repoRoot "templates\$template\dot-claude\settings.json") -Raw | ConvertFrom-Json
        if (@($settings.permissions.allow) -notcontains "Read(~/.claude/skills/**)") { $missing += $template }
    }

    if ($missing.Count -gt 0) { return ("no Read(~/.claude/skills/**) allow in: " + ($missing -join ", ")) }
    return $true
}

Write-Host ""
Write-Host "Installer"
Write-Host "---------"

$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-selftest-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$previousConfigDir = $env:CLAUDE_CONFIG_DIR

try {
    $env:CLAUDE_CONFIG_DIR = $scratch

    Test-Case -Name "install -WhatIf writes nothing" -Check {

        & (Join-Path $PSScriptRoot "install.ps1") -WhatIf 6>$null | Out-Null

        if (-not (Test-Path -LiteralPath $scratch)) { return $true }
        return "the configuration directory was created during a dry run"
    }

    Test-Case -Name "install creates the harness" -Check {

        & (Join-Path $PSScriptRoot "install.ps1") 6>$null | Out-Null

        $missing = @()

        foreach ($required in @("CLAUDE.md", "settings.json")) {
            if (-not (Test-Path -LiteralPath (Join-Path $scratch $required))) {
                $missing += $required
            }
        }

        if ($missing.Count -eq 0) { return $true }
        return ("missing after install: " + ($missing -join ", "))
    }

    Test-Case -Name "install is idempotent" -Check {

        $output = & (Join-Path $PSScriptRoot "install.ps1") 6>&1 | Out-String

        # Match the summary counts, not the status labels: the word "Installed:"
        # in the summary line contains "INSTALL" and made this check vacuous.
        $summary = [regex]::Match($output, "Installed:\s*(\d+) created,\s*(\d+) updated")

        if (-not $summary.Success) { return "could not read the installer summary" }
        if ($summary.Groups[1].Value -ne "0") { return "a second run created $($summary.Groups[1].Value) file(s)" }
        if ($summary.Groups[2].Value -ne "0") { return "a second run updated $($summary.Groups[2].Value) file(s)" }
        if (Test-Path -LiteralPath (Join-Path $scratch ".harness-backup")) { return "a backup was taken with nothing to overwrite" }

        return $true
    }

    Test-Case -Name "install backs up before overwriting" -Check {

        $claudeMd = Join-Path $scratch "CLAUDE.md"
        Set-Content -LiteralPath $claudeMd -Value "LOCAL EDIT" -NoNewline

        & (Join-Path $PSScriptRoot "install.ps1") 6>$null | Out-Null

        $backup = Get-ChildItem -LiteralPath (Join-Path $scratch ".harness-backup") -Recurse -Filter "CLAUDE.md" -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if (-not $backup) { return "no backup was written" }
        if ((Get-Content -LiteralPath $backup.FullName -Raw).Trim() -ne "LOCAL EDIT") { return "the backup does not hold the replaced content" }

        return $true
    }

    Test-Case -Name "V5 install leaves skills and agents it does not ship where they are" -Check {

        # why: 1.0.0 has no earlier public version to retire, so anything user/ does not ship is the user's own.
        $theirs = @("skills\remember\SKILL.md", "agents\planner.md")
        foreach ($relative in $theirs) {
            $path = Join-Path $scratch $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            Set-Content -LiteralPath $path -Value "---`ndescription: written by the user`n---`n"
        }
        $before = @{}
        foreach ($relative in $theirs) { $before[$relative] = [System.IO.File]::ReadAllText((Join-Path $scratch $relative)) }

        $output = & (Join-Path $PSScriptRoot "install.ps1") 6>&1 | Out-String

        foreach ($relative in $theirs) {
            $path = Join-Path $scratch $relative
            if (-not (Test-Path -LiteralPath $path)) { return "$relative was moved" }
            if ([System.IO.File]::ReadAllText($path) -ne $before[$relative]) { return "$relative was changed" }
            $backup = @(Get-ChildItem -LiteralPath (Join-Path $scratch ".harness-backup") -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName.EndsWith("\" + $relative) })
            if ($backup.Count -gt 0) { return "$relative was copied into the backup" }
        }
        if ($output -match "RETIRED|KEPT") { return "install still reports a retirement" }

        $source = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "install.ps1"))
        foreach ($token in @("Get-RetiredInstall", "RETIRED")) {
            if ($source.Contains($token)) { return "install.ps1 still holds $token" }
        }
        $manifest = Import-Module (Join-Path $PSScriptRoot "lib\Manifest.psm1") -Force -PassThru
        $exported = @($manifest.ExportedFunctions.Keys | Sort-Object)
        if (($exported -join ",") -ne "Get-HarnessManifest") { return ("Manifest.psm1 exports: " + ($exported -join ", ")) }
        return $true
    }

    Test-Case -Name "health-check reports an orphaned skill" -Check {

        # Drift is two-directional. install.ps1 copies but never removes, so a
        # skill deleted from the repository stays installed and active while a
        # one-directional check reports everything matching.
        & (Join-Path $PSScriptRoot "install.ps1") 6>$null | Out-Null

        $orphan = Join-Path $scratch (Join-Path "skills" "selftest-orphan-probe")
        New-Item -ItemType Directory -Path $orphan -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $orphan "SKILL.md") -Value "---`ndescription: probe`n---`n" -NoNewline

        $output = & (Join-Path $PSScriptRoot "health-check.ps1") 6>&1 | Out-String

        Remove-Item -LiteralPath $orphan -Recurse -Force -ErrorAction SilentlyContinue

        if ($output -match "selftest-orphan-probe") { return $true }
        return "an orphaned skill was not reported"
    }

    Test-Case -Name "health-check fails on invalid settings" -Check {

        Set-Content -LiteralPath (Join-Path $scratch "settings.json") -Value "{ not json" -NoNewline

        & (Join-Path $PSScriptRoot "health-check.ps1") 6>$null | Out-Null

        if ($LASTEXITCODE -ne 0) { return $true }
        return "health-check passed with unparseable settings.json"
    }
}
finally {
    $env:CLAUDE_CONFIG_DIR = $previousConfigDir

    if (Test-Path -LiteralPath $scratch) {
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case -Name "health-check blames the missing runtime, not the network" -Check {

    # Reported from a second machine: serena registered fine with no uvx
    # installed, and the check said "network, or the service is down". That sent
    # someone to look at their connection for a server that had nothing to run.
    #
    # Reproduced by taking uv off PATH for this run only - surgically, so claude
    # and git stay reachable and the rest of the check still works.
    $catalogue = Get-Content -LiteralPath (Join-Path $repoRoot "mcp\servers.json") -Raw | ConvertFrom-Json

    $claude = Get-Command claude -ErrorAction SilentlyContinue

    if (-not $claude) { return "claude is not on PATH, so this cannot be probed" }

    $claudeDirectory = (Split-Path -Parent $claude.Source).TrimEnd("\")

    # Pick a server whose runtime does NOT live beside claude.exe. The first
    # version of this took uv off PATH, and uv shares a directory with claude
    # here - so the whole check degraded, every server reported "not registered"
    # and the case passed without ever reaching the branch it claims to test.
    $candidate = $null

    foreach ($property in $catalogue.mcpServers.PSObject.Properties) {

        if (-not $property.Value.command) { continue }

        $located = Get-Command $property.Value.command -ErrorAction SilentlyContinue

        if (-not $located) { continue }

        if ((Split-Path -Parent $located.Source).TrimEnd("\") -eq $claudeDirectory) { continue }

        $candidate = [PSCustomObject]@{
            Server    = $property.Name
            Command   = $property.Value.command
            Directory = (Split-Path -Parent $located.Source)
        }

        break
    }

    if (-not $candidate) {
        return "no catalogued stdio runtime could be hidden without also hiding claude"
    }

    $previousPath = $env:PATH

    try {

        $env:PATH = (($env:PATH -split ";") |
            Where-Object { $_ -and ($_.TrimEnd("\") -ne $candidate.Directory.TrimEnd("\")) }) -join ";"

        if (Get-Command $candidate.Command -ErrorAction SilentlyContinue) {
            return "could not take $($candidate.Command) off PATH, so this would prove nothing"
        }

        if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
            return "hiding $($candidate.Command) also hid claude, so this would prove nothing"
        }

        $output = & (Join-Path $PSScriptRoot "health-check.ps1") 6>&1 | Out-String
    }
    finally {
        $env:PATH = $previousPath
    }

    # No escape hatch. If the scenario did not reproduce, that is a failure to
    # investigate, not a pass.
    if ($output -match "$($candidate.Server) is declared but not registered") {
        return "the probe degraded the check instead of reproducing the scenario"
    }

    if ($output -notmatch "cannot start: '$($candidate.Command)' is not in PATH") {
        return "it did not name the missing runtime: $($candidate.Command)"
    }

    if ($output -match "$($candidate.Server) is registered but did not connect") {
        return "it still blamed the network for a missing runtime"
    }

    return $true
}

Write-Host ""
Write-Host "Git helpers"
Write-Host "-----------"

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

Write-Host ""
Write-Host "Secret-commit hook"
Write-Host "------------------"

# Run against an installed project: the hook imports VerifyCommon.psm1 from
# .claude/scripts, which only sits beside it after installation.
$hookRepo = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-hook-" + [guid]::NewGuid().ToString("N").Substring(0, 8))

try {
    New-Item -ItemType Directory -Path $hookRepo -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $hookRepo "App.csproj") -Value "<Project />" -NoNewline

    & (Join-Path $PSScriptRoot "init-project.ps1") -Type dotnet -Path $hookRepo -NoTrust 6>$null | Out-Null

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

Write-Host ""
Write-Host "Template deduplication"
Write-Host "----------------------"

Test-Case -Name "no file is duplicated between templates" -Check {

    $templatesRoot = Join-Path $repoRoot "templates"
    $byRelativePath = @{}
    $duplicates = @()

    $hasher = [System.Security.Cryptography.SHA256]::Create()

    foreach ($template in (Get-ChildItem -LiteralPath $templatesRoot -Directory)) {

        if ($template.Name.StartsWith("_")) { continue }

        foreach ($file in (Get-ChildItem -LiteralPath $template.FullName -File -Recurse -Force)) {

            $relative = Get-CompatibleRelativePath -BasePath $template.FullName -TargetPath $file.FullName
            $hash = [System.BitConverter]::ToString(
                $hasher.ComputeHash([System.IO.File]::ReadAllBytes($file.FullName))).Replace("-", "")

            if ($byRelativePath.ContainsKey($relative) -and ($byRelativePath[$relative] -eq $hash)) {
                $duplicates += $relative
            }

            $byRelativePath[$relative] = $hash
        }
    }

    if ($duplicates.Count -eq 0) { return $true }
    return ("identical in more than one template, belongs in _shared: " + ($duplicates -join ", "))
}

Write-Host ""
Write-Host "Dogfooding"
Write-Host "----------"

# The harness installs itself, so the same gate that protects other projects
# protects this one. If _shared changes and the harness is not reinstalled, its
# own copies drift and it stops testing what it ships.
Test-Case -Name "the harness installs the shared content it ships" -Check {

    $installed = Join-Path $repoRoot ".claude"

    if (-not (Test-Path -LiteralPath $installed)) {
        return "the harness has no .claude of its own; run init-project.ps1 -Type generic on it"
    }

    $stale = @()

    foreach ($file in (Get-ChildItem -LiteralPath $sharedRoot -File -Recurse -Force)) {

        $relative = Get-CompatibleRelativePath -BasePath $sharedRoot -TargetPath $file.FullName

        # payload dot-claude/ installs as .claude/, dot-cursor/ as .cursor/
        $segments = $relative.Split([System.IO.Path]::DirectorySeparatorChar)

        if ($segments[0] -eq "dot-claude") {
            $segments[0] = ".claude"
        }
        elseif ($segments[0] -eq "dot-cursor") {
            $segments[0] = ".cursor"
        }

        $relative = ($segments -join [System.IO.Path]::DirectorySeparatorChar)
        $mine = Join-Path $repoRoot $relative

        if (-not (Test-Path -LiteralPath $mine)) {
            $stale += "$relative (missing)"
            continue
        }

        if (-not (Test-FileContentEqual -ReferenceFile $file.FullName -DifferenceFile $mine)) {
            $stale += "$relative (differs)"
        }
    }

    if ($stale.Count -eq 0) { return $true }
    return ("out of date with templates/_shared: " + ($stale -join ", ") + " - re-run init-project.ps1 -Type generic -Force")
}

Test-Case -Name "the harness verification runs the self-test" -Check {

    $ownVerify = Join-Path $repoRoot (Join-Path ".claude" (Join-Path "scripts" "verify.ps1"))

    if (-not (Test-Path -LiteralPath $ownVerify)) { return "no .claude/scripts/verify.ps1" }

    $hits = @(Select-String -Path $ownVerify -Pattern "test-harness.ps1")

    if ($hits.Count -gt 0) { return $true }
    return "verify.ps1 does not run test-harness.ps1, so the gate would pass without verifying anything"
}

Test-Case -Name "the harness has its own project instructions" -Check {

    $agents = Join-Path $repoRoot "AGENTS.md"

    if (-not (Test-Path -LiteralPath $agents)) { return "no AGENTS.md at the repository root" }

    $hits = @(Select-String -Path $agents -Pattern 'verify\.ps1')

    if ($hits.Count -gt 0) { return $true }
    return "AGENTS.md does not name the verification command"
}

Write-Host ""
Write-Host "Detection"
Write-Host "---------"

# init-project.ps1 used to demand -Type and -Path on every run. They are detected
# now, and a detector is only worth having if it is right: each case below
# asserts the file that ONLY that template installs.
#
# A plain function, not a scriptblock parameter. Test-Case runs its -Check in its
# own scope, so a scriptblock passed in here would see $null for everything;
# .GetNewClosure() fixes the variables and then breaks command resolution,
# because it binds the block to a new dynamic module that cannot see the
# harness module's functions. Script-level functions are visible from inside a
# -Check block, so this is the shape that works.
function Invoke-DetectionCase {
    param(
        # Files to create in a fresh temporary project, path -> content.
        [Parameter(Mandatory = $true)][hashtable]$Files,

        # Paths that must exist under the project after init-project.ps1 runs.
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Expect,

        # Paths that must NOT exist. This is where the opt-outs are proved.
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]]$Reject = @()
    )

    $project = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-detect-" + [guid]::NewGuid().ToString("N").Substring(0, 8))

    try {

        New-Item -ItemType Directory -Path $project -Force | Out-Null

        foreach ($name in $Files.Keys) {
            Set-Content -LiteralPath (Join-Path $project $name) -Value $Files[$name] -NoNewline
        }

        # A HASHTABLE splat, not an array one. Splatting an array passes its
        # elements positionally, so @("-Path", $project) bound "-Path" to $Type
        # and the run died on an unknown template.
        # NoTrust always: the suite must not write temporary directories into
        # the real ~/.claude.json. Trust has its own cases, against a
        # CLAUDE_CONFIG_DIR of their own.
        $parameters = @{ Path = $project; NoTrust = $true }

        & (Join-Path $PSScriptRoot "init-project.ps1") @parameters 6>$null | Out-Null

        if ($LASTEXITCODE -ne 0) { return "init-project.ps1 exited $LASTEXITCODE" }

        foreach ($path in $Expect) {

            if (-not (Test-Path -LiteralPath (Join-Path $project $path))) {
                return "$path was not installed"
            }
        }

        foreach ($path in $Reject) {

            if (Test-Path -LiteralPath (Join-Path $project $path)) {
                return "$path was installed and should not have been"
            }
        }

        return $true
    }
    finally {
        Remove-Item -LiteralPath $project -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case -Name "a .NET repository gets the dotnet template with no -Type" -Check {

    # csharp.md ships only in templates/dotnet, so it proves which template ran.
    return (Invoke-DetectionCase `
        -Files @{ "App.csproj" = "<Project />" } `
        -Expect @(".claude\rules\csharp.md"))
}

Test-Case -Name "a repository with no .NET project falls back to generic" -Check {

    return (Invoke-DetectionCase `
        -Files @{ "notes.txt" = "nothing to detect" } `
        -Expect @(".claude\scripts\verify.ps1") `
        -Reject @(".claude\rules\csharp.md"))
}

Test-Case -Name "user settings hide the toolkit's harness-init skill" -Check {

    # `tlc harness install` links harness-init into ~/.claude/skills on every
    # install and update, and its doctor fails when the link is gone - so it is
    # hidden rather than deleted. Run in a project, it would write the toolkit's
    # hooks into .claude/settings.json and gitignore that file, which `harness
    # init` exists to avoid. "off" hides it from the model and from the / menu.
    $settings = Get-Content -LiteralPath (Join-Path $repoRoot "user\settings.json") -Raw | ConvertFrom-Json

    if (-not $settings.PSObject.Properties["skillOverrides"]) { return "no skillOverrides in user/settings.json" }
    if ($settings.skillOverrides."harness-init" -ne "off") { return "harness-init is '$($settings.skillOverrides."harness-init")', expected 'off'" }

    return $true
}

Test-Case -Name "user settings keep humanizer for the user only, and its MIT notice ships with it" -Check {

    # A rewriting skill the model could pick on its own would edit prose nobody
    # asked it to touch. "user-invocable-only" keeps it in the / menu and out
    # of the model's context; the frontmatter stays as upstream ships it.
    $settings = Get-Content -LiteralPath (Join-Path $repoRoot "user\settings.json") -Raw | ConvertFrom-Json

    if ($settings.skillOverrides."humanizer" -ne "user-invocable-only") { return "humanizer is '$($settings.skillOverrides."humanizer")', expected 'user-invocable-only'" }

    $skill = Join-Path $repoRoot "user\skills\humanizer\SKILL.md"
    if (-not (Test-Path -LiteralPath $skill)) { return "no user\skills\humanizer\SKILL.md" }
    if ((Get-Content -LiteralPath $skill -Raw) -notmatch "(?m)^name: humanizer\s*$") { return "SKILL.md is not named humanizer" }

    $license = Join-Path $repoRoot "user\skills\humanizer\LICENSE"
    if (-not (Test-Path -LiteralPath $license)) { return "no LICENSE beside the skill; MIT requires the notice to travel with the copy" }
    if ((Get-Content -LiteralPath $license -Raw) -notmatch "MIT License") { return "LICENSE is not the MIT notice" }

    return $true
}

Test-Case -Name "init keeps the harness-toolkit session state out of git" -Check {

    # The toolkit's user-level hooks write .tlc/harness/state/ into every
    # repository they run in; left unignored it shows up as untracked noise and
    # can be committed with one machine's session data in it.
    $project = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-ignore-" + [guid]::NewGuid().ToString("N").Substring(0, 8))

    try {
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $project ".gitignore") -Value "bin/"

        & (Join-Path $PSScriptRoot "init-project.ps1") -Path $project -NoTrust 6>$null | Out-Null

        $lines = @(Get-Content -LiteralPath (Join-Path $project ".gitignore"))

        foreach ($entry in @("**/.tlc/harness/state/", ".claude/state/", "bin/")) {
            if ($lines -notcontains $entry) { return "$entry is not in the project's .gitignore" }
        }

        return $true
    }
    finally {
        Remove-Item -LiteralPath $project -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case -Name "an explicit -Type dotnet is refused on a repository with no .NET project" -Check {

    # This check existed before detection did, and it passed everything: with
    # -LiteralPath, Get-ChildItem -Include matches every file, so any non-empty
    # directory looked like a .NET project. Nothing failed, so nothing noticed.
    $project = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-reject-" + [guid]::NewGuid().ToString("N").Substring(0, 8))

    try {

        New-Item -ItemType Directory -Path $project -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $project "notes.txt") -Value "not a project" -NoNewline

        & (Join-Path $PSScriptRoot "init-project.ps1") -Type dotnet -Path $project -NoTrust 6>$null | Out-Null

        if ($LASTEXITCODE -eq 0) { return "-Type dotnet was accepted on a directory with no .NET project" }

        if (Test-Path -LiteralPath (Join-Path $project ".claude")) {
            return "it exited non-zero but still wrote a harness"
        }

        return $true
    }
    finally {
        Remove-Item -LiteralPath $project -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case -Name "init trusts the workspace in Claude Code's state file" -Check {

    # The trust flag is the difference between a project that is protected and
    # one that only looks it, so this asserts the write AND that the rest of the
    # file survived: .claude.json holds every project's state and the account.
    $project = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-trust-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    $configDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-trustcfg-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    $previousConfig = $env:CLAUDE_CONFIG_DIR

    try {

        New-Item -ItemType Directory -Path $project -Force | Out-Null
        New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $project "notes.txt") -Value "plain" -NoNewline

        $state = @{
            numStartups = 4
            oauthAccount = @{ accountUuid = "keep-me" }
            projects = @{
                "C:/somewhere/else" = @{ hasTrustDialogAccepted = $true; lastCost = 1.5 }
            }
        }

        $statePath = Join-Path $configDirectory ".claude.json"
        Set-Content -LiteralPath $statePath -Value ($state | ConvertTo-Json -Depth 20) -Encoding UTF8

        $env:CLAUDE_CONFIG_DIR = $configDirectory

        & (Join-Path $PSScriptRoot "init-project.ps1") -Path $project 6>$null | Out-Null

        if ($LASTEXITCODE -ne 0) { return "init-project.ps1 exited $LASTEXITCODE" }

        $written = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json

        # Forward slashes: a backslash key is ignored by Claude Code, and the
        # write would have reported success while trusting nothing.
        $key = ([System.IO.Path]::GetFullPath($project)).Replace("\", "/")

        if (-not $written.projects.PSObject.Properties[$key]) {
            return "no entry was written for $key"
        }

        if (-not $written.projects.$key.hasTrustDialogAccepted) {
            return "the entry was written without hasTrustDialogAccepted"
        }

        if ($written.oauthAccount.accountUuid -ne "keep-me") {
            return "the rewrite lost the account"
        }

        if (-not $written.projects."C:/somewhere/else".hasTrustDialogAccepted) {
            return "the rewrite lost another project's state"
        }

        if (-not (Test-Path -LiteralPath (Join-Path $configDirectory ".harness-backup"))) {
            return "the state file was rewritten without a backup"
        }

        return $true
    }
    finally {
        $env:CLAUDE_CONFIG_DIR = $previousConfig
        Remove-Item -LiteralPath $project -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $configDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case -Name "-NoTrust leaves the state file alone" -Check {

    # The opt-out has to be real: this is the switch someone reaches for on a
    # repository whose own hooks they are not ready to run.
    $project = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-notrust-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    $configDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-notrustcfg-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    $previousConfig = $env:CLAUDE_CONFIG_DIR

    try {

        New-Item -ItemType Directory -Path $project -Force | Out-Null
        New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $project "notes.txt") -Value "plain" -NoNewline

        $statePath = Join-Path $configDirectory ".claude.json"
        Set-Content -LiteralPath $statePath -Value '{ "projects": {} }' -Encoding UTF8

        $before = Get-Content -LiteralPath $statePath -Raw

        $env:CLAUDE_CONFIG_DIR = $configDirectory

        & (Join-Path $PSScriptRoot "init-project.ps1") -Path $project -NoTrust 6>$null | Out-Null

        if ($LASTEXITCODE -ne 0) { return "init-project.ps1 exited $LASTEXITCODE" }

        if ((Get-Content -LiteralPath $statePath -Raw) -ne $before) {
            return "-NoTrust still rewrote the state file"
        }

        # It must still have scaffolded: -NoTrust is not -WhatIf.
        if (-not (Test-Path -LiteralPath (Join-Path $project ".claude\scripts\verify.ps1"))) {
            return "-NoTrust also suppressed the scaffold"
        }

        return $true
    }
    finally {
        $env:CLAUDE_CONFIG_DIR = $previousConfig
        Remove-Item -LiteralPath $project -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $configDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case -Name "a state file that does not parse is left untouched" -Check {

    # Fail open, and above all do not write. This file holds the credentials;
    # half-repairing it would be worse than not trusting the workspace.
    $project = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-badstate-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    $configDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-badcfg-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    $previousConfig = $env:CLAUDE_CONFIG_DIR

    try {

        New-Item -ItemType Directory -Path $project -Force | Out-Null
        New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $project "notes.txt") -Value "plain" -NoNewline

        $statePath = Join-Path $configDirectory ".claude.json"
        Set-Content -LiteralPath $statePath -Value '{ this is not json' -Encoding UTF8

        # Compare against what is on disk, not against the literal: Set-Content
        # adds a BOM and a trailing newline, so the literal never matches and
        # the case would fail whatever the script did.
        $before = Get-Content -LiteralPath $statePath -Raw

        $env:CLAUDE_CONFIG_DIR = $configDirectory

        & (Join-Path $PSScriptRoot "init-project.ps1") -Path $project 6>$null | Out-Null

        if ($LASTEXITCODE -ne 0) { return "a broken state file took down the scaffold" }

        if ((Get-Content -LiteralPath $statePath -Raw) -ne $before) {
            return "the broken state file was rewritten"
        }

        if (Test-Path -LiteralPath (Join-Path $configDirectory ".harness-backup")) {
            return "it backed the file up, so it intended to write"
        }

        if (-not (Test-Path -LiteralPath (Join-Path $project ".claude\scripts\verify.ps1"))) {
            return "the scaffold did not complete"
        }

        return $true
    }
    finally {
        $env:CLAUDE_CONFIG_DIR = $previousConfig
        Remove-Item -LiteralPath $project -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $configDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case -Name "no script resolves a path parameter around Resolve-HarnessPath" -Check {

    # The behavioural cases above cover init-project. This is what
    # stops the next script from reintroducing it: GetFullPath on a PARAMETER is
    # the shape of the bug, and it is invisible until someone runs the command
    # from somewhere other than where their shell started.
    $offenders = @()

    foreach ($script in (Get-ChildItem -LiteralPath (Join-Path $repoRoot "scripts") -Filter *.ps1 -File)) {
        if ($script.Name -eq "test-harness.ps1") { continue }

        $text = Get-Content -LiteralPath $script.FullName -Raw

        # Parameters are the risk. GetFullPath on an already-absolute value the
        # script computed itself is fine, so this matches the declared ones only.
        $parameters = @()

        foreach ($match in [regex]::Matches($text, '\[string(?:\[\])?\]\$(\w+)')) {
            $parameters += $match.Groups[1].Value
        }

        foreach ($parameter in ($parameters | Select-Object -Unique)) {

            if ($text -match ('\[System\.IO\.Path\]::GetFullPath\(\$' + [regex]::Escape($parameter) + '\)')) {
                $offenders += ($script.Name + " -> `$" + $parameter)
            }
        }
    }

    if ($offenders.Count -gt 0) {
        return ("use Resolve-HarnessPath instead: " + ($offenders -join ", "))
    }

    return $true
}

Test-Case -Name "-Path defaults to the current directory, not the process one" -Check {

    # [System.IO.Path]::GetFullPath(".") resolves against the PROCESS working
    # directory, which does not follow Set-Location. While -Path was mandatory
    # that never mattered; with a default of "." it decides which repository
    # gets written to.
    $project = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-cwd-" + [guid]::NewGuid().ToString("N").Substring(0, 8))

    try {

        New-Item -ItemType Directory -Path $project -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $project "notes.txt") -Value "plain" -NoNewline

        Push-Location -LiteralPath $project

        try {
            & (Join-Path $PSScriptRoot "init-project.ps1") -NoTrust 6>$null | Out-Null
        }
        finally {
            Pop-Location
        }

        if ($LASTEXITCODE -ne 0) { return "init-project.ps1 exited $LASTEXITCODE" }

        if (-not (Test-Path -LiteralPath (Join-Path $project ".claude\scripts\verify.ps1"))) {
            return "nothing was installed into the current directory"
        }

        return $true
    }
    finally {
        Remove-Item -LiteralPath $project -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Host ""
Write-Host "Extension points"
Write-Host "----------------"

# why: R7 reads this machine's persisted PATH, so it only has something to say about the
# checkout setup installed; any other checkout (a fork, a clone, a worktree) is not on it.
$installedBin = Join-Path $repoRoot "bin"
$isInstalled = @(([Environment]::GetEnvironmentVariable("PATH", "User")) -split ";" |
    Where-Object { $_.Trim().TrimEnd("\") -eq $installedBin.TrimEnd("\") }).Count -gt 0

if (-not $isInstalled) {
    Skip-Case -Name "R7 install.ps1 puts tazuna on PATH so it runs from a project" -Reason "this checkout is not the one setup put on the user PATH"
}
else {
Test-Case -Name "R7 install.ps1 puts tazuna on PATH so it runs from a project" -Check {

    # Every instruction reads "cd into your project, then run tazuna init".
    # That is only true if the harness is on PATH: .\tazuna.ps1 is not in the
    # project, so the documented command could not work from the directory it
    # told you to be in.
    $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")

    $onPath = $false

    $binDirectory = Join-Path $repoRoot "bin"

    foreach ($entry in @($userPath -split ";" | Where-Object { $_ })) {

        $trimmed = $entry.Trim().TrimEnd("\")

        if ($trimmed -eq $binDirectory.TrimEnd("\")) { $onPath = $true }

        # The repository root on PATH puts tazuna.ps1 ahead of tazuna.cmd, so
        # its presence is a failure even when bin\ is there too.
        if ($trimmed -eq $repoRoot.TrimEnd("\")) {
            return "$repoRoot is on the user PATH; 'tazuna' resolves to the .ps1 - run install.ps1"
        }
    }

    if (-not $onPath) { return "$binDirectory is not on the user PATH; run install.ps1" }

    # The PERSISTED user PATH, not this process's. A shell inherits PATH when it
    # starts, so Get-Command here would report on whatever the environment was
    # when this process began - failing after a correct install, and passing
    # after the entry was removed. That is a worse test than none.
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot "bin\tazuna.cmd"))) {
        return "the PATH entry exists but there is no tazuna.cmd in it"
    }

    # Resolve it the way a NEW shell would: search the persisted PATH by hand.
    $found = $null

    foreach ($entry in @($userPath -split ";" | Where-Object { $_ })) {

        $candidate = Join-Path $entry.Trim() "tazuna.cmd"

        if (Test-Path -LiteralPath $candidate) { $found = $candidate; break }
    }

    if (-not $found) { return "no tazuna.cmd is reachable from the user PATH" }

    if ((Split-Path -Parent $found).TrimEnd("\") -ne $binDirectory.TrimEnd("\")) {
        return "a new shell would resolve tazuna to $found, not this repository"
    }

    # The root cause, guarded directly. PowerShell resolves an ExternalScript
    # before an Application, so a .ps1 sharing a base name with the launcher in
    # the SAME directory wins - and on an AllSigned machine it then refuses to
    # run. The launcher only works because nothing else sits beside it.
    $rival = Get-ChildItem -LiteralPath $binDirectory -File |
        Where-Object { $_.Extension -eq ".ps1" }

    if ($rival) {
        return ("bin\ must hold no .ps1: " + (($rival | ForEach-Object { $_.Name }) -join ", "))
    }

    return $true
}
}

Test-Case -Name "R4 tazuna.cmd survives a machine that refuses unsigned scripts" -Check {

    # A machine that runs AllSigned fails `.\tazuna.ps1 setup` with
    # "not digitally signed" before anything ran. This shim is the entry point
    # for that machine, and it is only worth shipping if it forwards faithfully.
    $shim = Join-Path $repoRoot "bin\tazuna.cmd"

    if (-not (Test-Path -LiteralPath $shim)) { return "tazuna.cmd is missing" }

    $text = [System.IO.File]::ReadAllText($shim)

    # CRLF is not a preference here. With LF, cmd.exe splits its own keywords and
    # every rem line fails with "'m' is not recognized" - measured.
    if ($text -notmatch "`r`n") { return "tazuna.cmd must use CRLF line endings or cmd.exe mis-parses it" }

    foreach ($required in @("-ExecutionPolicy Bypass", "-NoProfile", "%~dp0..\tazuna.ps1", "%*")) {

        if (-not $text.Contains($required)) { return "tazuna.cmd does not carry $required" }
    }

    # Behaviour, not shape: an unknown command must come back non-zero through
    # the shim exactly as it does directly, or a caller cannot trust it.
    $null = & cmd.exe /c $shim "no-such-command" 2>$null
    $throughShim = $LASTEXITCODE

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "tazuna.ps1") "no-such-command" 2>$null | Out-Null
    $direct = $LASTEXITCODE

    if ($throughShim -ne $direct) {
        return "the shim returned $throughShim where tazuna.ps1 returned $direct"
    }

    if ($throughShim -eq 0) { return "an unknown command was reported as success" }

    return $true
}

Test-Case -Name "no regex pattern ends in a backslash" -Check {

    # `-notmatch '<BS><BS>.git<BS>'` parsed clean, passed review and passed every
    # test - because .NET only compiles the pattern when there is something to
    # match, and there never was until a credential file actually leaked. A
    # pattern ending in a backslash is an illegal regex; this catches it while
    # the cost is a failing test rather than a missed secret.
    $offenders = @()

    foreach ($file in (Get-RepoFile -Extension ".ps1", ".psm1")) {

        $number = 0

        foreach ($line in Get-Content -LiteralPath $file.FullName) {

            $number++

            if ($line -notlike "*-match*" -and $line -notlike "*-notmatch*" -and
                $line -notlike "*-replace*" -and $line -notlike "*-split*") { continue }

            # A quoted literal whose last character is a single backslash.
            foreach ($quote in @("'", '"')) {

                foreach ($piece in ($line -split $quote)) {

                    if ($piece.Length -eq 0) { continue }
                    if (-not $piece.EndsWith([string][char]92)) { continue }

                    # An even run of trailing backslashes is an escaped
                    # backslash, which is legal.
                    $run = 0
                    $index = $piece.Length - 1

                    while ($index -ge 0 -and $piece[$index] -eq [char]92) {
                        $run++
                        $index--
                    }

                    if ($run % 2 -eq 1) {
                        $offenders += "$($file.Name):$number"
                    }
                }
            }
        }
    }

    $offenders = @($offenders | Select-Object -Unique)

    if ($offenders.Count -gt 0) {
        return "illegal trailing backslash in a pattern: $($offenders -join ', ')"
    }

    return $true
}

Test-Case -Name "file comparison survives an inherited -WhatIf" -Check {

    # bootstrap.ps1 passes -WhatIf down to install.ps1, and that set
    # $WhatIfPreference for everything below it. Get-FileHash is a function in
    # Windows PowerShell 5.1, the preference reaches inside it, and it returns
    # nothing - so the installer's "has this file changed?" threw, and only in
    # the dry run that exists to be safe.
    $module = Join-Path $repoRoot "scripts\lib\Files.psm1"

    # Built by replacement, not -f: the -f operator reads the probe's own braces
    # as format items.
    $probe = @'
Import-Module "MODULE" -Force
$WhatIfPreference = $true
$same = Test-FileContentEqual -ReferenceFile "SAME" -DifferenceFile "SAME"
$different = Test-FileContentEqual -ReferenceFile "SAME" -DifferenceFile "OTHER"
if ($same -and (-not $different)) { "ok" } else { "wrong result" }
'@

    $probe = $probe.Replace("MODULE", $module)
    $probe = $probe.Replace("SAME", (Join-Path $repoRoot "README.md"))
    $probe = $probe.Replace("OTHER", (Join-Path $repoRoot ".gitignore"))

    $probeFile = Join-Path ([System.IO.Path]::GetTempPath()) ("whatif-" + [guid]::NewGuid().ToString("N") + ".ps1")

    try {

        Set-Content -LiteralPath $probeFile -Value $probe -Encoding UTF8

        $output = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probeFile) | Select-Object -Last 1

        if ($output -ne "ok") { return "comparison broke under -WhatIf: $output" }
    }
    finally {
        Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue
    }

    return $true
}

Test-Case -Name "no harness script depends on Get-FileHash" -Check {

    # Reading a file is not a mutation, but Get-FileHash behaves as though it
    # were. Both places that hash files - the installer's change detection and
    # the verification gate's fingerprint - must keep working no matter what a
    # caller upstream set.
    $offenders = @()

    foreach ($file in (Get-RepoFile -Extension ".ps1", ".psm1")) {

        foreach ($line in (Get-Content -LiteralPath $file.FullName)) {

            # A call always carries a parameter. The prose explaining why this
            # is avoided says "Get-FileHash is a function in Windows...", and
            # the line just above searches for the name itself.
            # Assembled, so this line does not report itself.
            if (-not $line.Contains("Get-File" + "Hash -")) { continue }

            if ($true) {
                $offenders += (Get-CompatibleRelativePath -BasePath $repoRoot -TargetPath $file.FullName)
            }
        }
    }

    $offenders = @($offenders | Select-Object -Unique)

    if ($offenders.Count -gt 0) {
        return "use [System.Security.Cryptography.SHA256] instead: $($offenders -join ', ')"
    }

    return $true
}

Test-Case -Name "no MCP server is registered without its written justification" -Check {

    # docs/mcp.md requires five answers before a server is installed. The rule
    # only holds if something enforces it: a catalogue is exactly the kind of
    # file that accumulates entries nobody can account for later.
    $cataloguePath = Join-Path $repoRoot (Join-Path "mcp" "servers.json")
    $decisionsPath = Join-Path $repoRoot (Join-Path "docs" "mcp.md")

    if (-not (Test-Path -LiteralPath $cataloguePath)) { return "mcp/servers.json is missing" }
    if (-not (Test-Path -LiteralPath $decisionsPath)) { return "docs/mcp.md is missing" }

    $catalogue = Get-Content -LiteralPath $cataloguePath -Raw | ConvertFrom-Json
    $decisions = Get-Content -LiteralPath $decisionsPath -Raw

    if (-not $catalogue.mcpServers) { return $true }

    $undocumented = @()

    foreach ($name in @($catalogue.mcpServers.PSObject.Properties.Name | Where-Object { $_ })) {

        if (-not $decisions.Contains($name)) { $undocumented += $name }
    }

    if ($undocumented.Count -gt 0) {
        return "answer the five questions in docs/mcp.md first: $($undocumented -join ', ')"
    }

    return $true
}

Test-Case -Name "settings use the spelling Claude Code writes back" -Check {

    # defaultMode accepts "manual" and "default" for the same mode, but when the
    # CLI rewrites settings.json - which `plugin install --scope user` does - it
    # normalises "manual" to "default". Declaring "manual" therefore left every
    # freshly bootstrapped machine reporting drift against its own repository,
    # and a fresh install that ends in a warning teaches you to ignore warnings.
    $settings = Get-Content -LiteralPath (Join-Path $repoRoot "user\settings.json") -Raw | ConvertFrom-Json

    $mode = $settings.permissions.defaultMode

    if (-not $mode) { return "no permissions.defaultMode" }

    if ($mode -eq "manual") {
        return "use 'default': the CLI rewrites 'manual' to it and the harness then reports drift against itself"
    }

    # The modes that hand over control are never the default here.
    if (@("acceptEdits", "bypassPermissions", "auto") -contains $mode) {
        return "defaultMode is '$mode', which grants tools without asking"
    }

    return $true
}

# why: a fork or a local clone has another origin; the published URL itself is pinned by R8.
$origin = (Invoke-GitCommand -RepositoryPath $repoRoot -Arguments @("remote", "get-url", "origin") -AllowFailure).Text.Trim()

if ($origin -ne "https://github.com/AlfredoNeeto/tazuna.git") {
    Skip-Case -Name "the remote installer clones this repository" -Reason "origin is '$origin', not the published repository"
}
else {
Test-Case -Name "the remote installer clones this repository" -Check {

    # install.ps1 is the one file nobody runs from a working copy - it runs on a
    # machine that does not have the repository yet. A wrong URL in it is
    # therefore silent here and fails only on the new machine, which is the
    # moment it exists for.
    $installerPath = Join-Path $repoRoot "install.ps1"

    if (-not (Test-Path -LiteralPath $installerPath)) { return "install.ps1 is missing" }

    $installer = Get-Content -LiteralPath $installerPath -Raw

    $remote = (& git -C $repoRoot remote get-url origin)

    if ($LASTEXITCODE -ne 0) { return "no origin remote to compare against" }

    $remote = $remote.Trim()

    if (-not $installer.Contains($remote)) {
        return "install.ps1 does not clone origin ($remote)"
    }

    return $true
}
}

Test-Case -Name "the remote installer hands over to bootstrap.ps1" -Check {
    # A second installer that drifts from bootstrap is worse than none.
    $installer = Get-Content -LiteralPath (Join-Path $repoRoot "install.ps1") -Raw
    if (-not $installer.Contains("bootstrap.ps1")) { return "install.ps1 does not run bootstrap.ps1" }
    return $true
}

Test-Case -Name "every tazuna.ps1 command maps to a script that exists" -Check {

    # The dispatcher keeps its own table of command -> script. Rename a script
    # and the table still looks right; it fails only when someone runs that one
    # command, which may be months later.
    $dispatcher = Join-Path $repoRoot "tazuna.ps1"

    if (-not (Test-Path -LiteralPath $dispatcher)) { return "tazuna.ps1 is missing" }

    $missing = @()
    $named = @()

    foreach ($line in (Get-Content -LiteralPath $dispatcher)) {

        if (-not $line.Contains("Script = ")) { continue }

        $after = $line.Substring($line.IndexOf("Script = ") + 9).Trim()

        if ($after.StartsWith('$null')) { continue }

        $name = ($after -split '"')[1]

        if (-not $name) { continue }

        $named += $name

        if (-not (Test-Path -LiteralPath (Join-Path $repoRoot (Join-Path "scripts" $name)))) {
            $missing += $name
        }
    }

    if ($named.Count -eq 0) { return "no commands found in the dispatcher table" }

    if ($missing.Count -gt 0) {
        return "commands point at scripts that do not exist: $($missing -join ', ')"
    }

    return $true
}

Test-Case -Name "every script a skill tells you to run exists" -Check {

    # A skill is prose until something runs. When a script is renamed, the skill
    # keeps pointing at the old name and fails only in front of the user, mid
    # task - so the reference is checked here instead.
    $missing = @()

    foreach ($skill in (Get-ChildItem -LiteralPath (Join-Path $repoRoot "user\skills") -Filter "SKILL.md" -Recurse)) {

        foreach ($line in (Get-Content -LiteralPath $skill.FullName)) {

            if (-not $line.Contains("$harness/scripts/")) { continue }

            # $harness/scripts/<name>.ps1, however it is quoted.
            $rest = $line.Substring($line.IndexOf("$harness/scripts/") + "$harness/scripts/".Length)

            $name = ($rest -split '"')[0]
            $name = ($name -split "'")[0]
            $name = ($name -split " ")[0]

            if (-not $name.EndsWith(".ps1")) { continue }

            if (-not (Test-Path -LiteralPath (Join-Path $repoRoot (Join-Path "scripts" $name)))) {
                $missing += "$($skill.Directory.Name) -> scripts\$name"
            }
        }
    }

    $missing = @($missing | Select-Object -Unique)

    if ($missing.Count -gt 0) { return ($missing -join "; ") }

    return $true
}

Test-Case -Name "every slash command the documentation names exists" -Check {

    # Skills get renamed and removed; prose telling the user to run them does not
    # notice. docs/harness-model.md named /verify-loop long after it was gone.
    # Built-in commands the documentation may name are listed explicitly.
    $builtIn = @("code-review", "security-review", "config", "memory", "permissions", "plan")

    $known = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -Filter "SKILL.md" | ForEach-Object { $_.Directory.Name })
    $known += @((Get-HarnessManifest).AgentSkills)

    $documents = @(Get-Item -LiteralPath (Join-Path $repoRoot "README.md"), (Join-Path $repoRoot "AGENTS.md"))
    # resumo-* are notes about external material, not documentation of this harness.
    $documents += @(Get-ChildItem -LiteralPath (Join-Path $repoRoot "docs") -Filter *.md | Where-Object { -not $_.Name.StartsWith("resumo-") })
    foreach ($folder in @("user", "templates", "mcp")) {
        $documents += @(Get-ChildItem -LiteralPath (Join-Path $repoRoot $folder) -Recurse -Filter *.md)
    }

    $unknown = @()

    foreach ($document in $documents) {

        $text = Get-Content -LiteralPath $document.FullName -Raw

        foreach ($match in [regex]::Matches($text, '(?m)(?:^|[\s`(\["''])/([a-z][a-z0-9-]+)(?=[\s`),.:;\]"'']|$)')) {

            $name = $match.Groups[1].Value

            if (($known -notcontains $name) -and ($builtIn -notcontains $name)) {
                $unknown += "$($document.Name) -> /$name"
            }
        }
    }

    $unknown = @($unknown | Select-Object -Unique)

    if ($unknown.Count -gt 0) { return ($unknown -join "; ") }

    return $true
}

Test-Case -Name "declared plugins are version-controlled, not machine-local" -Check {

    # `claude plugin install` writes to the configuration directory only. Unless
    # the declaration is in user/settings.json, a new machine silently does not
    # get the plugin - and CLAUDE.md relies on ponytail for the code-minimality
    # rules it no longer states itself.
    $settings = Get-Content -LiteralPath (Join-Path $repoRoot "user\settings.json") -Raw | ConvertFrom-Json

    if (-not $settings.enabledPlugins) { return "no enabledPlugins in user/settings.json" }

    $declared = @($settings.enabledPlugins.PSObject.Properties.Name | Where-Object { $_ })

    if ($declared.Count -eq 0) { return "enabledPlugins is empty" }

    # A plugin from a marketplace that is not declared cannot be installed on a
    # fresh machine.
    foreach ($name in $declared) {

        $marketplace = ($name -split "@")[-1]

        if ($marketplace -eq $name) { continue }

        if (-not $settings.extraKnownMarketplaces) {
            return "$name needs marketplace '$marketplace' but none are declared"
        }

        if (-not $settings.extraKnownMarketplaces.PSObject.Properties[$marketplace]) {
            return "$name needs marketplace '$marketplace', which is not declared"
        }
    }

    return $true
}

Test-Case -Name "the MCP catalogue is valid and carries no literal secrets" -Check {

    # This file is committed, so a literal credential in it is already leaked.
    $catalogue = Join-Path $repoRoot (Join-Path "mcp" "servers.json")

    $parseError = $null

    if (-not (Test-JsonFile -Path $catalogue -ErrorMessage ([ref]$parseError))) {
        return "mcp/servers.json is not valid JSON: $parseError"
    }

    $text = Get-Content -LiteralPath $catalogue -Raw

    $patterns = @(
        "-----BEGIN [A-Z ]*PRIVATE KEY-----",
        "AKIA[0-9A-Z]{16}",
        "gh[pousr]_[A-Za-z0-9]{36}",
        "xox[baprs]-[A-Za-z0-9-]{10,}",
        "sk-ant-[A-Za-z0-9_\-]{20,}"
    )

    foreach ($pattern in $patterns) {
        if ($text -match $pattern) { return "mcp/servers.json contains a literal credential" }
    }

    return $true
}

Test-Case -Name "install-mcp.ps1 reports an empty catalogue as empty" -Check {

    # @($null) is an array of one, which once made an empty catalogue report a
    # server as already present.
    #
    # -WhatIf is not optional here. Without it this case REGISTERED every server
    # in the catalogue into the real ~/.claude.json, so running the verification
    # changed machine state outside the repository - and that is how serena came
    # to be registered before anyone ran install-mcp.ps1. A suite that mutates
    # the machine it is measuring cannot be trusted about what it measured.
    # The empty-catalogue branch returns before ShouldProcess, so -WhatIf does
    # not weaken what this asserts.
    $output = & (Join-Path $PSScriptRoot "install-mcp.ps1") -WhatIf 6>&1 | Out-String

    if ($LASTEXITCODE -ne 0) { return "exited $LASTEXITCODE on an empty catalogue" }

    $catalogue = Get-Content -LiteralPath (Join-Path $repoRoot (Join-Path "mcp" "servers.json")) -Raw | ConvertFrom-Json
    $defined = @($catalogue.mcpServers.PSObject.Properties.Name | Where-Object { $_ })

    if ($defined.Count -eq 0) {

        if ($output -match "No user-scope MCP servers are defined") { return $true }
        return "an empty catalogue was not reported as empty"
    }

    return $true
}

Test-Case -Name "install-mcp.ps1 refuses to register a server whose runtime is absent" -Check {

    # Registering writes a JSON entry and checks nothing, so a stdio server with
    # no runtime registered happily and then failed to start in every session.
    # Same probe as the health-check case: hide a runtime that does not live
    # beside claude.exe, so the rest of the script still works.
    $catalogue = Get-Content -LiteralPath (Join-Path $repoRoot "mcp\servers.json") -Raw | ConvertFrom-Json

    $claude = Get-Command claude -ErrorAction SilentlyContinue

    if (-not $claude) { return "claude is not on PATH, so this cannot be probed" }

    $claudeDirectory = (Split-Path -Parent $claude.Source).TrimEnd("\")
    $candidate = $null

    foreach ($property in $catalogue.mcpServers.PSObject.Properties) {

        if (-not $property.Value.command) { continue }

        $located = Get-Command $property.Value.command -ErrorAction SilentlyContinue

        if (-not $located) { continue }
        if ((Split-Path -Parent $located.Source).TrimEnd("\") -eq $claudeDirectory) { continue }

        $candidate = [PSCustomObject]@{
            Server    = $property.Name
            Command   = $property.Value.command
            Directory = (Split-Path -Parent $located.Source)
        }

        break
    }

    if (-not $candidate) {
        return "no catalogued stdio runtime could be hidden without also hiding claude"
    }

    $previousPath = $env:PATH

    try {

        $env:PATH = (($env:PATH -split ";") |
            Where-Object { $_ -and ($_.TrimEnd("\") -ne $candidate.Directory.TrimEnd("\")) }) -join ";"

        if (Get-Command $candidate.Command -ErrorAction SilentlyContinue) {
            return "could not take $($candidate.Command) off PATH, so this would prove nothing"
        }

        # -WhatIf throughout: this case must never touch the real registration.
        $output = & (Join-Path $PSScriptRoot "install-mcp.ps1") -WhatIf 6>&1 | Out-String
    }
    finally {
        $env:PATH = $previousPath
    }

    if ($output -notmatch "'$($candidate.Command)' is not in PATH") {
        return "it did not report that $($candidate.Command) is missing"
    }

    if ($output -match "would register $($candidate.Server)") {
        return "it would have registered a server that cannot start"
    }

    return $true
}

Test-Case -Name "install-mcp.ps1 replaces a registration that no longer matches the catalogue" -Check {

    # Editing a definition here used to change nothing on a machine that had
    # already registered that server: the NAME was present, so it was reported
    # present and left alone, and the machine kept the old definition forever.
    # Found when serena moved from a git checkout to a pinned release.
    #
    # Isolated through CLAUDE_CONFIG_DIR, so the real registration is untouched,
    # and -WhatIf so nothing is written even there.
    $configDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-mcpcfg-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    $previousConfig = $env:CLAUDE_CONFIG_DIR

    try {

        New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
        $env:CLAUDE_CONFIG_DIR = $configDirectory

        # An HTTP entry: registering it spawns no process and reaches nothing.
        $wrong = '{\"type\":\"http\",\"url\":\"https://example.invalid/stale\"}'

        $global:LASTEXITCODE = 0
        & claude mcp add-json --scope user context7 $wrong 2>&1 | Out-Null

        if ($LASTEXITCODE -ne 0) { return "could not seed a stale registration" }

        $output = & (Join-Path $PSScriptRoot "install-mcp.ps1") -WhatIf 6>&1 | Out-String

        if ($output -notmatch "STALE\s+context7") {
            return "a registration that does not match the catalogue was not reported stale"
        }

        if ($output -match "PRESENT\s+context7") {
            return "it reported the stale registration as present and left it alone"
        }

        return $true
    }
    finally {
        $env:CLAUDE_CONFIG_DIR = $previousConfig
        Remove-Item -LiteralPath $configDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case -Name "a catalogued stdio server says how to get and warm its runtime" -Check {

    # $install makes the skip message actionable; $warm is what stops a fresh
    # machine registering a server that then times out on its first start.
    # Without both, the next server added produces a dead end instead.
    $catalogue = Get-Content -LiteralPath (Join-Path $repoRoot "mcp\servers.json") -Raw | ConvertFrom-Json

    $missing = @()

    foreach ($property in $catalogue.mcpServers.PSObject.Properties) {

        if (-not $property.Value.command) { continue }

        foreach ($key in @("`$install", "`$warm")) {

            if (-not $property.Value.$key) { $missing += ($property.Name + " has no " + $key) }
        }
    }

    if ($missing.Count -gt 0) {
        return ("incomplete catalogue entry: " + ($missing -join ", "))
    }

    return $true
}

Test-Case -Name "warming runs the runtime that is actually registered" -Check {

    # A $warm command that resolves a different version from the registered one
    # warms the wrong cache and the first start is cold anyway - which is the
    # failure this whole mechanism exists to prevent, wearing a success message.
    $catalogue = Get-Content -LiteralPath (Join-Path $repoRoot "mcp\servers.json") -Raw | ConvertFrom-Json

    $wrong = @()

    foreach ($property in $catalogue.mcpServers.PSObject.Properties) {

        $warm = $property.Value."`$warm"

        if (-not $warm) { continue }

        if (-not $warm.StartsWith($property.Value.command)) {
            $wrong += ($property.Name + ": warms with '" + $warm.Split(" ")[0] + "', registered with '" + $property.Value.command + "'")
            continue
        }

        # The package specifier is what uv and npx cache. If the registered args
        # name one, the warm command has to name the same one.
        foreach ($argument in @($property.Value.args)) {

            if ($argument -match "^(--from$|-y$|--)") { continue }

            if ($argument -match "@|/") {

                if (-not $warm.Contains($argument)) {
                    $wrong += ($property.Name + ": registered with '" + $argument + "', which the warm command does not mention")
                }

                break
            }
        }
    }

    if ($wrong.Count -gt 0) { return ($wrong -join "; ") }

    return $true
}



Write-Host ""
Write-Host ""
Write-Host "Verification gate"
Write-Host "-----------------"

# The gate is the mechanism behind "verification defines done". It once failed
# silently because a mandatory [string[]] parameter rejects empty strings, the
# resulting exception hit the fail-open catch, and the gate never fired. These
# cases exist so that cannot happen again unnoticed.
$gateProject = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-gate-" + [guid]::NewGuid().ToString("N").Substring(0, 8))

try {
    New-Item -ItemType Directory -Path $gateProject -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $gateProject "Program.cs") -Value "class P { }" -NoNewline
    Set-Content -LiteralPath (Join-Path $gateProject "App.csproj") -Value "<Project />" -NoNewline

    & (Join-Path $PSScriptRoot "init-project.ps1") -Type dotnet -Path $gateProject -NoTrust 6>$null | Out-Null

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

Write-Host ""
Write-Host "Verifier toolchain"
Write-Host "------------------"

# The .NET verifier has to choose between the dotnet CLI and Visual Studio's
# MSBuild. Choosing wrong is not cosmetic: the dotnet CLI cannot restore, build
# or test a .NET Framework project, so such a repository would fail
# verification on every session, and a gate that cannot be satisfied gets
# switched off.
#
# Both cases run with the toolchains hidden - no vswhere, no dotnet on PATH -
# so each one fails with the message that names the branch it took. The
# assertion is then the same on a machine with Visual Studio and on one
# without, and it costs no build.
function Invoke-VerifierToolchainCase {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Files,

        [Parameter(Mandatory = $true)]
        [string]$Expect
    )

    $project = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-toolchain-" + [guid]::NewGuid().ToString("N").Substring(0, 8))

    $previousPath = $env:Path
    $previousProgramFiles = ${env:ProgramFiles(x86)}
    $previousPreference = $ErrorActionPreference

    try {

        New-Item -ItemType Directory -Path $project -Force | Out-Null

        foreach ($name in $Files.Keys) {
            Set-Content -LiteralPath (Join-Path $project $name) -Value $Files[$name] -NoNewline
        }

        & (Join-Path $PSScriptRoot "init-project.ps1") -Type dotnet -Path $project -NoTrust 6>$null | Out-Null

        $verify = Join-Path $project (Join-Path ".claude" (Join-Path "scripts" "verify.ps1"))

        if (-not (Test-Path -LiteralPath $verify)) {
            return "init-project did not install a verifier"
        }

        # vswhere lives under Program Files (x86), so pointing that variable at
        # the empty project directory is what makes the Visual Studio lookup
        # come back empty.
        $env:Path = ((($previousPath -split ";") | Where-Object { $_ -and ($_ -notmatch "dotnet") }) -join ";")
        ${env:ProgramFiles(x86)} = $project

        $ErrorActionPreference = "Continue"
        $global:LASTEXITCODE = 0

        $output = (& powershell -NoProfile -ExecutionPolicy Bypass -File $verify | Out-String)
        $code = $LASTEXITCODE

        if ($code -eq 0) {
            return "the verifier passed with no toolchain available at all"
        }

        if ($output -notlike "*$Expect*") {
            return ("expected '" + $Expect + "', got: " + ($output -replace "\s+", " "))
        }

        return $true
    }
    finally {
        $env:Path = $previousPath
        ${env:ProgramFiles(x86)} = $previousProgramFiles
        $ErrorActionPreference = $previousPreference

        Remove-Item -LiteralPath $project -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case -Name "the verifier reaches for MSBuild on a .NET Framework project" -Check {

    return (Invoke-VerifierToolchainCase `
        -Files @{
            "Legacy.csproj"   = '<Project ToolsVersion="15.0"><Import Project="$(MSBuildExtensionsPath)\Microsoft\VisualStudio\v15.0\WebApplications\Microsoft.WebApplication.targets" /></Project>'
            "packages.config" = "<packages />"
        } `
        -Expect "no Visual Studio MSBuild was found")
}

Test-Case -Name "the verifier still uses the dotnet CLI on an SDK-style project" -Check {

    return (Invoke-VerifierToolchainCase `
        -Files @{ "Modern.csproj" = '<Project Sdk="Microsoft.NET.Sdk" />' } `
        -Expect "The .NET SDK was not found in PATH")
}

Write-Host ""
Write-Host "Setup, doctor and MCP"
Write-Host "---------------------"

# External programs are replaced by recording stubs placed first on PATH, and
# the configuration directory is a scratch CLAUDE_CONFIG_DIR. What these prove
# is our wiring to npm, tlc, npx and claude; that the upstream CLIs do what
# their READMEs say is only settled by a real `tazuna setup`.
$manifest = Get-HarnessManifest
$script:setupRuns = @{}
$script:scratchRoots = @()

function New-ScratchRoot {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-setup-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $script:scratchRoots += $root
    return $root
}

function New-StubBin {
    param([Parameter(Mandatory = $true)][string]$Root)

    $bin = Join-Path $Root "stub-bin"
    New-Item -ItemType Directory -Path $bin -Force | Out-Null

    # hazard: -WhatIf:$false - the stubs run inside setup's scope, and an inherited -WhatIf left the log empty and printed "What if:".
    $record = 'Add-Content -LiteralPath $env:HARNESS_STUB_LOG -Value ("{0} " + ($args -join " ")) -WhatIf:$false'

    $stubs = @{
        "node"   = 'if ($env:HARNESS_STUB_NODE) { Write-Output $env:HARNESS_STUB_NODE } else { Write-Output "v24.15.0" }'
        "npm"    = ($record -f "npm") + "`n" + 'if ($env:HARNESS_STUB_FAIL -eq "npm") { exit 1 }'
        "uvx"    = ($record -f "uvx")
        "npx"    = ($record -f "npx") + @'

$names = @(); $take = $false
foreach ($a in $args) {
    if ($a -eq "-s") { $take = $true; continue }
    if ($a.StartsWith("-")) { $take = $false; continue }
    if ($take) { $names += $a }
}
$skillsHome = $env:CLAUDE_CONFIG_DIR
if (($args -join " ") -match " -a cursor( |$)") { $skillsHome = $env:TAZUNA_CURSOR_DIR }
foreach ($n in $names) {
    $dir = Join-Path $skillsHome (Join-Path "skills" $n)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dir "SKILL.md") -Value "---`nname: $n`ndescription: stub`n---`n"
}
'@
        "tlc"    = ($record -f "tlc") + @'

if (($args[0] -eq "harness") -and ($args[1] -eq "install") -and ($env:HARNESS_STUB_FAIL -ne "tlc-hook") -and $env:TAZUNA_CURSOR_DIR -and (Test-Path -LiteralPath $env:TAZUNA_CURSOR_DIR)) {
    Set-Content -LiteralPath (Join-Path $env:TAZUNA_CURSOR_DIR "hooks.json") -Value '{"version":1,"hooks":{"stop":[{"command":"cmd /c node C:/stub/.tlc/harness/bin/tlc-exec.mjs obs-stop"}]}}'
}
if (($args[0] -eq "harness") -and ($args[1] -eq "install") -and ($env:HARNESS_STUB_FAIL -ne "tlc-hook") -and (Test-Path -LiteralPath (Join-Path $env:CLAUDE_CONFIG_DIR "settings.json"))) {
    $path = Join-Path $env:CLAUDE_CONFIG_DIR "settings.json"
    $settings = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $hook = [PSCustomObject]@{ type = "command"; command = "node"; args = @("C:/stub/.tlc/harness/bin/tlc-exec.mjs", "stop") }
    $hooks = [PSCustomObject]@{ Stop = @([PSCustomObject]@{ hooks = @($hook) }) }
    if ($settings.PSObject.Properties["hooks"]) { $settings.hooks = $hooks }
    else { Add-Member -InputObject $settings -MemberType NoteProperty -Name hooks -Value $hooks }
    [System.IO.File]::WriteAllText($path, ($settings | ConvertTo-Json -Depth 20))
}
'@
        "claude" = ($record -f "claude") + @'

if ($args[0] -eq "--version") { Write-Output "2.1.300 (Claude Code)" }
elseif (($args[0] -eq "plugin") -and ($args[1] -eq "list")) { Write-Output "[]" }
elseif (($args[0] -eq "mcp") -and ($args[1] -eq "list")) {
    if ($env:HARNESS_STUB_MCPLIST) { Write-Output $env:HARNESS_STUB_MCPLIST }
}
elseif (($args[0] -eq "mcp") -and ($args[1] -eq "remove")) {
    if ($env:HARNESS_STUB_FAIL -eq "claude-mcp-remove") { exit 1 }
}
elseif (($args[0] -eq "mcp") -and ($args[1] -eq "add")) {
    Add-Content -LiteralPath $env:HARNESS_STUB_LOG -Value ("claude-cwd " + (Get-Location).Path) -WhatIf:$false
    # why: echoing the arguments on failure is what lets K9 prove the PAT is masked in the error path.
    if ($env:HARNESS_STUB_FAIL -eq "claude-mcp-add") { Write-Output ("error: " + ($args -join " ")); exit 1 }
}
exit 0
'@
    }

    foreach ($name in $stubs.Keys) {
        Set-Content -LiteralPath (Join-Path $bin ($name + ".ps1")) -Value $stubs[$name]
    }

    return $bin
}

function Invoke-WithStubs {
    <#
        Runs a harness script in a child powershell with the stubs first on PATH
        and a scratch configuration directory. Returns code, output and the
        recorded calls.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Script,
        [string[]]$Arguments = @(),
        [hashtable]$Environment = @{},
        [string[]]$DropPathContaining = @()
    )

    $bin = Join-Path $Root "stub-bin"
    if (-not (Test-Path -LiteralPath $bin)) { $bin = New-StubBin -Root $Root }

    $log = Join-Path $Root "calls.log"
    $saved = @{}
    $variables = @{
        "PATH"              = $bin + ";" + ((($env:PATH -split ";") | Where-Object {
                                    $entry = $_
                                    $_ -and (-not ($DropPathContaining | Where-Object { Test-Path -LiteralPath (Join-Path $entry $_) }))
                                }) -join ";")
        "CLAUDE_CONFIG_DIR" = (Join-Path $Root "config")
        "HARNESS_STUB_LOG"  = $log
        # invariant: Cursor is absent unless a case creates this directory, whatever the machine has in ~/.cursor.
        "TAZUNA_CURSOR_DIR" = (Join-Path $Root "cursor")
    }

    foreach ($key in $Environment.Keys) { $variables[$key] = $Environment[$key] }

    foreach ($key in $variables.Keys) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
        [Environment]::SetEnvironmentVariable($key, $variables[$key], "Process")
    }

    $previous = $ErrorActionPreference

    try {
        $ErrorActionPreference = "Continue"
        $global:LASTEXITCODE = 0
        $output = (& powershell -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>&1 | Out-String)
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous

        foreach ($key in $saved.Keys) {
            [Environment]::SetEnvironmentVariable($key, $saved[$key], "Process")
        }
    }

    $calls = @()
    if (Test-Path -LiteralPath $log) { $calls = @(Get-Content -LiteralPath $log) }

    return [PSCustomObject]@{ Code = $code; Output = $output; Calls = $calls; Config = (Join-Path $Root "config") }
}

function Get-SetupRun {
    # One stubbed setup per scenario, run on first use, so -Only runs only what it needs.
    param([string]$Key, [hashtable]$Environment = @{}, [string[]]$Arguments = @())

    if (-not $script:setupRuns.ContainsKey($Key)) {
        $root = New-ScratchRoot
        $script:setupRuns[$Key] = Invoke-WithStubs -Root $root -Script (Join-Path $PSScriptRoot "bootstrap.ps1") `
            -Environment $Environment -Arguments $Arguments
        $script:setupRuns[$Key] | Add-Member -NotePropertyName Root -NotePropertyValue $root
    }

    return $script:setupRuns[$Key]
}

function Test-TlcHook {
    param([string]$ConfigDir)

    $path = Join-Path $ConfigDir "settings.json"
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    return ((Get-Content -LiteralPath $path -Raw) -match "tlc-exec")
}

$skillsLine = "npx -y " + $manifest.AgentSkillsPackage + " install -s " + ($manifest.AgentSkills -join " ") + " -a claude-code -g"

try {

    # S1 - setup

    Test-Case -Name "C1 setup installs the six agent-skills with the pinned CLI, and review-change" -Check {
        $run = Get-SetupRun -Key "fresh"
        if ($run.Code -ne 0) { return "setup exited $($run.Code): $($run.Output)" }
        # The literal the check names, so a changed pin fails here instead of following along.
        $literal = "npx -y @tech-leads-club/agent-skills@1.4.10 install -s tlc-discover tlc-spec-lean tlc-spec-driven tlc-plan tlc-implement harness-eval -a claude-code -g"
        if ($run.Calls -notcontains $literal) { return "no call: $literal" }

        $missing = @((@($manifest.AgentSkills) + "review-change") | Where-Object {
                -not (Test-Path -LiteralPath (Join-Path $run.Config "skills\$_\SKILL.md")) })
        if ($missing.Count -gt 0) { return ("missing after setup: " + ($missing -join ", ")) }
        return $true
    }

    Test-Case -Name "C1 doctor fails naming each of the seven skills when absent" -Check {
        $run = Get-SetupRun -Key "fresh"
        $skills = @($manifest.AgentSkills) + "review-change"
        $moved = Join-Path $run.Root "moved-skills"
        New-Item -ItemType Directory -Path $moved -Force | Out-Null

        foreach ($s in $skills) { Move-Item -LiteralPath (Join-Path $run.Config "skills\$s") -Destination $moved }

        try {
            $doctor = Invoke-WithStubs -Root $run.Root -Script (Join-Path $PSScriptRoot "health-check.ps1")
        }
        finally {
            foreach ($s in $skills) { Move-Item -LiteralPath (Join-Path $moved $s) -Destination (Join-Path $run.Config "skills") }
        }

        if ($doctor.Code -eq 0) { return "doctor passed with no skills installed" }
        $unnamed = @($skills | Where-Object { $doctor.Output -notmatch ("skill " + [regex]::Escape($_) + " is missing") })
        if ($unnamed.Count -gt 0) { return ("not named: " + ($unnamed -join ", ")) }
        return $true
    }

    Test-Case -Name "C2 settings.json holds the permissions and the tlc-exec hook, toolkit wired after install" -Check {
        $run = Get-SetupRun -Key "fresh"
        $settings = Get-Content -LiteralPath (Join-Path $run.Config "settings.json") -Raw | ConvertFrom-Json

        if (-not $settings.permissions.deny) { return "no permissions block" }
        if (-not (Test-TlcHook -ConfigDir $run.Config)) { return "no tlc-exec hook" }

        $npm = [array]::IndexOf($run.Calls, "npm install -g " + $manifest.ToolkitPackage)
        $tlc = [array]::IndexOf($run.Calls, "tlc harness install")
        if ($npm -lt 0) { return "npm install -g $($manifest.ToolkitPackage) was not called" }
        if ($tlc -lt $npm) { return "tlc harness install did not run after the npm install" }
        return $true
    }

    Test-Case -Name "C3 a second setup exits 0 and keeps the tlc-exec hook" -Check {
        $run = Get-SetupRun -Key "fresh"
        $again = Invoke-WithStubs -Root $run.Root -Script (Join-Path $PSScriptRoot "bootstrap.ps1")
        if ($again.Code -ne 0) { return "second setup exited $($again.Code)" }
        if (-not (Test-TlcHook -ConfigDir $run.Config)) { return "the hook is gone after the second run" }
        return $true
    }

    Test-Case -Name "C4 node below 24 stops setup before anything is written" -Check {
        $run = Get-SetupRun -Key "old-node" -Environment @{ HARNESS_STUB_NODE = "v22.0.0" }
        if ($run.Code -ne 1) { return "exit $($run.Code), expected 1" }
        if ($run.Output -notmatch "node 24\+ required") { return "no 'node 24+ required'" }
        if ($run.Output -notmatch "winget install OpenJS\.NodeJS\.LTS") { return "no winget command" }
        if (Test-Path -LiteralPath $run.Config) { return "the configuration directory was created" }
        return $true
    }

    Test-Case -Name "C5 setup -WhatIf writes nothing and installs nothing" -Check {
        $run = Get-SetupRun -Key "whatif" -Arguments @("-WhatIf")
        if ($run.Code -ne 0) { return "exit $($run.Code): $($run.Output)" }
        if (Test-Path -LiteralPath $run.Config) { return "the configuration directory was created" }
        $installs = @($run.Calls | Where-Object { $_.StartsWith("npm install") -or $_.StartsWith("npx ") -or $_.StartsWith("tlc ") })
        if ($installs.Count -gt 0) { return ("ran: " + ($installs -join "; ")) }
        return $true
    }

    Test-Case -Name "C6 setup registers context7, playwright and agent-skills at user scope, never serena" -Check {
        $run = Get-SetupRun -Key "fresh"
        $added = @($run.Calls | Where-Object { $_.StartsWith("claude mcp add-json --scope user ") })

        foreach ($name in @("context7", "playwright", "agent-skills")) {
            if (-not ($added | Where-Object { $_.StartsWith("claude mcp add-json --scope user $name ") })) { return "$name was not registered" }
        }

        if ($added | Where-Object { $_ -match "--scope user serena " }) { return "serena was registered at user scope" }
        return $true
    }

    Test-Case -Name "C7 setup leaves a user-scope serena the user registered" -Check {
        $run = Get-SetupRun -Key "user-serena" -Environment @{ HARNESS_STUB_MCPLIST = "serena: uvx --from serena-agent@1.7.0 serena start-mcp-server - Connected" }
        if ($run.Code -ne 0) { return "setup exited $($run.Code)" }
        $removed = @($run.Calls | Where-Object { $_.StartsWith("claude mcp remove") })
        if ($removed.Count -gt 0) { return ("setup removed: " + ($removed -join "; ")) }
        if ($run.Output -match "(?m)^\S*\s*REMOVED") { return "setup printed a REMOVED line" }
        return $true
    }

    Test-Case -Name "C35 doctor fails when settings.json has no tlc-exec hook" -Check {
        $run = Get-SetupRun -Key "fresh"
        $path = Join-Path $run.Config "settings.json"
        $original = [System.IO.File]::ReadAllText($path)

        try {
            Copy-Item -LiteralPath (Join-Path $repoRoot "user\settings.json") -Destination $path -Force
            $doctor = Invoke-WithStubs -Root $run.Root -Script (Join-Path $PSScriptRoot "health-check.ps1")
        }
        finally {
            [System.IO.File]::WriteAllText($path, $original)
        }

        if ($doctor.Code -eq 0) { return "doctor passed without the toolkit hook" }
        if ($doctor.Output -notmatch "no tlc-exec hook") { return "the missing hook was not named" }
        return $true
    }

    # S2 - init

    function New-InitProject {
        param([hashtable]$Files)
        $project = Join-Path (New-ScratchRoot) "project"
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        foreach ($name in $Files.Keys) { Set-Content -LiteralPath (Join-Path $project $name) -Value $Files[$name] -NoNewline }
        $run = Invoke-WithStubs -Root (Split-Path -Parent $project) -Script (Join-Path $PSScriptRoot "init-project.ps1") -Arguments @("-Path", $project, "-NoTrust")
        $run | Add-Member -NotePropertyName Project -NotePropertyValue $project
        return $run
    }

    Test-Case -Name "C8 init on a csproj writes the dotnet template" -Check {
        $run = New-InitProject -Files @{ "App.csproj" = '<Project Sdk="Microsoft.NET.Sdk" />' }
        foreach ($path in @("AGENTS.md", ".claude\settings.json", ".claude\scripts\verify.ps1")) {
            if (-not (Test-Path -LiteralPath (Join-Path $run.Project $path))) { return "$path missing" }
        }
        foreach ($pair in @(@("AGENTS.md", "AGENTS.md"), @("dot-claude\settings.json", ".claude\settings.json"), @("dot-claude\scripts\verify.ps1", ".claude\scripts\verify.ps1"))) {
            if (-not (Test-FileContentEqual -ReferenceFile (Join-Path $repoRoot ("templates\dotnet\" + $pair[0])) -DifferenceFile (Join-Path $run.Project $pair[1]))) {
                return "$($pair[1]) is not the dotnet one"
            }
        }
        return $true
    }

    Test-Case -Name "C9 init with no recognised stack writes the generic template" -Check {
        $run = New-InitProject -Files @{ "notes.txt" = "hello" }
        foreach ($pair in @(@("AGENTS.md", "AGENTS.md"), @("dot-claude\settings.json", ".claude\settings.json"), @("dot-claude\scripts\verify.ps1", ".claude\scripts\verify.ps1"))) {
            if (-not (Test-FileContentEqual -ReferenceFile (Join-Path $repoRoot ("templates\generic\" + $pair[0])) -DifferenceFile (Join-Path $run.Project $pair[1]))) {
                return "$($pair[1]) is not the generic one"
            }
        }
        return $true
    }

    Test-Case -Name "C10 init leaves no .tlc directory in the project" -Check {
        $run = New-InitProject -Files @{ "App.csproj" = '<Project Sdk="Microsoft.NET.Sdk" />' }
        if ($run.Code -ne 0) { return "init exited $($run.Code)" }
        if (Test-Path -LiteralPath (Join-Path $run.Project ".tlc")) { return ".tlc was written" }
        if ($run.Calls | Where-Object { $_.StartsWith("tlc ") }) { return "init called tlc" }
        return $true
    }

    Test-Case -Name "C11 templates and the written settings wire the three hooks to .claude/hooks" -Check {
        $run = New-InitProject -Files @{ "App.csproj" = '<Project Sdk="Microsoft.NET.Sdk" />' }
        $wiring = @{ "SessionStart" = "record-session-baseline.ps1"; "PreToolUse" = "block-secret-commit.ps1"; "Stop" = "require-verification.ps1" }
        $files = @(
            (Join-Path $repoRoot "templates\dotnet\dot-claude\settings.json"),
            (Join-Path $repoRoot "templates\generic\dot-claude\settings.json"),
            (Join-Path $run.Project ".claude\settings.json"))

        foreach ($file in $files) {
            $settings = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
            foreach ($event in $wiring.Keys) {
                if (-not $settings.hooks.PSObject.Properties[$event]) { return "$file has no $event hook" }
                $text = $settings.hooks.$event | ConvertTo-Json -Depth 10
                if ($text -notmatch ("/\.claude/hooks/" + [regex]::Escape($wiring[$event]))) { return "$file $event does not run $($wiring[$event])" }
            }
        }
        return $true
    }

    Test-Case -Name "C14 a second init reports every file UNCHANGED and exits 0" -Check {
        $run = New-InitProject -Files @{ "App.csproj" = '<Project Sdk="Microsoft.NET.Sdk" />' }
        $again = Invoke-WithStubs -Root (Split-Path -Parent $run.Project) -Script (Join-Path $PSScriptRoot "init-project.ps1") -Arguments @("-Path", $run.Project, "-NoTrust")
        if ($again.Code -ne 0) { return "exit $($again.Code)" }
        if ($again.Output -notmatch "Project harness: 0 created, 0 updated, [1-9]\d* unchanged, 0 skipped") { return "second run was not all UNCHANGED" }
        return $true
    }

    Test-Case -Name "C15 both AGENTS.md templates are at most 40 lines" -Check {
        foreach ($type in @("dotnet", "generic")) {
            $count = @(Get-Content -LiteralPath (Join-Path $repoRoot "templates\$type\AGENTS.md")).Count
            if ($count -gt 40) { return "$type AGENTS.md has $count lines" }
        }
        return $true
    }

    # S3 - mcp add

    $catalog = (Get-Content -LiteralPath (Join-Path $repoRoot "mcp\catalog.json") -Raw | ConvertFrom-Json).servers
    $catalogNames = @($catalog.PSObject.Properties.Name)
    $adoEnvironment = @{ ADO_COLLECTION_URL = "http://tfs.invalid/DefaultCollection"; ADO_PAT = "not-a-real-token" }

    function Invoke-McpAdd {
        param([string]$Project, [string[]]$Arguments, [hashtable]$Environment = $adoEnvironment, [string[]]$Drop = @())
        return (Invoke-WithStubs -Root (Split-Path -Parent $Project) -Script (Join-Path $PSScriptRoot "project-mcp.ps1") `
            -Arguments (@($Arguments) + @("-Path", $Project)) -Environment $Environment -DropPathContaining $Drop)
    }

    function New-McpProject {
        $project = Join-Path (New-ScratchRoot) "project"
        New-Item -ItemType Directory -Path (Join-Path $project ".claude") -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $project ".mcp.json") -Value '{ "mcpServers": { "mine": { "command": "mine" } } }'
        Set-Content -LiteralPath (Join-Path $project ".claude\settings.json") -Value '{ "permissions": { "allow": ["Read(x)"] } }'
        return $project
    }

    Test-Case -Name "C16 mcp add writes each of the 4 shared catalog entries and keeps an existing one" -Check {
        if ($catalogNames.Count -ne 5) { return "the catalog has $($catalogNames.Count) entries, expected 5" }

        # why: azure-devops is registered in Claude Code local scope instead (C20, C21, K1).
        foreach ($name in @($catalogNames | Where-Object { $_ -ne "azure-devops" })) {
            $project = New-McpProject
            $run = Invoke-McpAdd -Project $project -Arguments @("add", $name)
            if ($run.Code -ne 0) { return "$name exited $($run.Code): $($run.Output)" }

            $mcp = Get-Content -LiteralPath (Join-Path $project ".mcp.json") -Raw | ConvertFrom-Json
            if (-not $mcp.mcpServers.mine) { return "$name dropped the existing entry" }
            if ((Get-JsonCanonicalForm -Value $mcp.mcpServers.$name) -ne (Get-JsonCanonicalForm -Value $catalog.$name.server)) { return "$name entry differs from the catalog" }
            $settings = Get-Content -LiteralPath (Join-Path $project ".claude\settings.json") -Raw | ConvertFrom-Json
            if (@($settings.enabledMcpjsonServers) -notcontains $name) { return "$name is not in enabledMcpjsonServers" }
        }
        return $true
    }

    Test-Case -Name "C17 mcp add enables the server and keeps the existing permissions" -Check {
        $project = New-McpProject
        $null = Invoke-McpAdd -Project $project -Arguments @("add", "mermaid")
        $settings = Get-Content -LiteralPath (Join-Path $project ".claude\settings.json") -Raw | ConvertFrom-Json
        if (@($settings.enabledMcpjsonServers) -notcontains "mermaid") { return "mermaid is not enabled" }
        if (@($settings.permissions.allow) -notcontains "Read(x)") { return "the existing permissions were lost" }
        return $true
    }

    Test-Case -Name "C18 a second identical mcp add prints UNCHANGED and changes no byte" -Check {
        $project = New-McpProject
        $null = Invoke-McpAdd -Project $project -Arguments @("add", "mermaid")
        $before = @((Get-FileSha256 -Path (Join-Path $project ".mcp.json")), (Get-FileSha256 -Path (Join-Path $project ".claude\settings.json")))
        $run = Invoke-McpAdd -Project $project -Arguments @("add", "mermaid")
        $after = @((Get-FileSha256 -Path (Join-Path $project ".mcp.json")), (Get-FileSha256 -Path (Join-Path $project ".claude\settings.json")))
        if ($run.Code -ne 0) { return "exit $($run.Code)" }
        if ($run.Output -notmatch "UNCHANGED\s+mermaid") { return "no 'UNCHANGED mermaid'" }
        if (($before -join ",") -ne ($after -join ",")) { return "a file changed on the second run" }
        return $true
    }

    Test-Case -Name "C19 mcp add of an unknown name lists the catalog, exits 1 and writes nothing" -Check {
        $project = Join-Path (New-ScratchRoot) "project"
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        $run = Invoke-McpAdd -Project $project -Arguments @("add", "nope")
        if ($run.Code -ne 1) { return "exit $($run.Code), expected 1" }
        foreach ($name in $catalogNames) { if ($run.Output -notmatch [regex]::Escape($name)) { return "$name not listed" } }
        if (Test-Path -LiteralPath (Join-Path $project ".mcp.json")) { return ".mcp.json was written" }
        return $true
    }

    function New-AdoConfiguratorStub {
        # A configurator that records its -Path and whether .mcp.json existed when it ran.
        param([string]$Project, [int]$Code = 0)
        $marker = Join-Path (Split-Path -Parent $Project) "configurator.txt"
        $stub = Join-Path (Split-Path -Parent $Project) "configure-stub.ps1"
        Set-Content -LiteralPath $stub -Value ('param([string]$Path) Set-Content -LiteralPath "' + $marker + '" -Value ("path=" + $Path + ";mcp-existed=" + (Test-Path -LiteralPath "' + (Join-Path $Project ".mcp.json") + '")) -WhatIf:$false; exit ' + $Code)
        return [PSCustomObject]@{ Script = $stub; Marker = $marker }
    }

    Test-Case -Name "C20 mcp add azure-devops runs the configurator for the project before writing" -Check {
        $project = Join-Path (New-ScratchRoot) "project"
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        $stub = New-AdoConfiguratorStub -Project $project

        $run = Invoke-McpAdd -Project $project -Arguments @("add", "azure-devops", "-AdoConfigurator", $stub.Script)

        if (-not (Test-Path -LiteralPath $stub.Marker)) { return "the configurator did not run" }
        $expected = "path=" + (Resolve-Path -LiteralPath $project).ProviderPath + ";mcp-existed=False"
        if ((Get-Content -LiteralPath $stub.Marker -Raw).Trim() -ne $expected) { return ("configurator saw '" + (Get-Content -LiteralPath $stub.Marker -Raw).Trim() + "', expected '$expected'") }
        if ($run.Code -ne 0) { return "exit $($run.Code)" }
        return $true
    }

    Test-Case -Name "C21 mcp add azure-devops installs its rule and leaves it out of .mcp.json and enabledMcpjsonServers" -Check {
        $project = New-McpProject
        $stub = New-AdoConfiguratorStub -Project $project
        $run = Invoke-McpAdd -Project $project -Arguments @("add", "azure-devops", "-AdoConfigurator", $stub.Script)
        if ($run.Code -ne 0) { return "exit $($run.Code): $($run.Output)" }
        $rule = Join-Path $project ".claude\rules\azure-devops.md"
        if (-not (Test-FileContentEqual -ReferenceFile (Join-Path $repoRoot "mcp\rules\azure-devops.md") -DifferenceFile $rule)) { return "the rule was not installed" }
        $mcp = Get-Content -LiteralPath (Join-Path $project ".mcp.json") -Raw | ConvertFrom-Json
        if ($mcp.mcpServers.PSObject.Properties["azure-devops"]) { return ".mcp.json got an azure-devops entry" }
        if (-not $mcp.mcpServers.mine) { return "the existing entry was dropped" }
        $settings = Get-Content -LiteralPath (Join-Path $project ".claude\settings.json") -Raw | ConvertFrom-Json
        if ($settings.PSObject.Properties["enabledMcpjsonServers"] -and (@($settings.enabledMcpjsonServers) -contains "azure-devops")) { return "azure-devops was enabled in settings.json" }
        return $true
    }

    # K - azure-devops per project: configure-ado.ps1 run in-process against a stub HTTP server and a stub claude.

    function Start-AdoStubServer {
        # hazard: HttpListener on a localhost prefix needs no URL ACL; any other host would need admin.
        $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()

        $job = Start-Job -ArgumentList $port -ScriptBlock {
            param($port)
            $listener = New-Object System.Net.HttpListener
            $listener.Prefixes.Add("http://localhost:$port/")
            $listener.Start()
            $good = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":good-pat"))
            while ($true) {
                $context = $listener.GetContext()
                $path = [Uri]::UnescapeDataString($context.Request.Url.AbsolutePath)
                $status = 404
                if ($context.Request.Headers["Authorization"] -ne $good) { $status = 401 }
                elseif (($path -eq "/MOBILE/_apis/projects/MyProject") -or ($path -eq "/tfs/DefaultCollection/_apis/projects/My Project")) { $status = 200 }
                elseif ($path -eq "/OLD/_apis/projects/MyProject") { $status = 400 }
                $bytes = [Text.Encoding]::ASCII.GetBytes("{}")
                $context.Response.StatusCode = $status
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $context.Response.Close()
            }
        }

        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline) {
            try { $null = Invoke-WebRequest -Uri "http://localhost:$port/" -UseBasicParsing -TimeoutSec 2 } catch { if ($_.Exception.Response) { break } }
            Start-Sleep -Milliseconds 200
        }

        return [PSCustomObject]@{ Job = $job; Url = "http://localhost:$port" }
    }

    $script:adoServer = $null

    function Get-AdoStubServer {
        if (-not $script:adoServer) { $script:adoServer = Start-AdoStubServer }
        return $script:adoServer
    }

    function Invoke-AdoConfigure {
        <#
            Runs configure-ado.ps1 in this process with the stub claude first on PATH (or no claude at
            all) and Read-Host replaced, so no case can block on a prompt. Returns code, output, calls.
        #>
        param(
            [string]$ProjectUrl,
            [string]$PatText = "good-pat",
            [switch]$SkipTest,
            [switch]$WhatIf,
            [switch]$NoClaude,
            [string]$Fail = ""
        )

        $root = New-ScratchRoot
        $project = Join-Path $root "project"
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        $bin = New-StubBin -Root $root
        $log = Join-Path $root "calls.log"

        $path = $bin + ";" + $env:PATH
        if ($NoClaude) { $path = (Join-Path $env:SystemRoot "System32") + ";" + (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0") }

        $saved = @{}
        $variables = @{ PATH = $path; HARNESS_STUB_LOG = $log; HARNESS_STUB_FAIL = $Fail }
        foreach ($key in $variables.Keys) {
            $saved[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
            [Environment]::SetEnvironmentVariable($key, $variables[$key], "Process")
        }

        $secure = New-Object System.Security.SecureString
        foreach ($character in $PatText.ToCharArray()) { $secure.AppendChar($character) }

        $arguments = @{ ProjectUrl = $ProjectUrl; Pat = $secure; Path = $project }
        if ($SkipTest) { $arguments["SkipTest"] = $true }
        if ($WhatIf) { $arguments["WhatIf"] = $true }

        # why: a function shadows the cmdlet for the script called below; a prompt is recorded instead of blocking.
        function Read-Host { Write-Host "PROMPTED"; return "" }

        $previous = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $global:LASTEXITCODE = 0
            $output = (& (Join-Path $PSScriptRoot "configure-ado.ps1") @arguments *>&1 | Out-String)
            $code = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previous
            foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key], "Process") }
        }

        $calls = @()
        if (Test-Path -LiteralPath $log) { $calls = @(Get-Content -LiteralPath $log) }
        $mcpCalls = @($calls | Where-Object { $_.StartsWith("claude mcp ") })

        return [PSCustomObject]@{ Code = $code; Output = $output; Calls = $calls; McpCalls = $mcpCalls; Project = $project }
    }

    Test-Case -Name "K1 a project URL registers azure-devops in local scope with the collection, project, PAT and API 7.0" -Check {
        $server = Get-AdoStubServer
        $run = Invoke-AdoConfigure -ProjectUrl ($server.Url + "/MOBILE/MyProject")
        if ($run.Code -ne 0) { return "exit $($run.Code): $($run.Output)" }
        $add = @($run.McpCalls | Where-Object { $_.StartsWith("claude mcp add ") })
        if ($add.Count -ne 1) { return ("expected one claude mcp add, got: " + ($run.McpCalls -join " | ")) }
        $expected = @(
            "claude mcp add azure-devops -s local ",
            ("-e AZURE_DEVOPS_ORG_URL=" + $server.Url + "/MOBILE "),
            "-e AZURE_DEVOPS_AUTH_METHOD=pat ",
            "-e AZURE_DEVOPS_API_VERSION=7.0 ",
            "-e AZURE_DEVOPS_PAT=good-pat ",
            "-e AZURE_DEVOPS_DEFAULT_PROJECT=MyProject ",
            " -- npx -y @tiberriver256/mcp-server-azure-devops"
        )
        foreach ($part in $expected) { if (-not $add[0].Contains($part)) { return "missing '$part' in: $($add[0])" } }
        $cwd = @($run.Calls | Where-Object { $_.StartsWith("claude-cwd ") })
        if ($cwd[0] -ne ("claude-cwd " + (Resolve-Path -LiteralPath $run.Project).ProviderPath)) { return "claude ran in '$($cwd[0])', not the project" }
        if ($run.Output.Contains("PROMPTED")) { return "it prompted although every value was given" }
        return $true
    }

    Test-Case -Name "K2 a project URL with a virtual directory, an encoded name, a page suffix and a trailing slash is split into collection and project" -Check {
        $server = Get-AdoStubServer
        $run = Invoke-AdoConfigure -ProjectUrl ($server.Url + "/tfs/DefaultCollection/My%20Project/_git/repo/")
        if ($run.Code -ne 0) { return "exit $($run.Code): $($run.Output)" }
        $add = @($run.McpCalls | Where-Object { $_.StartsWith("claude mcp add ") })
        if (-not $add[0].Contains("-e AZURE_DEVOPS_ORG_URL=" + $server.Url + "/tfs/DefaultCollection ")) { return "wrong collection: $($add[0])" }
        if (-not $add[0].Contains("-e AZURE_DEVOPS_DEFAULT_PROJECT=My Project ")) { return "wrong project: $($add[0])" }
        return $true
    }

    Test-Case -Name "K3 the PAT reaches no console output, no project file and no environment variable" -Check {
        $marker = "selftest-not-a-real-token-" + [guid]::NewGuid().ToString("N")
        $userBefore = [Environment]::GetEnvironmentVariable("ADO_PAT", "User")
        $run = Invoke-AdoConfigure -ProjectUrl "http://tfs.invalid/DefaultCollection/MyProject" -PatText $marker -SkipTest
        if ($run.Code -ne 0) { return "exit $($run.Code): $($run.Output)" }
        if (-not (@($run.McpCalls) -join " ").Contains("AZURE_DEVOPS_PAT=" + $marker)) { return "the PAT did not reach claude mcp add, so this case proves nothing" }
        if ($run.Output.Contains($marker)) { return "the PAT appeared in the output" }
        foreach ($file in @(Get-ChildItem -LiteralPath $run.Project -Recurse -File -Force)) {
            if ([System.IO.File]::ReadAllText($file.FullName).Contains($marker)) { return "the PAT was written to $($file.FullName)" }
        }
        if ([Environment]::GetEnvironmentVariable("ADO_PAT", "User") -ne $userBefore) { return "the User ADO_PAT changed" }
        foreach ($name in @("ADO_PAT", "AZURE_DEVOPS_PAT")) {
            foreach ($scope in @("Process", "User")) {
                if ([string][Environment]::GetEnvironmentVariable($name, $scope) -eq $marker) { return "the $scope $name holds the PAT" }
            }
        }
        return $true
    }

    Test-Case -Name "K4 a re-run removes the local entry before adding it, and a failed remove does not stop it" -Check {
        $run = Invoke-AdoConfigure -ProjectUrl "http://tfs.invalid/DefaultCollection/MyProject" -SkipTest -Fail "claude-mcp-remove"
        if ($run.Code -ne 0) { return "exit $($run.Code): $($run.Output)" }
        if ($run.McpCalls.Count -ne 2) { return ("expected remove then add, got: " + ($run.McpCalls -join " | ")) }
        if ($run.McpCalls[0] -ne "claude mcp remove azure-devops -s local") { return "first call was: $($run.McpCalls[0])" }
        if (-not $run.McpCalls[1].StartsWith("claude mcp add azure-devops -s local ")) { return "second call was: $($run.McpCalls[1])" }
        return $true
    }

    Test-Case -Name "K5 a PAT the server refuses, a project it does not have, and a server that does not answer each register nothing and exit 1" -Check {
        $server = Get-AdoStubServer
        $cases = @(
            @{ Url = ($server.Url + "/MOBILE/MyProject"); Pat = "bad-pat"; Expect = "Not authorized (401)" },
            @{ Url = ($server.Url + "/MOBILE/Missing"); Pat = "good-pat"; Expect = "Project 'Missing' not found (404)" },
            @{ Url = ($server.Url + "/OLD/MyProject"); Pat = "good-pat"; Expect = "HTTP 400 - usually the api-version" },
            @{ Url = "http://127.0.0.1:9/MOBILE/MyProject"; Pat = "good-pat"; Expect = "FAIL" }
        )
        foreach ($case in $cases) {
            $run = Invoke-AdoConfigure -ProjectUrl $case.Url -PatText $case.Pat
            if ($run.Code -ne 1) { return "$($case.Url): exit $($run.Code), expected 1" }
            if ($run.Output -notmatch "FAIL") { return "$($case.Url): no FAIL" }
            if (-not $run.Output.Contains($case.Expect)) { return "$($case.Url): output lacks '$($case.Expect)'" }
            if ($run.McpCalls.Count -ne 0) { return "$($case.Url): claude mcp was called" }
        }
        return $true
    }

    Test-Case -Name "K6 a bare collection URL is refused as not a project URL, with an example" -Check {
        foreach ($url in @("http://azuredevops/MOBILE", "http://azuredevops/MOBILE/_git/x")) {
            $run = Invoke-AdoConfigure -ProjectUrl $url -SkipTest
            if ($run.Code -ne 1) { return "${url}: exit $($run.Code), expected 1" }
            if (-not $run.Output.Contains("Not a project URL")) { return "${url}: no 'Not a project URL'" }
            if (-not $run.Output.Contains("http://server/DefaultCollection/MyProject")) { return "${url}: no example" }
            if ($run.McpCalls.Count -ne 0) { return "${url}: claude mcp was called" }
        }
        return $true
    }

    Test-Case -Name "K7 a URL without a scheme, an empty URL and an empty PAT each exit 1 without calling claude mcp" -Check {
        $runs = @(
            (Invoke-AdoConfigure -ProjectUrl "azuredevops/MOBILE/P" -SkipTest),
            (Invoke-AdoConfigure -ProjectUrl "" -SkipTest),
            (Invoke-AdoConfigure -ProjectUrl "http://azuredevops/MOBILE/P" -PatText "" -SkipTest)
        )
        $names = @("no scheme", "empty URL", "empty PAT")
        for ($i = 0; $i -lt 3; $i++) {
            if ($runs[$i].Code -ne 1) { return "$($names[$i]): exit $($runs[$i].Code), expected 1" }
            if ($runs[$i].McpCalls.Count -ne 0) { return "$($names[$i]): claude mcp was called" }
        }
        return $true
    }

    Test-Case -Name "K8 without claude on PATH it says Claude Code is required and exits 1 before any prompt" -Check {
        $run = Invoke-AdoConfigure -ProjectUrl "" -NoClaude
        if ($run.Code -ne 1) { return "exit $($run.Code), expected 1" }
        if (-not $run.Output.Contains("Claude Code (claude) is required")) { return "no 'Claude Code (claude) is required'" }
        if ($run.Output.Contains("PROMPTED")) { return "it prompted before refusing" }
        return $true
    }

    Test-Case -Name "K9 a failing claude mcp add prints FAIL, masks the PAT in what claude printed, and exits 1" -Check {
        $marker = "selftest-not-a-real-token-" + [guid]::NewGuid().ToString("N")
        $run = Invoke-AdoConfigure -ProjectUrl "http://tfs.invalid/DefaultCollection/MyProject" -PatText $marker -SkipTest -Fail "claude-mcp-add"
        if ($run.Code -ne 1) { return "exit $($run.Code), expected 1" }
        if ($run.Output -notmatch "FAIL\s+claude mcp add exited 1") { return "no 'FAIL claude mcp add exited 1'" }
        if (-not $run.Output.Contains("AZURE_DEVOPS_PAT=(PAT)")) { return "claude's echoed arguments were not printed masked, so this case proves nothing" }
        if ($run.Output.Contains($marker)) { return "the PAT appeared in the failure output" }
        return $true
    }

    Test-Case -Name "K10 -WhatIf registers nothing and tazuna mcp add azure-devops -WhatIf writes no project file" -Check {
        $run = Invoke-AdoConfigure -ProjectUrl "http://tfs.invalid/DefaultCollection/MyProject" -SkipTest -WhatIf
        if ($run.Code -ne 0) { return "exit $($run.Code): $($run.Output)" }
        if (Test-Path -LiteralPath (Join-Path $run.Project ".claude")) { return "configure-ado -WhatIf created a project file" }
        if ($run.Output -notmatch "WHATIF\s+would register azure-devops") { return "no 'WHATIF would register azure-devops'" }
        if ($run.McpCalls.Count -ne 0) { return ("claude mcp was called: " + ($run.McpCalls -join " | ")) }

        $project = New-McpProject
        $before = @(Get-ChildItem -LiteralPath $project -Recurse -File -Force | ForEach-Object { $_.FullName + "=" + (Get-FileSha256 -Path $_.FullName) })
        $stub = New-AdoConfiguratorStub -Project $project
        $add = Invoke-McpAdd -Project $project -Arguments @("add", "azure-devops", "-AdoConfigurator", $stub.Script, "-WhatIf")
        $after = @(Get-ChildItem -LiteralPath $project -Recurse -File -Force | ForEach-Object { $_.FullName + "=" + (Get-FileSha256 -Path $_.FullName) })
        if ($add.Code -ne 0) { return "mcp add -WhatIf exit $($add.Code)" }
        if ($add.Output -notmatch "WHATIF\s+would write \.claude\\rules\\azure-devops\.md") { return "no WHATIF line for the rule" }
        if (($before -join ",") -ne ($after -join ",")) { return "mcp add -WhatIf changed a project file" }
        return $true
    }

    Test-Case -Name "C22 every credential-bearing value in the MCP catalogs is a placeholder" -Check {
        $placeholder = '^\$\{[A-Z_][A-Z0-9_]*(:-[^}]*)?\}$'
        $plainLiterals = @("pat", "7.0")
        $problems = @()

        $user = (Get-Content -LiteralPath (Join-Path $repoRoot "mcp\servers.json") -Raw | ConvertFrom-Json).mcpServers
        $servers = @()
        foreach ($p in $user.PSObject.Properties) { $servers += [PSCustomObject]@{ Name = $p.Name; Server = $p.Value } }
        foreach ($name in $catalogNames) { $servers += [PSCustomObject]@{ Name = $name; Server = $catalog.$name.server } }

        foreach ($entry in $servers) {
            foreach ($section in @("env", "headers")) {
                if (-not $entry.Server.PSObject.Properties[$section]) { continue }
                foreach ($value in $entry.Server.$section.PSObject.Properties) {
                    if (($value.Value -notmatch $placeholder) -and ($plainLiterals -notcontains $value.Value)) {
                        $problems += "$($entry.Name).$section.$($value.Name)"
                    }
                }
            }
            $text = $entry.Server | ConvertTo-Json -Depth 20
            foreach ($pattern in @("-----BEGIN [A-Z ]*PRIVATE KEY-----", "AKIA[0-9A-Z]{16}", "gh[pousr]_[A-Za-z0-9]{36}", "sk-ant-[A-Za-z0-9_\-]{20,}", "sk-[A-Za-z0-9]{32,}", "AIza[0-9A-Za-z_\-]{35}")) {
                if ($text -match $pattern) { $problems += "$($entry.Name) matches $pattern" }
            }
        }

        if ($problems.Count -gt 0) { return ("literal values: " + ($problems -join ", ")) }
        return $true
    }

    Test-Case -Name "C23 mcp list prints the 5 names with their purpose" -Check {
        $project = Join-Path (New-ScratchRoot) "project"
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        $run = Invoke-McpAdd -Project $project -Arguments @("list")
        if ($run.Code -ne 0) { return "exit $($run.Code)" }
        foreach ($name in @("azure-devops", "serena", "drawio", "plantuml", "mermaid")) {
            $purpose = $catalog.$name.purpose
            if (-not $purpose) { return "$name has no purpose" }
            if ($run.Output -notmatch ([regex]::Escape($name) + "\s+" + [regex]::Escape($purpose))) { return "$name is not printed with its purpose" }
        }
        return $true
    }

    Test-Case -Name "C24 mcp add serena without uvx says how to get it, exits 1 and writes nothing" -Check {
        $project = Join-Path (New-ScratchRoot) "project"
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        Remove-Item -LiteralPath (Join-Path (New-StubBin -Root (Split-Path -Parent $project)) "uvx.ps1")

        $run = Invoke-McpAdd -Project $project -Arguments @("add", "serena") -Drop @("uvx.exe", "uvx.cmd", "uvx.ps1", "uvx")
        if ($run.Code -ne 1) { return "exit $($run.Code), expected 1" }
        if ($run.Output -notmatch "uvx required") { return "no 'uvx required'" }
        if ($run.Output -notmatch [regex]::Escape("irm https://astral.sh/uv/install.ps1 | iex")) { return "no install command" }
        if (Test-Path -LiteralPath (Join-Path $project ".mcp.json")) { return ".mcp.json was written" }
        return $true
    }

    # S4 - README

    $readme = Get-Content -LiteralPath (Join-Path $repoRoot "README.md") -Raw -Encoding UTF8

    $readmeSections = @("About the project", "Getting started", "Usage", "How it works", "Safety", "Troubleshooting", "Contributing", "License", "Acknowledgments")

    Test-Case -Name "C25 the README has exactly the 9 sections in order" -Check {
        $found = @([regex]::Matches($readme, '(?m)^## (.+?)\s*$') | ForEach-Object { $_.Groups[1].Value })
        if (($found -join "|") -ne ($readmeSections -join "|")) { return ("sections: " + ($found -join " | ")) }
        return $true
    }

    Test-Case -Name "C26 the README names every command and every catalog name" -Check {
        foreach ($command in @("setup", "init", "mcp", "doctor", "update", "test")) {
            if ($readme -notmatch ("tazuna " + $command + "\b")) { return "tazuna $command is not named" }
        }
        foreach ($name in $catalogNames) { if ($readme -notmatch ("``" + [regex]::Escape($name) + "``")) { return "$name is not named" } }
        return $true
    }

    Test-Case -Name "C27 the README draws the loop in mermaid" -Check {
        $block = [regex]::Match($readme, '(?s)```mermaid(.*?)```')
        if (-not $block.Success) { return "no mermaid block" }
        $at = -1
        foreach ($step in @("Discovery", "Plan", "Checks", "Build", "Verify", "review", "Human")) {
            $index = $block.Groups[1].Value.IndexOf($step, [System.StringComparison]::OrdinalIgnoreCase)
            if ($index -le $at) { return "'$step' missing or out of order" }
            $at = $index
        }
        return $true
    }

    Test-Case -Name "C28 the README states both licences" -Check {
        if ($readme -notmatch "Elastic License 2\.0") { return "no Elastic License 2.0" }
        if ($readme -notmatch "CC-BY-4\.0") { return "no CC-BY-4.0" }
        return $true
    }

    Test-Case -Name "C29 the README maps change size to each workflow" -Check {
        foreach ($skill in @("/tlc-spec-lean", "/tlc-spec-driven", "/tlc-plan", "/tlc-implement", "/review-change")) {
            if (-not ([regex]::IsMatch($readme, "(?m)^\|.*``" + [regex]::Escape($skill) + "``.*\|\s*$"))) { return "no table row for $skill" }
        }
        return $true
    }

    # The public README.

    function Get-ReadmeSection {
        # The body of one "## " section of the README, up to the next "## " or the end.
        param([string]$Heading)
        $match = [regex]::Match($readme, '(?s)(?:^|\n)## ' + [regex]::Escape($Heading) + '[ \t]*\r?\n(.*?)(?=\n## |\z)')
        if (-not $match.Success) { return $null }
        return $match.Groups[1].Value
    }

    function Get-MermaidBlock {
        param([string]$Text)
        return @([regex]::Matches($Text, '(?ms)^```mermaid[ \t]*\r?$(.*?)^```') | ForEach-Object { $_.Groups[1].Value })
    }

    function Get-MermaidKind {
        param([string]$Block)
        $first = @($Block -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith("%%") })[0]
        return ($first -split "\s+")[0]
    }

    function Find-HumanizerMark {
        # Lines outside fenced code that carry an em dash, an en dash or a bold label.
        param([string]$Text)
        $hits = @()
        $fenced = $false
        $lineNumber = 0
        foreach ($line in ($Text -split "`r?`n")) {
            $lineNumber++
            if ($line.StartsWith('```')) { $fenced = -not $fenced; continue }
            if ($fenced) { continue }
            if ($line.Contains([string][char]0x2014)) { $hits += "em dash:$lineNumber" }
            if ($line.Contains([string][char]0x2013)) { $hits += "en dash:$lineNumber" }
            if ($line -match '^\s*- \*\*') { $hits += "bold bullet:$lineNumber" }
            if ($line -match '^\s*\d+\. \*\*') { $hits += "bold numbered:$lineNumber" }
            if ($line -match '^\s*\| \*\*') { $hits += "bold cell:$lineNumber" }
        }
        return $hits
    }

    function Find-MissingLinkTarget {
        # Relative link and src targets in a markdown text that are not files the repository would track.
        param([string]$Root, [string]$Text)
        $listed = @((Invoke-GitCommand -RepositoryPath $Root -Arguments @("ls-files", "--cached", "--others", "--exclude-standard")).Output)
        $targets = @([regex]::Matches($Text, '\]\(([^)\s]+)\)') | ForEach-Object { $_.Groups[1].Value })
        $targets += @([regex]::Matches($Text, '\b(?:src|href)="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
        $missing = @()
        foreach ($target in ($targets | Select-Object -Unique)) {
            if ($target -match '^(https?:|mailto:|#)') { continue }
            $path = ($target -split "#")[0]
            if (($listed -notcontains $path) -or (-not (Test-Path -LiteralPath (Join-Path $Root $path.Replace("/", "\"))))) { $missing += $path }
        }
        return $missing
    }

    Test-Case -Name "P1 the README header shows the banner, the title, where to start, the issues and the MIT badge" -Check {
        $header = $readme.Substring(0, $readme.IndexOf("`n## "))
        foreach ($token in @('<img src="docs/assets/banner.svg"', '<h1>Tazuna</h1>', '](#getting-started)', '](#usage)', '](https://github.com/AlfredoNeeto/tazuna/issues)')) {
            if (-not $header.Contains($token)) { return "the header has no $token" }
        }
        if ($header -notmatch '\[!\[[^\]]*\]\([^)]*MIT[^)]*\)\]\(LICENSE\)') { return "no badge reading MIT that links LICENSE" }
        return $true
    }

    Test-Case -Name "P2 the README has a Table of contents that links the 9 sections" -Check {
        $toc = @([regex]::Matches($readme, '(?s)<details>\s*<summary>(.*?)</summary>(.*?)</details>') |
            Where-Object { ($_.Groups[1].Value -replace '<[^>]+>', '').Trim() -eq "Table of contents" })
        if ($toc.Count -ne 1) { return "$($toc.Count) <details> with the summary Table of contents" }
        foreach ($section in $readmeSections) {
            $anchor = $section.ToLowerInvariant().Replace(" ", "-")
            if (-not $toc[0].Groups[2].Value.Contains("](#$anchor)")) { return "the table of contents does not link #$anchor" }
        }
        return $true
    }

    Test-Case -Name "P3 the README is under 300 lines with at most 4 diagrams, the first naming the loop in order" -Check {
        $lines = @($readme.TrimEnd() -split "`r?`n").Count
        if ($lines -ge 300) { return "$lines lines" }
        $blocks = @(Get-MermaidBlock -Text $readme)
        if ($blocks.Count -gt 4) { return "$($blocks.Count) mermaid blocks" }
        if ($blocks.Count -eq 0) { return "no mermaid block" }
        $at = -1
        foreach ($step in @("Discovery", "Plan", "Checks", "Build", "Verify", "Code review", "Human review")) {
            $index = $blocks[0].IndexOf($step, $at + 1, [System.StringComparison]::Ordinal)
            if ($index -lt 0) { return "the first diagram does not name '$step' after the previous step" }
            $at = $index
        }
        return $true
    }

    Test-Case -Name "P4 the README draws one UML state machine, activity, deployment and sequence diagram" -Check {
        $blocks = @(Get-MermaidBlock -Text $readme)
        $kinds = @($blocks | ForEach-Object { Get-MermaidKind -Block $_ } | Sort-Object)
        if (($kinds -join ",") -ne "classDiagram,flowchart,sequenceDiagram,stateDiagram-v2") { return ("diagram kinds: " + ($kinds -join ", ")) }

        $activity = @($blocks | Where-Object { (Get-MermaidKind -Block $_) -eq "flowchart" })[0]
        $initial = [regex]::Matches($activity, '\b\w+\(\(\s*\)\)(?!\))').Count
        $final = [regex]::Matches($activity, '\b\w+\(\(\(\s*\)\)\)').Count
        if (($initial -ne 1) -or ($final -ne 1)) { return "activity: $initial initial and $final final nodes, expected 1 and 1" }
        $decisions = @([regex]::Matches($activity, '\b(\w+)\{') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        if ($decisions.Count -eq 0) { return "activity: no decision node" }
        $guarded = 0
        foreach ($edge in [regex]::Matches($activity, '(?m)^\s*(\w+)(?:\{[^}\r\n]*\})?\s*-->\s*(\|[^|\r\n]*\|)?')) {
            if ($decisions -notcontains $edge.Groups[1].Value) { continue }
            if ($edge.Groups[2].Value -notmatch '^\|"\[[^\]]+\]"\|$') { return "activity: an edge leaving $($edge.Groups[1].Value) has no [guard]: '$($edge.Value.Trim())'" }
            $guarded++
        }
        if ($guarded -lt 2) { return "activity: $guarded guarded edges" }

        $deployment = @($blocks | Where-Object { (Get-MermaidKind -Block $_) -eq "classDiagram" })[0]
        if ([regex]::Matches($deployment, '(?m)^\s*namespace\s+\S+\s*\{').Count -lt 2) { return "deployment: fewer than 2 namespace nodes" }
        if (-not $deployment.Contains("<<artifact>>")) { return "deployment: no <<artifact>>" }

        $sequence = @($blocks | Where-Object { (Get-MermaidKind -Block $_) -eq "sequenceDiagram" })[0]
        if (($sequence -notmatch '(?m)^\s*alt\b') -or ($sequence -notmatch '(?m)^\s*end\s*$')) { return "sequence: no alt fragment closed by end" }
        return $true
    }

    Test-Case -Name "P5 the loop marks Verify enforced and the optional steps dashed, and says so under the diagram" -Check {
        $match = [regex]::Match($readme, '(?ms)^```mermaid[ \t]*\r?\n\s*stateDiagram-v2(.*?)^```[ \t]*\r?$')
        if (-not $match.Success) { return "no stateDiagram-v2 block" }
        $state = $match.Groups[1].Value
        $alias = @{}
        foreach ($m in [regex]::Matches($state, '(?m)^\s*state\s+"([^"]+)"\s+as\s+(\w+)')) { $alias[$m.Groups[1].Value] = $m.Groups[2].Value }
        $class = @{}
        foreach ($m in [regex]::Matches($state, '(?m)^\s*class\s+([\w,]+)\s+(\w+)\s*$')) {
            foreach ($id in ($m.Groups[1].Value -split ",")) { $class[$id] = $m.Groups[2].Value }
        }
        foreach ($entry in @(@("Verify", "enforced"), @("Discovery", "optional"), @("Plan", "optional"), @("Checks", "optional"), @("Code review", "optional"))) {
            $id = $entry[0]
            if ($alias.ContainsKey($id)) { $id = $alias[$id] }
            if ($class[$id] -ne $entry[1]) { return "$($entry[0]) has class '$($class[$id])', expected $($entry[1])" }
        }
        if ($state -notmatch '(?m)^\s*classDef\s+optional\s+.*stroke-dasharray') { return "classDef optional has no stroke-dasharray" }
        $after = $readme.Substring($match.Index + $match.Length)
        $line = @($after -split "`r?`n" | Where-Object { $_.Trim() })[0]
        foreach ($token in @("Verify", "enforced", "Stop", "every change", "dashed", "workflow")) {
            if (-not $line.Contains($token)) { return "the line under the loop does not say '$token': $line" }
        }
        return $true
    }

    Test-Case -Name "P6 the README has no em dash, en dash or bold label outside code, and a planted one of each is reported" -Check {
        $hits = @(Find-HumanizerMark -Text $readme)
        if ($hits.Count -gt 0) { return ("marks: " + ($hits -join ", ")) }
        # why: a scan that never reports anything would pass here too; the planted marks prove it can fail.
        $planted = @(("a " + [char]0x2014 + " b"), ("a " + [char]0x2013 + " b"), "- **Label** text", "12. **Label** text", "| **Cell** | x |", '```', "- **inside a fence**", '```') -join "`n"
        $found = @(Find-HumanizerMark -Text $planted)
        if ($found.Count -ne 5) { return ("the planted text was reported as: " + ($found -join ", ")) }
        return $true
    }

    Test-Case -Name "P7 every README image has an English alt text" -Check {
        $images = @([regex]::Matches($readme, '<img\b[^>]*>') | ForEach-Object { $_.Value })
        if ($images.Count -eq 0) { return "no <img>" }
        foreach ($image in $images) {
            $alt = [regex]::Match($image, '\balt="([^"]*)"')
            if ((-not $alt.Success) -or (-not $alt.Groups[1].Value.Trim())) { return "no alt: $image" }
            if ($alt.Groups[1].Value -notmatch '^[\x20-\x7E]+$') { return "alt is not plain ASCII: $($alt.Groups[1].Value)" }
            if ($alt.Groups[1].Value -match '(?i)\b(com|do|da|o|ao|de)\b') { return "alt reads Portuguese: $($alt.Groups[1].Value)" }
        }
        return $true
    }

    Test-Case -Name "P8 every relative link in the README points at a file in the repository, and a planted missing one is reported" -Check {
        $missing = @(Find-MissingLinkTarget -Root $repoRoot -Text $readme)
        if ($missing.Count -gt 0) { return ("not in the repository: " + ($missing -join ", ")) }
        # why: a scan that never reports anything would pass here too; the planted target proves it can fail.
        $planted = @(Find-MissingLinkTarget -Root $repoRoot -Text "[x](docs/planted-missing.md) <img src=`"docs/assets/planted.svg`">")
        if (($planted -join ",") -ne "docs/planted-missing.md,docs/assets/planted.svg") { return ("the planted targets were reported as: " + ($planted -join ", ")) }
        return $true
    }

    Test-Case -Name "P9 LICENSE holds the MIT License for Alfredo Neto, 2026" -Check {
        $path = Join-Path $repoRoot "LICENSE"
        if (-not (Test-Path -LiteralPath $path)) { return "no LICENSE" }
        $text = [System.IO.File]::ReadAllText($path)
        if (@($text -split "`r?`n")[0].Trim() -ne "MIT License") { return "the first line is not MIT License" }
        foreach ($token in @("Copyright (c) 2026 Alfredo Neto", "Permission is hereby granted, free of charge, to any person obtaining a copy")) {
            if (-not $text.Contains($token)) { return "LICENSE does not contain '$token'" }
        }
        return $true
    }

    Test-Case -Name "P10 the License section names MIT for Tazuna and the licence of each bundled piece" -Check {
        $section = Get-ReadmeSection -Heading "License"
        if ($null -eq $section) { return "no '## License' section" }
        $lines = @($section -split "`r?`n")
        foreach ($pair in @(@("MIT", "](LICENSE)"), @("harness-toolkit", "Elastic License 2.0"), @("agent-skills", "CC-BY-4.0"), @("humanizer", "MIT"))) {
            if (@($lines | Where-Object { $_.Contains($pair[0]) -and $_.Contains($pair[1]) }).Count -eq 0) { return "no line with both '$($pair[0])' and '$($pair[1])'" }
        }
        return $true
    }

    Test-Case -Name "P11 the video summary is gone and nothing outside .specs names it" -Check {
        # why: built from parts so this file is not itself a tracked mention.
        $name = "resumo" + "-video"
        $relative = "docs/$name-app-zero-ia-harness-spec-driven.md"
        if (Test-Path -LiteralPath (Join-Path $repoRoot $relative.Replace("/", "\"))) { return "$relative exists" }
        if (@((Invoke-GitCommand -RepositoryPath $repoRoot -Arguments @("ls-files", "--", $relative)).Output).Count -gt 0) { return "$relative is tracked" }
        $grep = Invoke-GitCommand -RepositoryPath $repoRoot -Arguments @("grep", "-l", $name, "--", ".", ":(exclude).specs") -AllowFailure
        if (@($grep.Output).Count -gt 0) { return ("named in: " + ($grep.Output -join ", ")) }
        return $true
    }

    # S5 - smaller surface

    $dispatcher = Join-Path $repoRoot "tazuna.ps1"

    Test-Case -Name "C30 tazuna help lists exactly the six commands, then help and version" -Check {
        $output = (& powershell -NoProfile -ExecutionPolicy Bypass -File $dispatcher | Out-String)
        $section = $output.Substring($output.IndexOf("Commands"))
        $listed = @([regex]::Matches($section, "(?m)^  ([a-z]+)\s{2,}\S") | ForEach-Object { $_.Groups[1].Value })
        $expected = @("setup", "init", "mcp", "doctor", "update", "test", "help", "version")
        if (($listed -join ",") -ne ($expected -join ",")) { return ("listed: " + ($listed -join ", ")) }
        return $true
    }

    Test-Case -Name "C31 each of the 8 removed commands is unknown" -Check {
        foreach ($command in @("install", "skill", "skills", "toolkit", "backup", "worktree", "ado", "adoinit")) {
            $previous = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            $global:LASTEXITCODE = 0
            $output = (& powershell -NoProfile -ExecutionPolicy Bypass -File $dispatcher $command 2>&1 | Out-String)
            $code = $LASTEXITCODE
            $ErrorActionPreference = $previous
            if ($code -ne 1) { return "$command exited $code" }
            if ($output -notmatch "Unknown command") { return "$command did not say Unknown command" }
        }
        return $true
    }

    Test-Case -Name "C32 nothing is tracked under the 4 removed paths" -Check {
        foreach ($path in @("profiles", "third-party", "user/skills/tlc-*", "docs/diagrams")) {
            $listed = (Invoke-GitCommand -RepositoryPath $repoRoot -Arguments @("ls-files", "--", $path)).Output
            if (@($listed | Where-Object { $_ }).Count -gt 0) { return "$path still has tracked files" }
        }
        return $true
    }

    # The rename to Tazuna.

    Test-Case -Name "R1 tazuna help shows the Tazuna <version> banner, the usage, the six commands, help and version" -Check {
        $output = (& powershell -NoProfile -ExecutionPolicy Bypass -File $dispatcher | Out-String)
        if (-not $output.Contains("Tazuna $($manifest.Version)")) { return "no 'Tazuna $($manifest.Version)' banner" }
        if (-not $output.Contains("tazuna <command> [options]")) { return "no usage line 'tazuna <command> [options]'" }
        $section = $output.Substring($output.IndexOf("Commands"))
        $listed = @([regex]::Matches($section, "(?m)^  ([a-z]+)\s{2,}\S") | ForEach-Object { $_.Groups[1].Value })
        if (($listed -join ",") -ne "setup,init,mcp,doctor,update,test,help,version") { return ("listed: " + ($listed -join ", ")) }
        return $true
    }

    Test-Case -Name "R2 bin holds only tazuna.cmd, CRLF, with the four forwarding tokens" -Check {
        $names = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot "bin") -Force | ForEach-Object { $_.Name })
        if (($names -join ",") -ne "tazuna.cmd") { return ("bin holds: " + ($names -join ", ")) }
        $text = [System.IO.File]::ReadAllText((Join-Path $repoRoot "bin\tazuna.cmd"))
        if ($text -match "(?<!`r)`n") { return "a line ends in LF without CR" }
        foreach ($token in @("-NoProfile", "-ExecutionPolicy Bypass", "%~dp0..\tazuna.ps1", "%*")) {
            if (-not $text.Contains($token)) { return "missing $token" }
        }
        return $true
    }

    Test-Case -Name "R3 neither harness.ps1 nor bin\harness.cmd exists or is tracked" -Check {
        foreach ($old in @("harness.ps1", "bin/harness.cmd")) {
            if (Test-Path -LiteralPath (Join-Path $repoRoot $old)) { return "$old exists" }
            $listed = (Invoke-GitCommand -RepositoryPath $repoRoot -Arguments @("ls-files", "--", $old)).Output
            if (@($listed | Where-Object { $_ }).Count -gt 0) { return "$old is tracked" }
        }
        return $true
    }

    Test-Case -Name "R5 tazuna setup -WhatIf forwards -WhatIf and writes nothing" -Check {
        $run = Invoke-WithStubs -Root (New-ScratchRoot) -Script $dispatcher -Arguments @("setup", "-WhatIf")
        if ($run.Code -ne 0) { return "exit $($run.Code): $($run.Output)" }
        if (Test-Path -LiteralPath $run.Config) { return "the configuration directory was created" }
        $installs = @($run.Calls | Where-Object { $_.StartsWith("npm install") -or $_.StartsWith("npx ") -or $_.StartsWith("tlc ") })
        if ($installs.Count -gt 0) { return ("ran: " + ($installs -join "; ")) }
        return $true
    }

    Test-Case -Name "R6 the PATH step reports that tazuna now works from any directory" -Check {
        # why: asserted on the source - the PATH step writes the real user PATH, which a test must not change.
        $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot "install.ps1") -Raw
        if (-not $source.Contains("'tazuna' now works from any directory")) { return "no 'tazuna' now works message" }
        if ($source.Contains("'harness' now works")) { return "the old 'harness' now works message is still there" }
        return $true
    }

    function Invoke-InstallerWithGitStub {
        # hazard: the stub git fails the clone on purpose, so install.ps1 stops before bootstrap runs.
        param([hashtable]$Environment)
        $root = New-ScratchRoot
        $bin = New-StubBin -Root $root
        Set-Content -LiteralPath (Join-Path $bin "git.ps1") -Value ('Add-Content -LiteralPath $env:HARNESS_STUB_LOG -Value ("git " + ($args -join " "))' + "`r`nexit 1")
        return Invoke-WithStubs -Root $root -Script (Join-Path $repoRoot "install.ps1") -Environment $Environment
    }

    Test-Case -Name "R8 install.ps1 clones the tazuna repository into HOME\tazuna by default" -Check {
        $default = Join-Path $HOME "tazuna"
        if (Test-Path -LiteralPath $default) { return "$default exists; refusing to run the installer against it" }
        $run = Invoke-InstallerWithGitStub -Environment @{ TAZUNA_PATH = "" }
        $expected = "git clone https://github.com/AlfredoNeeto/tazuna.git $default"
        if ($run.Calls -notcontains $expected) { return ("calls: " + ($run.Calls -join "; ")) }
        return $true
    }

    Test-Case -Name "R9 install.ps1 clones into TAZUNA_PATH when it is set" -Check {
        $target = Join-Path (New-ScratchRoot) "elsewhere"
        $run = Invoke-InstallerWithGitStub -Environment @{ TAZUNA_PATH = $target }
        $expected = "git clone https://github.com/AlfredoNeeto/tazuna.git $target"
        if ($run.Calls -notcontains $expected) { return ("calls: " + ($run.Calls -join "; ")) }
        return $true
    }

    Test-Case -Name "R10 doctor tells you to run tazuna setup for a missing hook and a missing skill" -Check {
        $run = Get-SetupRun -Key "fresh"
        $path = Join-Path $run.Config "settings.json"
        $original = [System.IO.File]::ReadAllText($path)
        $skill = Join-Path $run.Config "skills\harness-eval"
        $moved = Join-Path $run.Root "moved-harness-eval"

        try {
            Copy-Item -LiteralPath (Join-Path $repoRoot "user\settings.json") -Destination $path -Force
            Move-Item -LiteralPath $skill -Destination $moved
            $doctor = Invoke-WithStubs -Root $run.Root -Script (Join-Path $PSScriptRoot "health-check.ps1")
        }
        finally {
            [System.IO.File]::WriteAllText($path, $original)
            if (Test-Path -LiteralPath $moved) { Move-Item -LiteralPath $moved -Destination $skill }
        }

        if ($doctor.Output -notmatch "no tlc-exec hook[^\r\n]*; run: tazuna setup") { return "the missing hook does not end in 'run: tazuna setup'" }
        if ($doctor.Output -notmatch "skill harness-eval is missing; run: tazuna setup") { return "the missing skill does not end in 'run: tazuna setup'" }
        return $true
    }

    Test-Case -Name "R11 the README header says Tazuna and its PowerShell commands use tazuna" -Check {
        $header = $readme.Substring(0, $readme.IndexOf("`n## "))
        if (-not $header.Contains("<h1>Tazuna</h1>")) { return "no <h1>Tazuna</h1> before the first section" }
        $lines = @()
        foreach ($block in [regex]::Matches($readme, '(?s)```powershell(.*?)```')) {
            $lines += @($block.Groups[1].Value -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith("#") })
        }
        $old = @($lines | Where-Object { $_ -match "^harness(\s|$)" })
        if ($old.Count -gt 0) { return ("still harness: " + ($old -join " | ")) }
        if (@($lines | Where-Object { $_ -match "^tazuna\s" }).Count -eq 0) { return "no fenced command starts with tazuna" }
        return $true
    }

    Test-Case -Name "R12 the README explains the name in one paragraph of About the project, which shows no code" -Check {
        # invariant: this file stays ASCII for Windows PowerShell 5.1, so the kanji is built from code points.
        $kanji = [string][char]0x624B + [char]0x7DB1
        $about = Get-ReadmeSection -Heading "About the project"
        if ($null -eq $about) { return "no '## About the project' section" }
        if ($about -match '(?m)^\s*```') { return "About the project holds a fenced code block" }
        $paragraphs = @($about -split "(`r?`n){2,}")
        $hit = @($paragraphs | Where-Object { $_.Contains($kanji) -and $_.Contains("reins") -and $_.Contains("guides") -and $_.Contains("sensors") })
        if ($hit.Count -eq 0) { return "no paragraph holds the kanji, the reins, guides and sensors together" }
        return $true
    }

    function Find-OldCommandName {
        # why: one scanner for the repository and the planted file, so the negative control exercises the same code.
        param([string]$Root, [string[]]$Relative)
        $pattern = '(?<![\w/.-])harness (setup|init|mcp|doctor|update|test)\b|(?<![\w-])harness\.(cmd|ps1)\b'
        $hits = @()
        foreach ($name in $Relative) {
            $lineNumber = 0
            foreach ($line in (Get-Content -LiteralPath (Join-Path $Root $name) -Encoding UTF8)) {
                $lineNumber++
                if ($line -match $pattern) { $hits += ($name + ":" + $lineNumber) }
            }
        }
        return $hits
    }

    Test-Case -Name "R13 no user-facing file names the old harness command, and a planted one is reported" -Check {
        $text = @(".md", ".ps1", ".psm1", ".json", ".cmd", ".txt", ".yml", ".yaml", ".svg")
        $scanned = @()
        foreach ($file in (Get-RepoFile -Extension $text)) {
            $relative = (Get-CompatibleRelativePath -BasePath $repoRoot -TargetPath $file.FullName).Replace([string][char]92, "/")
            if ($relative -eq "scripts/test-harness.ps1") { continue }
            $top = ($relative -split "/")[0]
            if (($relative -in @("README.md", "install.ps1", "tazuna.ps1")) -or ($top -in @("docs", "mcp", "templates", "user", "scripts"))) {
                $scanned += $relative
            }
        }
        if ($scanned -notcontains "README.md") { return "README.md was not scanned" }
        $hits = @(Find-OldCommandName -Root $repoRoot -Relative $scanned)
        if ($hits.Count -gt 0) { return ("old command in: " + ($hits -join ", ")) }

        # why: a scan that never reports anything would pass here too; the planted offender proves it can fail.
        $scratch = New-ScratchRoot
        Set-Content -LiteralPath (Join-Path $scratch "planted.md") -Value @("first line", "run harness setup again")
        $planted = @(Find-OldCommandName -Root $scratch -Relative @("planted.md"))
        if (($planted -join ",") -ne "planted.md:2") { return ("the planted offender was reported as: " + ($planted -join ", ")) }
        return $true
    }

    Test-Case -Name "R14 the Tech Leads Club names keep the word harness" -Check {
        if ($manifest.ToolkitPackage -ne "@tech-leads-club/harness-toolkit@0.16.2") { return "toolkit package is $($manifest.ToolkitPackage)" }
        if ($manifest.AgentSkills -notcontains "harness-eval") { return "harness-eval is not in the skills list" }
        $bootstrap = Get-Content -LiteralPath (Join-Path $PSScriptRoot "bootstrap.ps1") -Raw
        if (-not $bootstrap.Contains('@("harness", "install")')) { return "bootstrap no longer runs tlc harness install" }
        foreach ($name in @("harness-toolkit", "tlc harness install", "harness-eval", ".tlc/harness/state/")) {
            if (-not $readme.Contains($name)) { return "the README no longer names $name" }
        }
        return $true
    }

    # The mascot, Frenatus. The geometry constants are the ones the consistency
    # checklist in docs/mascot.md fixes: rein lines, seal glass, halo window,
    # eye. They describe the drawing, so a redrawn master changes them here and in
    # docs/mascot.md together.

    $mascotSource = Join-Path $repoRoot "docs\assets\tazuna\src"
    $mascotAssets = Join-Path $repoRoot "docs\assets\tazuna"
    $mascotBible = Join-Path $repoRoot "docs\mascot.md"
    $mascotNames = @("view-front", "expr-success", "expr-error")
    $mascotKept = @($mascotNames + @("icon-32"))
    $mascotDeleted = @("view-side", "view-back", "view-34", "expr-neutral", "expr-happy", "expr-thinking", "expr-focused",
        "expr-confused", "expr-surprised", "pose-standing", "pose-coding", "pose-inspecting", "pose-planning", "pose-debugging", "pose-celebrating")
    $mascotInk = "#0c0809"

    function Read-SpriteGrid {
        # A text sprite: palette lines, "---", then rows. Read here on its own so the
        # test does not trust the renderer's parser.
        param([string]$Path)
        $colours = New-Object System.Collections.Hashtable ([System.StringComparer]::Ordinal)
        $rows = @()
        $inGrid = $false
        foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
            if (-not $inGrid) {
                if ($line -eq "---") { $inGrid = $true }
                elseif ($line -match '^(\S) (#[0-9a-f]{6})$') { $colours[$Matches[1]] = $Matches[2] }
                continue
            }
            if ($line -ne "") { $rows += $line }
        }
        $width = 0
        if ($rows.Count -gt 0) { $width = $rows[0].Length }
        return [PSCustomObject]@{ Colours = $colours; Rows = $rows; Width = $width; Height = $rows.Count }
    }

    function Get-MascotGrid { param([string]$Name) return (Read-SpriteGrid -Path (Join-Path $mascotSource "$Name.txt")) }

    function Get-SpriteHex {
        param($Grid, [int]$X, [int]$Y)
        $ch = [string]$Grid.Rows[$Y][$X]
        if ($ch -eq ".") { return $null }
        return $Grid.Colours[$ch]
    }

    function Get-RelativeLuminance {
        param([string]$Hex)
        $parts = @(1, 3, 5) | ForEach-Object {
            $v = [Convert]::ToInt32($Hex.Substring($_, 2), 16) / 255.0
            if ($v -le 0.03928) { $v / 12.92 } else { [Math]::Pow(($v + 0.055) / 1.055, 2.4) }
        }
        return 0.2126 * $parts[0] + 0.7152 * $parts[1] + 0.0722 * $parts[2]
    }

    function Get-ContrastRatio {
        param([string]$Hex, [string]$Against)
        $a = Get-RelativeLuminance -Hex $Hex
        $b = Get-RelativeLuminance -Hex $Against
        if ($a -lt $b) { $swap = $a; $a = $b; $b = $swap }
        return ($a + 0.05) / ($b + 0.05)
    }

    function New-TestGrid {
        # A sprite grid built in memory, for the planted negative controls.
        param([hashtable]$Colours, [string[]]$Rows)
        return [PSCustomObject]@{ Colours = $Colours; Rows = $Rows; Width = $Rows[0].Length; Height = $Rows.Count }
    }

    function Find-OpenEdge {
        # "x,y" of each pixel that is neither ink nor transparent and faces a transparent pixel.
        param($Grid)
        $hits = @()
        for ($y = 0; $y -lt $Grid.Height; $y++) {
            for ($x = 0; $x -lt $Grid.Width; $x++) {
                $hex = Get-SpriteHex -Grid $Grid -X $x -Y $y
                if (($null -eq $hex) -or ($hex -eq $mascotInk)) { continue }
                foreach ($step in @(@(1, 0), @(-1, 0), @(0, 1), @(0, -1))) {
                    $nx = $x + $step[0]
                    $ny = $y + $step[1]
                    if (($nx -lt 0) -or ($ny -lt 0) -or ($nx -ge $Grid.Width) -or ($ny -ge $Grid.Height)) { continue }
                    if ([string]$Grid.Rows[$ny][$nx] -eq ".") { $hits += "$x,$y"; break }
                }
            }
        }
        return $hits
    }

    function Find-ReinBreak {
        # "x,y" of the first pixel where the straight line from (X0,Y0) to (X1,Y1) is not rein
        # leather or a gold keeper - or, with -Shade, has no leather shade under it; $null if unbroken.
        param($Grid, [int]$X0, [int]$Y0, [int]$X1, [int]$Y1, [switch]$Shade)
        for ($x = $X0; $x -le $X1; $x++) {
            $y = [int][Math]::Round($Y0 + ($Y1 - $Y0) * ($x - $X0) / ($X1 - $X0))
            if (@("#6c4326", "#d9a948") -notcontains (Get-SpriteHex -Grid $Grid -X $x -Y $y)) { return "$x,$y" }
            if ($Shade -and ((Get-SpriteHex -Grid $Grid -X $x -Y ($y + 1)) -ne "#3a2215")) { return "$x,$($y + 1)" }
        }
        return $null
    }

    function Get-SealGlass {
        # The colours of the seal's glass: a Size x Size block from (X,Y).
        param($Grid, [int]$X, [int]$Y, [int]$Size)
        $glass = @()
        for ($dy = 0; $dy -lt $Size; $dy++) {
            for ($dx = 0; $dx -lt $Size; $dx++) { $glass += (Get-SpriteHex -Grid $Grid -X ($X + $dx) -Y ($Y + $dy)) }
        }
        return $glass
    }

    function Get-FigureCount {
        # Figure pixels in columns 0..Width-1 and rows 0..Height-1.
        param($Grid, [int]$Width, [int]$Height)
        $count = 0
        for ($y = 0; $y -lt $Height; $y++) {
            for ($x = 0; $x -lt $Width; $x++) { if ([string]$Grid.Rows[$y][$x] -ne ".") { $count++ } }
        }
        return $count
    }

    function Get-BibleSection {
        # The body of one "## " section of docs/mascot.md, up to the next "## " or the end.
        param([string]$Heading)
        $text = [System.IO.File]::ReadAllText($mascotBible)
        $match = [regex]::Match($text, '(?s)^## ' + [regex]::Escape($Heading) + '\s*$(.*?)(?=^## |\z)', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        if (-not $match.Success) { return $null }
        return $match.Groups[1].Value
    }

    function Get-MascotPalette {
        $section = Get-BibleSection -Heading "Color palette"
        if ($null -eq $section) { return @() }
        return @([regex]::Matches($section, '#[0-9a-f]{6}') | ForEach-Object { $_.Value } | Select-Object -Unique)
    }

    function Copy-MascotScratch {
        # scripts/render-mascot.ps1 and docs/, so the renderer runs with its fixed
        # relative paths and never touches the repository's own assets.
        $root = New-ScratchRoot
        New-Item -ItemType Directory -Path (Join-Path $root "scripts") -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "render-mascot.ps1") -Destination (Join-Path $root "scripts")
        Copy-Item -LiteralPath (Join-Path $repoRoot "docs") -Destination (Join-Path $root "docs") -Recurse
        return $root
    }

    function Get-RenderedOutput {
        param([string]$Root)
        return @(Get-ChildItem -LiteralPath (Join-Path $Root "docs\assets") -Recurse -File |
            Where-Object { ($_.Extension -in @(".svg", ".png")) -and ($_.DirectoryName -notlike "*\src") })
    }

    function Remove-RenderedOutput {
        param([string]$Root)
        foreach ($file in (Get-RenderedOutput -Root $Root)) { Remove-Item -LiteralPath $file.FullName -Force }
    }

    function Invoke-MascotRenderer {
        param([string]$Root, [string[]]$Arguments = @())
        $previous = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $global:LASTEXITCODE = 0
        $output = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\render-mascot.ps1") @Arguments 2>&1 | Out-String)
        $code = $LASTEXITCODE
        $ErrorActionPreference = $previous
        return [PSCustomObject]@{ Code = $code; Output = $output }
    }

    function Compare-RenderedSvg {
        # Names of the .svg files under docs/assets that differ between a render root and the repository.
        param([string]$Root)
        $differs = @()
        foreach ($mine in @(Get-ChildItem -LiteralPath $mascotAssets -Filter *.svg) + @(Get-Item -LiteralPath (Join-Path $repoRoot "docs\assets\banner.svg"))) {
            $theirs = Join-Path $Root (Get-CompatibleRelativePath -BasePath $repoRoot -TargetPath $mine.FullName)
            if (-not (Test-Path -LiteralPath $theirs)) { $differs += ($mine.Name + " (not rendered)"); continue }
            if (-not (Test-FileContentEqual -ReferenceFile $mine.FullName -DifferenceFile $theirs)) { $differs += $mine.Name }
        }
        return $differs
    }

    function Find-MissingAssetPath {
        # Every docs/assets/... path a markdown text references that does not exist under the root.
        param([string]$Root, [string]$Text)
        $missing = @()
        foreach ($hit in @([regex]::Matches($Text, 'docs/assets/[A-Za-z0-9_./-]+') | ForEach-Object { $_.Value } | Select-Object -Unique)) {
            if (-not (Test-Path -LiteralPath (Join-Path $Root $hit.Replace("/", "\")))) { $missing += $hit }
        }
        return $missing
    }

    Test-Case -Name "M3 the renderer rejects a colour outside the palette, names the file and the colour, and writes nothing" -Check {
        $root = Copy-MascotScratch
        Remove-RenderedOutput -Root $root
        $grid = @("Z #ff0000", "K #0c0809", "---") + @(1..64 | ForEach-Object { "Z" * 64 })
        Set-Content -LiteralPath (Join-Path $root "docs\assets\tazuna\src\bad-colour.txt") -Value ($grid -join "`n")
        $run = Invoke-MascotRenderer -Root $root
        if ($run.Code -eq 0) { return "the renderer exited 0" }
        if (-not $run.Output.Contains("bad-colour.txt")) { return "the output does not name bad-colour.txt: $($run.Output)" }
        if (-not $run.Output.Contains("#ff0000")) { return "the output does not name #ff0000" }
        $written = @(Get-RenderedOutput -Root $root)
        if ($written.Count -gt 0) { return ("written despite the rejection: " + (($written | ForEach-Object { $_.Name }) -join ", ")) }
        return $true
    }

    Test-Case -Name "M4 the bible's palette has 12 to 16 colours, among them the ink, the seal's garnet, the gold and the rein leather" -Check {
        $palette = @(Get-MascotPalette)
        if (($palette.Count -lt 12) -or ($palette.Count -gt 16)) { return "$($palette.Count) colours" }
        foreach ($required in @($mascotInk, "#3e0c13", "#d9a948", "#6c4326")) {
            if ($palette -notcontains $required) { return "$required is not in the palette" }
        }
        return $true
    }

    Test-Case -Name "M5 the icon source is 32x32 and every other source is 64x64" -Check {
        $icon = Get-MascotGrid -Name "icon-32"
        if (($icon.Width -ne 32) -or ($icon.Height -ne 32)) { return "icon-32.txt is $($icon.Width)x$($icon.Height)" }
        foreach ($name in $mascotNames) {
            $grid = Get-MascotGrid -Name $name
            if (($grid.Width -ne 64) -or ($grid.Height -ne 64)) { return "$name.txt is $($grid.Width)x$($grid.Height)" }
        }
        return $true
    }

    Test-Case -Name "M6 ink closes every sprite's silhouette: no other colour faces transparency" -Check {
        foreach ($name in $mascotKept) {
            $open = @(Find-OpenEdge -Grid (Get-MascotGrid -Name $name))
            if ($open.Count -gt 0) { return "$name`: $($open.Count) pixel(s) face transparency without ink, the first at $($open[0])" }
        }
        # why: a scan that never reports would pass here too; a gold pixel beside a transparent one must be reported.
        $planted = @(Find-OpenEdge -Grid (New-TestGrid -Colours @{ "K" = $mascotInk; "O" = "#d9a948" } -Rows @("KKK", "KO.", "KKK")))
        if (($planted -join ";") -ne "1,1") { return ("the planted grid was reported as: " + ($planted -join ";")) }
        return $true
    }

    Test-Case -Name "M7 two straight reins run unbroken from the bit to the right edge of every sprite" -Check {
        foreach ($name in $mascotNames) {
            $grid = Get-MascotGrid -Name $name
            foreach ($rein in @(@(24, 47, 63, 35), @(24, 55, 63, 43))) {
                $break = Find-ReinBreak -Grid $grid -X0 $rein[0] -Y0 $rein[1] -X1 $rein[2] -Y1 $rein[3] -Shade
                if ($null -ne $break) { return "$name`: the rein from ($($rein[0]),$($rein[1])) breaks at $break" }
            }
        }
        $icon = Get-MascotGrid -Name "icon-32"
        foreach ($rein in @(@(13, 27, 31, 19), @(12, 31, 31, 24))) {
            $break = Find-ReinBreak -Grid $icon -X0 $rein[0] -Y0 $rein[1] -X1 $rein[2] -Y1 $rein[3]
            if ($null -ne $break) { return "icon-32: the rein from ($($rein[0]),$($rein[1])) breaks at $break" }
        }
        # why: a scan that never finds a break would pass here too; one cut pixel on the upper rein must be found.
        $cut = Get-MascotGrid -Name "view-front"
        $cut.Rows[41] = $cut.Rows[41].Substring(0, 42) + "." + $cut.Rows[41].Substring(43)
        $found = Find-ReinBreak -Grid $cut -X0 24 -Y0 47 -X1 63 -Y1 35 -Shade
        if ($found -ne "42,41") { return "the cut rein was reported as: $found" }
        return $true
    }

    Test-Case -Name "M8 the seal's glass is dark at rest, bone and gold on pass, and cracked with ink on fail" -Check {
        foreach ($entry in @(@("view-front", 22, 30, 3), @("icon-32", 9, 16, 2))) {
            foreach ($hex in (Get-SealGlass -Grid (Get-MascotGrid -Name $entry[0]) -X $entry[1] -Y $entry[2] -Size $entry[3])) {
                if (@("#3e0c13", "#1c1419") -notcontains $hex) { return "$($entry[0]): the seal's glass holds $hex at rest" }
            }
        }
        foreach ($hex in (Get-SealGlass -Grid (Get-MascotGrid -Name "expr-success") -X 22 -Y 30 -Size 3)) {
            if (@("#e2d6bb", "#f9e7a8") -notcontains $hex) { return "expr-success: the seal's glass holds $hex, not bone or gold" }
        }
        $fissure = @(Get-SealGlass -Grid (Get-MascotGrid -Name "expr-error") -X 22 -Y 30 -Size 3 | Where-Object { $_ -eq $mascotInk })
        if ($fissure.Count -lt 2) { return "expr-error: the seal's glass holds $($fissure.Count) ink pixel(s), expected a fissure of at least 2" }
        return $true
    }

    Test-Case -Name "M9 every figure row of every sprite has a pixel at 3:1 contrast on GitHub dark and on white" -Check {
        foreach ($name in $mascotKept) {
            $grid = Get-MascotGrid -Name $name
            foreach ($ground in @("#0d1117", "#ffffff")) {
                for ($y = 0; $y -lt $grid.Height; $y++) {
                    $figure = $false
                    $readable = $false
                    for ($x = 0; $x -lt $grid.Width; $x++) {
                        $hex = Get-SpriteHex -Grid $grid -X $x -Y $y
                        if ($null -eq $hex) { continue }
                        $figure = $true
                        if ((Get-ContrastRatio -Hex $hex -Against $ground) -ge 3.0) { $readable = $true; break }
                    }
                    if ($figure -and (-not $readable)) { return "$name`: row $y has no pixel readable on $ground" }
                }
            }
        }
        return $true
    }

    Test-Case -Name "M10 the resplendor grows on pass and shrinks on fail" -Check {
        # invariant: columns 0-15, rows 0-33 hold only the halo and its rays, in every state.
        $count = @{}
        foreach ($name in $mascotNames) { $count[$name] = Get-FigureCount -Grid (Get-MascotGrid -Name $name) -Width 16 -Height 34 }
        if ($count["expr-success"] -le $count["view-front"]) { return "the halo holds $($count['expr-success']) pixels on pass and $($count['view-front']) at rest" }
        if ($count["expr-error"] -ge $count["view-front"]) { return "the halo holds $($count['expr-error']) pixels on fail and $($count['view-front']) at rest" }
        # why: a count that is always zero or always full would fail above only by luck; a planted grid must count exactly.
        if ((Get-FigureCount -Grid (New-TestGrid -Colours @{ "O" = "#d9a948" } -Rows @("O..", ".O.", "..O")) -Width 2 -Height 2) -ne 2) { return "the planted grid was miscounted" }
        return $true
    }

    Test-Case -Name "M11 only the 4 kept sprites have a source and a rendered svg, and there is no sheet" -Check {
        $expected = @($mascotKept | Sort-Object)
        $svgs = @(Get-ChildItem -LiteralPath $mascotAssets -File | ForEach-Object { $_.Name } | Sort-Object)
        if (($svgs -join ",") -ne (($expected | ForEach-Object { "$_.svg" }) -join ",")) { return ("docs/assets/tazuna holds: " + ($svgs -join ", ")) }
        $folders = @(Get-ChildItem -LiteralPath $mascotAssets -Directory | ForEach-Object { $_.Name })
        if (($folders -join ",") -ne "src") { return ("folders: " + ($folders -join ", ")) }
        $sources = @(Get-ChildItem -LiteralPath $mascotSource -Force | ForEach-Object { $_.Name } | Sort-Object)
        if (($sources -join ",") -ne (($expected | ForEach-Object { "$_.txt" }) -join ",")) { return ("src holds: " + ($sources -join ", ")) }
        if (Test-Path -LiteralPath (Join-Path $mascotAssets "sheet.svg")) { return "sheet.svg exists" }
        return $true
    }

    Test-Case -Name "M12 success and error differ by shape, not only by colour" -Check {
        $success = Get-MascotGrid -Name "expr-success"
        $failure = Get-MascotGrid -Name "expr-error"
        $different = 0
        for ($y = 0; $y -lt 64; $y++) {
            for ($x = 0; $x -lt 64; $x++) {
                if (([string]$success.Rows[$y][$x] -eq ".") -ne ([string]$failure.Rows[$y][$x] -eq ".")) { $different++ }
            }
        }
        if ($different -ge 4) { return $true }
        return "the transparency masks differ in $different pixel(s), expected at least 4"
    }

    Test-Case -Name "M14 the bible has the 14 sections of the brief in order" -Check {
        $expected = @("Project interpretation", "Design objective", "Concept 1", "Concept 2", "Concept 3", "Recommended direction",
            "Character bible", "Harness architecture", "Pixel art specification", "Color palette", "Character sheet", "GitHub usage",
            "Image generation prompt", "Consistency checklist")
        $text = [System.IO.File]::ReadAllText($mascotBible)
        $found = @([regex]::Matches($text, '(?m)^## (.+?)\s*$') | ForEach-Object { $_.Groups[1].Value })
        if (($found -join "|") -ne ($expected -join "|")) { return ("sections: " + ($found -join " | ")) }
        return $true
    }

    Test-Case -Name "M15 the character bible answers the 19 fields in order" -Check {
        $expected = @("Name", "Role", "Concept", "Personality", "Visual identity", "Body proportions", "Head design", "Eyes", "Face",
            "Harness design", "Primary colors", "Secondary colors", "Accent colors", "Mandatory features", "Forbidden features",
            "Pixel-art rules", "Signature silhouette", "Accessories", "Expression system")
        $section = Get-BibleSection -Heading "Character bible"
        if ($null -eq $section) { return "no '## Character bible' section" }
        $found = @([regex]::Matches($section, '(?m)^### (.+?)\s*$') | ForEach-Object { $_.Groups[1].Value })
        if (($found -join "|") -ne ($expected -join "|")) { return ("fields: " + ($found -join " | ")) }
        return $true
    }

    Test-Case -Name "M16 the image-generation prompt names the palette, the grid, the Andalusian horse and the mood-only rule" -Check {
        $prompt = Get-BibleSection -Heading "Image generation prompt"
        if ($null -eq $prompt) { return "no '## Image generation prompt' section" }
        foreach ($colour in @(Get-MascotPalette)) {
            if (-not $prompt.Contains($colour)) { return "the prompt does not name $colour" }
        }
        foreach ($token in @("64x64", "Andalusian", "mood only")) {
            if (-not $prompt.Contains($token)) { return "the prompt does not say '$token'" }
        }
        return $true
    }

    Test-Case -Name "M17 the forbidden features name the Penitent One, Torrent and every agent's logo" -Check {
        $bible = Get-BibleSection -Heading "Character bible"
        $match = [regex]::Match($bible, '(?s)^### Forbidden features\s*$(.*?)(?=^### |\z)', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        if (-not $match.Success) { return "no '### Forbidden features' field" }
        foreach ($name in @("Penitent One", "Torrent", "Anthropic logo", "Cursor logo")) {
            if (-not $match.Groups[1].Value.Contains($name)) { return "$name is not forbidden by name" }
        }
        return $true
    }

    Test-Case -Name "M18 the banner keeps its viewBox, is titled Tazuna and carries the mascot" -Check {
        $banner = [System.IO.File]::ReadAllText((Join-Path $repoRoot "docs\assets\banner.svg"))
        if (-not $banner.Contains('viewBox="0 0 960 300"')) { return "the viewBox is not 0 0 960 300" }
        if ([regex]::Matches($banner, '<text[^>]*>Tazuna</text>').Count -ne 1) { return "no text element reading exactly Tazuna" }
        $group = [regex]::Match($banner, '(?s)<g id="frenatus"[^>]*>(.*?)</g>')
        if (-not $group.Success) { return "no <g id=`"frenatus`">" }
        $runs = [regex]::Matches($group.Groups[1].Value, 'M\d+ \d+h\d+').Count
        if ($runs -lt 200) { return "the mascot group has $runs pixel runs, expected at least 200" }
        return $true
    }

    Test-Case -Name "M19 the README shows the banner in its header and a mascot sprite in its footer" -Check {
        $header = $readme.Substring(0, $readme.IndexOf("`n## "))
        if (-not $header.Contains('<img src="docs/assets/banner.svg"')) { return "no banner image before the first section" }
        $footer = $readme.Substring($readme.LastIndexOf("`n## "))
        $sprite = [regex]::Match($footer, '<img src="docs/assets/tazuna/([a-z0-9-]+)\.svg"')
        if (-not $sprite.Success) { return "no docs/assets/tazuna sprite after the last section" }
        if ($mascotKept -notcontains $sprite.Groups[1].Value) { return "the footer sprite '$($sprite.Groups[1].Value)' is not one of the 4 kept sprites" }
        return $true
    }

    Test-Case -Name "M20 the Acknowledgments credit Frenatus as the original mascot, the Tech Leads Club and the video, and Clawd is gone" -Check {
        $credits = Get-ReadmeSection -Heading "Acknowledgments"
        if ($null -eq $credits) { return "no '## Acknowledgments' section" }
        foreach ($token in @("Frenatus", "the original mascot", "Tech Leads Club", "https://www.youtube.com/watch?v=yKLedmyUDMA")) {
            if (-not $credits.Contains($token)) { return "the Acknowledgments do not contain '$token'" }
        }
        if ($readme -match "(?i)clawd") { return "the README still mentions Clawd" }
        return $true
    }

    Test-Case -Name "M21 the Clawd art is gone from the tree and from git" -Check {
        $old = "docs/assets/clawd-knight.svg"
        if (Test-Path -LiteralPath (Join-Path $repoRoot $old.Replace("/", "\"))) { return "$old exists" }
        $listed = (Invoke-GitCommand -RepositoryPath $repoRoot -Arguments @("ls-files", "--", $old)).Output
        if (@($listed | Where-Object { $_ }).Count -gt 0) { return "$old is tracked" }
        return $true
    }

    Test-Case -Name "M22 the social preview is a 1280x640 PNG" -Check {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $repoRoot "docs\assets\social-preview.png"))
        if (($bytes.Length -lt 24) -or ($bytes[1] -ne 0x50) -or ($bytes[2] -ne 0x4E) -or ($bytes[3] -ne 0x47)) { return "not a PNG" }
        # hazard: -shl on a [byte] stays a byte and wraps, so 0x05 shl 8 reads as 0; widen first.
        $width = ([int]$bytes[16] -shl 24) + ([int]$bytes[17] -shl 16) + ([int]$bytes[18] -shl 8) + [int]$bytes[19]
        $height = ([int]$bytes[20] -shl 24) + ([int]$bytes[21] -shl 16) + ([int]$bytes[22] -shl 8) + [int]$bytes[23]
        if (($width -ne 1280) -or ($height -ne 640)) { return "${width}x${height}" }
        return $true
    }

    Test-Case -Name "M23 every docs/assets path the README references exists, and a planted missing one is reported" -Check {
        $missing = @(Find-MissingAssetPath -Root $repoRoot -Text $readme)
        if ($missing.Count -gt 0) { return ("referenced but missing: " + ($missing -join ", ")) }
        # why: a scanner that never reports anything would pass here too; the planted path proves it can fail.
        $planted = @(Find-MissingAssetPath -Root (New-ScratchRoot) -Text '<img src="docs/assets/planted-missing.svg">')
        if (($planted -join ",") -ne "docs/assets/planted-missing.svg") { return ("the planted path was reported as: " + ($planted -join ", ")) }
        return $true
    }

    Test-Case -Name "M24 a second render with no source change writes nothing" -Check {
        $root = Copy-MascotScratch
        $first = Invoke-MascotRenderer -Root $root
        if ($first.Code -ne 0) { return "the first run exited $($first.Code): $($first.Output)" }
        $before = @{}
        foreach ($file in (Get-RenderedOutput -Root $root)) { $before[$file.FullName] = $file.LastWriteTimeUtc.Ticks }
        $second = Invoke-MascotRenderer -Root $root
        if ($second.Code -ne 0) { return "the second run exited $($second.Code)" }
        if (-not $second.Output.Contains("0 file(s) written")) { return "the second run did not report 0 file(s) written: $($second.Output)" }
        foreach ($file in (Get-RenderedOutput -Root $root)) {
            if ($before[$file.FullName] -ne $file.LastWriteTimeUtc.Ticks) { return "$($file.Name) was rewritten" }
        }
        return $true
    }

    Test-Case -Name "M25 the renderer refuses a ragged row and an undeclared character, names the row, and writes nothing" -Check {
        foreach ($fault in @(@("ragged", 5), @("undeclared", 3))) {
            $root = Copy-MascotScratch
            Remove-RenderedOutput -Root $root
            $path = Join-Path $root "docs\assets\tazuna\src\view-front.txt"
            $lines = [System.IO.File]::ReadAllLines($path)
            $separator = [array]::IndexOf($lines, "---")
            $index = $separator + $fault[1]
            if ($fault[0] -eq "ragged") { $lines[$index] = $lines[$index].Substring(1) }
            else { $lines[$index] = "?" + $lines[$index].Substring(1) }
            [System.IO.File]::WriteAllLines($path, $lines)
            $run = Invoke-MascotRenderer -Root $root
            if ($run.Code -eq 0) { return "$($fault[0]): the renderer exited 0" }
            if (-not $run.Output.Contains("view-front.txt")) { return "$($fault[0]): the output does not name view-front.txt: $($run.Output)" }
            if (-not $run.Output.Contains("row $($fault[1])")) { return "$($fault[0]): the output does not name row $($fault[1]): $($run.Output)" }
            $written = @(Get-RenderedOutput -Root $root)
            if ($written.Count -gt 0) { return ("$($fault[0]): written despite the rejection: " + (($written | ForEach-Object { $_.Name }) -join ", ")) }
        }
        return $true
    }

    Test-Case -Name "M26 render-mascot.ps1 -WhatIf names exactly the 6 files it would write and writes none" -Check {
        $root = Copy-MascotScratch
        Remove-RenderedOutput -Root $root
        $run = Invoke-MascotRenderer -Root $root -Arguments @("-WhatIf")
        if ($run.Code -ne 0) { return "exited $($run.Code): $($run.Output)" }
        $expected = @(@($mascotKept | ForEach-Object { "docs/assets/tazuna/$_.svg" }) + @("docs/assets/banner.svg", "docs/assets/social-preview.png") | Sort-Object)
        # why: the -WhatIf sentence is localised ("on target", "no destino"); the quoted path is not.
        $named = @([regex]::Matches($run.Output, '"(docs/[^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
        if (($named -join ",") -ne ($expected -join ",")) { return ("-WhatIf names: " + ($named -join ", ")) }
        $written = @(Get-RenderedOutput -Root $root)
        if ($written.Count -gt 0) { return ("-WhatIf wrote: " + (($written | ForEach-Object { $_.Name }) -join ", ")) }
        return $true
    }

    Test-Case -Name "M27 the committed svgs match a fresh render, and a changed source is reported by file" -Check {
        $root = Copy-MascotScratch
        Remove-RenderedOutput -Root $root
        $run = Invoke-MascotRenderer -Root $root
        if ($run.Code -ne 0) { return "the renderer exited $($run.Code): $($run.Output)" }
        $differs = @(Compare-RenderedSvg -Root $root)
        if ($differs.Count -gt 0) { return ("out of date with their sources: " + ($differs -join ", ") + " - run .\scripts\render-mascot.ps1") }

        # why: a comparison that never differs would pass here too; one changed pixel proves it can fail.
        $path = Join-Path $root "docs\assets\tazuna\src\view-front.txt"
        $lines = [System.IO.File]::ReadAllLines($path)
        $index = [array]::IndexOf($lines, "---") + 31
        $replacement = "c"
        if ([string]$lines[$index][30] -eq "c") { $replacement = "g" }
        $lines[$index] = $lines[$index].Substring(0, 30) + $replacement + $lines[$index].Substring(31)
        [System.IO.File]::WriteAllLines($path, $lines)
        $run = Invoke-MascotRenderer -Root $root
        if ($run.Code -ne 0) { return "the re-render exited $($run.Code): $($run.Output)" }
        $differs = @(Compare-RenderedSvg -Root $root)
        if ($differs -notcontains "view-front.svg") { return ("the changed source was reported as: " + ($differs -join ", ")) }
        return $true
    }

    Test-Case -Name "M32 a lower-case and an upper-case character keep their own colours in the reader and the render" -Check {
        $root = Copy-MascotScratch
        Remove-RenderedOutput -Root $root
        $path = Join-Path $root "docs\assets\tazuna\src\case-pair.txt"
        $grid = @("A #d9a948", "a #a5752a", "---") + @(1..64 | ForEach-Object { ("Aa" * 32) })
        Set-Content -LiteralPath $path -Value ($grid -join "`n")
        $read = Read-SpriteGrid -Path $path
        $pair = @((Get-SpriteHex -Grid $read -X 0 -Y 0), (Get-SpriteHex -Grid $read -X 1 -Y 0))
        if (($pair -join ",") -ne "#d9a948,#a5752a") { return ("the reader saw A,a as " + ($pair -join ",")) }
        $run = Invoke-MascotRenderer -Root $root
        if ($run.Code -ne 0) { return "the renderer exited $($run.Code): $($run.Output)" }
        $svg = [System.IO.File]::ReadAllText((Join-Path $root "docs\assets\tazuna\case-pair.svg"))
        foreach ($hex in @("#d9a948", "#a5752a")) { if (-not $svg.Contains('fill="' + $hex + '"')) { return "case-pair.svg has no $hex" } }
        return $true
    }

    # Tenebrism and the expression system: most of the figure sinks into shadow,
    # the light comes from the upper left, the eye answers the seal, and the
    # README wears the same palette.

    function Get-DarkShare {
        # The fraction of figure pixels whose relative luminance is at most that of the coat's shadow, #2f2530.
        param($Grid)
        $limit = Get-RelativeLuminance -Hex "#2f2530"
        $figure = 0
        $dark = 0
        for ($y = 0; $y -lt $Grid.Height; $y++) {
            for ($x = 0; $x -lt $Grid.Width; $x++) {
                $hex = Get-SpriteHex -Grid $Grid -X $x -Y $y
                if ($null -eq $hex) { continue }
                $figure++
                if ((Get-RelativeLuminance -Hex $hex) -le $limit) { $dark++ }
            }
        }
        if ($figure -eq 0) { return 0 }
        return $dark / $figure
    }

    function Test-LitFromLeft {
        # $true when the right half's figure pixels are darker on average than the left half's.
        param($Grid)
        $half = [int]($Grid.Width / 2)
        $sum = @(0.0, 0.0)
        $count = @(0, 0)
        for ($y = 0; $y -lt $Grid.Height; $y++) {
            for ($x = 0; $x -lt $Grid.Width; $x++) {
                $hex = Get-SpriteHex -Grid $Grid -X $x -Y $y
                if ($null -eq $hex) { continue }
                $side = [int]($x -ge $half)
                $sum[$side] += Get-RelativeLuminance -Hex $hex
                $count[$side]++
            }
        }
        if (($count[0] -eq 0) -or ($count[1] -eq 0)) { return "one half holds no figure pixel" }
        $left = $sum[0] / $count[0]
        $right = $sum[1] / $count[1]
        if ($right -lt $left) { return $true }
        return ("right half mean luminance {0:N4} is not below the left half's {1:N4}" -f $right, $left)
    }

    Test-Case -Name "M28 the eye's bone catchlight shows at rest and on pass and is gone on fail" -Check {
        foreach ($name in @("view-front", "expr-success")) {
            if ((Get-SpriteHex -Grid (Get-MascotGrid -Name $name) -X 35 -Y 19) -ne "#e2d6bb") { return "$name`: no bone catchlight at (35,19)" }
        }
        $closed = Get-MascotGrid -Name "expr-error"
        for ($y = 17; $y -le 21; $y++) {
            for ($x = 33; $x -le 39; $x++) {
                if ((Get-SpriteHex -Grid $closed -X $x -Y $y) -eq "#e2d6bb") { return "expr-error: the eye still shows a catchlight at ($x,$y)" }
            }
        }
        return $true
    }

    Test-Case -Name "M29 most of every figure sinks into shadow: half of each sprite" -Check {
        foreach ($name in $mascotKept) {
            $share = Get-DarkShare -Grid (Get-MascotGrid -Name $name)
            if ($share -lt 0.5) { return ("{0}: {1:P0} of figure pixels are dark, expected at least 50%" -f $name, $share) }
        }
        # why: a share that is always high would pass here too; an all-gold grid must read as 0.
        $planted = New-TestGrid -Colours @{ "A" = "#d9a948" } -Rows @("AAAA", "AAAA")
        if ((Get-DarkShare -Grid $planted) -ne 0) { return "an all-gold grid was read as dark" }
        return $true
    }

    Test-Case -Name "M30 the hero is lit from the left: its right half is darker than its left" -Check {
        $verdict = Test-LitFromLeft -Grid (Get-MascotGrid -Name "view-front")
        if ($verdict -ne $true) { return "view-front: $verdict" }
        # why: a comparison that never fails would pass here too; a grid lit from the right must be refused.
        $planted = New-TestGrid -Colours @{ "K" = $mascotInk; "W" = "#f9e7a8" } -Rows @("KKWW", "KKWW")
        if ((Test-LitFromLeft -Grid $planted) -eq $true) { return "a grid lit from the right was accepted" }
        return $true
    }

    function Find-MissingStyleWord {
        # "<where>: <word>" for each of tenebrist, baroque and gothic a text does not contain.
        param([string]$Where, [string]$Text)
        $missing = @()
        foreach ($word in @("tenebrist", "baroque", "gothic")) {
            if ($Text.IndexOf($word, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { $missing += "${Where}: $word" }
        }
        return $missing
    }

    Test-Case -Name "M31 the bible names the style tenebrist, baroque and gothic in the identity, the pixel rules and the prompt" -Check {
        $bible = Get-BibleSection -Heading "Character bible"
        if ($null -eq $bible) { return "no '## Character bible' section" }
        $missing = @()
        foreach ($field in @("Visual identity", "Pixel-art rules")) {
            $match = [regex]::Match($bible, '(?s)^### ' + [regex]::Escape($field) + '\s*$(.*?)(?=^### |\z)', [System.Text.RegularExpressions.RegexOptions]::Multiline)
            if (-not $match.Success) { return "no '### $field' field" }
            $missing += @(Find-MissingStyleWord -Where $field -Text $match.Groups[1].Value)
        }
        $prompt = Get-BibleSection -Heading "Image generation prompt"
        if ($null -eq $prompt) { return "no '## Image generation prompt' section" }
        $missing += @(Find-MissingStyleWord -Where "Image generation prompt" -Text $prompt)
        if ($missing.Count -gt 0) { return ("missing: " + ($missing -join ", ")) }
        # why: a scan that never reports would pass here too; a text without gothic must be reported.
        $planted = @(Find-MissingStyleWord -Where "planted" -Text "A tenebrist, baroque samurai.")
        if (($planted -join ",") -ne "planted: gothic") { return ("the planted text was reported as: " + ($planted -join ", ")) }
        return $true
    }

    function Find-SectionWithoutEpigraph {
        # The "## " headings of a markdown text whose first non-blank line is not an italic blockquote "> *...*".
        param([string]$Text)
        $missing = @()
        foreach ($match in [regex]::Matches($Text, '(?ms)^## (.+?)[ \t]*\r?\n(.*?)(?=^## |\z)')) {
            $first = @($match.Groups[2].Value -split "`r?`n" | Where-Object { $_.Trim() })[0]
            if ($first -notmatch '^> \*[^*].*\*\s*$') { $missing += $match.Groups[1].Value }
        }
        return $missing
    }

    Test-Case -Name "P21 each of the 9 README sections opens with an italic blockquote epigraph" -Check {
        $missing = @(Find-SectionWithoutEpigraph -Text $readme)
        if ($missing.Count -gt 0) { return ("no epigraph: " + ($missing -join ", ")) }
        $found = [regex]::Matches($readme, '(?m)^## ').Count
        if ($found -ne $readmeSections.Count) { return "$found sections checked, expected $($readmeSections.Count)" }
        # why: a scan that never reports would pass here too; a plain opening line must be reported.
        $planted = @(Find-SectionWithoutEpigraph -Text "## One`n`n> *A vow.*`n`ntext`n`n## Two`n`nplain text`n")
        if (($planted -join ",") -ne "Two") { return ("the planted text was reported as: " + ($planted -join ", ")) }
        return $true
    }

    function Find-OffPaletteBadge {
        # Each shields.io badge whose colour or labelColor is not in the palette, as "<colour> in <badge path>".
        param([string]$Text, [string[]]$Palette)
        $hits = @()
        foreach ($match in [regex]::Matches($Text, 'img\.shields\.io/badge/([^?)\s]+)\?([^)\s]*)')) {
            $colour = "#" + (($match.Groups[1].Value -split "-")[-1]).ToLowerInvariant()
            $label = [regex]::Match($match.Groups[2].Value, '(?:^|&)labelColor=([0-9a-fA-F]{6})')
            if ($Palette -notcontains $colour) { $hits += "$colour in $($match.Groups[1].Value)" }
            if (-not $label.Success) { $hits += "no labelColor in $($match.Groups[1].Value)" }
            elseif ($Palette -notcontains ("#" + $label.Groups[1].Value.ToLowerInvariant())) { $hits += "labelColor #$($label.Groups[1].Value) in $($match.Groups[1].Value)" }
        }
        return $hits
    }

    Test-Case -Name "P22 every README badge is coloured from the mascot palette" -Check {
        $palette = @(Get-MascotPalette)
        if ([regex]::Matches($readme, 'img\.shields\.io/badge/').Count -lt 4) { return "fewer than 4 badges" }
        $hits = @(Find-OffPaletteBadge -Text $readme -Palette $palette)
        if ($hits.Count -gt 0) { return ("off the palette: " + ($hits -join "; ")) }
        # why: a scan that never reports would pass here too; a red badge must be reported.
        $planted = @(Find-OffPaletteBadge -Text "(https://img.shields.io/badge/x-y-ff0000?style=flat-square&labelColor=0c0809)" -Palette $palette)
        if (($planted -join ",") -ne "#ff0000 in x-y-ff0000") { return ("the planted badge was reported as: " + ($planted -join ", ")) }
        return $true
    }

    function Find-MermaidThemeProblem {
        # Why a mermaid block is not coloured only from the palette, or nothing when it is.
        param([string]$Block, [string[]]$Palette)
        $problems = @()
        $colours = @([regex]::Matches($Block, '#[0-9a-fA-F]{6}\b') | ForEach-Object { $_.Value.ToLowerInvariant() } | Select-Object -Unique)
        if ($colours.Count -eq 0) { $problems += "no colour" }
        foreach ($colour in $colours) { if ($Palette -notcontains $colour) { $problems += "$colour is off the palette" } }
        $kind = Get-MermaidKind -Block $Block
        if ($kind -eq "stateDiagram-v2") {
            $aliases = @{}
            foreach ($m in [regex]::Matches($Block, '(?m)^\s*state\s+"[^"]+"\s+as\s+(\w+)')) { $aliases[$m.Groups[1].Value] = $true }
            $states = @{}
            foreach ($m in [regex]::Matches($Block, '(?m)^\s*(\[\*\]|\w+)\s*-->\s*(\[\*\]|\w+)')) {
                foreach ($id in @($m.Groups[1].Value, $m.Groups[2].Value)) { if ($id -ne "[*]") { $states[$id] = $true } }
            }
            foreach ($id in $aliases.Keys) { $states[$id] = $true }
            $classed = @{}
            foreach ($m in [regex]::Matches($Block, '(?m)^\s*class\s+([\w,]+)\s+\w+\s*$')) { foreach ($id in ($m.Groups[1].Value -split ",")) { $classed[$id] = $true } }
            foreach ($id in ($states.Keys | Sort-Object)) { if (-not $classed.ContainsKey($id)) { $problems += "state $id has no class" } }
        }
        else {
            $first = @($Block -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })[0]
            if ((-not $first.StartsWith("%%{init:")) -or ($first -notmatch "theme['""]?\s*:\s*['""]base['""]")) { $problems += "$kind does not open with a %%{init:} directive setting theme base" }
        }
        return $problems
    }

    Test-Case -Name "P23 the 4 README diagrams are coloured only from the palette, the loop through classDef" -Check {
        $palette = @(Get-MascotPalette)
        $blocks = @(Get-MermaidBlock -Text $readme)
        if ($blocks.Count -ne 4) { return "$($blocks.Count) mermaid blocks" }
        foreach ($block in $blocks) {
            $problems = @(Find-MermaidThemeProblem -Block $block -Palette $palette)
            if ($problems.Count -gt 0) { return ((Get-MermaidKind -Block $block) + ": " + ($problems -join "; ")) }
        }
        # why: a scan that never reports would pass here too; a red flowchart and an unclassed state must be reported.
        $red = @(Find-MermaidThemeProblem -Block "%%{init: {'theme': 'base', 'themeVariables': {'primaryColor': '#ff0000'}}}%%`nflowchart TD`n  a --> b" -Palette $palette)
        if (($red -join ",") -ne "#ff0000 is off the palette") { return ("the planted flowchart was reported as: " + ($red -join ", ")) }
        $state = @(Find-MermaidThemeProblem -Block "stateDiagram-v2`n  A --> B`n  classDef x fill:#0c0809`n  class A x" -Palette $palette)
        if (($state -join ",") -ne "state B has no class") { return ("the planted state diagram was reported as: " + ($state -join ", ")) }
        return $true
    }

    function Find-OffPaletteColour {
        # The hex colours of an SVG text that are not in the palette; "no colour" when it holds none.
        param([string]$Svg, [string[]]$Palette)
        $colours = @([regex]::Matches($Svg, '#[0-9a-fA-F]{6}\b') | ForEach-Object { $_.Value.ToLowerInvariant() } | Select-Object -Unique)
        if ($colours.Count -eq 0) { return @("no colour") }
        return @($colours | Where-Object { $Palette -notcontains $_ })
    }

    Test-Case -Name "P24 the README shows the palette divider at least 3 times" -Check {
        $shown = [regex]::Matches($readme, '<img src="docs/assets/divider\.svg"').Count
        if ($shown -lt 3) { return "the divider is shown $shown time(s), expected at least 3" }
        $palette = @(Get-MascotPalette)
        $svg = [System.IO.File]::ReadAllText((Join-Path $repoRoot "docs\assets\divider.svg"))
        $off = @(Find-OffPaletteColour -Svg $svg -Palette $palette)
        if ($off.Count -gt 0) { return ("divider.svg: " + ($off -join ", ")) }
        # why: a scan that never reports would pass here too; a red rect must be reported.
        $planted = @(Find-OffPaletteColour -Svg '<svg><rect fill="#d9a948"/><rect fill="#FF0000"/></svg>' -Palette $palette)
        if (($planted -join ",") -ne "#ff0000") { return ("the planted svg was reported as: " + ($planted -join ", ")) }
        return $true
    }

    # The animated banner and the smaller mascot set.

    $bannerTagline = "A verification gate for Claude Code and Cursor that works in any stack."

    function Get-SvgGroup {
        # The inner markup of the flat <g id="..."> group, or $null.
        param([string]$Svg, [string]$Id)
        $match = [regex]::Match($Svg, '(?s)<g id="' + [regex]::Escape($Id) + '"[^>]*>(.*?)</g>')
        if (-not $match.Success) { return $null }
        return $match.Groups[1].Value
    }

    function Get-CssRuleBody {
        # The bodies of every CSS rule whose selector list names "#<id>".
        param([string]$Svg, [string]$Id)
        return @([regex]::Matches($Svg, '#' + [regex]::Escape($Id) + '(?![\w-])[^{}<]*\{([^{}]*)\}') | ForEach-Object { $_.Groups[1].Value })
    }

    function Get-CssAnimation {
        # The keyframes name and duration of the first animation declared for "#<id>".
        param([string]$Svg, [string]$Id)
        foreach ($body in (Get-CssRuleBody -Svg $Svg -Id $Id)) {
            $animation = [regex]::Match($body, 'animation:\s*([\w-]+)\s+([\d.]+m?s)\b')
            if ($animation.Success) { return [PSCustomObject]@{ Name = $animation.Groups[1].Value; Duration = $animation.Groups[2].Value } }
        }
        return $null
    }

    function Get-RenderedBanner {
        $root = Copy-MascotScratch
        Remove-RenderedOutput -Root $root
        $run = Invoke-MascotRenderer -Root $root
        if ($run.Code -ne 0) { throw "the renderer exited $($run.Code): $($run.Output)" }
        return [PSCustomObject]@{
            Banner  = [System.IO.File]::ReadAllText((Join-Path $root "docs\assets\banner.svg"))
            Success = [System.IO.File]::ReadAllText((Join-Path $root "docs\assets\tazuna\expr-success.svg"))
        }
    }

    $committedBanner = [System.IO.File]::ReadAllText((Join-Path $repoRoot "docs\assets\banner.svg"))

    Test-Case -Name "P12 the renderer writes a banner whose front and lit frames alternate over a 6s cycle" -Check {
        $render = Get-RenderedBanner
        $front = Get-SvgGroup -Svg $render.Banner -Id "frenatus"
        $lit = Get-SvgGroup -Svg $render.Banner -Id "frenatus-lit"
        if ($null -eq $front) { return "no <g id=`"frenatus`">" }
        if ($null -eq $lit) { return "no <g id=`"frenatus-lit`">" }
        foreach ($frame in @(@("frenatus", $front), @("frenatus-lit", $lit))) {
            $runs = [regex]::Matches($frame[1], 'M\d+ \d+h\d+').Count
            if ($runs -lt 200) { return "$($frame[0]) has $runs pixel runs, expected at least 200" }
        }
        $success = Get-SvgGroup -Svg $render.Success -Id "expr-success"
        if ($lit -ne $success) { return "the lit frame is not the expr-success drawing" }
        $animation = Get-CssAnimation -Svg $render.Banner -Id "frenatus-lit"
        if ($null -eq $animation) { return "#frenatus-lit declares no animation" }
        if ($animation.Duration -ne "6s") { return "#frenatus-lit animates over $($animation.Duration)" }
        if ($render.Banner -notmatch ('@keyframes\s+' + [regex]::Escape($animation.Name) + '\s*\{')) { return "no @keyframes $($animation.Name)" }
        # invariant: 4 s front, 2 s lit, so the lit frame turns on at two thirds of the cycle and the front frame turns off there.
        $rest = Get-CssAnimation -Svg $render.Banner -Id "frenatus"
        if (($null -eq $rest) -or ($rest.Duration -ne "6s")) { return "#frenatus does not alternate on a 6s cycle" }
        foreach ($pair in @(@($animation.Name, "0", "1"), @($rest.Name, "1", "0"))) {
            $frames = [regex]::Match($render.Banner, '@keyframes\s+' + [regex]::Escape($pair[0]) + '\s*\{(.*?\})\s*\}')
            if ($frames.Groups[1].Value -notmatch ('0%, 66\.66% \{ opacity: ' + $pair[1] + '; \} 66\.67%, 100% \{ opacity: ' + $pair[2] + '; \}')) { return "@keyframes $($pair[0]) does not switch from $($pair[1]) to $($pair[2]) at two thirds" }
        }
        return $true
    }

    Test-Case -Name "P13 the banner stops on the front frame when the viewer prefers reduced motion" -Check {
        $render = Get-RenderedBanner
        $media = [regex]::Match($render.Banner, '(?s)@media\s*\(prefers-reduced-motion:\s*reduce\)\s*\{(.*?\})\s*\}')
        if (-not $media.Success) { return "no @media (prefers-reduced-motion: reduce) block" }
        if ($media.Groups[1].Value -notmatch 'animation:\s*none') { return "the reduced-motion block does not set animation: none" }
        foreach ($id in @("frenatus", "frenatus-lit", "verify-lit")) {
            if (@(Get-CssRuleBody -Svg $media.Groups[1].Value -Id $id | Where-Object { $_ -match 'animation:\s*none' }).Count -eq 0) { return "the reduced-motion block does not stop #$id" }
        }
        $resting = @(Get-CssRuleBody -Svg $render.Banner -Id "frenatus-lit" | Where-Object { $_ -match 'opacity:\s*0\s*(;|$)' })
        if ($resting.Count -eq 0) { return "#frenatus-lit does not rest at opacity 0" }
        return $true
    }

    function Find-MiddleMascot {
        # The mascot sprites a markdown text shows between its first "## " section and its last one.
        param([string]$Text)
        $first = $Text.IndexOf("`n## ")
        $last = $Text.LastIndexOf("`n## ")
        if (($first -lt 0) -or ($last -le $first)) { return @() }
        return @([regex]::Matches($Text.Substring($first, $last - $first), 'docs/assets/tazuna/([a-z0-9-]+)\.svg') | ForEach-Object { $_.Groups[1].Value })
    }

    Test-Case -Name "P14 the mascot stays out of the middle of the README: only the banner and the footer show it" -Check {
        $middle = @(Find-MiddleMascot -Text $readme)
        if ($middle.Count -gt 0) { return ("the middle of the README shows: " + ($middle -join ", ")) }
        # why: a scan that never reports would pass here too; a sprite planted between two sections must be reported.
        $planted = @(Find-MiddleMascot -Text "head`n## One`n<img src=`"docs/assets/tazuna/expr-error.svg`">`n## Two`nfoot")
        if (($planted -join ",") -ne "expr-error") { return ("the planted README was reported as: " + ($planted -join ", ")) }
        return $true
    }

    Test-Case -Name "P15 the banner has no Japanese and reads exactly the title, the tagline and the five steps" -Check {
        foreach ($ch in $committedBanner.ToCharArray()) {
            if (([int]$ch -ge 0x3000) -and ([int]$ch -le 0x9FFF)) { return ("the banner holds U+{0:X4}" -f [int]$ch) }
        }
        $texts = @([regex]::Matches($committedBanner, '<text\b[^>]*>([^<]*)</text>') | ForEach-Object { $_.Groups[1].Value })
        $expected = @("Tazuna", $bannerTagline, "Plan", "Checks", "Build", "Verify", "Review")
        if (($texts -join "|") -ne ($expected -join "|")) { return ("texts: " + ($texts -join " | ")) }
        return $true
    }

    Test-Case -Name "P16 the banner is a dark card with a gilded title" -Check {
        $card = [regex]::Match($committedBanner, '<rect\b[^>]*>')
        if ((-not $card.Success) -or ($card.Value -notmatch 'fill="#1c1419"')) { return "the first rect is not filled #1c1419: $($card.Value)" }
        if ($committedBanner -notmatch '<text\b[^>]*fill="#f9e7a8"[^>]*>Tazuna</text>') { return "the title is not filled #f9e7a8" }
        return $true
    }

    Test-Case -Name "P17 the Verify step lights with the seal, on the same keyframes and cycle" -Check {
        $group = [regex]::Match($committedBanner, '(?s)<g\b[^>]*>((?:(?!</?g\b).)*<text\b[^>]*>Verify</text>(?:(?!</?g\b).)*)</g>')
        if (-not $group.Success) { return "no <g> holding the Verify text" }
        $ids = @([regex]::Matches($group.Groups[1].Value, '\bid="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
        $seal = Get-CssAnimation -Svg $committedBanner -Id "frenatus-lit"
        if ($null -eq $seal) { return "#frenatus-lit declares no animation" }
        foreach ($id in $ids) {
            $step = Get-CssAnimation -Svg $committedBanner -Id $id
            if (($null -ne $step) -and ($step.Name -eq $seal.Name) -and ($step.Duration -eq $seal.Duration)) { return $true }
        }
        return ("no element beside Verify animates on " + $seal.Name + " " + $seal.Duration + "; ids: " + ($ids -join ", "))
    }

    Test-Case -Name "P18 the renderer draws both images with the English tagline and holds no Portuguese" -Check {
        $path = Join-Path $PSScriptRoot "render-mascot.ps1"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        foreach ($name in @("Get-SocialPreviewBytes", "Get-BannerSvg")) {
            $function = $ast.Find({ param($node) ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($node.Name -eq $name) }, $true)
            if ($null -eq $function) { return "no function $name" }
            if (-not $function.Extent.Text.Contains($bannerTagline)) { return "$name does not use the tagline" }
        }
        $source = [System.IO.File]::ReadAllText($path)
        foreach ($token in @("Um port", "o de verifica", "qualquer stack", "[char]0xE3", "[char]0xE7")) {
            if ($source.Contains($token)) { return "render-mascot.ps1 still holds '$token'" }
        }
        return $true
    }

    Test-Case -Name "P19 the working specs stay local: nothing under .specs is tracked and .gitignore keeps it out" -Check {
        $tracked = @((Invoke-GitCommand -RepositoryPath $repoRoot -Arguments @("ls-files", "--", ".specs")).Output)
        if ($tracked.Count -gt 0) { return ("tracked under .specs: " + (($tracked | Select-Object -First 5) -join ", ")) }
        $ignored = Invoke-GitCommand -RepositoryPath $repoRoot -Arguments @("check-ignore", "-q", "--no-index", ".specs/features/any/plan.md") -AllowFailure
        if ($ignored.ExitCode -ne 0) { return ".gitignore does not ignore .specs/" }
        return $true
    }

    function Find-MissingBiblePath {
        # Backticked docs/... or .specs/... paths in a markdown text that do not exist under the root.
        param([string]$Root, [string]$Text)
        $missing = @()
        foreach ($hit in @([regex]::Matches($Text, '`((?:docs|\.specs)/[^`<>*]+)`') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)) {
            if (-not (Test-Path -LiteralPath (Join-Path $Root $hit.TrimEnd("/").Replace("/", "\")))) { $missing += $hit }
        }
        return $missing
    }

    Test-Case -Name "P20 the bible names no deleted sprite or sheet, and every path it names exists" -Check {
        $bible = [System.IO.File]::ReadAllText($mascotBible)
        foreach ($name in $mascotDeleted) {
            if ($bible -match ([regex]::Escape($name) + '\.(svg|txt)\b')) { return "the bible names $name as a file" }
        }
        if ($bible.Contains("sheet.svg")) { return "the bible names sheet.svg" }
        # why: .specs/ is gitignored, so a path into it exists here and is missing in every clone.
        if ($bible.Contains(".specs/")) { return "the bible names a path under .specs/, which is not published" }
        $missing = @(Find-MissingBiblePath -Root $repoRoot -Text $bible)
        if ($missing.Count -gt 0) { return ("named but missing: " + ($missing -join ", ")) }
        # why: a scan that never reports anything would pass here too; the planted path proves it can fail.
        $planted = @(Find-MissingBiblePath -Root $repoRoot -Text 'Files: `.specs/features/mascot-hitch/concepts/Z9/`.')
        if (($planted -join ",") -ne ".specs/features/mascot-hitch/concepts/Z9/") { return ("the planted path was reported as: " + ($planted -join ", ")) }
        return $true
    }

    Write-Host ""
    Write-Host "Architecture"
    Write-Host "------------"

    $libDirectory = Join-Path $PSScriptRoot "lib"

    function Get-CalledCommand {
        # why: the syntax tree, not text or tokens - a name in a comment is not a call, and a call
        # inside "$(...)" is one, which the tokenizer reports as a plain string.
        param([string]$Text)
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
        return @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Select-Object -Unique)
    }

    function Get-ImportedLibModule {
        # Library areas a script imports: string constants ending in lib\<Area>.psm1.
        param([string]$Text)
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
        $found = @()
        foreach ($node in @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true))) {
            $match = [regex]::Match($node.Value, '(?:^|[\\/])lib[\\/](\w+)\.psm1$')
            if ($match.Success) { $found += $match.Groups[1].Value }
        }
        return @($found | Select-Object -Unique)
    }

    function Get-LibExport {
        # Area -> exported function names, as PowerShell itself loads each module.
        $exports = @{}
        foreach ($file in @(Get-ChildItem -LiteralPath $libDirectory -Filter *.psm1 -File)) {
            $module = Import-Module $file.FullName -Force -PassThru -DisableNameChecking
            $exports[$file.BaseName] = @($module.ExportedFunctions.Keys)
        }
        return $exports
    }

    function Find-UnusedImport {
        param([string]$Name, [string]$Text, [hashtable]$Exports)
        $called = Get-CalledCommand -Text $Text
        $unused = @()
        foreach ($area in (Get-ImportedLibModule -Text $Text)) {
            if (-not $Exports.ContainsKey($area)) { $unused += "$Name imports lib\$area.psm1, which does not exist"; continue }
            if (-not @($Exports[$area] | Where-Object { $called -contains $_ })) { $unused += "$Name imports $area without calling it" }
        }
        return $unused
    }

    function Find-MissingImport {
        param([string]$Name, [string]$Text, [hashtable]$Exports)
        $called = Get-CalledCommand -Text $Text
        $imported = Get-ImportedLibModule -Text $Text
        $missing = @()
        foreach ($area in $Exports.Keys) {
            if ($imported -contains $area) { continue }
            foreach ($function in @($Exports[$area] | Where-Object { $called -contains $_ })) { $missing += "$Name calls $function without importing $area" }
        }
        return $missing
    }

    function Get-ConsumerScript {
        return @(@(Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.ps1 -File) + @(Get-Item -LiteralPath (Join-Path $repoRoot "tazuna.ps1")))
    }

    Test-Case -Name "A1 scripts/lib holds exactly the eight library modules" -Check {
        $expected = @("Console.psm1", "Cursor.psm1", "Files.psm1", "Git.psm1", "Json.psm1", "Manifest.psm1", "Paths.psm1", "Toolchain.psm1")
        if (-not (Test-Path -LiteralPath $libDirectory)) { return "scripts\lib does not exist" }
        $found = @(Get-ChildItem -LiteralPath $libDirectory -File | ForEach-Object { $_.Name } | Sort-Object)
        if (($found -join ",") -ne ($expected -join ",")) { return ("scripts\lib holds: " + ($found -join ", ")) }
        return $true
    }

    Test-Case -Name "A2 each of the 20 moved functions is exported by exactly one library module" -Check {
        $moved = @("Get-ClaudeConfigDir", "Get-ClaudeStateFile", "Resolve-HarnessPath", "Get-CompatibleRelativePath", "New-HarnessBackupRoot",
            "Get-FileSha256", "Test-FileContentEqual", "Copy-FileIfChanged", "Set-Utf8Content",
            "Test-JsonFile", "Get-JsonCanonicalForm", "Test-JsonContentEqual",
            "Get-StatusColour", "Write-Status", "Write-Section", "Write-Banner",
            "Invoke-GitCommand", "Get-GitRoot", "Get-GitStatusSummary",
            "Get-HarnessManifest")
        if ($moved.Count -ne 20) { return "the test lists $($moved.Count) names" }
        $exports = Get-LibExport
        foreach ($function in $moved) {
            $owners = @($exports.Keys | Where-Object { $exports[$_] -contains $function })
            if ($owners.Count -ne 1) { return "$function is exported by $($owners.Count) module(s): $($owners -join ', ')" }
        }
        return $true
    }

    Test-Case -Name "A3 the old common module is gone and nothing outside .specs names it" -Check {
        # Assembled, so this file does not report itself.
        $name = "Harness" + "Common"
        if (Test-Path -LiteralPath (Join-Path $PSScriptRoot ($name + ".psm1"))) { return "scripts\$name.psm1 still exists" }
        $hits = @()
        foreach ($file in (Get-RepoFile)) {
            $relative = Get-CompatibleRelativePath -BasePath $repoRoot -TargetPath $file.FullName
            if ($relative.StartsWith(".specs\")) { continue }
            if ($file.Name -eq ($name + ".psm1")) { $hits += $relative; continue }
            if ([System.IO.File]::ReadAllText($file.FullName).Contains($name)) { $hits += $relative }
        }
        if ($hits.Count -gt 0) { return ("still named in: " + ($hits -join ", ")) }
        return $true
    }

    Test-Case -Name "A4 no library module imports another module, and a planted import is reported" -Check {
        if (@(Get-CalledCommand -Text "Import-Module (Join-Path `$PSScriptRoot 'Other.psm1')") -notcontains "Import-Module") { return "the scanner missed a planted Import-Module" }
        $offenders = @(Get-ChildItem -LiteralPath $libDirectory -Filter *.psm1 -File | Where-Object {
                (Get-CalledCommand -Text ([System.IO.File]::ReadAllText($_.FullName))) -contains "Import-Module" } | ForEach-Object { $_.Name })
        if ($offenders.Count -gt 0) { return ("imports a module: " + ($offenders -join ", ")) }
        return $true
    }

    Test-Case -Name "A5 only Console.psm1 writes to the host, and a planted Write-Host is reported" -Check {
        if (@(Get-CalledCommand -Text "function Get-X { Write-Host 'x' }") -notcontains "Write-Host") { return "the scanner missed a planted Write-Host" }
        $offenders = @(Get-ChildItem -LiteralPath $libDirectory -Filter *.psm1 -File | Where-Object {
                ($_.Name -ne "Console.psm1") -and ((Get-CalledCommand -Text ([System.IO.File]::ReadAllText($_.FullName))) -contains "Write-Host") } | ForEach-Object { $_.Name })
        if ($offenders.Count -gt 0) { return ("writes to the host: " + ($offenders -join ", ")) }
        return $true
    }

    Test-Case -Name "A6 every library import is used by its script, and a planted unused import is reported" -Check {
        $exports = Get-LibExport
        $planted = @(Find-UnusedImport -Name "planted" -Exports $exports -Text "Import-Module (Join-Path `$PSScriptRoot `"lib\Git.psm1`") -Force`nWrite-Output 1")
        if ($planted -notcontains "planted imports Git without calling it") { return ("the planted unused import was reported as: " + ($planted -join "; ")) }
        $scripts = Get-ConsumerScript
        if ($scripts.Count -ne 11) { return "scanned $($scripts.Count) scripts, expected 11" }
        $violations = @()
        foreach ($script in $scripts) { $violations += @(Find-UnusedImport -Name $script.Name -Exports $exports -Text ([System.IO.File]::ReadAllText($script.FullName))) }
        if ($violations.Count -gt 0) { return ($violations -join "; ") }
        return $true
    }

    Test-Case -Name "A7 every library call has its module imported by the same script, and a planted missing import is reported" -Check {
        $exports = Get-LibExport
        $planted = @(Find-MissingImport -Name "planted" -Exports $exports -Text "Write-Status -Label OK -Detail x")
        if ($planted -notcontains "planted calls Write-Status without importing Console") { return ("the planted missing import was reported as: " + ($planted -join "; ")) }
        $scripts = Get-ConsumerScript
        if ($scripts.Count -ne 11) { return "scanned $($scripts.Count) scripts, expected 11" }
        $violations = @()
        foreach ($script in $scripts) { $violations += @(Find-MissingImport -Name $script.Name -Exports $exports -Text ([System.IO.File]::ReadAllText($script.FullName))) }
        if ($violations.Count -gt 0) { return ($violations -join "; ") }
        return $true
    }

    Test-Case -Name "A8 no template references scripts/lib, and a planted reference is reported" -Check {
        $scan = { param([string]$Text) $Text.Contains("scripts/lib") -or $Text.Contains("scripts\lib") }
        if (-not (& $scan "Import-Module ..\..\scripts\lib\Paths.psm1")) { return "the scanner missed a planted reference" }
        $templates = Join-Path $repoRoot "templates"
        $hits = @(Get-RepoFile | Where-Object { $_.FullName.StartsWith($templates + "\") } |
            Where-Object { & $scan ([System.IO.File]::ReadAllText($_.FullName)) } | ForEach-Object { $_.FullName })
        if ($hits.Count -gt 0) { return ("references scripts/lib: " + ($hits -join ", ")) }
        return $true
    }

    Test-Case -Name "A9 the manifest pins node 24 and Claude Code 2.1.277 as minimums" -Check {
        $pins = Get-HarnessManifest
        if ($pins.MinimumNodeMajor -ne 24) { return "MinimumNodeMajor is '$($pins.MinimumNodeMajor)'" }
        if ($pins.MinimumClaudeVersion -ne "2.1.277") { return "MinimumClaudeVersion is '$($pins.MinimumClaudeVersion)'" }
        return $true
    }

    Test-Case -Name "A10 bootstrap and health-check read the node version only through Get-NodeMajorVersion" -Check {
        foreach ($name in @("bootstrap.ps1", "health-check.ps1")) {
            $text = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot $name))
            if ($text.Contains("node --version")) { return "$name still runs node --version itself" }
            if ((Get-CalledCommand -Text $text) -notcontains "Get-NodeMajorVersion") { return "$name does not call Get-NodeMajorVersion" }
        }
        return $true
    }

    Test-Case -Name "A11 health-check holds no literal Claude Code minimum" -Check {
        if ([System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "health-check.ps1")).Contains("2.1.277")) { return "health-check.ps1 still holds 2.1.277" }
        return $true
    }

    Test-Case -Name "A12 node v23.0.0 stops setup with exit 1 before anything is written" -Check {
        $run = Invoke-WithStubs -Root (New-ScratchRoot) -Script (Join-Path $PSScriptRoot "bootstrap.ps1") -Environment @{ HARNESS_STUB_NODE = "v23.0.0" }
        if ($run.Code -ne 1) { return "exit $($run.Code), expected 1" }
        if ($run.Output -notmatch "node 24\+ required") { return "no 'node 24+ required'" }
        if (Test-Path -LiteralPath $run.Config) { return "the configuration directory was created" }
        return $true
    }

    Test-Case -Name "A14 AGENTS.md states the scripts/lib rules in Where things go" -Check {
        $agents = [System.IO.File]::ReadAllText((Join-Path $repoRoot "AGENTS.md"))
        $section = [regex]::Match($agents, '(?s)## Where things go\s*(.*?)(?=\n## |\z)')
        if (-not $section.Success) { return "no '## Where things go' section" }
        $row = @($section.Groups[1].Value -split "`n" | Where-Object { $_.StartsWith("|") -and $_.Contains("scripts/lib/") }) | Select-Object -First 1
        if (-not $row) { return "no table row names scripts/lib/" }
        foreach ($token in @("Import-Module", "Write-Host", "import")) {
            if (-not $row.Contains($token)) { return "the scripts/lib/ row does not say '$token'" }
        }
        return $true
    }

    # Install experience.

    function Invoke-Tazuna {
        param([string[]]$Arguments = @(), [string]$WorkingDirectory)

        $previous = $ErrorActionPreference
        $previousDirectory = [Environment]::CurrentDirectory

        try {
            $ErrorActionPreference = "Continue"
            if ($WorkingDirectory) { [Environment]::CurrentDirectory = $WorkingDirectory }
            $global:LASTEXITCODE = 0
            $output = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "tazuna.ps1") @Arguments 2>&1 | Out-String)
            $code = $LASTEXITCODE
        }
        finally {
            [Environment]::CurrentDirectory = $previousDirectory
            $ErrorActionPreference = $previous
        }

        return [PSCustomObject]@{ Code = $code; Output = $output }
    }

    function Invoke-HostCapture {
        <#
            Runs a script with the stubs and returns exactly the characters it
            wrote to the host, read back from a UTF-8 file, so no code page sits
            between the script and the assertion.
            why: door 3 is only ever open for a child writing to a console of its
            own; -OwnConsole starts one hidden, and without it stdout is a pipe.
        #>
        param(
            [Parameter(Mandatory = $true)][string]$Root,
            [Parameter(Mandatory = $true)][string]$Script,
            [string[]]$Arguments = @(),
            [hashtable]$Environment = @{},
            [switch]$OwnConsole
        )

        $bin = Join-Path $Root "stub-bin"
        if (-not (Test-Path -LiteralPath $bin)) { $bin = New-StubBin -Root $Root }

        $file = Join-Path $Root ("host-" + [guid]::NewGuid().ToString("N").Substring(0, 8) + ".txt")
        # hazard: a quoted '-WhatIf' binds as a positional string, not as the switch.
        $quoted = @($Arguments | ForEach-Object { if ($_.StartsWith("-")) { $_ } else { "'" + $_ + "'" } }) -join " "
        $command = "& '$Script' $quoted *>&1 | Out-File -LiteralPath '$file' -Encoding utf8; exit `$LASTEXITCODE"

        $variables = @{
            "PATH"              = $bin + ";" + $env:PATH
            "CLAUDE_CONFIG_DIR" = (Join-Path $Root "config")
            "HARNESS_STUB_LOG"  = (Join-Path $Root "calls.log")
        }

        foreach ($key in $Environment.Keys) { $variables[$key] = $Environment[$key] }

        $saved = @{}

        foreach ($key in $variables.Keys) {
            $saved[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
            [Environment]::SetEnvironmentVariable($key, $variables[$key], "Process")
        }

        try {
            if ($OwnConsole) {
                $process = Start-Process -FilePath "powershell" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $command) `
                    -WindowStyle Hidden -Wait -PassThru
                $code = $process.ExitCode
            }
            else {
                $global:LASTEXITCODE = 0
                & powershell -NoProfile -ExecutionPolicy Bypass -Command $command | Out-Null
                $code = $LASTEXITCODE
            }
        }
        finally {
            foreach ($key in $saved.Keys) {
                [Environment]::SetEnvironmentVariable($key, $saved[$key], "Process")
            }
        }

        $text = ""
        if (Test-Path -LiteralPath $file) { $text = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8) }

        return [PSCustomObject]@{ Code = $code; Output = $text }
    }

    function Get-HostText {
        # The characters one call wrote to the host, and the colour of each piece.
        param([scriptblock]$Write)
        $records = @(& $Write 6>&1)
        return [PSCustomObject]@{
            Text    = (@($records | ForEach-Object { $_.MessageData.Message }) -join "")
            Colours = @($records | ForEach-Object { $_.MessageData.ForegroundColor })
        }
    }

    function Use-RichConsole {
        # Sets the Console module's decision for the length of one block, then restores it.
        param([bool]$Rich, [scriptblock]$Block)
        $console = Get-Module Console | Select-Object -First 1
        $was = & $console { $script:Rich }
        & $console { param($value) $script:Rich = $value } $Rich
        try { & $Block }
        finally { & $console { param($value) $script:Rich = $value } $was }
    }

    function Get-NonAscii {
        param([string]$Text)
        return @($Text.ToCharArray() | Where-Object { [int]$_ -ge 128 } | Select-Object -Unique)
    }

    function Get-StepHeader {
        param([string]$Text)
        return @([regex]::Matches($Text, '(?m)^(\[\d+/\d+\] .+?)\s*$') | ForEach-Object { $_.Groups[1].Value })
    }

    $version = (Get-HarnessManifest).Version
    $tick = [string][char]0x2714

    Test-Case -Name "X1 tazuna help init prints the synopsis and an example of init-project.ps1" -Check {
        $run = Invoke-Tazuna -Arguments @("help", "init")
        if ($run.Code -ne 0) { return "exit $($run.Code)" }
        if (-not $run.Output.Contains("Installs a project harness template into an existing repository.")) { return "no synopsis: $($run.Output)" }
        if ($run.Output -notmatch '(?m)^\s+tazuna init\b') { return "no example line with init" }
        return $true
    }

    Test-Case -Name "X2 tazuna init --help and -h print the help and do not run init" -Check {
        $expected = (Invoke-Tazuna -Arguments @("help", "init")).Output
        foreach ($flag in @("--help", "-h")) {
            $empty = New-ScratchRoot
            $run = Invoke-Tazuna -Arguments @("init", $flag) -WorkingDirectory $empty
            if ($run.Code -ne 0) { return "init $flag exited $($run.Code)" }
            if ($run.Output -cne $expected) { return "init $flag differs from help init" }
            $written = @(Get-ChildItem -LiteralPath $empty -Force)
            if ($written.Count -gt 0) { return ("init $flag ran and wrote: " + (($written | ForEach-Object { $_.Name }) -join ", ")) }
        }
        return $true
    }

    Test-Case -Name "X3 tazuna help nosuch says Unknown command and exits 1" -Check {
        $run = Invoke-Tazuna -Arguments @("help", "nosuch")
        if ($run.Code -ne 1) { return "exit $($run.Code), expected 1" }
        if (-not $run.Output.Contains("Unknown command: nosuch")) { return "no 'Unknown command: nosuch'" }
        return $true
    }

    Test-Case -Name "X4 tazuna version, --version and -v print exactly tazuna <manifest version>" -Check {
        foreach ($form in @("version", "--version", "-v")) {
            $run = Invoke-Tazuna -Arguments @($form)
            if ($run.Code -ne 0) { return "$form exited $($run.Code)" }
            if ($run.Output.Trim() -cne "tazuna $version") { return "$form printed '$($run.Output.Trim())'" }
        }
        return $true
    }

    Test-Case -Name "X5 tazuna install is unknown, exits 1 and lists setup" -Check {
        $run = Invoke-Tazuna -Arguments @("install")
        if ($run.Code -ne 1) { return "exit $($run.Code), expected 1" }
        if (-not $run.Output.Contains("Unknown command: install")) { return "no 'Unknown command: install'" }
        if ($run.Output -notmatch '(?m)^Commands: .*\bsetup\b') { return "setup is not listed" }
        return $true
    }

    Test-Case -Name "X6 a command within 2 edits is suggested, and none beyond" -Check {
        foreach ($pair in @(@("doctr", "doctor"), @("setpu", "setup"))) {
            $run = Invoke-Tazuna -Arguments @($pair[0])
            if ($run.Code -ne 1) { return "$($pair[0]) exited $($run.Code)" }
            if (-not $run.Output.Contains("Did you mean 'tazuna $($pair[1])'?")) { return "$($pair[0]) did not suggest $($pair[1]): $($run.Output)" }
        }
        $far = Invoke-Tazuna -Arguments @("nosuch")
        if ($far.Code -ne 1) { return "nosuch exited $($far.Code)" }
        if ($far.Output.Contains("Did you mean")) { return "nosuch got a suggestion" }
        return $true
    }

    Test-Case -Name "X7 tazuna mcp with no arguments prints the catalogue and exits 0" -Check {
        $bare = Invoke-Tazuna -Arguments @("mcp")
        $list = Invoke-Tazuna -Arguments @("mcp", "list")
        if ($bare.Code -ne 0) { return "exit $($bare.Code)" }
        if ($bare.Output -cne $list.Output) { return "differs from mcp list" }
        return $true
    }

    Test-Case -Name "X8 tazuna help lists the six commands, help and version" -Check {
        $output = (Invoke-Tazuna).Output
        $section = $output.Substring($output.IndexOf("Commands"))
        $listed = @([regex]::Matches($section, "(?m)^  ([a-z]+)\s{2,}\S") | ForEach-Object { $_.Groups[1].Value })
        if (($listed -join ",") -ne "setup,init,mcp,doctor,update,test,help,version") { return ("listed: " + ($listed -join ", ")) }
        return $true
    }

    Test-Case -Name "X9 setup prints its title once and none of the four old ones" -Check {
        $run = Get-SetupRun -Key "fresh"
        $count = [regex]::Matches($run.Output, [regex]::Escape("Tazuna $version - setup")).Count
        if ($count -ne 1) { return "the plain title appears $count times" }
        foreach ($old in @("Claude Code harness bootstrap", "Tazuna Installer", "MCP Server Registration", "Tazuna Health Check")) {
            if ($run.Output.Contains($old)) { return "still prints '$old'" }
        }
        $rich = Use-RichConsole -Rich $true -Block { Get-HostText { Write-Banner -Title "Tazuna $version" -Command "setup" } }
        if (-not $rich.Text.Contains("Tazuna $version " + [char]0x00B7 + " setup")) { return "the rich title is: $($rich.Text)" }
        return $true
    }

    Test-Case -Name "X10 install, install-mcp and health-check still print their own title" -Check {
        $root = New-ScratchRoot
        foreach ($pair in @(@("install.ps1", "install"), @("install-mcp.ps1", "mcp"), @("health-check.ps1", "doctor"))) {
            $arguments = @()
            if ($pair[0] -ne "health-check.ps1") { $arguments = @("-WhatIf") }
            $run = Invoke-WithStubs -Root $root -Script (Join-Path $PSScriptRoot $pair[0]) -Arguments $arguments
            if (-not $run.Output.Contains("Tazuna $version - $($pair[1])")) { return "$($pair[0]) has no 'Tazuna $version - $($pair[1])' title" }
        }
        return $true
    }

    Test-Case -Name "X11 setup numbers its steps: 7, 6 with -SkipMcp or -WhatIf, 5 with both" -Check {
        $cases = @(
            @{ Key = "fresh"; Arguments = @(); Steps = @("Prerequisites", "User harness", "harness-toolkit", "agent-skills", "Plugins", "MCP servers", "Verifying") },
            @{ Key = "skipmcp"; Arguments = @("-SkipMcp"); Steps = @("Prerequisites", "User harness", "harness-toolkit", "agent-skills", "Plugins", "Verifying") },
            @{ Key = "whatif"; Arguments = @("-WhatIf"); Steps = @("Prerequisites", "User harness", "harness-toolkit", "agent-skills", "Plugins", "MCP servers") },
            @{ Key = "whatif-skipmcp"; Arguments = @("-WhatIf", "-SkipMcp"); Steps = @("Prerequisites", "User harness", "harness-toolkit", "agent-skills", "Plugins") }
        )
        foreach ($case in $cases) {
            $run = Get-SetupRun -Key $case.Key -Arguments $case.Arguments
            $total = $case.Steps.Count
            $expected = @(for ($i = 0; $i -lt $total; $i++) { "[{0}/{1}] {2}" -f ($i + 1), $total, $case.Steps[$i] })
            $found = Get-StepHeader -Text $run.Output
            if (($found -join "|") -ne ($expected -join "|")) { return ("{0}: {1}" -f $case.Key, ($found -join " | ")) }
        }
        return $true
    }

    Test-Case -Name "X12 setup -WhatIf and init -WhatIf say WHATIF once per action and nothing else" -Check {
        $forbidden = '(?m)^(What if:|(BACKUP|UPDATE|INSTALL|CREATE|RUN)\s)'
        $runs = @()

        $fresh = Get-SetupRun -Key "whatif" -Arguments @("-WhatIf")
        $runs += @{ Name = "setup -WhatIf"; Output = $fresh.Output; Expect = @("would run: npm install -g", "would install CLAUDE\.md", "would register context7", "would create ") }

        $installed = Get-SetupRun -Key "fresh"
        $claudeMd = Join-Path $installed.Config "CLAUDE.md"
        $original = [System.IO.File]::ReadAllText($claudeMd)
        try {
            [System.IO.File]::WriteAllText($claudeMd, $original + "`nlocal edit`n")
            $changed = Invoke-WithStubs -Root $installed.Root -Script (Join-Path $PSScriptRoot "bootstrap.ps1") -Arguments @("-WhatIf")
        }
        finally {
            [System.IO.File]::WriteAllText($claudeMd, $original)
        }
        $runs += @{ Name = "setup -WhatIf over a changed CLAUDE.md"; Output = $changed.Output; Expect = @("would update CLAUDE\.md") }

        $project = Join-Path (New-ScratchRoot) "project"
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        $initFresh = Invoke-WithStubs -Root (Split-Path -Parent $project) -Script (Join-Path $PSScriptRoot "init-project.ps1") -Arguments @("-Path", $project, "-WhatIf")
        if (@(Get-ChildItem -LiteralPath $project -Force).Count -gt 0) { return "init -WhatIf wrote into the project" }
        $runs += @{ Name = "init -WhatIf"; Output = $initFresh.Output; Expect = @("would install AGENTS\.md", "would create \.gitignore") }

        $existing = New-InitProject -Files @{ "notes.txt" = "hello" }
        Add-Content -LiteralPath (Join-Path $existing.Project "AGENTS.md") -Value "local edit"
        $initForce = Invoke-WithStubs -Root (Split-Path -Parent $existing.Project) -Script (Join-Path $PSScriptRoot "init-project.ps1") `
            -Arguments @("-Path", $existing.Project, "-Force", "-NoTrust", "-WhatIf")
        $runs += @{ Name = "init -Force -WhatIf over a changed AGENTS.md"; Output = $initForce.Output; Expect = @("would update AGENTS\.md") }

        foreach ($run in $runs) {
            $bad = @([regex]::Matches($run.Output, $forbidden) | ForEach-Object { $_.Value.Trim() })
            if ($bad.Count -gt 0) { return ("{0} printed: {1}" -f $run.Name, ($bad -join ", ")) }
            foreach ($expected in $run.Expect) {
                if ($run.Output -notmatch ('(?m)^WHATIF\s+' + $expected)) { return ("{0} has no 'WHATIF {1}'" -f $run.Name, $expected) }
            }
        }
        return $true
    }

    Test-Case -Name "X13 a healthy setup ends with Harness installed, the elapsed time and tazuna init" -Check {
        $run = Get-SetupRun -Key "fresh"
        if ($run.Code -ne 0) { return "exit $($run.Code)" }
        $done = [regex]::Match($run.Output, 'Harness installed in \d+s')
        if (-not $done.Success) { return "no 'Harness installed in <n>s'" }
        if ($run.Output.IndexOf("tazuna init", $done.Index) -lt 0) { return "no 'tazuna init' after the summary" }
        return $true
    }

    Test-Case -Name "X14 setup prints the PATH line only when the calling shell lacks bin" -Check {
        $bin = Join-Path $repoRoot "bin"
        $line = '$env:Path += ";' + $bin + '"'

        $without = Invoke-WithStubs -Root (New-ScratchRoot) -Script (Join-Path $PSScriptRoot "bootstrap.ps1") -Arguments @("-SkipMcp") -DropPathContaining @("tazuna.cmd")
        if ($without.Code -ne 0) { return "setup without bin exited $($without.Code)" }
        if (-not $without.Output.Contains($line)) { return "no '$line' when bin is not on PATH" }

        $root = New-ScratchRoot
        $withPath = (Join-Path $root "stub-bin") + ";" + $bin + ";" + $env:PATH
        $with = Invoke-WithStubs -Root $root -Script (Join-Path $PSScriptRoot "bootstrap.ps1") -Arguments @("-SkipMcp") -Environment @{ PATH = $withPath }
        if ($with.Code -ne 0) { return "setup with bin exited $($with.Code)" }
        if ($with.Output.Contains('$env:Path +=')) { return "the PATH line printed while bin was on PATH" }
        return $true
    }

    Test-Case -Name "X15 a step that throws prints one FAIL line and the way out, exit 1" -Check {
        $run = Get-SetupRun -Key "npm-fails" -Environment @{ HARNESS_STUB_FAIL = "npm" }
        if ($run.Code -ne 1) { return "exit $($run.Code), expected 1" }
        if ($run.Output -notmatch "(?m)^FAIL\s+harness-toolkit failed: 'npm install -g") { return "no 'FAIL harness-toolkit failed:' line: $($run.Output)" }
        if (-not $run.Output.Contains("Fix it and run tazuna setup again - finished steps are safe to repeat")) { return "no way out" }
        foreach ($record in @("CategoryInfo", "FullyQualifiedErrorId", "At line:")) {
            if ($run.Output.Contains($record)) { return "printed a PowerShell error record ($record)" }
        }
        return $true
    }

    Test-Case -Name "X16 a failing health check ends setup with health check FAILED, exit 1" -Check {
        $run = Get-SetupRun -Key "no-hook" -Environment @{ HARNESS_STUB_FAIL = "tlc-hook" } -Arguments @("-SkipMcp")
        if ($run.Code -ne 1) { return "exit $($run.Code), expected 1" }
        if (@(Get-StepHeader -Text $run.Output)[-1] -ne "[6/6] Verifying") { return "the health check did not run" }
        if ($run.Output -notmatch 'FAIL\s+Setup finished in \d+s, but the health check FAILED') { return "no 'health check FAILED' summary" }
        return $true
    }

    $labels = @{
        Green  = @("OK", "PASS", "PRESENT", "UNCHANGED", "DONE")
        Red    = @("FAIL", "MISSING", "ERROR", "DENIED")
        Yellow = @("WARN", "WHATIF", "SKIP", "PENDING")
        Other  = @("INSTALL", "CREATE", "UPDATE", "ADDED", "BACKUP", "MCP", "PLUGIN", "TOOL", "PROFILE", "POINTER", "KEPT")
    }
    $glyphs = @{ Green = [char]0x2714; Red = [char]0x2716; Yellow = [char]0x25B2; Other = [char]0x25CF }

    Test-Case -Name "X17 rich output puts one glyph per meaning before the unchanged line" -Check {
        $wrong = Use-RichConsole -Rich $true -Block {
            foreach ($meaning in $labels.Keys) {
                foreach ($label in $labels[$meaning]) {
                    $line = (Get-HostText { Write-Status -Label $label -Detail "detail" }).Text
                    $expected = [string]$glyphs[$meaning] + " " + ("{0,-9} {1}" -f $label, "detail")
                    if ($line -cne $expected) { "$label wrote '$line'" }
                }
            }
        }
        if (@($wrong).Count -gt 0) { return (@($wrong) -join "; ") }

        $run = Invoke-HostCapture -Root (New-ScratchRoot) -Script (Join-Path $PSScriptRoot "bootstrap.ps1") -Arguments @("-WhatIf") `
            -Environment @{ WT_SESSION = "self-test"; TAZUNA_PLAIN = $null } -OwnConsole
        if ($run.Code -ne 0) { return "rich setup exited $($run.Code): $($run.Output)" }
        if (-not $run.Output.Contains($tick)) { return "no $tick in a Windows Terminal console" }
        if (-not $run.Output.Contains("Tazuna $version " + [char]0x00B7 + " setup")) { return "no rich title" }
        return $true
    }

    Test-Case -Name "X18 plain output is the plain line and ASCII only" -Check {
        $wrong = Use-RichConsole -Rich $false -Block {
            foreach ($label in ($labels.Values | ForEach-Object { $_ })) {
                $line = (Get-HostText { Write-Status -Label $label -Detail "detail" }).Text
                if ($line -cne ("{0,-9} {1}" -f $label, "detail")) { "$label wrote '$line'" }
            }
        }
        if (@($wrong).Count -gt 0) { return (@($wrong) -join "; ") }

        $piped = Invoke-HostCapture -Root (New-ScratchRoot) -Script (Join-Path $PSScriptRoot "bootstrap.ps1") -Environment @{ WT_SESSION = "self-test"; TAZUNA_PLAIN = $null }
        if ($piped.Code -ne 0) { return "piped setup exited $($piped.Code): $($piped.Output)" }
        $found = Get-NonAscii -Text $piped.Output
        if ($found.Count -gt 0) { return ("piped setup wrote: " + ($found -join " ")) }

        $conhost = Invoke-HostCapture -Root (New-ScratchRoot) -Script (Join-Path $PSScriptRoot "bootstrap.ps1") -Arguments @("-WhatIf") `
            -Environment @{ WT_SESSION = $null; TAZUNA_PLAIN = $null } -OwnConsole
        if ($conhost.Code -ne 0) { return "setup outside Windows Terminal exited $($conhost.Code)" }
        if (-not $conhost.Output.Contains("Tazuna $version - setup")) { return "the console run printed nothing recognisable" }
        $found = Get-NonAscii -Text $conhost.Output
        if ($found.Count -gt 0) { return ("setup outside Windows Terminal wrote: " + ($found -join " ")) }
        return $true
    }

    Test-Case -Name "X19 TAZUNA_PLAIN=1 keeps Windows Terminal output ASCII" -Check {
        $run = Invoke-HostCapture -Root (New-ScratchRoot) -Script (Join-Path $PSScriptRoot "bootstrap.ps1") -Arguments @("-WhatIf") `
            -Environment @{ WT_SESSION = "self-test"; TAZUNA_PLAIN = "1" } -OwnConsole
        if ($run.Code -ne 0) { return "exit $($run.Code)" }
        if (-not $run.Output.Contains("Tazuna $version - setup")) { return "the console run printed nothing recognisable" }
        $found = Get-NonAscii -Text $run.Output
        if ($found.Count -gt 0) { return ("wrote: " + ($found -join " ")) }
        return $true
    }

    Test-Case -Name "X20 NO_COLOR removes colour in rich and plain output" -Check {
        # why: Windows PowerShell 5.1 records the host's current colour on an uncoloured Write-Host, so "no colour" is that colour.
        $plain = @((Get-HostText { Write-Host "x" }).Colours)[0]
        $saved = $env:NO_COLOR
        try {
            $env:NO_COLOR = "1"
            foreach ($rich in @($true, $false)) {
                $coloured = Use-RichConsole -Rich $rich -Block {
                    foreach ($write in @(
                            { Write-Status -Label "OK" -Detail "x" },
                            { Write-Section -Title "Section" },
                            { Write-Banner -Title "Tazuna" -Command "setup" -Subtitle "sub" })) {
                        $colours = @((Get-HostText $write).Colours | Where-Object { $_ -ne $plain })
                        if ($colours.Count -gt 0) { "$write -> $($colours -join ',')" }
                    }
                }
                if (@($coloured).Count -gt 0) { return ("rich=$rich coloured: " + (@($coloured) -join "; ")) }
            }

            # The commands themselves, in process: a listing written around Console would keep its colour.
            $tazuna = Join-Path $repoRoot "tazuna.ps1"
            foreach ($arguments in @(@(), @("help", "init"), @("mcp"))) {
                $colours = @((Get-HostText { & $tazuna @arguments }).Colours | Where-Object { $_ -ne $plain })
                if ($colours.Count -gt 0) { return ("tazuna $($arguments -join ' ') coloured under NO_COLOR: " + ($colours -join ",")) }
            }

            $env:NO_COLOR = $null
            $ok = Use-RichConsole -Rich $false -Block { Get-HostText { Write-Status -Label "OK" -Detail "x" } }
            if (@($ok.Colours) -notcontains [ConsoleColor]::Green) { return "OK is not green without NO_COLOR" }
            if (@((Get-HostText { & $tazuna }).Colours) -notcontains [ConsoleColor]::Cyan) { return "tazuna lists no Cyan name without NO_COLOR" }
        }
        finally {
            $env:NO_COLOR = $saved
        }
        return $true
    }

    Test-Case -Name "X22 the README Commands table has tazuna help <command> and tazuna version" -Check {
        $text = [System.IO.File]::ReadAllText((Join-Path $repoRoot "README.md"))
        $section = [regex]::Match($text, '(?s)\n### Commands[ \t]*\r?\n(.*?)(?=\n##)')
        if (-not $section.Success) { return "no '### Commands' subsection" }
        $first = @($section.Groups[1].Value -split "`n" | Where-Object { $_.StartsWith("|") } | ForEach-Object { ($_ -split "\|")[1].Trim() })
        foreach ($row in @('`tazuna help <command>`', '`tazuna version`')) {
            if ($first -notcontains $row) { return "no row $row" }
        }
        return $true
    }

    Test-Case -Name "tazuna help and the README name exactly the commands whose scripts support -WhatIf" -Check {
        $source = [System.IO.File]::ReadAllText((Join-Path $repoRoot "tazuna.ps1"))
        $expected = @()
        foreach ($entry in [regex]::Matches($source, '"(\w+)"\s*=\s*@\{\s*Script\s*=\s*"([\w-]+\.ps1)"')) {
            # why: the syntax tree, so both [CmdletBinding(SupportsShouldProcess)] and "= $true" count.
            $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $entry.Groups[2].Value), [ref]$null, [ref]$null)
            if ($null -eq $ast.ParamBlock) { continue }
            $binding = @($ast.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq "CmdletBinding" })
            $flag = @($binding | ForEach-Object { $_.NamedArguments } | Where-Object { $_.ArgumentName -eq "SupportsShouldProcess" })
            if (($flag.Count -gt 0) -and ($flag[0].ExpressionOmitted -or ($flag[0].Argument.Extent.Text -eq '$true'))) { $expected += $entry.Groups[1].Value }
        }
        if ($expected.Count -eq 0) { return "no dispatched script supports -WhatIf; the scan found nothing" }
        $expected = @($expected | Sort-Object)

        $help = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "tazuna.ps1") | Out-String) -replace '\s+', ' '
        $said = [regex]::Match($help, 'untouched\. ([a-z, ]+?) accept -WhatIf')
        if (-not $said.Success) { return "tazuna help does not say which commands accept -WhatIf" }
        $named = @($said.Groups[1].Value -split ',\s*|\s+and\s+' | Where-Object { $_ } | Sort-Object)
        if (($named -join ",") -ne ($expected -join ",")) { return ("tazuna help names " + ($named -join ", ") + "; the scripts support " + ($expected -join ", ")) }

        $text = [System.IO.File]::ReadAllText((Join-Path $repoRoot "README.md"))
        $said = [regex]::Match($text, '((?:`[a-z]+`(?:, | and ))+`[a-z]+`) accept `-WhatIf`')
        if (-not $said.Success) { return "the README does not say which commands accept -WhatIf" }
        $named = @([regex]::Matches($said.Groups[1].Value, '`([a-z]+)`') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
        if (($named -join ",") -ne ($expected -join ",")) { return ("the README names " + ($named -join ", ") + "; the scripts support " + ($expected -join ", ")) }
        return $true
    }

    Test-Case -Name "X23 the README Installation subsection shows the one-line install and the env:Path line" -Check {
        $text = [System.IO.File]::ReadAllText((Join-Path $repoRoot "README.md"))
        $section = [regex]::Match($text, '(?s)\n### Installation[ \t]*\r?\n(.*?)(?=\n##)')
        if (-not $section.Success) { return "no '### Installation' subsection" }
        foreach ($line in @('git clone https://github.com/AlfredoNeeto/tazuna.git "$HOME\tazuna"; & "$HOME\tazuna\bin\tazuna.cmd" setup', '$env:Path += ";$HOME\tazuna\bin"')) {
            if (-not $section.Groups[1].Value.Contains($line)) { return "Installation does not show: $line" }
        }
        return $true
    }

    # The release version, read from the manifest.

    $releaseVersion = (Get-HarnessManifest).Version

    Test-Case -Name "V1 the changelog's newest section is the manifest version, and it has no internal migration notes" -Check {
        $changelog = [System.IO.File]::ReadAllText((Join-Path $repoRoot "CHANGELOG.md"))
        $sections = @([regex]::Matches($changelog, '(?m)^## (.+?)\s*$') | ForEach-Object { $_.Groups[1].Value })
        if ((@($sections).Count -eq 0) -or ($sections[0] -ne $releaseVersion)) { return ("sections: " + ($sections -join " | ") + "; manifest: $releaseVersion") }
        foreach ($token in @("harness update", "1.x", "2.0.0", "3.0.0")) {
            if ($changelog.Contains($token)) { return "the changelog still holds '$token'" }
        }
        return $true
    }

    Test-Case -Name "V2 the README version badge shows the manifest version" -Check {
        $header = $readme.Substring(0, $readme.IndexOf("`n## "))
        if (-not $header.Contains("img.shields.io/badge/version-$releaseVersion-")) { return "no version-$releaseVersion badge in the README header" }
        return $true
    }

    Test-Case -Name "V3 user/CLAUDE.md is neutral: no fixed language and no first person" -Check {
        $text = [System.IO.File]::ReadAllText((Join-Path $repoRoot "user\CLAUDE.md"))
        if (-not $text.Contains("Respond in the language the user writes in")) { return "no 'Respond in the language the user writes in'" }
        foreach ($token in @("Portuguese", "Personal")) {
            if ($text.Contains($token)) { return "user/CLAUDE.md still holds '$token'" }
        }
        if ($text -match '(?i)\bmy\b') { return "user/CLAUDE.md still speaks in the first person: '$($Matches[0])'" }
        return $true
    }

    Test-Case -Name "V4 user/settings.json sets no language and keeps the owner's chosen defaults" -Check {
        $settings = Get-Content -LiteralPath (Join-Path $repoRoot "user\settings.json") -Raw | ConvertFrom-Json
        if ($settings.PSObject.Properties.Name -contains "language") { return "settings.json still sets language" }
        if ($settings.disableClaudeAiConnectors -ne $true) { return "disableClaudeAiConnectors is not true" }
        if ($settings.syncClaudeAiSkills -ne $false) { return "syncClaudeAiSkills is not false" }
        if ($settings.syncClaudeAiPlugins -ne $false) { return "syncClaudeAiPlugins is not false" }
        $plugins = @($settings.enabledPlugins.PSObject.Properties.Name)
        if (@($plugins | Where-Object { $_ -like "ponytail*" }).Count -eq 0) { return ("enabledPlugins: " + ($plugins -join ", ")) }
        return $true
    }

    Test-Case -Name "V6 the README says what setup replaces and names ponytail and the connectors setting" -Check {
        $sentences = @($readme -split '(?<=\.)\s+')
        $warned = @($sentences | Where-Object { $_.Contains("replaces") -and $_.Contains("~/.claude/settings.json") -and $_.Contains("~/.claude/CLAUDE.md") -and $_.Contains("backup") })
        if ($warned.Count -eq 0) { return "no sentence says setup replaces ~/.claude/settings.json and ~/.claude/CLAUDE.md and keeps a backup" }
        $license = Get-ReadmeSection -Heading "License"
        if (($null -eq $license) -or (-not $license.Contains("ponytail"))) { return "the License section does not name ponytail" }
        if (-not $readme.Contains("disableClaudeAiConnectors")) { return "the README does not name disableClaudeAiConnectors" }
        return $true
    }

    Test-Case -Name "V7 bin/tazuna.cmd is checked out with CRLF in every clone" -Check {
        $attributes = [System.IO.File]::ReadAllText((Join-Path $repoRoot ".gitattributes"))
        if ($attributes -notmatch '(?m)^\*\.cmd text eol=crlf\s*$') { return ".gitattributes has no '*.cmd text eol=crlf' line" }
        $eol = (Invoke-GitCommand -RepositoryPath $repoRoot -Arguments @("check-attr", "eol", "--", "bin/tazuna.cmd")).Text.Trim()
        if ($eol -ne "bin/tazuna.cmd: eol: crlf") { return "git check-attr says: $eol" }
        return $true
    }

    function Find-OwnerPhrase {
        # "<file>: <phrase>" for each file that states something true only on the owner's machine.
        param([string]$Root, [string[]]$Relative)
        $hits = @()
        foreach ($name in $Relative) {
            $text = [System.IO.File]::ReadAllText((Join-Path $Root $name))
            foreach ($phrase in @("this machine", "never been pushed", "this company", "which is private", "the company's")) {
                if ($text.IndexOf($phrase, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $hits += "${name}: $phrase" }
            }
        }
        return $hits
    }

    Test-Case -Name "V8 no published file states what is true only on the owner's machine, and a planted one is reported" -Check {
        $files = @("install.ps1", "AGENTS.md", ".gitignore", "mcp\rules\azure-devops.md", "scripts\configure-ado.ps1", "docs\mcp.md", "mcp\catalog.json")
        $hits = @(Find-OwnerPhrase -Root $repoRoot -Relative $files)
        if ($hits.Count -gt 0) { return ($hits -join "; ") }
        # why: a scan that never reports anything would pass here too; the planted phrase proves it can fail.
        $scratchRoot = New-ScratchRoot
        Set-Content -LiteralPath (Join-Path $scratchRoot "planted.md") -Value "Measured against This Company's server."
        $planted = @(Find-OwnerPhrase -Root $scratchRoot -Relative @("planted.md"))
        if (($planted -join ",") -ne "planted.md: this company") { return ("the planted phrase was reported as: " + ($planted -join ", ")) }
        return $true
    }

    Test-Case -Name "V9 doctor and setup point the user at tazuna commands, not repository scripts" -Check {
        $doctor = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "health-check.ps1"))
        if ($doctor.Contains('.\scripts\install')) { return "health-check.ps1 still suggests a .\scripts\install path" }
        $setup = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "bootstrap.ps1"))
        if (-not $setup.Contains("tazuna mcp list")) { return "bootstrap.ps1 does not suggest tazuna mcp list" }
        if ($setup.Contains("tazuna mcp add azure-devops")) { return "bootstrap.ps1 still suggests tazuna mcp add azure-devops" }
        return $true
    }

    Test-Case -Name "V10 .gitignore lists the backup once and anchors the Claude state directories at the root" -Check {
        $lines = @([System.IO.File]::ReadAllLines((Join-Path $repoRoot ".gitignore")) | ForEach-Object { $_.Trim() })
        $backups = @($lines | Where-Object { $_ -eq ".harness-backup/" })
        if ($backups.Count -ne 1) { return ".harness-backup/ is listed $($backups.Count) times" }
        foreach ($directory in @("projects", "sessions", "session-env", "shell-snapshots", "statsig", "telemetry", "todos", "cache", "paste-cache", "downloads", "backups", "plugins")) {
            if ($lines -contains "$directory/") { return "$directory/ is not anchored" }
            if ($lines -notcontains "/$directory/") { return "/$directory/ is missing" }
        }
        return $true
    }

    Test-Case -Name "V11 SECURITY.md says how to report a vulnerability privately" -Check {
        $path = Join-Path $repoRoot "SECURITY.md"
        if (-not (Test-Path -LiteralPath $path)) { return "no SECURITY.md" }
        if (-not ([System.IO.File]::ReadAllText($path)).Contains("https://github.com/AlfredoNeeto/tazuna/security/advisories/new")) { return "SECURITY.md does not link private vulnerability reporting" }
        return $true
    }

    Test-Case -Name "V12 the README prerequisites list python3" -Check {
        $section = [regex]::Match($readme, '(?s)\n### Prerequisites[ \t]*\r?\n(.*?)(?=\n##)')
        if (-not $section.Success) { return "no '### Prerequisites' subsection" }
        $first = @($section.Groups[1].Value -split "`n" | Where-Object { $_.StartsWith("|") } | ForEach-Object { ($_ -split "\|")[1].Trim() })
        if ($first -notcontains '`python3`') { return ("first cells: " + ($first -join ", ")) }
        return $true
    }

    Write-Host ""
    Write-Host "Cursor"
    Write-Host "------"

    # Payloads follow cursor.com/docs/agent/hooks. No case here runs inside Cursor itself.
    function New-CursorProject {
        $project = Join-Path (New-ScratchRoot) "project"
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $project "Program.cs") -Value "class P { }" -NoNewline
        Set-Content -LiteralPath (Join-Path $project "App.csproj") -Value "<Project />" -NoNewline
        & (Join-Path $PSScriptRoot "init-project.ps1") -Type dotnet -Path $project -NoTrust 6>$null | Out-Null
        return $project
    }

    function Invoke-ProjectHook {
        <# Runs a project hook from the project directory, as Cursor does; returns code, stdout and stderr. #>
        param([string]$Project, [string]$Hook, [hashtable]$Payload, [switch]$Cursor)

        $script = Join-Path $Project (Join-Path ".claude" (Join-Path "hooks" $Hook))
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
        if ($Cursor) { $arguments += " -Agent cursor" }

        $files = @{ In = [System.IO.Path]::GetTempFileName(); Out = [System.IO.Path]::GetTempFileName(); Err = [System.IO.Path]::GetTempFileName() }
        [System.IO.File]::WriteAllText($files.In, ($Payload | ConvertTo-Json -Compress))

        # why: Start-Process, not a pipe - PowerShell 5.1 prefixes captured native stderr with "powershell.exe :".
        $process = Start-Process -FilePath "powershell" -ArgumentList $arguments -WorkingDirectory $Project -NoNewWindow -Wait -PassThru `
            -RedirectStandardInput $files.In -RedirectStandardOutput $files.Out -RedirectStandardError $files.Err

        $result = [PSCustomObject]@{
            Code = $process.ExitCode
            Out  = [System.IO.File]::ReadAllText($files.Out).Trim()
            Err  = [System.IO.File]::ReadAllText($files.Err)
        }

        foreach ($file in $files.Values) { Remove-Item -LiteralPath $file -Force }
        return $result
    }

    function Get-CursorStop {
        param([int]$LoopCount)
        return @{ hook_event_name = "stop"; status = "completed"; loop_count = $LoopCount; conversation_id = "c1"; workspace_roots = @("/c:/scratch") }
    }

    function Set-PassingVerification {
        param([string]$Project)
        Import-Module (Join-Path $Project ".claude\scripts\VerifyCommon.psm1") -Force
        [PSCustomObject]@{ fingerprint = (Get-SourceFingerprint -ProjectRoot $Project); testsRan = $true; completedAt = (Get-Date).ToString("o") } |
            ConvertTo-Json | Set-Content -LiteralPath (Get-VerificationStateFile -ProjectRoot $Project) -Encoding UTF8
    }

    $script:cursorGate = $null

    function Get-CursorGateProject {
        # A project whose session baseline was recorded through the Cursor path, then changed.
        if (-not $script:cursorGate) {
            $project = New-CursorProject
            $start = @{ hook_event_name = "sessionStart"; session_id = "s1"; conversation_id = "c1"; workspace_roots = @("/c:/scratch") }
            $script:cursorBaseline = Invoke-ProjectHook -Project $project -Hook "record-session-baseline.ps1" -Payload $start -Cursor
            Add-Content -LiteralPath (Join-Path $project "Program.cs") -Value "// changed"
            $script:cursorGate = $project
        }
        return $script:cursorGate
    }

    Test-Case -Name "U1 the Cursor stop hook follows up once with verify.ps1 on an unverified change, exit 0" -Check {
        $project = Get-CursorGateProject
        $run = Invoke-ProjectHook -Project $project -Hook "require-verification.ps1" -Payload (Get-CursorStop -LoopCount 0) -Cursor
        if ($run.Code -ne 0) { return "exit $($run.Code), expected 0" }
        $answer = $run.Out | ConvertFrom-Json
        if (-not ([string]$answer.followup_message).Contains('.\.claude\scripts\verify.ps1')) { return "followup_message does not name verify.ps1: $($run.Out)" }
        return $true
    }

    Test-Case -Name "U2 the Cursor stop hook stays silent once loop_count is 1, exit 0" -Check {
        $project = Get-CursorGateProject
        $run = Invoke-ProjectHook -Project $project -Hook "require-verification.ps1" -Payload (Get-CursorStop -LoopCount 1) -Cursor
        if ($run.Code -ne 0) { return "exit $($run.Code), expected 0" }
        if ($run.Out) { return "stdout: $($run.Out)" }
        return $true
    }

    Test-Case -Name "U3 the Cursor stop hook stays silent after a passing verification, exit 0" -Check {
        $project = New-CursorProject
        $start = @{ hook_event_name = "sessionStart"; session_id = "s1"; workspace_roots = @("/c:/scratch") }
        $null = Invoke-ProjectHook -Project $project -Hook "record-session-baseline.ps1" -Payload $start -Cursor
        Add-Content -LiteralPath (Join-Path $project "Program.cs") -Value "// changed"
        Set-PassingVerification -Project $project
        $run = Invoke-ProjectHook -Project $project -Hook "require-verification.ps1" -Payload (Get-CursorStop -LoopCount 0) -Cursor
        if ($run.Code -ne 0) { return "exit $($run.Code), expected 0" }
        if ($run.Out) { return "stdout: $($run.Out)" }
        return $true
    }

    Test-Case -Name "U4 a hook given a Cursor payload without -Agent cursor steps aside: no output, exit 0" -Check {
        $project = Get-CursorGateProject
        $repoFor = New-CursorProject
        $null = Invoke-GitCommand -RepositoryPath $repoFor -Arguments @("init", "-q") -AllowFailure
        Set-Content -LiteralPath (Join-Path $repoFor ".env") -Value "TOKEN=abc" -NoNewline
        $null = Invoke-GitCommand -RepositoryPath $repoFor -Arguments @("add", "-f", ".env") -AllowFailure

        # invariant: each payload also carries the Claude fields that would make the unguarded hook act, so the pass proves the guard.
        $stop = Get-CursorStop -LoopCount 0
        $stop["cwd"] = $project
        $cases = @(
            @{ Project = $project; Hook = "require-verification.ps1"; Payload = $stop },
            @{ Project = $repoFor; Hook = "block-secret-commit.ps1"; Payload = @{ hook_event_name = "beforeShellExecution"; command = "git commit -m x"; tool_input = @{ command = "git commit -m x" }; cwd = $repoFor; workspace_roots = @("/c:/scratch") } },
            @{ Project = $repoFor; Hook = "record-session-baseline.ps1"; Payload = @{ hook_event_name = "sessionStart"; session_id = "s1"; cwd = $repoFor; workspace_roots = @("/c:/scratch") } }
        )

        foreach ($case in $cases) {
            $run = Invoke-ProjectHook -Project $case.Project -Hook $case.Hook -Payload $case.Payload
            if (($run.Code -ne 0) -or $run.Out -or $run.Err) { return "$($case.Hook): exit $($run.Code), stdout '$($run.Out)', stderr '$($run.Err)'" }
        }

        if (Test-Path -LiteralPath (Join-Path $repoFor ".claude\state\session-baseline.json")) { return "the unguarded baseline hook wrote a baseline" }
        return $true
    }

    Test-Case -Name "U5 the Cursor sessionStart hook records the baseline in the current directory" -Check {
        $project = Get-CursorGateProject
        if ($script:cursorBaseline.Code -ne 0) { return "exit $($script:cursorBaseline.Code)" }
        $file = Join-Path $project ".claude\state\session-baseline.json"
        if (-not (Test-Path -LiteralPath $file)) { return "no $file" }
        $baseline = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
        if ((-not $baseline.fingerprint) -or (-not $baseline.recordedAt)) { return "baseline lacks fingerprint or recordedAt" }
        return $true
    }

    $script:cursorSecretRepo = $null

    function Get-CursorSecretRepo {
        if (-not $script:cursorSecretRepo) {
            $repo = New-CursorProject
            $null = Invoke-GitCommand -RepositoryPath $repo -Arguments @("init", "-q") -AllowFailure
            Set-Content -LiteralPath (Join-Path $repo ".env") -Value "TOKEN=abc" -NoNewline
            $null = Invoke-GitCommand -RepositoryPath $repo -Arguments @("add", "-f", ".env") -AllowFailure
            $script:cursorSecretRepo = $repo
        }
        return $script:cursorSecretRepo
    }

    Test-Case -Name "U6 the Cursor shell hook denies a commit staging .env: exit 2, permission deny naming .env" -Check {
        $repo = Get-CursorSecretRepo
        $payload = @{ hook_event_name = "beforeShellExecution"; command = "git commit -m x"; cwd = $repo; workspace_roots = @("/c:/scratch") }
        $run = Invoke-ProjectHook -Project $repo -Hook "block-secret-commit.ps1" -Payload $payload -Cursor
        if ($run.Code -ne 2) { return "exit $($run.Code), expected 2" }
        $answer = $run.Out | ConvertFrom-Json
        if ($answer.permission -ne "deny") { return "permission '$($answer.permission)'" }
        if (-not ([string]$answer.agent_message).Contains(".env")) { return "agent_message does not name .env: $($run.Out)" }
        return $true
    }

    Test-Case -Name "U7 the Cursor shell hook allows a command that is not a commit with exactly {`"permission`":`"allow`"}" -Check {
        $repo = Get-CursorSecretRepo
        $payload = @{ hook_event_name = "beforeShellExecution"; command = "dotnet build"; cwd = $repo; workspace_roots = @("/c:/scratch") }
        $run = Invoke-ProjectHook -Project $repo -Hook "block-secret-commit.ps1" -Payload $payload -Cursor
        if ($run.Code -ne 0) { return "exit $($run.Code), expected 0" }
        if ($run.Out -ne '{"permission":"allow"}') { return "stdout '$($run.Out)'" }
        return $true
    }

    Test-Case -Name "U8 with a Claude payload and no -Agent the hooks keep their exit codes and stderr" -Check {
        $repo = Get-CursorSecretRepo
        $commit = Invoke-ProjectHook -Project $repo -Hook "block-secret-commit.ps1" -Payload @{ tool_name = "Bash"; cwd = $repo; tool_input = @{ command = "git commit -m x" } }
        if (($commit.Code -ne 2) -or $commit.Out -or (-not $commit.Err.StartsWith("Refusing this commit: it would commit secrets."))) { return "secret hook: exit $($commit.Code), stdout '$($commit.Out)', stderr '$($commit.Err)'" }

        $project = Get-CursorGateProject
        $stop = Invoke-ProjectHook -Project $project -Hook "require-verification.ps1" -Payload @{ cwd = $project }
        # why: the fixture never recorded a verification, so the gate's "not been run" reason is the one it must give.
        if (($stop.Code -ne 2) -or $stop.Out -or (-not $stop.Err.StartsWith("This session changed code, and the verification has not been run."))) {
            return "stop hook: exit $($stop.Code), stdout '$($stop.Out)', stderr '$($stop.Err)'"
        }

        $active = Invoke-ProjectHook -Project $project -Hook "require-verification.ps1" -Payload @{ cwd = $project; stop_hook_active = $true }
        if (($active.Code -ne 0) -or $active.Out -or $active.Err) { return "stop_hook_active: exit $($active.Code)" }
        return $true
    }

    function Split-Frontmatter {
        param([string]$Text)
        $match = [regex]::Match($Text.Replace("`r`n", "`n"), '(?s)\A---\n(.*?)\n---\n(.*)\z')
        if (-not $match.Success) { return $null }
        return [PSCustomObject]@{ Head = $match.Groups[1].Value; Body = $match.Groups[2].Value }
    }

    Test-Case -Name "U9 init installs .cursor/hooks.json with sessionStart, beforeShellExecution and stop, each -Agent cursor" -Check {
        $project = New-CursorProject
        $path = Join-Path $project ".cursor\hooks.json"
        if (-not (Test-Path -LiteralPath $path)) { return "no .cursor\hooks.json" }
        $config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($config.version -ne 1) { return "version '$($config.version)'" }
        $events = @($config.hooks.PSObject.Properties.Name | Sort-Object)
        if (($events -join ",") -ne "beforeShellExecution,sessionStart,stop") { return "events: $($events -join ',')" }
        $expected = @{ sessionStart = "record-session-baseline.ps1"; beforeShellExecution = "block-secret-commit.ps1"; stop = "require-verification.ps1" }
        foreach ($event in $expected.Keys) {
            $entries = @($config.hooks.$event)
            if ($entries.Count -ne 1) { return "$event has $($entries.Count) entries" }
            $command = [string]$entries[0].command
            if ((-not $command.Contains(".claude/hooks/" + $expected[$event])) -or (-not $command.EndsWith(" -Agent cursor"))) { return "$event command: $command" }
        }
        return $true
    }

    Test-Case -Name "U10 init converts each .claude/rules/*.md into a .cursor/rules/*.mdc with the same globs and body" -Check {
        $project = New-CursorProject
        foreach ($name in @("csharp", "testing")) {
            $source = Split-Frontmatter -Text ([System.IO.File]::ReadAllText((Join-Path $repoRoot "templates\dotnet\dot-claude\rules\$name.md")))
            $target = Join-Path $project ".cursor\rules\$name.mdc"
            if (-not (Test-Path -LiteralPath $target)) { return "no .cursor\rules\$name.mdc" }
            $rule = Split-Frontmatter -Text ([System.IO.File]::ReadAllText($target))
            if (-not $rule) { return "$name.mdc has no frontmatter" }
            $globs = @([regex]::Matches($source.Head, '(?m)^\s*-\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }) -join ","
            if ($rule.Head -notmatch ('(?m)^globs: ' + [regex]::Escape($globs) + '$')) { return "$name.mdc globs, expected '$globs': $($rule.Head)" }
            if ($rule.Head -notmatch '(?m)^alwaysApply: false$') { return "$name.mdc is not alwaysApply: false" }
            if ($rule.Body -ne $source.Body) { return "$name.mdc body differs from the source" }
        }
        return $true
    }

    Test-Case -Name "U11 init keeps a differing .cursor/hooks.json and says SKIP; -Force replaces it with a backup" -Check {
        $project = New-CursorProject
        $path = Join-Path $project ".cursor\hooks.json"
        $mine = '{"version":1,"hooks":{}}'
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [System.IO.File]::WriteAllText($path, $mine)

        $output = (& (Join-Path $PSScriptRoot "init-project.ps1") -Type dotnet -Path $project -NoTrust 6>&1 | Out-String)
        if ([System.IO.File]::ReadAllText($path) -ne $mine) { return "init replaced a differing .cursor\hooks.json without -Force" }
        if ($output -notmatch 'SKIP\s+\.cursor\\hooks\.json') { return "no SKIP line for .cursor\hooks.json" }

        & (Join-Path $PSScriptRoot "init-project.ps1") -Type dotnet -Path $project -NoTrust -Force 6>$null | Out-Null
        if ([System.IO.File]::ReadAllText($path) -eq $mine) { return "-Force did not replace it" }
        $backup = @(Get-ChildItem -LiteralPath (Join-Path $project ".harness-backup") -Recurse -File -Filter hooks.json | Where-Object { $_.FullName -like "*\.cursor\hooks.json" })
        if ($backup.Count -ne 1) { return "expected 1 backup of .cursor\hooks.json, found $($backup.Count)" }
        if ([System.IO.File]::ReadAllText($backup[0].FullName) -ne $mine) { return "the backup does not hold the replaced content" }
        return $true
    }

    Test-Case -Name "U12 init -WhatIf writes no .cursor directory" -Check {
        $project = Join-Path (New-ScratchRoot) "dry"
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $project "App.csproj") -Value "<Project />" -NoNewline
        & (Join-Path $PSScriptRoot "init-project.ps1") -Type dotnet -Path $project -NoTrust -WhatIf 6>$null | Out-Null
        if (Test-Path -LiteralPath (Join-Path $project ".cursor")) { return ".cursor exists after -WhatIf" }
        return $true
    }

    # hazard: dropping every PATH entry that holds a claude binary also drops whatever else lives there;
    # the stubs cover node, npm, npx and tlc, which is all setup calls.
    $noClaudePath = @("claude.exe", "claude.cmd", "claude.ps1", "claude")

    function Invoke-CursorScript {
        <# Runs a harness script against a scratch root with, optionally, no Claude Code and a Cursor directory. #>
        param([string]$Root, [string]$Script, [switch]$NoClaude, [string[]]$Arguments = @())

        if (-not (Test-Path -LiteralPath (Join-Path $Root "stub-bin"))) {
            $bin = New-StubBin -Root $Root
            if ($NoClaude) { Remove-Item -LiteralPath (Join-Path $bin "claude.ps1") -Force }
        }

        $drop = @()
        if ($NoClaude) { $drop = $noClaudePath }
        return (Invoke-WithStubs -Root $Root -Script (Join-Path $PSScriptRoot $Script) -Arguments $Arguments -DropPathContaining $drop)
    }

    function Get-CursorSetupRun {
        # One stubbed setup per scenario; $Cursor creates the Cursor directory first, optionally with an mcp.json.
        param([string]$Key, [switch]$NoClaude, [switch]$Cursor, [string]$McpJson)

        if (-not $script:setupRuns.ContainsKey($Key)) {
            $root = New-ScratchRoot
            if ($Cursor) {
                New-Item -ItemType Directory -Path (Join-Path $root "cursor") -Force | Out-Null
                if ($McpJson) { [System.IO.File]::WriteAllText((Join-Path $root "cursor\mcp.json"), $McpJson) }
            }
            $run = Invoke-CursorScript -Root $root -Script "bootstrap.ps1" -NoClaude:$NoClaude
            $run | Add-Member -NotePropertyName Root -NotePropertyValue $root
            $run | Add-Member -NotePropertyName Cursor -NotePropertyValue (Join-Path $root "cursor")
            $script:setupRuns[$Key] = $run
        }

        return $script:setupRuns[$Key]
    }

    $cursorMcp = '{"mcpServers":{"mine":{"command":"mine-server","args":["--x"]},"playwright":{"command":"my-playwright"}}}'

    Test-Case -Name "U13 setup with neither Claude Code nor Cursor refuses before writing anything, exit 1" -Check {
        $run = Get-CursorSetupRun -Key "no-agent" -NoClaude
        if ($run.Code -ne 1) { return "exit $($run.Code), expected 1: $($run.Output)" }
        if (-not $run.Output.Contains("Cannot continue: neither Claude Code nor Cursor is installed.")) { return "message missing: $($run.Output)" }
        foreach ($written in @($run.Config, $run.Cursor)) {
            if (Test-Path -LiteralPath $written) { return "$written was created" }
        }
        return $true
    }

    Test-Case -Name "U14 setup on a Cursor-only machine exits 0, calls no claude and writes nothing into the Claude config" -Check {
        $run = Get-CursorSetupRun -Key "cursor-only" -NoClaude -Cursor -McpJson $cursorMcp
        if ($run.Code -ne 0) { return "exit $($run.Code): $($run.Output)" }
        $claudeCalls = @($run.Calls | Where-Object { $_.StartsWith("claude ") })
        if ($claudeCalls.Count -gt 0) { return ("claude was called: " + ($claudeCalls -join "; ")) }
        foreach ($name in @("settings.json", "CLAUDE.md")) {
            if (Test-Path -LiteralPath (Join-Path $run.Config $name)) { return "$name written into the Claude config" }
        }
        return $true
    }

    Test-Case -Name "U15 install.ps1 copies user skills and agents into the Cursor directory, idempotent, backing up a changed file" -Check {
        $root = New-ScratchRoot
        $cursor = Join-Path $root "cursor"
        New-Item -ItemType Directory -Path $cursor -Force | Out-Null

        $first = Invoke-CursorScript -Root $root -Script "install.ps1"
        if ($first.Code -ne 0) { return "install exited $($first.Code): $($first.Output)" }

        $userRoot = Join-Path $repoRoot "user"
        $owned = @(Get-ChildItem -LiteralPath (Join-Path $userRoot "skills"), (Join-Path $userRoot "agents") -File -Recurse)
        foreach ($file in $owned) {
            $relative = Get-CompatibleRelativePath -BasePath $userRoot -TargetPath $file.FullName
            $installed = Join-Path $cursor $relative
            if (-not (Test-Path -LiteralPath $installed)) { return "$relative not in the Cursor directory" }
            if (-not (Test-FileContentEqual -ReferenceFile $file.FullName -DifferenceFile $installed)) { return "$relative differs" }
        }

        $second = Invoke-CursorScript -Root $root -Script "install.ps1"
        foreach ($file in $owned) {
            $relative = Get-CompatibleRelativePath -BasePath $userRoot -TargetPath $file.FullName
            if ($second.Output -notmatch ("UNCHANGED\s+.*" + [regex]::Escape($relative))) { return "second run did not report $relative UNCHANGED" }
        }

        $changed = Join-Path $cursor "skills\review-change\SKILL.md"
        [System.IO.File]::WriteAllText($changed, "mine")
        $null = Invoke-CursorScript -Root $root -Script "install.ps1"
        $backup = @(Get-ChildItem -LiteralPath (Join-Path $cursor ".harness-backup") -Recurse -File -Filter SKILL.md -ErrorAction SilentlyContinue |
            Where-Object { [System.IO.File]::ReadAllText($_.FullName) -eq "mine" })
        if ($backup.Count -ne 1) { return "expected one backup holding the changed file, found $($backup.Count)" }
        if (-not (Test-FileContentEqual -ReferenceFile (Join-Path $userRoot "skills\review-change\SKILL.md") -DifferenceFile $changed)) { return "the changed file was not replaced" }
        return $true
    }

    Test-Case -Name "U16 setup with Claude Code and Cursor installs the six skills for Cursor with -a cursor -g" -Check {
        $run = Get-CursorSetupRun -Key "both" -Cursor
        if ($run.Code -ne 0) { return "exit $($run.Code): $($run.Output)" }
        $literal = "npx -y @tech-leads-club/agent-skills@1.4.10 install -s tlc-discover tlc-spec-lean tlc-spec-driven tlc-plan tlc-implement harness-eval -a cursor -g"
        if ($run.Calls -notcontains $literal) { return "no call: $literal" }
        if ($run.Calls -notcontains $skillsLine) { return "the Claude Code install is gone: $skillsLine" }
        return $true
    }

    Test-Case -Name "U17 install.ps1 writes the global Cursor rule tazuna.mdc, alwaysApply true, body equal to user/CLAUDE.md" -Check {
        $run = Get-CursorSetupRun -Key "cursor-only" -NoClaude -Cursor -McpJson $cursorMcp
        $path = Join-Path $run.Cursor "rules\tazuna.mdc"
        if (-not (Test-Path -LiteralPath $path)) { return "no rules\tazuna.mdc" }
        $rule = Split-Frontmatter -Text ([System.IO.File]::ReadAllText($path))
        if (-not $rule) { return "tazuna.mdc has no frontmatter" }
        if ($rule.Head -notmatch '(?m)^alwaysApply: true$') { return "not alwaysApply: true: $($rule.Head)" }
        $expected = [System.IO.File]::ReadAllText((Join-Path $repoRoot "user\CLAUDE.md")).Replace("`r`n", "`n")
        if ($rule.Body -ne $expected) { return "the body differs from user/CLAUDE.md" }
        return $true
    }

    Test-Case -Name "U18 setup adds the missing user MCP servers to the Cursor mcp.json and keeps every existing entry" -Check {
        $run = Get-CursorSetupRun -Key "cursor-only" -NoClaude -Cursor -McpJson $cursorMcp
        $after = (Get-Content -LiteralPath (Join-Path $run.Cursor "mcp.json") -Raw | ConvertFrom-Json).mcpServers
        $before = ($cursorMcp | ConvertFrom-Json).mcpServers
        foreach ($name in @("mine", "playwright")) {
            if (($after.$name | ConvertTo-Json -Compress -Depth 10) -ne ($before.$name | ConvertTo-Json -Compress -Depth 10)) { return "$name changed: $($after.$name | ConvertTo-Json -Compress -Depth 10)" }
        }
        foreach ($name in @("context7", "agent-skills")) {
            if (-not $after.PSObject.Properties[$name]) { return "$name was not added" }
            $keys = @($after.$name.PSObject.Properties.Name | Where-Object { $_.StartsWith('$') })
            if ($keys.Count -gt 0) { return "$name kept documentation keys: $($keys -join ', ')" }
        }
        return $true
    }

    Test-Case -Name "U19 doctor fails naming each skill missing from the Cursor directory and a hooks.json with no toolkit entry" -Check {
        $run = Get-CursorSetupRun -Key "cursor-only" -NoClaude -Cursor -McpJson $cursorMcp
        $skills = @($manifest.AgentSkills) + "review-change"
        $moved = Join-Path $run.Root "moved-cursor-skills"
        New-Item -ItemType Directory -Path $moved -Force | Out-Null
        $hooks = Join-Path $run.Cursor "hooks.json"
        $wired = [System.IO.File]::ReadAllText($hooks)

        foreach ($s in $skills) { Move-Item -LiteralPath (Join-Path $run.Cursor "skills\$s") -Destination $moved }
        [System.IO.File]::WriteAllText($hooks, '{"version":1,"hooks":{}}')

        try {
            $doctor = Invoke-CursorScript -Root $run.Root -Script "health-check.ps1" -NoClaude
        }
        finally {
            foreach ($s in $skills) { Move-Item -LiteralPath (Join-Path $moved $s) -Destination (Join-Path $run.Cursor "skills") }
            [System.IO.File]::WriteAllText($hooks, $wired)
        }

        if ($doctor.Code -ne 1) { return "doctor exited $($doctor.Code) with no Cursor skills and no toolkit hook, expected 1" }
        $unnamed = @($skills | Where-Object { $doctor.Output -notmatch ("skill " + [regex]::Escape($_) + " is missing from " + [regex]::Escape((Join-Path $run.Cursor "skills"))) })
        if ($unnamed.Count -gt 0) { return ("not named: " + ($unnamed -join ", ")) }
        if ($doctor.Output -notmatch ("no harness-toolkit hook in " + [regex]::Escape($hooks))) { return "the missing toolkit hook is not reported" }
        return $true
    }

    Test-Case -Name "U20 doctor on a complete Cursor-only machine exits 0 and does not report Claude Code missing" -Check {
        $run = Get-CursorSetupRun -Key "cursor-only" -NoClaude -Cursor -McpJson $cursorMcp
        $doctor = Invoke-CursorScript -Root $run.Root -Script "health-check.ps1" -NoClaude
        if ($doctor.Code -ne 0) { return "exit $($doctor.Code): $($doctor.Output)" }
        if ($doctor.Output.Contains("Claude Code not found on PATH.")) { return "doctor reports Claude Code missing" }
        return $true
    }
}
finally {
    if ($script:adoServer) { Remove-Job -Job $script:adoServer.Job -Force -ErrorAction SilentlyContinue }

    foreach ($root in $script:scratchRoots) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "Claude Code integration"
Write-Host "-----------------------"

if ($SkipSlow) {
    Skip-Case -Name "agents and skills are recognised" -Reason "-SkipSlow"
}
elseif (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Skip-Case -Name "agents and skills are recognised" -Reason "Claude Code not on PATH"
}
else {

    Test-Case -Name "Claude Code recognises the harness agents" -Check {

        # Claude Code prints the available-agent list to stderr. Capturing it
        # through a file avoids Windows PowerShell 5.1 wrapping each stderr line
        # in a NativeCommandError, which loses the text.
        $previous = $ErrorActionPreference
        $ErrorActionPreference = "Continue"

        $errorFile = [System.IO.Path]::GetTempFileName()

        try {
            $standardOutput = (& claude -p "x" --agent harness-self-test-missing --max-turns 1 2> $errorFile | Out-String)
            $output = $standardOutput + (Get-Content -LiteralPath $errorFile -Raw -ErrorAction SilentlyContinue)
        }
        finally {
            Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
            $ErrorActionPreference = $previous
        }

        $missing = @()

        # Every agent the repository ships, so a new one cannot go unchecked.
        $shipped = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot "user\agents") -File -Filter *.md | ForEach-Object { $_.BaseName })

        if ($shipped.Count -eq 0) { return "no agents found in user\agents" }

        foreach ($agent in $shipped) {
            if ($output -notmatch "\b$agent\b") { $missing += $agent }
        }

        if ($missing.Count -eq 0) { return $true }
        return ("not listed as available: " + ($missing -join ", "))
    }
}

Test-Case -Name "V14 the self-test leaves the persisted user PATH as it found it" -Check {
    $now = [Environment]::GetEnvironmentVariable("PATH", "User")
    if ($now -ne $userPathAtStart) { return "the user PATH changed during the self-test: '$userPathAtStart' -> '$now'" }
    return $true
}

$env:TAZUNA_SKIP_PATH = $skipPathAtStart
$env:TAZUNA_CURSOR_DIR = $cursorDirAtStart

Write-Host ""
Write-Host "================="
Write-Host ("Passed: {0}   Failed: {1}   Skipped: {2}" -f $script:passed, $script:failed, $script:skipped)
Write-Host "================="
Write-Host ""

if ($Only -and (($script:passed + $script:failed) -eq 0)) {
    Write-Host "HARNESS SELF-TEST FAILED: no case named '$Only' ran"
    Write-Host ""
    exit 1
}

if ($script:failed -gt 0) {
    Write-Host "HARNESS SELF-TEST FAILED"
    Write-Host ""
    exit 1
}

Write-Host "HARNESS SELF-TEST PASSED"
Write-Host ""
exit 0
