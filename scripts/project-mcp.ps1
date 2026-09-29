<#
.SYNOPSIS
    Lists the project MCP catalog, or adds one of its servers to a project.

.DESCRIPTION
    `add` merges the catalog entry into <project>\.mcp.json, keeping every entry
    already there, and enables it in <project>\.claude\settings.json. Running it
    twice changes nothing.

    azure-devops is the exception: configure-ado.ps1 asks for the project URL
    and a PAT, verifies them, and registers the server in Claude Code's local
    scope for this project only, before any file is written. It never enters
    .mcp.json. Its rule lands in .claude\rules\azure-devops.md.

.PARAMETER Action
    list or add.

.PARAMETER Name
    The catalog name to add.

.PARAMETER Path
    The project. Defaults to the current directory.

.EXAMPLE
    tazuna mcp list
    tazuna mcp add azure-devops
    tazuna mcp add mermaid -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [string]$Action,

    [Parameter(Position = 1)]
    [string]$Name,

    [string]$Path = ".",

    # The self-test swaps in a stub; nobody else needs this.
    [string]$AdoConfigurator
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\Paths.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Files.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Json.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Console.psm1") -Force

$repoRoot = Split-Path -Parent $PSScriptRoot
$catalog = (Get-Content -LiteralPath (Join-Path $repoRoot "mcp\catalog.json") -Raw | ConvertFrom-Json).servers
$names = @($catalog.PSObject.Properties.Name)

function Show-Catalog {
    foreach ($entryName in $names) {
        Write-Entry -Name ("  {0,-14}" -f $entryName) -Text $catalog.$entryName.purpose
    }
}

if ((-not $Action) -or ($Action -eq "list")) {
    Write-Host ""
    Write-Host "Project MCP servers - add one with: tazuna mcp add <name>"
    Write-Host ""
    Show-Catalog
    Write-Host ""
    exit 0
}

if (($Action -ne "add") -or (-not $Name)) {
    Write-Host ""
    Write-Host "Usage: tazuna mcp list | tazuna mcp add <name>"
    Write-Host ""
    exit 1
}

if ($names -notcontains $Name) {
    Write-Host ""
    Write-Host "Unknown MCP server: $Name. The catalog has:"
    Write-Host ""
    Show-Catalog
    Write-Host ""
    exit 1
}

$entry = $catalog.$Name

if ($entry.requires -and (-not (Get-Command $entry.requires -ErrorAction SilentlyContinue))) {
    Write-Host ""
    Write-Host "$($entry.requires) required to run $Name, and it is not on PATH."

    if ($entry.install) {
        Write-Host "  install: $($entry.install)"
    }
    else {
        Write-Host "  install: winget install OpenJS.NodeJS.LTS"
    }

    Write-Host "  then open a new shell and run this again. Nothing was written."
    Write-Host ""
    exit 1
}

$projectRoot = Resolve-HarnessPath -Path $Path

if (-not (Test-Path -LiteralPath $projectRoot -PathType Container)) {
    Write-Host "ERROR: project directory does not exist: $projectRoot"
    exit 1
}

# Credentials first, so a cancelled prompt leaves the project untouched.
$localScope = ($Name -eq "azure-devops")

if ($localScope) {

    if (-not $AdoConfigurator) { $AdoConfigurator = Join-Path $PSScriptRoot "configure-ado.ps1" }

    $global:LASTEXITCODE = 0
    & $AdoConfigurator -Path $projectRoot -WhatIf:$WhatIfPreference

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Azure DevOps was not configured. Nothing was written."
        exit 1
    }
}

function Read-JsonObject {
    param([string]$File)

    if (-not (Test-Path -LiteralPath $File)) { return (New-Object PSObject) }

    try {
        return (Get-Content -LiteralPath $File -Raw | ConvertFrom-Json)
    }
    catch {
        throw "$File exists but does not parse. Fix or remove it before re-running."
    }
}

function Set-Member {
    param($Object, [string]$Key, $Value)

    if ($Object.PSObject.Properties[$Key]) { $Object.$Key = $Value }
    else { Add-Member -InputObject $Object -MemberType NoteProperty -Name $Key -Value $Value }
}

# why: a local-scope registration always rewrites the entry, and it lives outside the project files.
$changed = $localScope

# why: a shared .mcp.json entry for azure-devops would need a per-machine ${ADO_PAT}; its registration above replaces it.
if (-not $localScope) {

    # .mcp.json
    $mcpPath = Join-Path $projectRoot ".mcp.json"
    $mcp = Read-JsonObject -File $mcpPath

    if (-not $mcp.PSObject.Properties["mcpServers"]) { Set-Member $mcp "mcpServers" (New-Object PSObject) }

    $current = $null
    if ($mcp.mcpServers.PSObject.Properties[$Name]) { $current = $mcp.mcpServers.$Name }

    if ((Get-JsonCanonicalForm -Value $current) -ne (Get-JsonCanonicalForm -Value $entry.server)) {

        Set-Member $mcp.mcpServers $Name $entry.server

        if ($PSCmdlet.ShouldProcess($mcpPath, "Declare $Name")) {
            Set-Utf8Content -Path $mcpPath -Value (($mcp | ConvertTo-Json -Depth 20) + "`n")
        }

        $changed = $true
    }

    # .claude/settings.json - declared but not enabled does nothing.
    $settingsPath = Join-Path $projectRoot ".claude\settings.json"
    $settings = Read-JsonObject -File $settingsPath

    $enabled = @()
    if ($settings.PSObject.Properties["enabledMcpjsonServers"]) { $enabled = @($settings.enabledMcpjsonServers) }

    if ($enabled -notcontains $Name) {

        Set-Member $settings "enabledMcpjsonServers" (@($enabled) + $Name)

        if ($PSCmdlet.ShouldProcess($settingsPath, "Enable $Name")) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $settingsPath) -Force | Out-Null
            Set-Utf8Content -Path $settingsPath -Value (($settings | ConvertTo-Json -Depth 20) + "`n")
        }

        $changed = $true
    }

}

# The rule that goes with the server.
$ruleSource = Join-Path $repoRoot (Join-Path "mcp\rules" ($Name + ".md"))

if (Test-Path -LiteralPath $ruleSource) {

    $result = Copy-FileIfChanged `
        -SourceFile $ruleSource `
        -TargetFile (Join-Path $projectRoot (Join-Path ".claude\rules" ($Name + ".md"))) `
        -BackupRoot (New-HarnessBackupRoot -ParentDirectory $projectRoot) `
        -BackupRelativePath (Join-Path ".claude\rules" ($Name + ".md")) `
        -WhatIf:$WhatIfPreference

    if ($result -ne "Unchanged") { $changed = $true }

    # why: Copy-FileIfChanged is silent under -WhatIf; the dry run is reported by its caller.
    if ($WhatIfPreference -and ($result -ne "Unchanged")) {
        Write-Status -Label "WHATIF" -Detail ("would write .claude\rules\" + $Name + ".md")
    }
}

Write-Host ""

if ($changed) {
    Write-Status -Label "ADDED" -Detail $Name

    if ($localScope) { Write-Host "            restart Claude Code in this project" }
    else { Write-Host "            restart Claude Code in this project and approve the server once" }
}
else {
    Write-Status -Label "UNCHANGED" -Detail $Name
}

Write-Host ""
exit 0
