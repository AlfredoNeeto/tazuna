[CmdletBinding()]
param([switch]$SkipSlow, [string]$Only)

. (Join-Path $PSScriptRoot "TestKit.ps1")

Import-Module (Join-Path $scriptsRoot "lib\Cursor.psm1") -Force

Start-Section "Init"

$fixtures = Join-Path $PSScriptRoot (Join-Path "fixtures" "1.5.0")

function Get-Fixture {
    param([string]$Name)
    return [System.IO.File]::ReadAllText((Join-Path $fixtures $Name))
}

function Get-LegacyProject {
    # The files tazuna init 1.5.0 wrote into a .NET project, as it wrote them, plus project content of its own.
    $hook = "# a 1.x hook`r`nexit 0`r`n"
    return @{
        ".claude\hooks\require-verification.ps1"    = $hook
        ".claude\hooks\record-session-baseline.ps1" = $hook
        ".claude\hooks\block-secret-commit.ps1"     = $hook
        ".claude\scripts\VerifyCommon.psm1"         = "# the 1.x module`r`n"
        ".claude\scripts\verify.ps1"                = (Get-Fixture "verify.ps1")
        ".claude\rules\csharp.md"                   = (Get-Fixture "csharp.md")
        ".claude\rules\testing.md"                  = (Get-Fixture "testing.md")
        ".cursor\rules\csharp.mdc"                  = (ConvertTo-CursorRule -Text (Get-Fixture "csharp.md"))
        ".cursor\rules\testing.mdc"                 = (ConvertTo-CursorRule -Text (Get-Fixture "testing.md"))
        ".claude\state\session-baseline.json"       = '{"fingerprint":"x"}'
        ".claude\settings.json"                     = (Get-Fixture "settings.json")
        ".cursor\hooks.json"                        = (Get-Fixture "hooks.json")
        ".gitignore"                                = "bin/`n.harness-backup/`n.claude/state/`n**/.tlc/harness/state/`n"
        "AGENTS.md"                                 = "Run .\.claude\scripts\verify.ps1 before finishing.`n"
        "App.csproj"                                = '<Project Sdk="Microsoft.NET.Sdk" />'
    }
}

$retired = @(".claude\hooks", ".claude\scripts", ".claude\rules", ".claude\state", ".cursor\rules", ".cursor\hooks.json")

Test-Case -Name "IN1 the manifest lists the hash of every 1.5.0 fixture, as LF and as CRLF" -Check {
    $project = (Get-HarnessManifest).Retired.Project
    $pairs = @{ ".claude\scripts\verify.ps1" = "verify.ps1"; ".claude\rules\csharp.md" = "csharp.md"; ".claude\rules\testing.md" = "testing.md" }
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        foreach ($relative in $pairs.Keys) {
            $lf = (Get-Fixture $pairs[$relative]).Replace("`r`n", "`n")
            foreach ($text in @($lf, $lf.Replace("`n", "`r`n"))) {
                $hash = [System.BitConverter]::ToString($algorithm.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))).Replace("-", "")
                if ($project[$relative] -notcontains $hash) { return "$relative has no entry for $hash" }
            }
        }
    }
    finally { $algorithm.Dispose() }
    return $true
}

