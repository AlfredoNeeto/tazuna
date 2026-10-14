[CmdletBinding()]
param([switch]$SkipSlow, [string]$Only)

. (Join-Path $PSScriptRoot "TestKit.ps1")

try {

    Start-Section "README"

    # S4 - README

    # The public README.

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

    Test-Case -Name "P8 every relative link in the README points at a file in the repository, and a planted missing one is reported" -Check {
        $missing = @(Find-MissingLinkTarget -Root $repoRoot -Text $readme)
        if ($missing.Count -gt 0) { return ("not in the repository: " + ($missing -join ", ")) }
        # why: a scan that never reports anything would pass here too; the planted target proves it can fail.
        $planted = @(Find-MissingLinkTarget -Root $repoRoot -Text "[x](docs/planted-missing.md) <img src=`"docs/assets/planted.svg`">")
        if (($planted -join ",") -ne "docs/planted-missing.md,docs/assets/planted.svg") { return ("the planted targets were reported as: " + ($planted -join ", ")) }
        return $true
    }

    Start-Section "Commands and paths"

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
        $source = Get-Content -LiteralPath (Join-Path $scriptsRoot "install.ps1") -Raw
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
        # why: a scratch USERPROFILE is the child's $HOME, so a real install on this machine cannot get in the way.
        $scratchHome = New-ScratchRoot
        $default = Join-Path $scratchHome "tazuna"
        $run = Invoke-InstallerWithGitStub -Environment @{ TAZUNA_PATH = ""; USERPROFILE = $scratchHome }
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

    function New-InstalledClone {
        # A bare origin and a clone of it holding the real update.ps1 and its modules, and a
        # bootstrap.ps1 that only records that setup ran.
        $root = New-ScratchRoot
        $seed = Join-Path $root "seed"
        foreach ($relative in @("scripts\update.ps1", "scripts\lib\Console.psm1", "scripts\lib\Git.psm1")) {
            $path = Join-Path $seed $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $repoRoot $relative) -Destination $path
        }
        $log = Join-Path $root "setup.log"
        Set-Content -LiteralPath (Join-Path $seed "scripts\bootstrap.ps1") -Value ("Add-Content -LiteralPath '" + $log + "' -Value setup")
        Set-Content -LiteralPath (Join-Path $seed "version.txt") -Value "1"
        $origin = Join-Path $root "origin.git"
        $clone = Join-Path $root "clone"
        $git = @("-c", "user.name=harness", "-c", "user.email=harness@example.invalid", "-c", "core.autocrlf=false")
        & git -c init.defaultBranch=main init -q $seed
        & git -C $seed @git add -A
        & git -C $seed @git commit -q -m one
        & git clone -q --bare $seed $origin
        & git clone -q $origin $clone
        # The newer version reaches origin after the clone was made.
        Set-Content -LiteralPath (Join-Path $seed "version.txt") -Value "2"
        & git -C $seed @git commit -q -am two
        & git -C $origin fetch -q $seed main:main
        return [PSCustomObject]@{ Clone = $clone; Log = $log; Git = $git }
    }

    Test-Case -Name "R15 install.ps1 on an existing clone fast-forwards it to the newest version, then runs setup" -Check {
        $fixture = New-InstalledClone
        $run = Invoke-WithStubs -Root (Split-Path -Parent $fixture.Clone) -Script (Join-Path $repoRoot "install.ps1") -Environment @{ TAZUNA_PATH = $fixture.Clone }
        if ($run.Code -ne 0) { return "install.ps1 exited $($run.Code): $($run.Output)" }
        $version = ([System.IO.File]::ReadAllText((Join-Path $fixture.Clone "version.txt"))).Trim()
        if ($version -ne "2") { return "the clone still holds version $version" }
        if (-not (Test-Path -LiteralPath $fixture.Log)) { return "setup did not run after the update" }
        return $true
    }

    Test-Case -Name "R16 install.ps1 refuses a clone with local changes or local commits, keeps them, and runs no setup" -Check {
        foreach ($shape in @("changed", "committed")) {
            $fixture = New-InstalledClone
            $file = Join-Path $fixture.Clone "version.txt"
            Set-Content -LiteralPath $file -Value "mine"
            if ($shape -eq "committed") { $git = $fixture.Git; & git -C $fixture.Clone @git commit -q -am mine }
            $run = Invoke-WithStubs -Root (Split-Path -Parent $fixture.Clone) -Script (Join-Path $repoRoot "install.ps1") -Environment @{ TAZUNA_PATH = $fixture.Clone }
            if ($run.Code -eq 0) { return "a $shape clone was accepted: $($run.Output)" }
            if (([System.IO.File]::ReadAllText($file)).Trim() -ne "mine") { return "the $shape clone lost its local version.txt" }
            if (Test-Path -LiteralPath $fixture.Log) { return "setup ran on a $shape clone" }
        }
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
            $doctor = Invoke-WithStubs -Root $run.Root -Script (Join-Path $scriptsRoot "health-check.ps1")
        }
        finally {
            [System.IO.File]::WriteAllText($path, $original)
            if (Test-Path -LiteralPath $moved) { Move-Item -LiteralPath $moved -Destination $skill }
        }

        if ($doctor.Output -notmatch "no tlc-exec hook[^\r\n]*; run: tazuna setup") { return "the missing hook does not end in 'run: tazuna setup'" }
        if ($doctor.Output -notmatch "skill harness-eval is missing; run: tazuna setup") { return "the missing skill does not end in 'run: tazuna setup'" }
        return $true
    }

    Start-Section "Release"

    # The release version, read from the manifest.

    $releaseVersion = (Get-HarnessManifest).Version

    Test-Case -Name "V1 the changelog's newest section is the manifest version" -Check {
        $changelog = [System.IO.File]::ReadAllText((Join-Path $repoRoot "CHANGELOG.md"))
        $sections = @([regex]::Matches($changelog, '(?m)^## (.+?)\s*$') | ForEach-Object { $_.Groups[1].Value })
        if ((@($sections).Count -eq 0) -or ($sections[0] -ne $releaseVersion)) { return ("sections: " + ($sections -join " | ") + "; manifest: $releaseVersion") }
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

    Test-Case -Name "V7 bin/tazuna.cmd is checked out with CRLF in every clone" -Check {
        $attributes = [System.IO.File]::ReadAllText((Join-Path $repoRoot ".gitattributes"))
        if ($attributes -notmatch '(?m)^\*\.cmd text eol=crlf\s*$') { return ".gitattributes has no '*.cmd text eol=crlf' line" }
        $eol = (Invoke-GitCommand -RepositoryPath $repoRoot -Arguments @("check-attr", "eol", "--", "bin/tazuna.cmd")).Text.Trim()
        if ($eol -ne "bin/tazuna.cmd: eol: crlf") { return "git check-attr says: $eol" }
        return $true
    }

    Test-Case -Name "V9 doctor and setup point the user at tazuna commands, not repository scripts" -Check {
        $doctor = [System.IO.File]::ReadAllText((Join-Path $scriptsRoot "health-check.ps1"))
        if ($doctor.Contains('.\scripts\install')) { return "health-check.ps1 still suggests a .\scripts\install path" }
        $setup = [System.IO.File]::ReadAllText((Join-Path $scriptsRoot "bootstrap.ps1"))
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

}
finally {
    Clear-ScratchRoot
}

Complete-TestFile
