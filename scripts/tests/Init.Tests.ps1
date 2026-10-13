[CmdletBinding()]
param([switch]$SkipSlow, [string]$Only)

. (Join-Path $PSScriptRoot "TestKit.ps1")

Start-Section "Detection"

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

        & (Join-Path $scriptsRoot "init-project.ps1") @parameters 6>$null | Out-Null

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

        & (Join-Path $scriptsRoot "init-project.ps1") -Path $project -NoTrust 6>$null | Out-Null

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

        & (Join-Path $scriptsRoot "init-project.ps1") -Type dotnet -Path $project -NoTrust 6>$null | Out-Null

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

        & (Join-Path $scriptsRoot "init-project.ps1") -Path $project 6>$null | Out-Null

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

        & (Join-Path $scriptsRoot "init-project.ps1") -Path $project -NoTrust 6>$null | Out-Null

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

        & (Join-Path $scriptsRoot "init-project.ps1") -Path $project 6>$null | Out-Null

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
            & (Join-Path $scriptsRoot "init-project.ps1") -NoTrust 6>$null | Out-Null
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

try {

    Start-Section "Init"

    # S2 - init

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
        $again = Invoke-WithStubs -Root (Split-Path -Parent $run.Project) -Script (Join-Path $scriptsRoot "init-project.ps1") -Arguments @("-Path", $run.Project, "-NoTrust")
        if ($again.Code -ne 0) { return "exit $($again.Code)" }
        if ($again.Output -notmatch "Project harness: 0 created, 0 updated, [1-9]\d* unchanged, 0 skipped") { return "second run was not all UNCHANGED" }
        return $true
    }

    Test-Case -Name "UP1 a second init replaces Tazuna's hooks and module with a backup, and keeps the project's verify.ps1" -Check {
        $run = New-InitProject -Files @{ "App.csproj" = '<Project Sdk="Microsoft.NET.Sdk" />' }
        $owned = @(".claude\hooks\require-verification.ps1", ".claude\hooks\record-session-baseline.ps1", ".claude\hooks\block-secret-commit.ps1", ".claude\scripts\VerifyCommon.psm1")
        $projectOwned = ".claude\scripts\verify.ps1"

        foreach ($relative in ($owned + $projectOwned)) { Add-Content -LiteralPath (Join-Path $run.Project $relative) -Value "# an older copy" }

        $again = Invoke-WithStubs -Root (Split-Path -Parent $run.Project) -Script (Join-Path $scriptsRoot "init-project.ps1") -Arguments @("-Path", $run.Project, "-NoTrust")
        if ($again.Code -ne 0) { return "exit $($again.Code): $($again.Output)" }

        foreach ($relative in $owned) {
            $template = Join-Path $repoRoot ("templates\_shared\dot-claude" + $relative.Substring(".claude".Length))
            if (-not (Test-FileContentEqual -ReferenceFile $template -DifferenceFile (Join-Path $run.Project $relative))) { return "$relative was not brought up to date" }
            if ($again.Output -notmatch ("UPDATE\s+" + [regex]::Escape($relative))) { return "init did not report UPDATE for $relative" }
            $backups = @(Get-ChildItem -LiteralPath $run.Project -Recurse -Force -File -Filter (Split-Path -Leaf $relative) | Where-Object { $_.FullName -match "harness-backup" })
            if ($backups.Count -eq 0) { return "no backup of the old $relative" }
        }

        if ([System.IO.File]::ReadAllText((Join-Path $run.Project $projectOwned)) -notmatch "an older copy") { return "$projectOwned was replaced without -Force" }
        if ($again.Output -notmatch ("SKIP\s+" + [regex]::Escape($projectOwned))) { return "init did not report SKIP for $projectOwned" }
        return $true
    }

    Test-Case -Name "UP2 init fails when the project's own settings.json leaves the gate unwired, and -Force wires it" -Check {
        $root = New-ScratchRoot
        $project = Join-Path $root "project"
        New-Item -ItemType Directory -Path (Join-Path $project ".claude") -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $project "App.csproj") -Value '<Project Sdk="Microsoft.NET.Sdk" />' -NoNewline
        Set-Content -LiteralPath (Join-Path $project ".claude\settings.json") -Value '{ "permissions": { "allow": [] } }' -NoNewline

        $first = Invoke-WithStubs -Root $root -Script (Join-Path $scriptsRoot "init-project.ps1") -Arguments @("-Path", $project, "-NoTrust")
        if ($first.Code -ne 1) { return "exit $($first.Code) with an unwired settings.json, expected 1" }
        if ($first.Output -notmatch "verification gate is OFF") { return ("no message about the gate: " + $first.Output) }

        # why: a Stop hook that runs something else is not the gate either.
        Set-Content -LiteralPath (Join-Path $project ".claude\settings.json") -Value '{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "node other-stop.js" } ] } ] } }' -NoNewline
        $other = Invoke-WithStubs -Root $root -Script (Join-Path $scriptsRoot "init-project.ps1") -Arguments @("-Path", $project, "-NoTrust")
        if ($other.Code -ne 1) { return "exit $($other.Code) with a Stop hook that is not the gate, expected 1" }

        $forced = Invoke-WithStubs -Root $root -Script (Join-Path $scriptsRoot "init-project.ps1") -Arguments @("-Path", $project, "-NoTrust", "-Force")
        if ($forced.Code -ne 0) { return "-Force: exit $($forced.Code): $($forced.Output)" }
        return $true
    }

    Test-Case -Name "C15 both AGENTS.md templates are at most 40 lines" -Check {
        foreach ($type in @("dotnet", "generic")) {
            $count = @(Get-Content -LiteralPath (Join-Path $repoRoot "templates\$type\AGENTS.md")).Count
            if ($count -gt 40) { return "$type AGENTS.md has $count lines" }
        }
        return $true
    }
}
finally {
    Clear-ScratchRoot
}

Complete-TestFile