Test-Case -Name "IN2 init removes what 1.x installed, backs it up, and keeps the project's own content" -Check {
    $run = New-InitProject -Files (Get-LegacyProject)
    if ($run.Code -ne 0) { return "init exited $($run.Code): $($run.Output)" }

    foreach ($relative in $retired) {
        if (Test-Path -LiteralPath (Join-Path $run.Project $relative)) { return "$relative is still there" }
    }

    $settings = Get-Content -LiteralPath (Join-Path $run.Project ".claude\settings.json") -Raw | ConvertFrom-Json
    if ($settings.PSObject.Properties["hooks"]) { return "settings.json still has hooks" }
    if (@($settings.permissions.allow | Where-Object { $_ -like "*verify.ps1*" }).Count -gt 0) { return "settings.json still allows verify.ps1" }
    if (@($settings.permissions.allow) -notcontains "Bash(dotnet build:*)") { return "the project's own allow rules were removed" }
    if (@($settings.permissions.deny) -notcontains "Bash(dotnet nuget push:*)") { return "the project's own deny rules were removed" }

    $ignore = [System.IO.File]::ReadAllText((Join-Path $run.Project ".gitignore"))
    if ($ignore -match "\.claude/state/") { return ".gitignore still lists .claude/state/" }
    foreach ($kept in @("bin/", ".harness-backup/", "**/.tlc/harness/state/")) { if (-not $ignore.Contains($kept)) { return ".gitignore lost $kept" } }

    if ([System.IO.File]::ReadAllText((Join-Path $run.Project "AGENTS.md")) -notmatch "verify\.ps1") { return "AGENTS.md was changed" }
    if ($run.Output -notmatch "WARN\s+AGENTS\.md still names verify\.ps1") { return ("no AGENTS.md warning: " + $run.Output) }

    $backup = @(Get-ChildItem -LiteralPath (Join-Path $run.Project ".harness-backup") -Recurse -File | ForEach-Object { $_.Name })
    foreach ($name in @("verify.ps1", "VerifyCommon.psm1", "require-verification.ps1", "settings.json", "hooks.json", "csharp.mdc", ".gitignore")) {
        if ($backup -notcontains $name) { return "no backup of $name" }
    }
    if ($run.Output -notmatch "tlc harness grind on") { return "init did not hand over to the toolkit" }
    return $true
}

