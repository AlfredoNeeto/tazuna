[CmdletBinding()]
param([switch]$SkipSlow, [string]$Only)

. (Join-Path $PSScriptRoot "TestKit.ps1")

Start-Section "Setup, doctor and MCP"

function Test-TlcHook {
    param([string]$ConfigDir)

    $path = Join-Path $ConfigDir "settings.json"
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    return ((Get-Content -LiteralPath $path -Raw) -match "tlc-exec")
}

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

    Test-Case -Name "C36 setup installs the skills from the pinned catalog 0.17.8 and puts back the caller's SKILLS_CDN_REF" -Check {
        foreach ($scenario in @(@{ Key = "fresh"; Before = "" }, @{ Key = "catalog-preset"; Before = "9.9.9" })) {

            $environment = @{}
            if ($scenario.Before) { $environment["SKILLS_CDN_REF"] = $scenario.Before }

            $run = Get-SetupRun -Key $scenario.Key -Environment $environment
            if ($run.Code -ne 0) { return "$($scenario.Key): setup exited $($run.Code): $($run.Output)" }

            $calls = @($run.Calls)
            $skillInstalls = 0
            $later = 0

            for ($index = 0; $index -lt $calls.Count; $index++) {

                if (-not $calls[$index].StartsWith("npx ")) { continue }

                # The literal the check names, so a changed pin fails here instead of following along.
                $expected = "catalog " + $scenario.Before
                if ($calls[$index].StartsWith("npx -y @tech-leads-club/agent-skills@1.4.10 ")) { $expected = "catalog 0.17.8"; $skillInstalls++ }
                elseif ($skillInstalls -gt 0) { $later++ }

                if ($calls[$index + 1] -ne $expected) { return ("$($scenario.Key): '" + $calls[$index] + "' saw '" + $calls[$index + 1] + "', expected '" + $expected + "'") }
            }

            if ($skillInstalls -eq 0) { return "$($scenario.Key): setup never ran the agent-skills install" }
            if ($later -eq 0) { return "$($scenario.Key): no npx ran after the skills install, so the restore went unobserved" }
        }

        return $true
    }
    Test-Case -Name "ST3 setup installs the toolkit only when the pinned version is not there yet" -Check {
        $pinned = $manifest.ToolkitPackage.Substring($manifest.ToolkitPackage.LastIndexOf("@") + 1)
        $install = "npm install -g " + $manifest.ToolkitPackage

        $fresh = Get-SetupRun -Key "fresh"
        if (@($fresh.Calls | Where-Object { $_ -eq $install }).Count -ne 1) { return "a machine without the toolkit did not install it" }

        $present = Get-SetupRun -Key "toolkit-present" -Environment @{ HARNESS_STUB_TOOLKIT = $pinned }
        if ($present.Code -ne 0) { return "exit $($present.Code): $($present.Output)" }
        if (@($present.Calls | Where-Object { $_.StartsWith("npm install") }).Count -ne 0) { return "the pinned toolkit was installed again" }
        if ($present.Output -notmatch "already installed") { return "setup did not say the toolkit was already installed" }
        if (@($present.Calls | Where-Object { $_ -eq "tlc harness install" }).Count -ne 1) { return "tlc harness install no longer runs" }

        $older = Get-SetupRun -Key "toolkit-older" -Environment @{ HARNESS_STUB_TOOLKIT = "0.0.1" }
        if (@($older.Calls | Where-Object { $_ -eq $install }).Count -ne 1) { return "an older toolkit was not brought to the pin" }
        return $true
    }
    Test-Case -Name "ST4 a plugin that fails to install fails setup with exit 1 and names it" -Check {
        $run = Get-SetupRun -Key "plugin-fails" -Environment @{ HARNESS_STUB_FAIL = "claude-plugin-install" }
        if ($run.Code -ne 1) { return "exit $($run.Code), expected 1" }
        if ($run.Output -notmatch "plugin install ponytail@ponytail exited 1") { return ("the failure does not name the plugin: " + $run.Output) }
        return $true
    }
    Test-Case -Name "SK1 setup installs fix-bug and ship for Claude Code, and doctor names either one missing" -Check {
        $kit = @("fix-bug", "ship")

        $claude = Get-SetupRun -Key "fresh"
        $missing = @($kit | Where-Object { -not (Test-Path -LiteralPath (Join-Path $claude.Config "skills\$_\SKILL.md")) })
        if ($missing.Count -gt 0) { return ("not installed for Claude Code: " + ($missing -join ", ")) }


        $moved = Join-Path $claude.Root "moved-kit"
        New-Item -ItemType Directory -Path $moved -Force | Out-Null
        foreach ($skill in $kit) { Move-Item -LiteralPath (Join-Path $claude.Config "skills\$skill") -Destination $moved }

        try {
            $doctor = Invoke-WithStubs -Root $claude.Root -Script (Join-Path $scriptsRoot "health-check.ps1")
        }
        finally {
            foreach ($skill in $kit) { Move-Item -LiteralPath (Join-Path $moved $skill) -Destination (Join-Path $claude.Config "skills") }
        }

        if ($doctor.Code -eq 0) { return "doctor passed without fix-bug and ship" }
        $unnamed = @($kit | Where-Object { $doctor.Output -notmatch ("skill " + [regex]::Escape($_) + " is missing") })
        if ($unnamed.Count -gt 0) { return ("doctor did not name: " + ($unnamed -join ", ")) }
        return $true
    }
    Test-Case -Name "C1 doctor fails naming each of the seven skills when absent" -Check {
        $run = Get-SetupRun -Key "fresh"
        $skills = @($manifest.AgentSkills) + "review-change"
        $moved = Join-Path $run.Root "moved-skills"
        New-Item -ItemType Directory -Path $moved -Force | Out-Null

        foreach ($s in $skills) { Move-Item -LiteralPath (Join-Path $run.Config "skills\$s") -Destination $moved }

        try {
            $doctor = Invoke-WithStubs -Root $run.Root -Script (Join-Path $scriptsRoot "health-check.ps1")
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
        $again = Invoke-WithStubs -Root $run.Root -Script (Join-Path $scriptsRoot "bootstrap.ps1")
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
            $doctor = Invoke-WithStubs -Root $run.Root -Script (Join-Path $scriptsRoot "health-check.ps1")
        }
        finally {
            [System.IO.File]::WriteAllText($path, $original)
        }

        if ($doctor.Code -eq 0) { return "doctor passed without the toolkit hook" }
        if ($doctor.Output -notmatch "no tlc-exec hook") { return "the missing hook was not named" }
        return $true
    }
}
finally {
    Clear-ScratchRoot
}

Start-Section "Claude Code integration"

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

Complete-TestFile
