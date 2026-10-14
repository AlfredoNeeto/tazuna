[CmdletBinding()]
param([switch]$SkipSlow, [string]$Only)

. (Join-Path $PSScriptRoot "TestKit.ps1")

Start-Section "Installer"

$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-selftest-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$previousConfigDir = $env:CLAUDE_CONFIG_DIR

try {
    $env:CLAUDE_CONFIG_DIR = $scratch

    Test-Case -Name "install -WhatIf writes nothing" -Check {

        & (Join-Path $scriptsRoot "install.ps1") -WhatIf 6>$null | Out-Null

        if (-not (Test-Path -LiteralPath $scratch)) { return $true }
        return "the configuration directory was created during a dry run"
    }

    Test-Case -Name "install creates the harness" -Check {

        & (Join-Path $scriptsRoot "install.ps1") 6>$null | Out-Null

        $missing = @()

        foreach ($required in @("CLAUDE.md", "settings.json")) {
            if (-not (Test-Path -LiteralPath (Join-Path $scratch $required))) {
                $missing += $required
            }
        }

        if ($missing.Count -eq 0) { return $true }
        return ("missing after install: " + ($missing -join ", "))
    }

    Test-Case -Name "install is idempotent" -Check {

        $output = & (Join-Path $scriptsRoot "install.ps1") 6>&1 | Out-String

        # Match the summary counts, not the status labels: the word "Installed:"
        # in the summary line contains "INSTALL" and made this check vacuous.
        $summary = [regex]::Match($output, "Installed:\s*(\d+) created,\s*(\d+) updated")

        if (-not $summary.Success) { return "could not read the installer summary" }
        if ($summary.Groups[1].Value -ne "0") { return "a second run created $($summary.Groups[1].Value) file(s)" }
        if ($summary.Groups[2].Value -ne "0") { return "a second run updated $($summary.Groups[2].Value) file(s)" }
        if (Test-Path -LiteralPath (Join-Path $scratch ".harness-backup")) { return "a backup was taken with nothing to overwrite" }

        return $true
    }

    Test-Case -Name "ST1 install merges settings.json: shipped keys win, the toolkit hooks and the user's keys stay, an equal file is left alone" -Check {
        # why: under -Only no earlier case has installed anything yet.
        & (Join-Path $scriptsRoot "install.ps1") 6>$null | Out-Null
        $settingsPath = Join-Path $scratch "settings.json"
        $live = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        Add-Member -InputObject $live -MemberType NoteProperty -Name "hooks" -Value ([PSCustomObject]@{ Stop = @([PSCustomObject]@{ hooks = @([PSCustomObject]@{ type = "command"; command = "node tlc-exec.mjs stop" }) }) })
        Add-Member -InputObject $live -MemberType NoteProperty -Name "modelSettings" -Value ([PSCustomObject]@{ kept = $true })
        $live.permissions = [PSCustomObject]@{ allow = @("Bash(curl:*)") }
        # why: a key Tazuna ships that the live file lacks must be added, not only replaced where present.
        $live.PSObject.Properties.Remove("disableClaudeAiConnectors")
        [System.IO.File]::WriteAllText($settingsPath, ($live | ConvertTo-Json -Depth 20))

        $output = & (Join-Path $scriptsRoot "install.ps1") 6>&1 | Out-String
        $merged = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        $shipped = Get-Content -LiteralPath (Join-Path $repoRoot "user\settings.json") -Raw | ConvertFrom-Json

        if (-not $merged.PSObject.Properties["hooks"]) { return "the toolkit's hooks were dropped" }
        if (-not $merged.PSObject.Properties["modelSettings"]) { return "the user's modelSettings was dropped" }
        if ((Get-JsonCanonicalForm -Value $merged.permissions) -ne (Get-JsonCanonicalForm -Value $shipped.permissions)) { return "the shipped permissions did not replace the live ones" }
        if ((-not $merged.PSObject.Properties["disableClaudeAiConnectors"]) -or ($merged.disableClaudeAiConnectors -ne $shipped.disableClaudeAiConnectors)) { return "a shipped key missing from the live file was not added" }
        if ($output -notmatch "UPDATE\s+settings\.json") { return ("the changed file was not reported UPDATE: " + $output) }

        # why: the toolkit rewrites the file in its own layout; the same content must not count as a change.
        [System.IO.File]::WriteAllText($settingsPath, ($merged | ConvertTo-Json -Depth 20 -Compress))
        $backupsBefore = @(Get-ChildItem -LiteralPath (Join-Path $scratch ".harness-backup") -Recurse -Filter "settings.json" -ErrorAction SilentlyContinue).Count

        $again = & (Join-Path $scriptsRoot "install.ps1") 6>&1 | Out-String

        if ($again -notmatch "UNCHANGED\s+settings\.json") { return ("an equal settings.json was not reported UNCHANGED: " + $again) }
        $backupsAfter = @(Get-ChildItem -LiteralPath (Join-Path $scratch ".harness-backup") -Recurse -Filter "settings.json" -ErrorAction SilentlyContinue).Count
        if ($backupsAfter -ne $backupsBefore) { return "an equal settings.json was backed up again" }
        return $true
    }

    Test-Case -Name "ST2 install stops and writes nothing when the live settings.json does not parse" -Check {
        & (Join-Path $scriptsRoot "install.ps1") 6>$null | Out-Null
        $settingsPath = Join-Path $scratch "settings.json"
        $claudeMd = Join-Path $scratch "CLAUDE.md"
        $settingsBefore = [System.IO.File]::ReadAllText($settingsPath)
        $claudeBefore = [System.IO.File]::ReadAllText($claudeMd)

        # why: a removed CLAUDE.md that comes back would prove the install wrote something.
        Remove-Item -LiteralPath $claudeMd -Force
        [System.IO.File]::WriteAllText($settingsPath, "{ not json")

        try {
            $previous = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            $global:LASTEXITCODE = 0
            $output = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsRoot "install.ps1") 2>&1 | Out-String)
            $code = $LASTEXITCODE
            $ErrorActionPreference = $previous

            if ($code -ne 1) { return "exit $code, expected 1" }
            if ([System.IO.File]::ReadAllText($settingsPath) -ne "{ not json") { return "the unreadable settings.json was overwritten" }
            if (Test-Path -LiteralPath $claudeMd) { return "CLAUDE.md was installed although setup stopped" }
            if ($output -notmatch "not valid JSON") { return ("no reason given: " + $output) }
            return $true
        }
        finally {
            [System.IO.File]::WriteAllText($settingsPath, $settingsBefore)
            [System.IO.File]::WriteAllText($claudeMd, $claudeBefore)
        }
    }
    Test-Case -Name "install backs up before overwriting" -Check {

        $claudeMd = Join-Path $scratch "CLAUDE.md"
        Set-Content -LiteralPath $claudeMd -Value "LOCAL EDIT" -NoNewline

        & (Join-Path $scriptsRoot "install.ps1") 6>$null | Out-Null

        $backup = Get-ChildItem -LiteralPath (Join-Path $scratch ".harness-backup") -Recurse -Filter "CLAUDE.md" -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if (-not $backup) { return "no backup was written" }
        if ((Get-Content -LiteralPath $backup.FullName -Raw).Trim() -ne "LOCAL EDIT") { return "the backup does not hold the replaced content" }

        return $true
    }

    Test-Case -Name "V5 install leaves skills and agents it does not ship where they are" -Check {

        # why: 1.0.0 has no earlier public version to retire, so anything user/ does not ship is the user's own.
        $theirs = @("skills\remember\SKILL.md", "agents\planner.md")
        foreach ($relative in $theirs) {
            $path = Join-Path $scratch $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            Set-Content -LiteralPath $path -Value "---`ndescription: written by the user`n---`n"
        }
        $before = @{}
        foreach ($relative in $theirs) { $before[$relative] = [System.IO.File]::ReadAllText((Join-Path $scratch $relative)) }

        $output = & (Join-Path $scriptsRoot "install.ps1") 6>&1 | Out-String

        foreach ($relative in $theirs) {
            $path = Join-Path $scratch $relative
            if (-not (Test-Path -LiteralPath $path)) { return "$relative was moved" }
            if ([System.IO.File]::ReadAllText($path) -ne $before[$relative]) { return "$relative was changed" }
            $backup = @(Get-ChildItem -LiteralPath (Join-Path $scratch ".harness-backup") -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName.EndsWith("\" + $relative) })
            if ($backup.Count -gt 0) { return "$relative was copied into the backup" }
        }
        if ($output -match "RETIRED|KEPT") { return "install still reports a retirement" }

        $source = [System.IO.File]::ReadAllText((Join-Path $scriptsRoot "install.ps1"))
        foreach ($token in @("Get-RetiredInstall", "RETIRED")) {
            if ($source.Contains($token)) { return "install.ps1 still holds $token" }
        }
        $manifest = Import-Module (Join-Path $scriptsRoot "lib\Manifest.psm1") -Force -PassThru
        $exported = @($manifest.ExportedFunctions.Keys | Sort-Object)
        if (($exported -join ",") -ne "Get-HarnessManifest") { return ("Manifest.psm1 exports: " + ($exported -join ", ")) }
        return $true
    }

    function Invoke-InstallOutput {
        # why: Write-Status writes to the console, which 6>&1 does not capture in this process; a child's output can be read.
        param([string[]]$Arguments = @())
        return (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsRoot "install.ps1") @Arguments 2>&1 | Out-String)
    }

    function Add-RecordedFile {
        # Plants a file as an earlier version would have installed it: on disk, and in the record with the hash it was written with.
        param([string]$Relative, [string]$Written, [string]$OnDisk)
        $path = Join-Path $scratch $Relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        Set-Utf8Content -Path $path -Value $Written
        $hash = Get-FileSha256 -Path $path
        if ($OnDisk) { Set-Utf8Content -Path $path -Value $OnDisk }
        $recordFile = Join-Path $scratch ".tazuna-installed.json"
        $record = Get-Content -LiteralPath $recordFile -Raw | ConvertFrom-Json
        Add-Member -InputObject $record.files -NotePropertyName $Relative -NotePropertyValue $hash -Force
        Set-Utf8Content -Path $recordFile -Value ($record | ConvertTo-Json -Depth 5)
    }

    Test-Case -Name "RM1 install records what it wrote, removes a recorded file it no longer ships with a backup, and a second run removes nothing" -Check {

        & (Join-Path $scriptsRoot "install.ps1") 6>$null | Out-Null
        $record = Get-Content -LiteralPath (Join-Path $scratch ".tazuna-installed.json") -Raw | ConvertFrom-Json
        $recorded = @($record.files.PSObject.Properties.Name)
        if ($recorded -contains "settings.json") { return "the record lists the merged settings.json" }
        if ($recorded -notcontains "CLAUDE.md") { return ("the record lists: " + ($recorded -join ", ")) }
        if ($record.files."CLAUDE.md" -ne (Get-FileSha256 -Path (Join-Path $scratch "CLAUDE.md"))) { return "the recorded hash of CLAUDE.md is not the installed file's" }

        Add-RecordedFile -Relative "skills\retired-skill\SKILL.md" -Written "---`ndescription: shipped once`n---`n"
        $output = Invoke-InstallOutput

        if (Test-Path -LiteralPath (Join-Path $scratch "skills\retired-skill")) { return "the retired skill or its folder is still there" }
        if ($output -notmatch "REMOVE\s+skills\\retired-skill\\SKILL\.md") { return ("no REMOVE line: " + $output) }
        $backup = @(Get-ChildItem -LiteralPath (Join-Path $scratch ".harness-backup") -Recurse -Filter "SKILL.md" | Where-Object { $_.FullName -match "retired-skill" })
        if ($backup.Count -eq 0) { return "the removed file was not backed up" }
        $after = (Get-Content -LiteralPath (Join-Path $scratch ".tazuna-installed.json") -Raw | ConvertFrom-Json).files.PSObject.Properties.Name
        if (@($after) -contains "skills\retired-skill\SKILL.md") { return "the record still lists the removed file" }

        $again = Invoke-InstallOutput
        if (($again -match "REMOVE\s") -or ($again -notmatch "0 removed")) { return ("a second run removed something: " + $again) }
        return $true
    }

    Test-Case -Name "RM2 a recorded file edited since it was installed is kept with a warning" -Check {

        & (Join-Path $scriptsRoot "install.ps1") 6>$null | Out-Null
        Add-RecordedFile -Relative "skills\edited-skill\SKILL.md" -Written "shipped" -OnDisk "edited by the user"
        $output = Invoke-InstallOutput

        $path = Join-Path $scratch "skills\edited-skill\SKILL.md"
        if (-not (Test-Path -LiteralPath $path)) { return "the edited file was removed" }
        if ([System.IO.File]::ReadAllText($path) -ne "edited by the user") { return "the edited file was changed" }
        if ($output -notmatch "WARN\s+kept skills\\edited-skill\\SKILL\.md") { return ("no WARN line: " + $output) }
        Remove-Item -LiteralPath (Join-Path $scratch "skills\edited-skill") -Recurse -Force
        return $true
    }

    Test-Case -Name "RM3 install -WhatIf names a removal and removes nothing" -Check {

        & (Join-Path $scriptsRoot "install.ps1") 6>$null | Out-Null
        Add-RecordedFile -Relative "agents\retired-agent.md" -Written "shipped once"
        $output = Invoke-InstallOutput -Arguments @("-WhatIf")

        if (-not (Test-Path -LiteralPath (Join-Path $scratch "agents\retired-agent.md"))) { return "-WhatIf removed the file" }
        if ($output -notmatch "would remove agents\\retired-agent\.md") { return ("no WHATIF line: " + $output) }
        & (Join-Path $scriptsRoot "install.ps1") 6>$null | Out-Null
        if (Test-Path -LiteralPath (Join-Path $scratch "agents\retired-agent.md")) { return "the real run after -WhatIf did not remove it" }
        return $true
    }

    Test-Case -Name "RM4 on a 1.x machine with no record, install removes fix-bug as 1.5.0 shipped it and keeps an edited one" -Check {

        $fixBug = Join-Path $scratch "skills\fix-bug\SKILL.md"
        $shipped = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "fixtures\1.5.0\fix-bug.SKILL.md")).Replace("`r`n", "`n")

        # why: a checkout's line endings follow core.autocrlf, so 1.x installed either form.
        foreach ($text in @($shipped, $shipped.Replace("`n", "`r`n"))) {
            Remove-Item -LiteralPath (Join-Path $scratch ".tazuna-installed.json") -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path (Split-Path -Parent $fixBug) -Force | Out-Null
            [System.IO.File]::WriteAllText($fixBug, $text)
            & (Join-Path $scriptsRoot "install.ps1") 6>$null | Out-Null
            if (Test-Path -LiteralPath (Split-Path -Parent $fixBug)) { return "fix-bug as 1.5.0 shipped it is still installed" }
        }

        New-Item -ItemType Directory -Path (Split-Path -Parent $fixBug) -Force | Out-Null
        [System.IO.File]::WriteAllText($fixBug, $shipped + "`nmy own note`n")
        $output = Invoke-InstallOutput
        if (-not (Test-Path -LiteralPath $fixBug)) { return "an edited fix-bug was removed" }
        if ($output -notmatch "WARN\s+kept skills\\fix-bug\\SKILL\.md") { return ("no WARN for the edited fix-bug: " + $output) }
        Remove-Item -LiteralPath (Split-Path -Parent $fixBug) -Recurse -Force
        return $true
    }

    Test-Case -Name "health-check reports an orphaned skill" -Check {

        # Drift is two-directional. install.ps1 copies but never removes, so a
        # skill deleted from the repository stays installed and active while a
        # one-directional check reports everything matching.
        & (Join-Path $scriptsRoot "install.ps1") 6>$null | Out-Null

        $orphan = Join-Path $scratch (Join-Path "skills" "selftest-orphan-probe")
        New-Item -ItemType Directory -Path $orphan -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $orphan "SKILL.md") -Value "---`ndescription: probe`n---`n" -NoNewline

        $output = & (Join-Path $scriptsRoot "health-check.ps1") 6>&1 | Out-String

        Remove-Item -LiteralPath $orphan -Recurse -Force -ErrorAction SilentlyContinue

        if ($output -match "selftest-orphan-probe") { return $true }
        return "an orphaned skill was not reported"
    }

    Test-Case -Name "health-check fails on invalid settings" -Check {

        Set-Content -LiteralPath (Join-Path $scratch "settings.json") -Value "{ not json" -NoNewline

        & (Join-Path $scriptsRoot "health-check.ps1") 6>$null | Out-Null

        if ($LASTEXITCODE -ne 0) { return $true }
        return "health-check passed with unparseable settings.json"
    }
}
finally {
    $env:CLAUDE_CONFIG_DIR = $previousConfigDir

    if (Test-Path -LiteralPath $scratch) {
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case -Name "health-check blames the missing runtime, not the network" -Check {

    # Reported from a second machine: serena registered fine with no uvx
    # installed, and the check said "network, or the service is down". That sent
    # someone to look at their connection for a server that had nothing to run.
    #
    # Reproduced by taking uv off PATH for this run only - surgically, so claude
    # and git stay reachable and the rest of the check still works.
    $catalogue = Get-Content -LiteralPath (Join-Path $repoRoot "mcp\servers.json") -Raw | ConvertFrom-Json

    $claude = Get-Command claude -ErrorAction SilentlyContinue

    if (-not $claude) { return "claude is not on PATH, so this cannot be probed" }

    $claudeDirectory = (Split-Path -Parent $claude.Source).TrimEnd("\")

    # Pick a server whose runtime does NOT live beside claude.exe. The first
    # version of this took uv off PATH, and uv shares a directory with claude
    # here - so the whole check degraded, every server reported "not registered"
    # and the case passed without ever reaching the branch it claims to test.
    $candidate = $null

    foreach ($property in $catalogue.mcpServers.PSObject.Properties) {

        if (-not $property.Value.command) { continue }

        $located = Get-Command $property.Value.command -ErrorAction SilentlyContinue

        if (-not $located) { continue }

        if ((Split-Path -Parent $located.Source).TrimEnd("\") -eq $claudeDirectory) { continue }

        $candidate = [PSCustomObject]@{
            Server    = $property.Name
            Command   = $property.Value.command
            Directory = (Split-Path -Parent $located.Source)
        }

        break
    }

    if (-not $candidate) {
        return "no catalogued stdio runtime could be hidden without also hiding claude"
    }

    $previousPath = $env:PATH

    try {

        $env:PATH = (($env:PATH -split ";") |
            Where-Object { $_ -and ($_.TrimEnd("\") -ne $candidate.Directory.TrimEnd("\")) }) -join ";"

        if (Get-Command $candidate.Command -ErrorAction SilentlyContinue) {
            return "could not take $($candidate.Command) off PATH, so this would prove nothing"
        }

        if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
            return "hiding $($candidate.Command) also hid claude, so this would prove nothing"
        }

        $output = & (Join-Path $scriptsRoot "health-check.ps1") 6>&1 | Out-String
    }
    finally {
        $env:PATH = $previousPath
    }

    # No escape hatch. If the scenario did not reproduce, that is a failure to
    # investigate, not a pass.
    if ($output -match "$($candidate.Server) is declared but not registered") {
        return "the probe degraded the check instead of reproducing the scenario"
    }

    if ($output -notmatch "cannot start: '$($candidate.Command)' is not in PATH") {
        return "it did not name the missing runtime: $($candidate.Command)"
    }

    if ($output -match "$($candidate.Server) is registered but did not connect") {
        return "it still blamed the network for a missing runtime"
    }

    return $true
}


Complete-TestFile
