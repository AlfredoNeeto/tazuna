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

Test-Case -Name "GD1 user settings keep the agent off the project's hook wiring, and no longer guard the removed 1.x gate" -Check {

    # After /harness-init, .claude/settings.json holds the toolkit's project hooks,
    # and the toolkit's own floor protects only the user-level settings file. A
    # gate the agent can unwire is not a deterministic mechanism.
    $settings = Get-Content -LiteralPath (Join-Path $repoRoot "user\settings.json") -Raw | ConvertFrom-Json
    $deny = @($settings.permissions.deny)

    if ($deny -notcontains "Edit(./.claude/settings.json)") { return "no Edit(./.claude/settings.json) deny rule" }

    $stale = @($deny | Where-Object { @("Edit(./.claude/state/**)", "Edit(./.claude/hooks/**)", "Edit(./.claude/scripts/**)") -contains $_ })
    if ($stale.Count -gt 0) { return ("still guards the 1.x gate: " + ($stale -join ", ")) }
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

Start-Section "Dogfooding"

Test-Case -Name "DF1 this repository carries none of the 1.x gate it no longer ships" -Check {

    # invariant: a copy of the old gate left here would keep firing beside grind and test nothing 2.0 ships.
    $left = @(@(".claude\hooks", ".claude\scripts", ".claude\state", ".cursor\hooks.json") |
        Where-Object { Test-Path -LiteralPath (Join-Path $repoRoot $_) })
    if ($left.Count -gt 0) { return ("still here: " + ($left -join ", ") + "; run tazuna init on this repository") }
    return $true
}

Test-Case -Name "the harness has its own project instructions, naming the self-test as its verification" -Check {

    $agents = Join-Path $repoRoot "AGENTS.md"

    if (-not (Test-Path -LiteralPath $agents)) { return "no AGENTS.md at the repository root" }
    if (@(Select-String -Path $agents -Pattern 'test-harness\.ps1').Count -eq 0) { return "AGENTS.md does not name scripts\test-harness.ps1" }
    if (@(Select-String -Path $agents -Pattern 'verify\.ps1').Count -gt 0) { return "AGENTS.md still names verify.ps1" }
    return $true
}

Test-Case -Name "SK3 ship keeps its contract: it verifies with the project gate and never publishes" -Check {
    $ship = [System.IO.File]::ReadAllText((Join-Path $repoRoot "user\skills\ship\SKILL.md"))

    # invariant: these are the sentences that make the skill what the README promises.
    foreach ($phrase in @("tlc harness status", "Conventional Commit", "Draft the pull request", "Never run ``git push``", "never merge", "Stop before publishing")) {
        if ($ship -notmatch $phrase) { return "ship no longer says: $phrase" }
    }
    return $true
}
Complete-TestFile
