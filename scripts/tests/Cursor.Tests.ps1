[CmdletBinding()]
param([switch]$SkipSlow, [string]$Only)

. (Join-Path $PSScriptRoot "TestKit.ps1")

try {

    Start-Section "Cursor"

    # Payloads follow cursor.com/docs/agent/hooks. No case here runs inside Cursor itself.
    function New-CursorProject {
        $project = Join-Path (New-ScratchRoot) "project"
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $project "Program.cs") -Value "class P { }" -NoNewline
        Set-Content -LiteralPath (Join-Path $project "App.csproj") -Value "<Project />" -NoNewline
        & (Join-Path $scriptsRoot "init-project.ps1") -Type dotnet -Path $project -NoTrust 6>$null | Out-Null
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

    Start-Section "Cursor install"

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

        $output = (& (Join-Path $scriptsRoot "init-project.ps1") -Type dotnet -Path $project -NoTrust 6>&1 | Out-String)
        if ([System.IO.File]::ReadAllText($path) -ne $mine) { return "init replaced a differing .cursor\hooks.json without -Force" }
        if ($output -notmatch 'SKIP\s+\.cursor\\hooks\.json') { return "no SKIP line for .cursor\hooks.json" }

        & (Join-Path $scriptsRoot "init-project.ps1") -Type dotnet -Path $project -NoTrust -Force 6>$null | Out-Null
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
        & (Join-Path $scriptsRoot "init-project.ps1") -Type dotnet -Path $project -NoTrust -WhatIf 6>$null | Out-Null
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
    Clear-ScratchRoot
}

Complete-TestFile
