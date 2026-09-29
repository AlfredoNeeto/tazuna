<#
.SYNOPSIS
    Prompts for an Azure DevOps project URL and a PAT, verifies both against the
    server, and registers the azure-devops MCP for one project only.

.DESCRIPTION
    Called by `tazuna mcp add azure-devops`. The project URL is the one the
    browser shows, e.g. http://server/Collection/Project. It is split into

      AZURE_DEVOPS_ORG_URL           the collection, http://server/Collection
      AZURE_DEVOPS_DEFAULT_PROJECT   the project, Project

    and both, with the PAT, are handed to `claude mcp add -s local`, which stores
    them in ~/.claude.json under this project's path: outside the repository, and
    loaded only when Claude Code runs in this project. Another project keeps its
    own values. Re-running replaces them.

    Why local scope and not ${ENV_VAR} placeholders in .mcp.json: Claude Code
    expands those only from its own process environment, so one value per
    machine, and a missing variable reaches the server as the literal text.

    The PAT is read with Read-Host -AsSecureString: it is not echoed, does not
    enter the PowerShell history, and is never printed by this script. It ends up
    in ~/.claude.json, readable by processes running as you - the same exposure
    the MCP server itself has once it holds the token.

    Both values are verified before anything is registered. An unverified
    credential looks configured and fails later, somewhere less obvious.

.PARAMETER ProjectUrl
    The project URL, for example http://server/DefaultCollection/MyProject.
    Anything after the project (/_git/repo, /_boards/...) is ignored.

.PARAMETER Pat
    The Personal Access Token, as a SecureString. Prompted for when omitted.
    There is deliberately no plain-string parameter: a token passed as text ends
    up in the session history and in any transcript.

.PARAMETER Path
    The project to register the server for. Defaults to the current directory.

.PARAMETER SkipTest
    Register without contacting the server. Use only when the server is
    unreachable from here right now; the values remain unverified.

.EXAMPLE
    .\scripts\configure-ado.ps1

.EXAMPLE
    .\scripts\configure-ado.ps1 -ProjectUrl "http://tfs/DefaultCollection/MyProject" -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ProjectUrl,

    [System.Security.SecureString]$Pat,

    [string]$Path = ".",

    [switch]$SkipTest
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\Console.psm1") -Force

$repoRoot = Split-Path -Parent $PSScriptRoot
$server = (Get-Content -LiteralPath (Join-Path $repoRoot "mcp\catalog.json") -Raw | ConvertFrom-Json).servers."azure-devops".server

# 7.0, not 7.1. On the on-premises server this was tested against, 5.0, 6.0 and 7.0 answered
# and 7.1 returned HTTP 400 on every endpoint tried. mcp/rules/azure-devops.md carries the numbers.
$apiVersion = $server.env.AZURE_DEVOPS_API_VERSION

$example = "http://server/DefaultCollection/MyProject"

function Read-PlainText {
    param([Parameter(Mandatory = $true)][System.Security.SecureString]$Secure)

    # ConvertFrom-SecureString -AsPlainText is PowerShell 7. This is the 5.1 way,
    # and the BSTR is zeroed rather than left in memory for the GC to find.
    $pointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)

    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Test-Project {
    <#
        Returns $null on success, or the reason it failed. Never returns the
        response: this only needs to know that the credential reaches the project.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Collection,
        [Parameter(Mandatory = $true)][string]$Project,
        [hashtable]$Headers
    )

    $arguments = @{
        Uri         = "$Collection/_apis/projects/" + [Uri]::EscapeDataString($Project) + "?api-version=$apiVersion"
        Method      = "Get"
        TimeoutSec  = 30
        ErrorAction = "Stop"
    }

    if ($Headers) { $arguments["Headers"] = $Headers }

    try {
        $null = Invoke-RestMethod @arguments
        return $null
    }
    catch {

        $status = $null

        if ($_.Exception.Response) { $status = $_.Exception.Response.StatusCode.value__ }

        if ($status -eq 400) {
            return "HTTP 400 - usually the api-version, not the URL: the server may not support $apiVersion."
        }

        if (($status -eq 401) -or ($status -eq 203)) {
            return "Not authorized ($status)."
        }

        if ($status -eq 404) {
            return "Project '$Project' not found (404) in $Collection."
        }

        return $_.Exception.Message
    }
}

function Stop-NotRegistered {
    param([string[]]$Lines)

    Write-Host ""
    foreach ($line in $Lines) { Write-Host $line }
    Write-Host "Nothing was registered."
    Write-Host ""
    exit 1
}

# Before any prompt: without Claude Code there is nowhere to register the server.
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Stop-NotRegistered -Lines @("Claude Code (claude) is required to register the azure-devops MCP, and it is not on PATH.")
}

$projectRoot = (Resolve-Path -LiteralPath $Path).ProviderPath

Write-Banner -Title "Azure DevOps configuration" -Subtitle "  Project URL and PAT for the azure-devops MCP of this project"

# ---------------------------------------------------------------------------
# Project URL -> collection + project
# ---------------------------------------------------------------------------

