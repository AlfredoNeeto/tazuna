<#
.SYNOPSIS
    Sets up this harness on a new machine, in one command.

.DESCRIPTION
    Sequences the installers that already exist rather than reimplementing them:
    prerequisites, the user harness, the Tech Leads Club harness-toolkit and
    agent-skills (their own CLIs, pinned in lib\Manifest.psm1), the plugins, the
    user-scope MCP servers, then the health check that says whether it worked.

    Project-scope MCP servers are not installed here: `tazuna mcp add <name>`
    adds one to the project that needs it.

    Safe to re-run. Every step it calls is idempotent, so this doubles as a
    repair command when a machine has drifted.

.PARAMETER SkipMcp
    Do not register MCP servers. Useful on a machine with no outbound network,
    or when the catalogue is under review.

.EXAMPLE
    .\scripts\bootstrap.ps1 -WhatIf
    .\scripts\bootstrap.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$SkipMcp
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\Paths.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Console.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Manifest.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Toolchain.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Cursor.psm1") -Force

$repoRoot = Split-Path -Parent $PSScriptRoot
$manifest = Get-HarnessManifest
$clock = [System.Diagnostics.Stopwatch]::StartNew()

# why: read before install.ps1 appends bin to this process's PATH - the shell
# that started setup keeps the PATH it had, and that is the one the summary is about.
$binDirectory = Join-Path $repoRoot "bin"
$callerPath = @($env:PATH -split ";")
$callerHasBin = @($callerPath | ForEach-Object { $_.Trim().TrimEnd("\") }) -contains $binDirectory.TrimEnd("\")

$steps = @("Prerequisites", "User harness", "harness-toolkit", "agent-skills", "Plugins")
if (-not $SkipMcp) { $steps += "MCP servers" }
if (-not $WhatIfPreference) { $steps += "Verifying" }

$script:currentStep = $steps[0]

function Start-Step {
    param([string]$Name)

    $script:currentStep = $Name
    Write-Section ("[{0}/{1}] {2}" -f ([array]::IndexOf($steps, $Name) + 1), $steps.Count, $Name)
}

# invariant: a step that throws ends setup with one FAIL line naming the step
# and exit 1 - never a PowerShell error record. Every step is idempotent, so
# running setup again is the repair.
trap {
    Write-Host ""
    Write-Status -Label "FAIL" -Detail ("{0} failed: {1}" -f $script:currentStep, $_.Exception.Message)
    Write-Host "Fix it and run tazuna setup again - finished steps are safe to repeat"
    Write-Host ""
    exit 1
}

Write-Banner -Title ("Tazuna " + $manifest.Version) -Command "setup"
Write-Host "  Repository:    $repoRoot"
Write-Host "  Claude config: $(Get-ClaudeConfigDir)"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
# Checked before anything is written. A partial install that stopped halfway is
# harder to reason about than one that refused to start.

Start-Step "Prerequisites"

$blocking = @()

function Test-Prerequisite {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Purpose,
        # What to run to get it. An optional prerequisite reported as merely
        # absent is a dead end: the thing that depends on it then registers,
        # fails, and the failure names something else entirely.
        [string]$Install,
        [switch]$Required
    )

    $found = Get-Command $Command -ErrorAction SilentlyContinue

    if ($found) {
        Write-Status -Label "OK" -Detail "$Command - $Purpose"
        return $true
    }

    if ($Required) {
        Write-Status -Label "MISSING" -Detail "$Command - $Purpose"
        $script:blocking += $Command
    }
    else {

        Write-Host ("  --        {0} - {1} (optional)" -f $Command, $Purpose)

        if ($Install) {
            Write-Host ("            install: " + $Install)
            Write-Host "            then open a new shell, so PATH is picked up"
        }
    }

    return $false
}

# invariant: Claude Code and Cursor are each optional; setup needs at least one of them.
$hasClaude = [bool](Get-Command claude -ErrorAction SilentlyContinue)
$cursorDir = Get-CursorConfigDir
$hasCursor = Test-Path -LiteralPath $cursorDir

if ($hasClaude) { Write-Status -Label "OK" -Detail "claude - Claude Code" }
else { Write-Host "  --        claude - Claude Code (not installed; its steps are skipped)" }

if ($hasCursor) { Write-Status -Label "OK" -Detail "Cursor - $cursorDir" }
else { Write-Host "  --        Cursor - $cursorDir not found (its steps are skipped)" }

if ((-not $hasClaude) -and (-not $hasCursor)) {
    Write-Host ""
    Write-Host "Cannot continue: neither Claude Code nor Cursor is installed."
    Write-Host ""
    Write-Host "  npm install -g @anthropic-ai/claude-code"
    Write-Host "  or install Cursor and open it once, so $cursorDir exists"
    Write-Host ""
    exit 1
}

Test-Prerequisite -Command "git"    -Purpose "version control, the drift check and update" -Required | Out-Null
# Optional toolchains, listed so a new machine can see what it is missing. None
# is required: the project templates detect whichever stack a repository uses.
Test-Prerequisite -Command "dotnet" -Purpose ".NET projects" | Out-Null
Test-Prerequisite -Command "python3" -Purpose "the tlc-* skill validators and the spec-lean completion gate" `
    -Install "winget install Python.Python.3.12" | Out-Null

if ($blocking.Count -gt 0) {

    Write-Host ""
    Write-Host ("Cannot continue: {0} is not installed." -f ($blocking -join ", "))
    Write-Host ""
    Write-Host "  winget install --id=Git.Git -e"
    Write-Host ""
    exit 1
}

# The harness-toolkit hooks, the agent-skills CLI and the npx MCP servers all run
# on Node, and the toolkit refuses anything below 24. Checked before anything is
# written, like the rest.
$nodeMajor = Get-NodeMajorVersion

if ($nodeMajor -lt (Get-HarnessManifest).MinimumNodeMajor) {
    Write-Status -Label "MISSING" -Detail "node 24+ required (harness-toolkit, agent-skills, MCP servers)"
    Write-Host ""
    Write-Host "  winget install OpenJS.NodeJS.LTS"
    Write-Host ""
    Write-Host "Then open a new shell and run this again. Nothing was changed."
    Write-Host ""
    exit 1
}

Write-Status -Label "OK" -Detail "node $nodeMajor"

# The AGENTS.md support the project templates rely on landed in 2.1.277. Below
# that, a scaffolded project looks complete and its instructions are ignored.
if ($hasClaude) {
    $claudeVersion = ((& claude --version) -split " ")[0]

    Write-Status -Label "OK" -Detail "Claude Code $claudeVersion"
}

# ---------------------------------------------------------------------------
# The user harness
# ---------------------------------------------------------------------------

Start-Step "User harness"

& (Join-Path $PSScriptRoot "install.ps1") -NoTitle -NoClaude:(-not $hasClaude) -WhatIf:$WhatIfPreference

if ($LASTEXITCODE -ne 0) { throw "install.ps1 exited $LASTEXITCODE." }

# ---------------------------------------------------------------------------
# Tech Leads Club: harness-toolkit and agent-skills
# ---------------------------------------------------------------------------
# Always after install.ps1: that replaces settings.json whole, and `tlc harness
# install` is what merges the toolkit's hooks back into it. Both are idempotent.

function Invoke-Step {
    param([string]$Command, [string[]]$Arguments)

    $line = ($Command + " " + ($Arguments -join " "))

    # why: $WhatIfPreference first - ShouldProcess under -WhatIf prints its own
    # "What if:" line, and the WHATIF line below already says the same thing.
    if ($WhatIfPreference -or (-not $PSCmdlet.ShouldProcess($line, "Run"))) {
        Write-Status -Label "WHATIF" -Detail "would run: $line"
        return
    }

    Write-Status -Label "RUN" -Detail $line

    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $global:LASTEXITCODE = 0
    # why: npm/node write UTF-8; PowerShell 5.1 decodes piped native output with
    # the OEM code page, which turns box-drawing and emoji into mojibake.
    $encoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
    try {
        & $Command @Arguments | Out-Host
        $code = $LASTEXITCODE
    }
    finally {
        [Console]::OutputEncoding = $encoding
        $ErrorActionPreference = $previous
    }

    if ($code -ne 0) { throw "'$line' exited $code." }
}

Start-Step "harness-toolkit"

Invoke-Step -Command "npm" -Arguments @("install", "-g", $manifest.ToolkitPackage)
Invoke-Step -Command "tlc" -Arguments @("harness", "install")

Start-Step "agent-skills"

$skillArguments = @("-y", $manifest.AgentSkillsPackage, "install", "-s") + @($manifest.AgentSkills)

if ($hasClaude) { Invoke-Step -Command "npx" -Arguments ($skillArguments + @("-a", "claude-code", "-g")) }
if ($hasCursor) { Invoke-Step -Command "npx" -Arguments ($skillArguments + @("-a", "cursor", "-g")) }

# ---------------------------------------------------------------------------
# Plugins
# ---------------------------------------------------------------------------
# The declaration in user/settings.json is necessary but not sufficient: on a
# clean configuration directory the marketplace is not registered and the plugin
# is not on disk. Measured on a fresh CLAUDE_CONFIG_DIR - the keys were there and
# `claude plugin marketplace list` said "No marketplaces configured".
#
# So fetch them here. Idempotent: an installed plugin is left alone.

Start-Step "Plugins"

$userSettingsPath = Join-Path $repoRoot (Join-Path "user" "settings.json")

$installedPlugins = @{}

if ($hasClaude) {
    try {

        $pluginJson = (& claude plugin list --json) -join "`n"

        if ($pluginJson) {

            foreach ($installed in (ConvertFrom-Json $pluginJson)) {
                $installedPlugins[$installed.id] = [bool]$installed.enabled
            }
        }
    }
    catch {
        $installedPlugins = @{}
    }
}

$userSettings = Get-Content -LiteralPath $userSettingsPath -Raw | ConvertFrom-Json

$declaredPlugins = @()

if ($userSettings.enabledPlugins) {
    $declaredPlugins = @($userSettings.enabledPlugins.PSObject.Properties.Name | Where-Object { $_ })
}

if (-not $hasClaude) {
    Write-Host "  --        skipped: plugins are installed into Claude Code, which is not installed"
    $declaredPlugins = @()
}
elseif ($declaredPlugins.Count -eq 0) {
    Write-Host "  --        none declared"
}

foreach ($declared in $declaredPlugins) {

    if ($installedPlugins.ContainsKey($declared) -and $installedPlugins[$declared]) {
        Write-Status -Label "PRESENT" -Detail $declared
        continue
    }

    if ($WhatIfPreference -or (-not $PSCmdlet.ShouldProcess($declared, "Install plugin"))) {
        Write-Status -Label "WHATIF" -Detail "would install $declared"
        continue
    }

    $marketplace = ($declared -split "@")[-1]

    # The marketplace source is version-controlled alongside the plugin, so a
    # new machine does not need to be told where it came from.
    $source = $null

    if ($userSettings.extraKnownMarketplaces -and
        $userSettings.extraKnownMarketplaces.PSObject.Properties[$marketplace]) {

        $definition = $userSettings.extraKnownMarketplaces.$marketplace.source

        if ($definition.repo) { $source = $definition.repo }
        elseif ($definition.path) { $source = $definition.path }
        elseif ($definition.url) { $source = $definition.url }
    }

    if ($source) {
        & claude plugin marketplace add $source --scope user | Out-Null
    }

    & claude plugin install $declared --scope user | Out-Null

    if ($LASTEXITCODE -eq 0) {
        Write-Status -Label "INSTALL" -Detail $declared
    }
    else {
        Write-Status -Label "FAIL" -Detail "$declared (claude plugin install exited $LASTEXITCODE)"
    }
}

# ---------------------------------------------------------------------------
# MCP servers
# ---------------------------------------------------------------------------

if (-not $SkipMcp) {

    Start-Step "MCP servers"

    if ($hasClaude) {
        & (Join-Path $PSScriptRoot "install-mcp.ps1") -NoTitle -WhatIf:$WhatIfPreference

        if ($LASTEXITCODE -ne 0) { throw "install-mcp.ps1 exited $LASTEXITCODE." }
    }

    if ($hasCursor) {

        $cursorMcp = Join-Path $cursorDir "mcp.json"
        $existing = ""
        if (Test-Path -LiteralPath $cursorMcp) { $existing = [System.IO.File]::ReadAllText($cursorMcp) }

        $catalogue = (Get-Content -LiteralPath (Join-Path $repoRoot (Join-Path "mcp" "servers.json")) -Raw | ConvertFrom-Json).mcpServers
        $merge = Add-CursorMcpServer -ExistingJson $existing -Catalogue $catalogue

        if ($merge.Added.Count -eq 0) {
            Write-Status -Label "PRESENT" -Detail "Cursor mcp.json already lists every user server"
        }
        elseif ($WhatIfPreference -or (-not $PSCmdlet.ShouldProcess($cursorMcp, "Add MCP servers"))) {
            Write-Status -Label "WHATIF" -Detail ("would add to Cursor mcp.json: " + ($merge.Added -join ", "))
        }
        else {
            if ($existing) {
                $backup = New-HarnessBackupRoot -ParentDirectory $cursorDir
                New-Item -ItemType Directory -Path $backup -Force | Out-Null
                Copy-Item -LiteralPath $cursorMcp -Destination (Join-Path $backup "mcp.json") -Force
            }

            [System.IO.File]::WriteAllText($cursorMcp, $merge.Json)
            Write-Status -Label "INSTALL" -Detail ("Cursor mcp.json: " + ($merge.Added -join ", "))
        }
    }
}

# ---------------------------------------------------------------------------
# Did it work?
# ---------------------------------------------------------------------------

if ($WhatIfPreference) {

    Write-Host ""
    Write-Host "Dry run: nothing was changed. Re-run without -WhatIf to install."
    Write-Host ""
    exit 0
}

Start-Step "Verifying"

& (Join-Path $PSScriptRoot "health-check.ps1") -NoTitle

$healthy = ($LASTEXITCODE -eq 0)
$elapsed = "in {0}s" -f [int]$clock.Elapsed.TotalSeconds

Write-Host ""

if ($healthy) {
    Write-Status -Label "DONE" -Detail "Harness installed $elapsed"
}
else {
    Write-Status -Label "FAIL" -Detail "Setup finished $elapsed, but the health check FAILED"
    Write-Host "          Read its output above: it names each problem and the fix."
}

if (-not $callerHasBin) {
    Write-Host ""
    Write-Host "This shell does not have tazuna on its PATH yet. Open a new one, or run:"
    Write-Host ('  $env:Path += ";{0}"' -f $binDirectory)
}

Write-Host ""

if (-not $healthy) { exit 1 }

Write-Host "Connect a project - from inside it, no arguments:"
Write-Host "  cd C:\src\MyApp"
Write-Host "  tazuna init"
Write-Host ""
Write-Host "Then see which MCP servers a project can add:"
Write-Host "  tazuna mcp list"
Write-Host ""

exit 0