Test-Case -Name "IN3 an edited verify.ps1 is kept and its steps are printed as the gate command" -Check {
    $files = Get-LegacyProject
    $files[".claude\scripts\verify.ps1"] = $files[".claude\scripts\verify.ps1"] -replace '\$VerificationSteps = @\(\r?\n\)',
        "`$VerificationSteps = @(`n    @{ Name = `"npm test`"; Command = { npm test }; IsTest = `$true }`n)"
    if ($files[".claude\scripts\verify.ps1"] -notmatch "npm test") { return "the fixture edit did not apply" }

    $run = New-InitProject -Files $files
    if (-not (Test-Path -LiteralPath (Join-Path $run.Project ".claude\scripts\verify.ps1"))) { return "the edited verify.ps1 was removed" }
    if ($run.Output -notmatch "WARN\s+kept \.claude\\scripts\\verify\.ps1") { return ("no WARN for verify.ps1: " + $run.Output) }
    if ($run.Output -notmatch "Command = \{ npm test \}") { return ("its steps were not printed: " + $run.Output) }
    if (Test-Path -LiteralPath (Join-Path $run.Project ".claude\scripts\VerifyCommon.psm1")) { return "VerifyCommon.psm1 stayed beside it" }
    return $true
}

Test-Case -Name "IN4 -WhatIf names the changes and writes nothing; a real run then a second run changes nothing more" -Check {
    $dry = New-InitProject -Files (Get-LegacyProject) -Arguments @("-WhatIf")
    if ($dry.Code -ne 0) { return "init -WhatIf exited $($dry.Code)" }
    foreach ($relative in $retired) {
        if (-not (Test-Path -LiteralPath (Join-Path $dry.Project $relative))) { return "-WhatIf removed $relative" }
    }
    if (Test-Path -LiteralPath (Join-Path $dry.Project ".harness-backup")) { return "-WhatIf wrote a backup" }
    if ($dry.Output -notmatch "would remove \.claude\\hooks\\require-verification\.ps1") { return ("no WHATIF line: " + $dry.Output) }
    $before = [System.IO.File]::ReadAllText((Join-Path $dry.Project ".claude\settings.json"))
    if ($before -ne (Get-Fixture "settings.json")) { return "-WhatIf rewrote settings.json" }

    $real = Invoke-WithStubs -Root (Split-Path -Parent $dry.Project) -Script (Join-Path $scriptsRoot "init-project.ps1") -Arguments @("-Path", $dry.Project)
    if ($real.Code -ne 0) { return "init exited $($real.Code)" }
    $settings = [System.IO.File]::ReadAllText((Join-Path $dry.Project ".claude\settings.json"))

    $again = Invoke-WithStubs -Root (Split-Path -Parent $dry.Project) -Script (Join-Path $scriptsRoot "init-project.ps1") -Arguments @("-Path", $dry.Project)
    if ($again.Output -notmatch "Nothing from Tazuna 1\.x here") { return ("a second run found more to do: " + $again.Output) }
    if ([System.IO.File]::ReadAllText((Join-Path $dry.Project ".claude\settings.json")) -ne $settings) { return "a second run rewrote settings.json" }
    return $true
}

Test-Case -Name "IN5 a .cursor/hooks.json holding a hook of the project's own keeps the file and that hook" -Check {
    $files = Get-LegacyProject
    $files[".cursor\hooks.json"] = '{"version":1,"hooks":{"stop":[{"command":"node tools/notify.js"},{"command":"powershell -NoProfile -ExecutionPolicy Bypass -File .claude/hooks/require-verification.ps1 -Agent cursor"}]}}'
    $run = New-InitProject -Files $files
    $path = Join-Path $run.Project ".cursor\hooks.json"
    if (-not (Test-Path -LiteralPath $path)) { return "hooks.json was removed with a hook of the project's in it" }
    $commands = @((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).hooks.stop | ForEach-Object { $_.command })
    if (($commands -join "|") -ne "node tools/notify.js") { return ("hooks.json holds: " + ($commands -join " | ")) }
    return $true
}

Test-Case -Name "IN6 a project with nothing from 1.x only gets the handover and no backup" -Check {
    $run = New-InitProject -Files @{ "notes.txt" = "hello" }
    if ($run.Code -ne 0) { return "init exited $($run.Code)" }
    if ($run.Output -notmatch "Nothing from Tazuna 1\.x here") { return ("output: " + $run.Output) }
    if ($run.Output -notmatch "/harness-init") { return "no handover to /harness-init" }
    if (@(Get-ChildItem -LiteralPath $run.Project -Force).Count -ne 1) { return "init wrote into a project with nothing to migrate" }
    return $true
}

Test-Case -Name "-Path defaults to the current directory, not the process one" -Check {

    # [System.IO.Path]::GetFullPath(".") resolves against the PROCESS working
    # directory, which does not follow Set-Location; with a default of "." it
    # decides which repository gets changed.
    $project = Join-Path (New-ScratchRoot) "cwd"
    $hook = Join-Path $project ".claude\hooks\require-verification.ps1"
    New-Item -ItemType Directory -Path (Split-Path -Parent $hook) -Force | Out-Null
    Set-Content -LiteralPath $hook -Value "exit 0"

    Push-Location -LiteralPath $project
    try {
        & (Join-Path $scriptsRoot "init-project.ps1") 6>$null | Out-Null
    }
    finally {
        Pop-Location
    }

    if ($LASTEXITCODE -ne 0) { return "init-project.ps1 exited $LASTEXITCODE" }
    if (Test-Path -LiteralPath $hook) { return "the current directory was not migrated" }
    return $true
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

Test-Case -Name "no script resolves a path parameter around Resolve-HarnessPath" -Check {

    # GetFullPath on a PARAMETER is the shape of the bug the case above covers
    # for init; this stops the next script from reintroducing it.
    $offenders = @()

    foreach ($script in (Get-ChildItem -LiteralPath (Join-Path $repoRoot "scripts") -Filter *.ps1 -File)) {
        if ($script.Name -eq "test-harness.ps1") { continue }

        $text = Get-Content -LiteralPath $script.FullName -Raw
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

Complete-TestFile