if (-not $ProjectUrl) {
    $ProjectUrl = Read-Host -Prompt "Project URL (e.g. $example)"
}

$ProjectUrl = ([string]$ProjectUrl).Trim()

if (-not $ProjectUrl) {
    Stop-NotRegistered -Lines @("No project URL given.")
}

# .StartsWith, not -like: ? is a single-character wildcard in -like.
if (-not ($ProjectUrl.StartsWith("http://") -or $ProjectUrl.StartsWith("https://"))) {
    Stop-NotRegistered -Lines @("Not a URL: $ProjectUrl", "It must start with http:// or https://, as $example")
}

$uri = [Uri]$ProjectUrl

# invariant: a project URL is <collection>/<project>[/_<area>...]; the first _ segment starts the page.
$segments = @()
foreach ($segment in $uri.AbsolutePath.Split("/")) {
    if (-not $segment) { continue }
    if ($segment.StartsWith("_")) { break }
    $segments += $segment
}

if ($segments.Count -lt 2) {
    Stop-NotRegistered -Lines @("Not a project URL: $ProjectUrl", "Open the project in the browser and copy its URL, as $example")
}

$project = [Uri]::UnescapeDataString($segments[$segments.Count - 1])
$collection = $uri.GetLeftPart([UriPartial]::Authority) + "/" + ($segments[0..($segments.Count - 2)] -join "/")

Write-Status -Label "COLLECTION" -Detail $collection
Write-Status -Label "PROJECT" -Detail $project

# ---------------------------------------------------------------------------
# PAT
# ---------------------------------------------------------------------------

$patText = $null

if (-not $Pat) {

    Write-Host ""
    Write-Host "Personal Access Token. Issue it on that server with the narrowest scopes the"
    Write-Host "work needs (Code and Work Items), and an expiry."
    Write-Host ""

    $Pat = Read-Host -Prompt "PAT (not echoed)" -AsSecureString
}

if ($Pat -and ($Pat.Length -gt 0)) {
    $patText = Read-PlainText -Secure $Pat
}

if (-not $patText) {
    Stop-NotRegistered -Lines @("No PAT given.")
}

# ---------------------------------------------------------------------------
# Verify before registering
# ---------------------------------------------------------------------------

Write-Section "Verifying"

if ($SkipTest) {
    Write-Status -Label "SKIP" -Detail "-SkipTest: neither value was checked against the server"
}
else {

    # Azure DevOps takes the PAT as HTTP Basic with an empty username.
    $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":" + $patText))
    $failure = Test-Project -Collection $collection -Project $project -Headers @{ Authorization = "Basic $basic" }

    if ($failure) {
        Write-Status -Label "FAIL" -Detail $failure
        Stop-NotRegistered -Lines @(
            "Check that the PAT was issued on this server, has not expired, and grants at",
            "least read on Code and Work Items, and that the URL opens the project."
        )
    }

    Write-Status -Label "OK" -Detail "PAT reaches project '$project'"
}

# ---------------------------------------------------------------------------
# Register in Claude Code's local scope
# ---------------------------------------------------------------------------

Write-Section "Registering"

$environment = [ordered]@{ AZURE_DEVOPS_ORG_URL = $collection }
foreach ($property in $server.env.PSObject.Properties) { $environment[$property.Name] = $property.Value }
$environment["AZURE_DEVOPS_PAT"] = $patText
$environment["AZURE_DEVOPS_DEFAULT_PROJECT"] = $project

$arguments = @("mcp", "add", "azure-devops", "-s", "local")
foreach ($key in $environment.Keys) { $arguments += @("-e", ($key + "=" + $environment[$key])) }
$arguments += @("--", $server.command) + @($server.args)

if (-not $PSCmdlet.ShouldProcess("azure-devops (Claude Code local scope, $projectRoot)", "Register")) {
    Write-Status -Label "WHATIF" -Detail "would register azure-devops for $projectRoot (local scope), PAT not shown"
    exit 0
}

Push-Location -LiteralPath $projectRoot

try {
    # hazard: stderr of a native command is redirected here, so Stop would turn an expected non-zero exit into a throw.
    $ErrorActionPreference = "Continue"

    # why: `claude mcp add` refuses a name that exists; a re-run replaces, so a missing entry is not an error.
    $null = & claude mcp remove azure-devops -s local 2>&1

    $global:LASTEXITCODE = 0
    $output = (& claude @arguments 2>&1 | Out-String)
    $code = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = "Stop"
    Pop-Location
}

if ($code -ne 0) {
    Write-Status -Label "FAIL" -Detail "claude mcp add exited $code"
    # invariant: the PAT is on that command line; whatever claude echoes back is masked before printing.
    Write-Host ($output.Replace($patText, "(PAT)"))
    Stop-NotRegistered -Lines @()
}

$patText = $null

Write-Status -Label "SET" -Detail "azure-devops for this project: $collection, project '$project', PAT (stored, not shown)"
Write-Host ""

exit 0
