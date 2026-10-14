[CmdletBinding()]
param([switch]$SkipSlow, [string]$Only)

. (Join-Path $PSScriptRoot "TestKit.ps1")

try {

    Start-Section "Cursor install"

    function Split-Frontmatter {
        param([string]$Text)
        $match = [regex]::Match($Text.Replace("`r`n", "`n"), '(?s)\A---\n(.*?)\n---\n(.*)\z')
        if (-not $match.Success) { return $null }
        return [PSCustomObject]@{ Head = $match.Groups[1].Value; Body = $match.Groups[2].Value }
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
        return (Invoke-WithStubs -Root $Root -Script (Join-Path $scriptsRoot $Script) -Arguments $Arguments -DropPathContaining $drop)
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

    Test-Case -Name "SK2 setup installs ship for Cursor too, and doctor names it missing there" -Check {
        $kit = @("ship")
        $run = Get-CursorSetupRun -Key "both" -Cursor
        if ($run.Code -ne 0) { return "exit $($run.Code): $($run.Output)" }
        $missing = @($kit | Where-Object { -not (Test-Path -LiteralPath (Join-Path $run.Cursor "skills\$_\SKILL.md")) })
        if ($missing.Count -gt 0) { return ("not installed for Cursor: " + ($missing -join ", ")) }

        $cursorOnly = Get-CursorSetupRun -Key "cursor-only" -NoClaude -Cursor -McpJson $cursorMcp
        $moved = Join-Path $cursorOnly.Root "moved-cursor-kit"
        New-Item -ItemType Directory -Path $moved -Force | Out-Null
        foreach ($skill in $kit) { Move-Item -LiteralPath (Join-Path $cursorOnly.Cursor "skills\$skill") -Destination $moved }

        try {
            $doctor = Invoke-CursorScript -Root $cursorOnly.Root -Script "health-check.ps1" -NoClaude
        }
        finally {
            foreach ($skill in $kit) { Move-Item -LiteralPath (Join-Path $moved $skill) -Destination (Join-Path $cursorOnly.Cursor "skills") }
        }

        if ($doctor.Code -ne 1) { return "doctor exited $($doctor.Code) without ship in Cursor, expected 1" }
        $unnamed = @($kit | Where-Object { $doctor.Output -notmatch ("skill " + [regex]::Escape($_) + " is missing from") })
        if ($unnamed.Count -gt 0) { return ("doctor did not name: " + ($unnamed -join ", ")) }
        return $true
    }
    Test-Case -Name "U16 setup with Claude Code and Cursor installs the manifest skills for both in one call, -a claude-code cursor -g" -Check {
        $run = Get-CursorSetupRun -Key "both" -Cursor
        if ($run.Code -ne 0) { return "exit $($run.Code): $($run.Output)" }
        $literal = "npx -y @tech-leads-club/agent-skills@1.5.0 install -s tlc-discover tlc-spec-lean tlc-spec-driven tlc-plan tlc-implement harness-eval modular-design-principles evolutionary-modular-architecture modular-decomposition the-judge coding-guidelines security-best-practices security-threat-model create-adr create-rfc -a claude-code cursor -g"
        if ($run.Calls -notcontains $literal) { return "no call: $literal" }
        $skillCalls = @($run.Calls | Where-Object { $_.StartsWith("npx -y @tech-leads-club/agent-skills@") })
        if ($skillCalls.Count -ne 1) { return "expected one skills install, got $($skillCalls.Count): " + ($skillCalls -join " | ") }
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
    Clear-ScratchRoot
}

Complete-TestFile
