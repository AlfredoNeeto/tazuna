[CmdletBinding()]
param([switch]$SkipSlow, [string]$Only)

. (Join-Path $PSScriptRoot "TestKit.ps1")

Start-Section "Scripts"

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

Start-Section "PowerShell 5.1 compatibility"

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
        $scanned = $scriptFiles | Where-Object { $_.Name -ne "Static.Tests.ps1" }

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

Start-Section "Repository hygiene"

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

Start-Section "Permissions"

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

Start-Section "Templates"

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

Start-Section "Agents and skills"

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

Start-Section "Template deduplication"

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

Start-Section "Dogfooding"

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


Test-Case -Name "IF1 every Claude settings file Tazuna ships runs the git hook only for commit, push or a git global option" -Check {
    $expected = @("Bash|Bash(*commit*)", "Bash|Bash(*push*)", "Bash|Bash(*git -*)", "PowerShell|PowerShell(*commit*)", "PowerShell|PowerShell(*push*)", "PowerShell|PowerShell(*git -*)")
    $files = @(
        (Join-Path $repoRoot "templates\generic\dot-claude\settings.json"),
        (Join-Path $repoRoot "templates\dotnet\dot-claude\settings.json"),
        (Join-Path $repoRoot ".claude\settings.json"))

    foreach ($file in $files) {
        $found = @()
        foreach ($entry in @((Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).hooks.PreToolUse)) {
            foreach ($hook in @($entry.hooks)) {
                if (($hook.args -join " ") -notmatch "block-secret-commit\.ps1") { continue }
                # invariant: a registration without "if" would start PowerShell for every shell command again.
                if (-not $hook.PSObject.Properties["if"]) { return "$file registers the git hook for every $($entry.matcher) call" }
                $found += ($entry.matcher + "|" + $hook.if)
            }
        }
        if ((@($found | Sort-Object) -join ",") -ne (@($expected | Sort-Object) -join ",")) { return "$file has: " + ($found -join ", ") }
    }
    return $true
}
Complete-TestFile
