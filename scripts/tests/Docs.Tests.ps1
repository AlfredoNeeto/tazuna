[CmdletBinding()]
param([switch]$SkipSlow, [string]$Only)

. (Join-Path $PSScriptRoot "TestKit.ps1")

try {

    Start-Section "README"

    # S4 - README

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
            if ($relative -eq "scripts/tests/Docs.Tests.ps1") { continue }
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
        if ($manifest.ToolkitPackage -ne "@tech-leads-club/harness-toolkit@0.16.3") { return "toolkit package is $($manifest.ToolkitPackage)" }
        if ($manifest.AgentSkills -notcontains "harness-eval") { return "harness-eval is not in the skills list" }
        $bootstrap = Get-Content -LiteralPath (Join-Path $scriptsRoot "bootstrap.ps1") -Raw
        if (-not $bootstrap.Contains('@("harness", "install")')) { return "bootstrap no longer runs tlc harness install" }
        foreach ($name in @("harness-toolkit", "tlc harness install", "harness-eval", ".tlc/harness/state/")) {
            if (-not $readme.Contains($name)) { return "the README no longer names $name" }
        }
        return $true
    }

    Start-Section "Release"

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

    Test-Case -Name "V12 the README prerequisites list python3" -Check {
        $section = [regex]::Match($readme, '(?s)\n### Prerequisites[ \t]*\r?\n(.*?)(?=\n##)')
        if (-not $section.Success) { return "no '### Prerequisites' subsection" }
        $first = @($section.Groups[1].Value -split "`n" | Where-Object { $_.StartsWith("|") } | ForEach-Object { ($_ -split "\|")[1].Trim() })
        if ($first -notcontains '`python3`') { return ("first cells: " + ($first -join ", ")) }
        return $true
    }
}
finally {
    Clear-ScratchRoot
}

Complete-TestFile
