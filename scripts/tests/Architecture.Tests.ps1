[CmdletBinding()]
param([switch]$SkipSlow, [string]$Only)

. (Join-Path $PSScriptRoot "TestKit.ps1")

try {

    Start-Section "Architecture"

    $libDirectory = Join-Path $scriptsRoot "lib"

    function Get-CalledCommand {
        # why: the syntax tree, not text or tokens - a name in a comment is not a call, and a call
        # inside "$(...)" is one, which the tokenizer reports as a plain string.
        param([string]$Text)
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
        return @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Select-Object -Unique)
    }

    function Get-ImportedLibModule {
        # Library areas a script imports: string constants ending in lib\<Area>.psm1.
        param([string]$Text)
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
        $found = @()
        foreach ($node in @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true))) {
            $match = [regex]::Match($node.Value, '(?:^|[\\/])lib[\\/](\w+)\.psm1$')
            if ($match.Success) { $found += $match.Groups[1].Value }
        }
        return @($found | Select-Object -Unique)
    }

    function Get-LibExport {
        # Area -> exported function names, as PowerShell itself loads each module.
        $exports = @{}
        foreach ($file in @(Get-ChildItem -LiteralPath $libDirectory -Filter *.psm1 -File)) {
            $module = Import-Module $file.FullName -Force -PassThru -DisableNameChecking
            $exports[$file.BaseName] = @($module.ExportedFunctions.Keys)
        }
        return $exports
    }

    function Find-UnusedImport {
        param([string]$Name, [string]$Text, [hashtable]$Exports)
        $called = Get-CalledCommand -Text $Text
        $unused = @()
        foreach ($area in (Get-ImportedLibModule -Text $Text)) {
            if (-not $Exports.ContainsKey($area)) { $unused += "$Name imports lib\$area.psm1, which does not exist"; continue }
            if (-not @($Exports[$area] | Where-Object { $called -contains $_ })) { $unused += "$Name imports $area without calling it" }
        }
        return $unused
    }

    function Find-MissingImport {
        param([string]$Name, [string]$Text, [hashtable]$Exports)
        $called = Get-CalledCommand -Text $Text
        $imported = Get-ImportedLibModule -Text $Text
        $missing = @()
        foreach ($area in $Exports.Keys) {
            if ($imported -contains $area) { continue }
            foreach ($function in @($Exports[$area] | Where-Object { $called -contains $_ })) { $missing += "$Name calls $function without importing $area" }
        }
        return $missing
    }

    function Get-ConsumerScript {
        return @(@(Get-ChildItem -LiteralPath $scriptsRoot -Filter *.ps1 -File) + @(Get-Item -LiteralPath (Join-Path $repoRoot "tazuna.ps1")))
    }

    Test-Case -Name "A1 scripts/lib holds exactly the eight library modules" -Check {
        $expected = @("Console.psm1", "Cursor.psm1", "Files.psm1", "Git.psm1", "Json.psm1", "Manifest.psm1", "Paths.psm1", "Toolchain.psm1")
        if (-not (Test-Path -LiteralPath $libDirectory)) { return "scripts\lib does not exist" }
        $found = @(Get-ChildItem -LiteralPath $libDirectory -File | ForEach-Object { $_.Name } | Sort-Object)
        if (($found -join ",") -ne ($expected -join ",")) { return ("scripts\lib holds: " + ($found -join ", ")) }
        return $true
    }

    Test-Case -Name "A2 each of the 20 moved functions is exported by exactly one library module" -Check {
        $moved = @("Get-ClaudeConfigDir", "Get-ClaudeStateFile", "Resolve-HarnessPath", "Get-CompatibleRelativePath", "New-HarnessBackupRoot",
            "Get-FileSha256", "Test-FileContentEqual", "Copy-FileIfChanged", "Set-Utf8Content",
            "Test-JsonFile", "Get-JsonCanonicalForm", "Test-JsonContentEqual",
            "Get-StatusColour", "Write-Status", "Write-Section", "Write-Banner",
            "Invoke-GitCommand", "Get-GitRoot", "Get-GitStatusSummary",
            "Get-HarnessManifest")
        if ($moved.Count -ne 20) { return "the test lists $($moved.Count) names" }
        $exports = Get-LibExport
        foreach ($function in $moved) {
            $owners = @($exports.Keys | Where-Object { $exports[$_] -contains $function })
            if ($owners.Count -ne 1) { return "$function is exported by $($owners.Count) module(s): $($owners -join ', ')" }
        }
        return $true
    }

    Test-Case -Name "A3 the old common module is gone and nothing outside .specs names it" -Check {
        # Assembled, so this file does not report itself.
        $name = "Harness" + "Common"
        if (Test-Path -LiteralPath (Join-Path $scriptsRoot ($name + ".psm1"))) { return "scripts\$name.psm1 still exists" }
        $hits = @()
        foreach ($file in (Get-RepoFile)) {
            $relative = Get-CompatibleRelativePath -BasePath $repoRoot -TargetPath $file.FullName
            if ($relative.StartsWith(".specs\")) { continue }
            if ($file.Name -eq ($name + ".psm1")) { $hits += $relative; continue }
            if ([System.IO.File]::ReadAllText($file.FullName).Contains($name)) { $hits += $relative }
        }
        if ($hits.Count -gt 0) { return ("still named in: " + ($hits -join ", ")) }
        return $true
    }

    Test-Case -Name "A4 no library module imports another module, and a planted import is reported" -Check {
        if (@(Get-CalledCommand -Text "Import-Module (Join-Path `$PSScriptRoot 'Other.psm1')") -notcontains "Import-Module") { return "the scanner missed a planted Import-Module" }
        $offenders = @(Get-ChildItem -LiteralPath $libDirectory -Filter *.psm1 -File | Where-Object {
                (Get-CalledCommand -Text ([System.IO.File]::ReadAllText($_.FullName))) -contains "Import-Module" } | ForEach-Object { $_.Name })
        if ($offenders.Count -gt 0) { return ("imports a module: " + ($offenders -join ", ")) }
        return $true
    }

    Test-Case -Name "A5 only Console.psm1 writes to the host, and a planted Write-Host is reported" -Check {
        if (@(Get-CalledCommand -Text "function Get-X { Write-Host 'x' }") -notcontains "Write-Host") { return "the scanner missed a planted Write-Host" }
        $offenders = @(Get-ChildItem -LiteralPath $libDirectory -Filter *.psm1 -File | Where-Object {
                ($_.Name -ne "Console.psm1") -and ((Get-CalledCommand -Text ([System.IO.File]::ReadAllText($_.FullName))) -contains "Write-Host") } | ForEach-Object { $_.Name })
        if ($offenders.Count -gt 0) { return ("writes to the host: " + ($offenders -join ", ")) }
        return $true
    }

    Test-Case -Name "A6 every library import is used by its script, and a planted unused import is reported" -Check {
        $exports = Get-LibExport
        $planted = @(Find-UnusedImport -Name "planted" -Exports $exports -Text "Import-Module (Join-Path `$PSScriptRoot `"lib\Git.psm1`") -Force`nWrite-Output 1")
        if ($planted -notcontains "planted imports Git without calling it") { return ("the planted unused import was reported as: " + ($planted -join "; ")) }
        $scripts = Get-ConsumerScript
        if ($scripts.Count -ne 12) { return "scanned $($scripts.Count) scripts, expected 12" }
        $violations = @()
        foreach ($script in $scripts) { $violations += @(Find-UnusedImport -Name $script.Name -Exports $exports -Text ([System.IO.File]::ReadAllText($script.FullName))) }
        if ($violations.Count -gt 0) { return ($violations -join "; ") }
        return $true
    }

    Test-Case -Name "A7 every library call has its module imported by the same script, and a planted missing import is reported" -Check {
        $exports = Get-LibExport
        $planted = @(Find-MissingImport -Name "planted" -Exports $exports -Text "Write-Status -Label OK -Detail x")
        if ($planted -notcontains "planted calls Write-Status without importing Console") { return ("the planted missing import was reported as: " + ($planted -join "; ")) }
        $scripts = Get-ConsumerScript
        if ($scripts.Count -ne 12) { return "scanned $($scripts.Count) scripts, expected 12" }
        $violations = @()
        foreach ($script in $scripts) { $violations += @(Find-MissingImport -Name $script.Name -Exports $exports -Text ([System.IO.File]::ReadAllText($script.FullName))) }
        if ($violations.Count -gt 0) { return ($violations -join "; ") }
        return $true
    }

    Test-Case -Name "A8 no template references scripts/lib, and a planted reference is reported" -Check {
        $scan = { param([string]$Text) $Text.Contains("scripts/lib") -or $Text.Contains("scripts\lib") }
        if (-not (& $scan "Import-Module ..\..\scripts\lib\Paths.psm1")) { return "the scanner missed a planted reference" }
        $templates = Join-Path $repoRoot "templates"
        $hits = @(Get-RepoFile | Where-Object { $_.FullName.StartsWith($templates + "\") } |
            Where-Object { & $scan ([System.IO.File]::ReadAllText($_.FullName)) } | ForEach-Object { $_.FullName })
        if ($hits.Count -gt 0) { return ("references scripts/lib: " + ($hits -join ", ")) }
        return $true
    }

    Test-Case -Name "A9 the manifest pins node 24 and Claude Code 2.1.296 as minimums" -Check {
        $pins = Get-HarnessManifest
        if ($pins.MinimumNodeMajor -ne 24) { return "MinimumNodeMajor is '$($pins.MinimumNodeMajor)'" }
        if ($pins.MinimumClaudeVersion -ne "2.1.296") { return "MinimumClaudeVersion is '$($pins.MinimumClaudeVersion)'" }
        return $true
    }

    Test-Case -Name "A10 bootstrap and health-check read the node version only through Get-NodeMajorVersion" -Check {
        foreach ($name in @("bootstrap.ps1", "health-check.ps1")) {
            $text = [System.IO.File]::ReadAllText((Join-Path $scriptsRoot $name))
            if ($text.Contains("node --version")) { return "$name still runs node --version itself" }
            if ((Get-CalledCommand -Text $text) -notcontains "Get-NodeMajorVersion") { return "$name does not call Get-NodeMajorVersion" }
        }
        return $true
    }

    Test-Case -Name "A11 health-check holds no literal Claude Code minimum" -Check {
        if ([System.IO.File]::ReadAllText((Join-Path $scriptsRoot "health-check.ps1")).Contains("2.1.296")) { return "health-check.ps1 holds the literal 2.1.296" }
        return $true
    }

    Test-Case -Name "A12 node v23.0.0 stops setup with exit 1 before anything is written" -Check {
        $run = Invoke-WithStubs -Root (New-ScratchRoot) -Script (Join-Path $scriptsRoot "bootstrap.ps1") -Environment @{ HARNESS_STUB_NODE = "v23.0.0" }
        if ($run.Code -ne 1) { return "exit $($run.Code), expected 1" }
        if ($run.Output -notmatch "node 24\+ required") { return "no 'node 24+ required'" }
        if (Test-Path -LiteralPath $run.Config) { return "the configuration directory was created" }
        return $true
    }

    Test-Case -Name "A14 AGENTS.md states the scripts/lib rules in Where things go" -Check {
        $agents = [System.IO.File]::ReadAllText((Join-Path $repoRoot "AGENTS.md"))
        $section = [regex]::Match($agents, '(?s)## Where things go\s*(.*?)(?=\n## |\z)')
        if (-not $section.Success) { return "no '## Where things go' section" }
        $row = @($section.Groups[1].Value -split "`n" | Where-Object { $_.StartsWith("|") -and $_.Contains("scripts/lib/") }) | Select-Object -First 1
        if (-not $row) { return "no table row names scripts/lib/" }
        foreach ($token in @("Import-Module", "Write-Host", "import")) {
            if (-not $row.Contains($token)) { return "the scripts/lib/ row does not say '$token'" }
        }
        return $true
    }
}
finally {
    Clear-ScratchRoot
}

Complete-TestFile
