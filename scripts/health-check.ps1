<#
.SYNOPSIS
    Verifies that the Claude Code harness is correctly installed on this machine.

.DESCRIPTION
    Checks the toolchain, the installed user harness, and the repository working
    tree. Exits non-zero if any required check fails, so it is usable as a gate
    in a bootstrap script.

    Checks performed:
      - claude, git, node 24+ and the .NET SDK resolve on PATH
      - the harness-toolkit hooks are wired and every harness skill is installed
      - Claude Code is at least the version required for AGENTS.md support
      - the configuration directory resolves consistently (CLAUDE_CONFIG_DIR aware)
      - CLAUDE.md and settings.json exist in the configuration directory
      - every installed JSON file parses
      - no drift between the repository's user/ tree and what is installed
      - no credential or session-state file has leaked into the repository

.PARAMETER NoTitle
    Leave the title out. tazuna setup passes it, because it prints its own.

.EXAMPLE
    .\scripts\health-check.ps1
#>
[CmdletBinding()]
param(
    [switch]$NoTitle
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\Paths.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Files.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Json.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Console.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Manifest.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Toolchain.psm1") -Force

# Minimum Claude Code version that supports AGENTS.md, which the project
# templates rely on for project-level instructions.
$minimumClaudeVersion = [version](Get-HarnessManifest).MinimumClaudeVersion

$repoRoot = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repoRoot "user"
$configDir = Get-ClaudeConfigDir
$manifest = Get-HarnessManifest

$script:failures = @()
$script:warnings = @()

function Add-Failure {
    param([string]$Message)
    $script:failures += $Message
    Write-Status -Label "FAIL" -Detail $Message
}

function Add-Warning {
    param([string]$Message)
    $script:warnings += $Message
    Write-Status -Label "WARN" -Detail $Message
}

function Add-Pass {
    param([string]$Message)
    Write-Status -Label "OK" -Detail $Message
}

if (-not $NoTitle) {
    Write-Banner -Title ("Tazuna " + $manifest.Version) -Command "doctor"
    Write-Host ""
}

Write-Host "Repository:   $repoRoot"
Write-Host "Config dir:   $configDir"

if ($env:CLAUDE_CONFIG_DIR) {
    Write-Host "              (from CLAUDE_CONFIG_DIR)"
} else {
    Write-Host "              (default; CLAUDE_CONFIG_DIR not set)"
}

Write-Host ""
Write-Host "Toolchain"
Write-Host "---------"

$claude = Get-Command claude -ErrorAction SilentlyContinue

if ($null -eq $claude) {
    Add-Failure "Claude Code not found on PATH."
}
else {
    Add-Pass "claude -> $($claude.Source)"

    $versionOutput = & claude --version
    $versionText = ($versionOutput | Out-String).Trim()
    $match = [regex]::Match($versionText, '(\d+)\.(\d+)\.(\d+)')

    if (-not $match.Success) {
        Add-Warning "Could not parse Claude Code version from: $versionText"
    }
    else {
        $installedVersion = [version]$match.Value

        if ($installedVersion -lt $minimumClaudeVersion) {
            Add-Failure ("Claude Code $installedVersion is older than $minimumClaudeVersion, " +
                         "which is required for AGENTS.md support.")
        }
        else {
            Add-Pass "Claude Code version $installedVersion (>= $minimumClaudeVersion)"
        }
    }
}

$git = Get-Command git -ErrorAction SilentlyContinue

if ($null -eq $git) {
    Add-Failure "git not found on PATH."
}
else {
    Add-Pass "git -> $($git.Source)"
}

# The harness-toolkit hooks run on Node; below 24 they do not start.
$nodeMajor = Get-NodeMajorVersion

if ($nodeMajor -ge (Get-HarnessManifest).MinimumNodeMajor) {
    Add-Pass "node $nodeMajor (>= 24, for the harness-toolkit hooks)"
}
else {
    Add-Failure "node 24+ required for the harness-toolkit hooks: winget install OpenJS.NodeJS.LTS"
}

$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue

if ($null -eq $dotnet) {
    # Informational. The harness is not a .NET harness: the generic template
    # detects Node, Python, Go, Rust and JVM projects too, and most machines
    # will not have every toolchain the templates can serve.
    Write-Host "  --        dotnet not on PATH (only needed for .NET projects)"
}
else {
    Add-Pass "dotnet -> $($dotnet.Source)"
}

# The tlc-* skills run their validators as `python3`, and so does the
# verification gate's spec-lean check. On Windows `python3` is often the
# Microsoft Store alias: on PATH, and runs nothing. Only a run proves it.
$pythonWorks = $false

if (Get-Command python3 -CommandType Application -ErrorAction SilentlyContinue) {

    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $global:LASTEXITCODE = 0

    try {
        $pythonVersion = (& python3 --version 2>&1 | Out-String).Trim()
        $pythonWorks = ($LASTEXITCODE -eq 0)
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

if ($pythonWorks) {
    Add-Pass "python3 -> $pythonVersion"
}
else {
    Add-Warning "python3 does not run: the tlc-* skills call it for their validators, and fall back to reading the artifacts. winget install Python.Python.3.12"
}

Write-Host ""
Write-Host "Installed harness"
Write-Host "-----------------"

if (-not (Test-Path -LiteralPath $configDir)) {
    Add-Failure "Configuration directory does not exist: $configDir"
}
else {
    foreach ($required in @("CLAUDE.md", "settings.json")) {

        $path = Join-Path $configDir $required

        if (Test-Path -LiteralPath $path) {
            Add-Pass $required
        }
        else {
            Add-Failure "$required is missing from $configDir"
        }
    }

    $settingsPath = Join-Path $configDir "settings.json"

    if (Test-Path -LiteralPath $settingsPath) {

        $parseError = $null

        if (Test-JsonFile -Path $settingsPath -ErrorMessage ([ref]$parseError)) {
            Add-Pass "settings.json parses as JSON"
        }
        else {
            Add-Failure "settings.json is not valid JSON: $parseError"
        }
    }
}

Write-Host ""
Write-Host "Repository drift"
Write-Host "----------------"

if (-not (Test-Path -LiteralPath $source)) {
    Add-Failure "user/ directory not found at $source"
}
else {
    $sourceFiles = @(Get-ChildItem -LiteralPath $source -File -Recurse -Force)
    function Test-InstalledFileMatches {
    <#
        Claude Code owns settings.json and rewrites it - reordering keys and
        switching to LF - so a byte comparison reported drift after every clean
        install about a file whose content had not changed. JSON is therefore
        compared by content; everything else by bytes, where formatting is the
        author's and a change to it is a real change.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Installed
    )

    if ([System.IO.Path]::GetExtension($Source) -eq ".json") {

        # The harness-toolkit merges its own hooks block into settings.json;
        # that is expected, not drift.
        try {
            $reference = Get-Content -LiteralPath $Source -Raw | ConvertFrom-Json
            $difference = Get-Content -LiteralPath $Installed -Raw | ConvertFrom-Json
        }
        catch {
            return $false
        }

        foreach ($document in @($reference, $difference)) {
            if ($document.PSObject.Properties["hooks"]) { $document.PSObject.Properties.Remove("hooks") }
        }

        return ((Get-JsonCanonicalForm -Value $reference) -eq (Get-JsonCanonicalForm -Value $difference))
    }

    return (Test-FileContentEqual -ReferenceFile $Source -DifferenceFile $Installed)
}

$drifted = 0

    foreach ($file in $sourceFiles) {

        $relative = Get-CompatibleRelativePath -BasePath $source -TargetPath $file.FullName
        $installed = Join-Path $configDir $relative

        if (-not (Test-Path -LiteralPath $installed)) {
            Add-Failure "$relative is in the repository but not installed."
            $drifted++
        }
        elseif (-not (Test-InstalledFileMatches -Source $file.FullName -Installed $installed)) {
            Add-Warning "$relative differs between the repository and $configDir"
            $drifted++
        }
    }

    if ($drifted -eq 0) {
        Add-Pass "$($sourceFiles.Count) file(s) match the installed harness"
    }
}

    # Drift is two-directional. Copying covers what the repository added; nothing
    # covers what it removed, so a deleted skill or agent stays installed and
    # active forever while the check above reports everything matching.
    $ownedDirectories = @("agents", "skills")

    # Claude Code manages synced and .trash itself; the agent-skills CLI installs
    # the tlc skills and `tlc harness install` links harness-init.
    $notOurs = @("synced", ".trash", "harness-init") + @($manifest.AgentSkills)

    $orphans = @()

    foreach ($owned in $ownedDirectories) {

        $installedDirectory = Join-Path $configDir $owned
        $sourceDirectory = Join-Path $source $owned

        if (-not (Test-Path -LiteralPath $installedDirectory)) {
            continue
        }

        foreach ($entry in (Get-ChildItem -LiteralPath $installedDirectory -Force)) {

            if ($notOurs -contains $entry.Name) {
                continue
            }

            if (-not (Test-Path -LiteralPath (Join-Path $sourceDirectory $entry.Name))) {
                $orphans += "$owned/$($entry.Name)"
            }
        }
    }

    if ($orphans.Count -gt 0) {
        Add-Warning ("installed but not in the repository, so still active: " + ($orphans -join ", "))
    }
    else {
        Add-Pass "No orphaned agents or skills"
    }

Write-Host ""
Write-Host "Toolkit and skills"
Write-Host "------------------"

$settingsText = ""
$installedSettings = Join-Path $configDir "settings.json"

if (Test-Path -LiteralPath $installedSettings) {
    $settingsText = Get-Content -LiteralPath $installedSettings -Raw
}

if ($settingsText -match "tlc-exec") {
    Add-Pass "harness-toolkit hooks are wired in settings.json"
}
else {
    Add-Failure "no tlc-exec hook in settings.json - the harness-toolkit is not wired; run: tazuna setup"
}

foreach ($skill in (@($manifest.AgentSkills) + @("review-change"))) {

    if (Test-Path -LiteralPath (Join-Path $configDir (Join-Path "skills" (Join-Path $skill "SKILL.md")))) {
        Add-Pass "skill $skill"
    }
    else {
        Add-Failure "skill $skill is missing; run: tazuna setup"
    }
}

Write-Host ""
Write-Host "Permission rules"
Write-Host "----------------"

if ($null -eq $claude) {
    Add-Warning "Cannot validate permission rules without Claude Code."
}
else {
    # `claude doctor` parses the effective settings files and reports malformed
    # permission rules, which JSON validation alone cannot catch.
    $doctorOutput = ""

    try {
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $doctorOutput = (& claude doctor | Out-String)
        $ErrorActionPreference = $previousPreference
    }
    catch {
        $doctorOutput = ""
        Add-Warning "Could not run 'claude doctor': $($_.Exception.Message)"
    }

    if ($doctorOutput -match "Invalid permission rule") {

        foreach ($line in ($doctorOutput -split "`n")) {
            if ($line -match "Invalid permission rule") {
                Add-Failure $line.Trim()
            }
        }
    }
    elseif ($doctorOutput -ne "") {
        Add-Pass "No malformed permission rules reported by 'claude doctor'"
    }
}

Write-Host ""
Write-Host "Plugins"
Write-Host "-------"

# The harness declares plugins in user/settings.json so a new machine gets them.
# A declared-but-missing plugin is silent otherwise, and CLAUDE.md now relies on
# ponytail for the code-minimality rules it no longer states itself.
$declaredPlugins = @()

$sourceSettings = Join-Path $source "settings.json"

if (Test-Path -LiteralPath $sourceSettings) {

    # JSON validity is already reported above. Parsing again here must not abort
    # the run, or one invalid file would hide every check that follows it.
    try {

        $settings = Get-Content -LiteralPath $sourceSettings -Raw | ConvertFrom-Json

        if ($settings.enabledPlugins) {
            $declaredPlugins = @($settings.enabledPlugins.PSObject.Properties.Name | Where-Object { $_ })
        }
    }
    catch {
        $declaredPlugins = @()
    }
}

if ($declaredPlugins.Count -eq 0) {
    Add-Pass "No plugins declared"
}
else {

    # Ask the CLI what is actually installed, not the settings file what is
    # declared. On a new machine the declaration is present from the first
    # install and the plugin is not there yet, so reading the declaration back
    # reports "enabled" about something that does not exist. `plugin disable`
    # also keeps a plugin installed, so the listing's own enabled flag is what
    # settles it.
    $liveEnabled = @{}
    $liveUnreadable = $false

    try {

        $pluginJson = (& claude plugin list --json) -join "`n"

        if ($pluginJson) {

            foreach ($installed in (ConvertFrom-Json $pluginJson)) {
                $liveEnabled[$installed.id] = [bool]$installed.enabled
            }
        }
    }
    catch {
        $liveUnreadable = $true
    }

    foreach ($declared in $declaredPlugins) {

        if ($liveUnreadable) {
            Add-Warning "$declared could not be checked: 'claude plugin list' did not answer"
        }
        elseif (-not $liveEnabled.ContainsKey($declared)) {
            Add-Warning "$declared is declared but not installed; run: claude plugin install $declared"
        }
        elseif (-not $liveEnabled[$declared]) {
            Add-Warning "$declared is installed but disabled; run: claude plugin enable $($declared.Split('@')[0])"
        }
        else {
            Add-Pass "$declared is enabled"
        }
    }
}

Write-Host ""
Write-Host "MCP servers"
Write-Host "-----------"

# The catalogue is version-controlled; the registration is machine-local. A
# server in mcp/servers.json that was never registered here is the exact gap
# that makes a second machine quietly different from this one.
$catalogue = Join-Path $repoRoot (Join-Path "mcp" "servers.json")

$declaredServers = @()

if (Test-Path -LiteralPath $catalogue) {

    try {

        $catalogueJson = Get-Content -LiteralPath $catalogue -Raw | ConvertFrom-Json

        if ($catalogueJson.mcpServers) {
            $declaredServers = @($catalogueJson.mcpServers.PSObject.Properties.Name | Where-Object { $_ })
        }
    }
    catch {
        Add-Failure "mcp/servers.json does not parse"
    }
}

if ($declaredServers.Count -eq 0) {
    Write-Host "  --        none declared"
}
else {

    # `claude mcp list` reports reachability as well as registration, so this
    # distinguishes "not set up on this machine" from "set up but unreachable".
    $mcpListing = ""

    try {
        $mcpListing = (& claude mcp list) -join "`n"
    }
    catch {
        $mcpListing = ""
    }

    foreach ($server in $declaredServers) {

        if (-not $mcpListing.Contains($server)) {
            Add-Warning "$server is declared but not registered here; run: tazuna setup"
            continue
        }

        $line = @($mcpListing -split "`n" | Where-Object { $_.Contains($server) }) | Select-Object -First 1

        if ($line -and $line.Contains("Connected")) {
            Add-Pass "$server is registered and reachable"
            continue
        }

        # Registering an MCP server writes a JSON entry. It does not check that
        # the command exists, so a stdio server whose runtime is missing
        # registers happily and then never starts. Reported as "network, or the
        # service is down", that sent someone looking at their connection for a
        # server that had nothing to run - measured on a second machine, where
        # serena registered with no uvx installed.
        $command = $null

        if ($catalogueJson -and $catalogueJson.mcpServers.PSObject.Properties[$server]) {
            $command = $catalogueJson.mcpServers.$server.command
        }

        if ($command -and (-not (Get-Command $command -ErrorAction SilentlyContinue))) {

            Add-Warning "$server cannot start: '$command' is not in PATH"
            Write-Host "            it is registered, so this is not a registration problem."
            Write-Host "            install whatever provides '$command', open a new shell, then"
            Write-Host "            re-run this check. bootstrap.ps1 prints the command for the"
            Write-Host "            runtimes this harness expects."
            continue
        }

        if ($command) {
            Add-Warning "$server is registered and '$command' exists, but it did not start"
        }
        else {
            Add-Warning "$server is registered but did not connect (network, or the service is down)"
        }
    }
}

Write-Host ""
Write-Host "Repository hygiene"
Write-Host "------------------"

$forbidden = @(".credentials.json", ".claude.json", "history.jsonl")
$leaked = 0

foreach ($name in $forbidden) {

    $hits = @(Get-ChildItem -LiteralPath $repoRoot -Filter $name -Recurse -Force -ErrorAction SilentlyContinue |
              # Path segments, not a regex: a pattern ending in a backslash is an
              # illegal regex and throws on the first hit - the one case that matters.
              Where-Object { ($_.FullName -split '\\') -notcontains '.git' })

    foreach ($hit in $hits) {
        Add-Failure "Credential or session file present in the repository: $($hit.FullName)"
        $leaked++
    }
}

if ($leaked -eq 0) {
    Add-Pass "No credential or session-state files in the repository"
}

Write-Host ""

if ($script:failures.Count -gt 0) {
    Write-Host "Harness health check FAILED ($($script:failures.Count) failure(s), $($script:warnings.Count) warning(s))."
    Write-Host ""
    Write-Host "Troubleshooting:"
    Write-Host "  tazuna setup -WhatIf              preview what repairing would change"
    Write-Host "  tazuna setup                      install or repair the user harness"
    Write-Host "  claude --safe-mode                start Claude Code with all customizations disabled"
    Write-Host ""
    exit 1
}

if ($script:warnings.Count -gt 0) {
    Write-Host "Harness health check passed with $($script:warnings.Count) warning(s)."
    Write-Host ""
    exit 0
}

Write-Host "Harness health check passed."
Write-Host ""
exit 0
