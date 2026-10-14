[CmdletBinding()]
param([switch]$SkipSlow, [string]$Only)

. (Join-Path $PSScriptRoot "TestKit.ps1")

try {

    Start-Section "Command line"

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
        if (-not $run.Output.Contains("Moves a project off Tazuna 1.x's verification gate and hands it to harness-toolkit.")) { return "no synopsis: $($run.Output)" }
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
            $run = Invoke-WithStubs -Root $root -Script (Join-Path $scriptsRoot $pair[0]) -Arguments $arguments
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
            $changed = Invoke-WithStubs -Root $installed.Root -Script (Join-Path $scriptsRoot "bootstrap.ps1") -Arguments @("-WhatIf")
        }
        finally {
            [System.IO.File]::WriteAllText($claudeMd, $original)
        }
        $runs += @{ Name = "setup -WhatIf over a changed CLAUDE.md"; Output = $changed.Output; Expect = @("would update CLAUDE\.md") }

        $legacy = New-InitProject -Files @{ ".claude\hooks\require-verification.ps1" = "exit 0"; ".gitignore" = ".claude/state/`n" } -Arguments @("-WhatIf")
        if (-not (Test-Path -LiteralPath (Join-Path $legacy.Project ".claude\hooks\require-verification.ps1"))) { return "init -WhatIf removed the hook" }
        $runs += @{ Name = "init -WhatIf on a 1.x project"; Output = $legacy.Output; Expect = @("would remove \.claude\\hooks\\require-verification\.ps1", "would remove \.claude/state/ from \.gitignore") }

        foreach ($run in $runs) {
            $bad = @([regex]::Matches($run.Output, $forbidden) | ForEach-Object { $_.Value.Trim() })
            if ($bad.Count -gt 0) { return ("{0} printed: {1}" -f $run.Name, ($bad -join ", ")) }
            foreach ($expected in $run.Expect) {
                if ($run.Output -notmatch ('(?m)^WHATIF\s+' + $expected)) { return ("{0} has no 'WHATIF {1}'" -f $run.Name, $expected) }
            }
        }
        return $true
    }

    Test-Case -Name "X13 a healthy setup ends with Harness installed, the elapsed time, /harness-init and tazuna init" -Check {
        $run = Get-SetupRun -Key "fresh"
        if ($run.Code -ne 0) { return "exit $($run.Code)" }
        $done = [regex]::Match($run.Output, 'Harness installed in \d+s')
        if (-not $done.Success) { return "no 'Harness installed in <n>s'" }
        foreach ($next in @("/harness-init", "tazuna init")) {
            if ($run.Output.IndexOf($next, $done.Index) -lt 0) { return "no '$next' after the summary" }
        }
        return $true
    }

    Test-Case -Name "X14 setup prints the PATH line only when the calling shell lacks bin" -Check {
        $bin = Join-Path $repoRoot "bin"
        $line = '$env:Path += ";' + $bin + '"'

        $without = Invoke-WithStubs -Root (New-ScratchRoot) -Script (Join-Path $scriptsRoot "bootstrap.ps1") -Arguments @("-SkipMcp") -DropPathContaining @("tazuna.cmd")
        if ($without.Code -ne 0) { return "setup without bin exited $($without.Code)" }
        if (-not $without.Output.Contains($line)) { return "no '$line' when bin is not on PATH" }

        $root = New-ScratchRoot
        $withPath = (Join-Path $root "stub-bin") + ";" + $bin + ";" + $env:PATH
        $with = Invoke-WithStubs -Root $root -Script (Join-Path $scriptsRoot "bootstrap.ps1") -Arguments @("-SkipMcp") -Environment @{ PATH = $withPath }
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

    Test-Case -Name "LK1 rich setup draws the mascot as 16 lines of 24-bit half blocks beside the title, tagline and paths" -Check {
        $sprite = Join-Path $repoRoot "docs\assets\tazuna\src\icon-32.txt"
        $saved = $env:NO_COLOR

        try {
            $env:NO_COLOR = $null
            $records = Use-RichConsole -Rich $true -Block {
                @(Write-Banner -Title "Tazuna $version" -Command "setup" -Tagline "No turn ends on untested code." -Details @("  Repository:    x") -Sprite $sprite 6>&1)
            }
        }
        finally {
            $env:NO_COLOR = $saved
        }

        $messages = @($records | ForEach-Object { $_.MessageData.Message })
        $art = @($messages | Where-Object { $_.Contains([string][char]27 + "[38;2;") })
        if ($art.Count -ne 16) { return "$($art.Count) lines of 24-bit art, expected 16 (32 sprite rows, two per line)" }
        if (-not $art[0].Contains([string][char]0x2580)) { return "the art does not use half blocks" }
        foreach ($text in @(("Tazuna $version " + [char]0x00B7 + " setup"), "No turn ends on untested code.", "Repository:    x")) {
            if (@($messages | Where-Object { $_.Contains($text) }).Count -eq 0) { return "the banner does not show '$text'" }
        }

        $run = Invoke-HostCapture -Root (New-ScratchRoot) -Script (Join-Path $scriptsRoot "bootstrap.ps1") -Arguments @("-WhatIf") `
            -Environment @{ WT_SESSION = "self-test"; TAZUNA_PLAIN = $null; NO_COLOR = $null } -OwnConsole
        if ($run.Code -ne 0) { return "rich setup exited $($run.Code): $($run.Output)" }
        if (-not $run.Output.Contains([string][char]27 + "[38;2;")) { return "rich setup drew no art" }
        # why: a long scratch path wraps at the console width, so the line is matched by its start.
        if (-not $run.Output.Contains("Repository:    ")) { return "rich setup does not show the repository" }
        return $true
    }
    Test-Case -Name "LK2 NO_COLOR and plain output draw no 24-bit art, and plain keeps the title, the rule and the path lines as they were" -Check {
        $noColour = Invoke-HostCapture -Root (New-ScratchRoot) -Script (Join-Path $scriptsRoot "bootstrap.ps1") -Arguments @("-WhatIf") `
            -Environment @{ WT_SESSION = "self-test"; TAZUNA_PLAIN = $null; NO_COLOR = "1" } -OwnConsole
        if ($noColour.Output.Contains([string][char]27 + "[38;2;")) { return "NO_COLOR still drew 24-bit colour" }

        $plain = Invoke-HostCapture -Root (New-ScratchRoot) -Script (Join-Path $scriptsRoot "bootstrap.ps1") -Arguments @("-WhatIf") `
            -Environment @{ WT_SESSION = "self-test"; TAZUNA_PLAIN = "1"; NO_COLOR = $null } -OwnConsole
        $title = "Tazuna $version - setup"
        $expected = @($title, ("=" * $title.Length), "  Repository:    ") -join "`r`n"
        if (-not $plain.Output.Contains($expected)) { return ("plain setup no longer opens with: " + $expected) }
        if ($plain.Output.Contains([string][char]27)) { return "plain setup wrote an escape sequence" }
        return $true
    }

    Test-Case -Name "LK3 a step header is a bar of three cells per step, done ones heavy, in rich output, and [i/n] over a rule in plain" -Check {
        $rich = Use-RichConsole -Rich $true -Block { (Get-HostText { Write-StepHeader -Index 2 -Count 5 -Title "Plugins" }).Text }
        $expected = ([string][char]0x2501 * 6) + ([string][char]0x2500 * 9) + "  2/5  Plugins"
        if ($rich -cne $expected) { return "rich: '$rich', expected '$expected'" }

        $plain = Use-RichConsole -Rich $false -Block { (Get-HostText { Write-StepHeader -Index 2 -Count 5 -Title "Plugins" }).Text }
        if ($plain -cne ("[2/5] Plugins" + ("-" * 13))) { return "plain: '$plain'" }
        return $true
    }

    Test-Case -Name "LK4 a panel is a rounded box whose rows share one width" -Check {
        $text = Use-RichConsole -Rich $true -Block { (Get-HostText { Write-Panel -Lines @("a", "", "longer line") }).Text }
        $side = [string][char]0x2502
        foreach ($piece in @(
                ("  " + [char]0x256D + ([string][char]0x2500 * 15) + [char]0x256E),
                ("  $side  " + "a".PadRight(11) + "  $side"),
                ("  $side  " + "".PadRight(11) + "  $side"),
                ("  $side  " + "longer line" + "  $side"),
                ("  " + [char]0x2570 + ([string][char]0x2500 * 15) + [char]0x256F))) {
            if (-not $text.Contains($piece)) { return "missing '$piece' in '$text'" }
        }
        return $true
    }

    Test-Case -Name "LK5 the sprite reader keeps upper- and lower-case palette characters apart and reads . as transparent" -Check {
        $source = Join-Path $repoRoot "docs\assets\tazuna\src\icon-32.txt"
        $grid = Get-SpritePixels -Path $source
        $rows = @([System.IO.File]::ReadAllLines($source) | Select-Object -Skip ([array]::IndexOf([System.IO.File]::ReadAllLines($source), "---") + 1))
        if ($grid.Count -ne 32) { return "$($grid.Count) rows, expected 32" }

        $upper = $rows[3].IndexOf("K"); $lower = $rows[3].IndexOf("k"); $clear = $rows[3].IndexOf(".")
        if ($grid[3][$upper] -ne "#0c0809") { return "K read as $($grid[3][$upper])" }
        if ($grid[3][$lower] -ne "#1c1419") { return "k read as $($grid[3][$lower]), the colour of K is $($grid[3][$upper])" }
        if ($null -ne $grid[3][$clear]) { return ". read as $($grid[3][$clear])" }
        return $true
    }

    Test-Case -Name "LK6 a healthy rich setup ends on the panel; plain lines skipped prerequisites up in the label column" -Check {
        $rich = Invoke-HostCapture -Root (New-ScratchRoot) -Script (Join-Path $scriptsRoot "bootstrap.ps1") `
            -Environment @{ WT_SESSION = "self-test"; TAZUNA_PLAIN = $null; NO_COLOR = $null } -OwnConsole
        if ($rich.Code -ne 0) { return "rich setup exited $($rich.Code): $($rich.Output)" }
        foreach ($text in @(([string][char]0x256D), ("Tazuna $version - Harness installed in"), "/harness-init", "tazuna init")) {
            if (-not $rich.Output.Contains($text)) { return "the rich ending does not show '$text'" }
        }
        if ($rich.Output -match "DONE\s+Harness installed") { return "the rich ending still prints the plain DONE line" }

        $plain = Get-SetupRun -Key "fresh"
        if ($plain.Output -notmatch '(?m)^--\s{8}Cursor - .+ not found \(its steps are skipped\)') { return "the skipped Cursor line is not in the label column" }
        if ($plain.Output -match '(?m)^  --') { return "a skipped prerequisite is still indented by hand" }
        return $true
    }
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

        $run = Invoke-HostCapture -Root (New-ScratchRoot) -Script (Join-Path $scriptsRoot "bootstrap.ps1") -Arguments @("-WhatIf") `
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

        $piped = Invoke-HostCapture -Root (New-ScratchRoot) -Script (Join-Path $scriptsRoot "bootstrap.ps1") -Environment @{ WT_SESSION = "self-test"; TAZUNA_PLAIN = $null }
        if ($piped.Code -ne 0) { return "piped setup exited $($piped.Code): $($piped.Output)" }
        $found = Get-NonAscii -Text $piped.Output
        if ($found.Count -gt 0) { return ("piped setup wrote: " + ($found -join " ")) }

        $conhost = Invoke-HostCapture -Root (New-ScratchRoot) -Script (Join-Path $scriptsRoot "bootstrap.ps1") -Arguments @("-WhatIf") `
            -Environment @{ WT_SESSION = $null; TAZUNA_PLAIN = $null } -OwnConsole
        if ($conhost.Code -ne 0) { return "setup outside Windows Terminal exited $($conhost.Code)" }
        if (-not $conhost.Output.Contains("Tazuna $version - setup")) { return "the console run printed nothing recognisable" }
        $found = Get-NonAscii -Text $conhost.Output
        if ($found.Count -gt 0) { return ("setup outside Windows Terminal wrote: " + ($found -join " ")) }
        return $true
    }

    Test-Case -Name "X19 TAZUNA_PLAIN=1 keeps Windows Terminal output ASCII" -Check {
        $run = Invoke-HostCapture -Root (New-ScratchRoot) -Script (Join-Path $scriptsRoot "bootstrap.ps1") -Arguments @("-WhatIf") `
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
            $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptsRoot $entry.Groups[2].Value), [ref]$null, [ref]$null)
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
}
finally {
    Clear-ScratchRoot
}

Complete-TestFile
