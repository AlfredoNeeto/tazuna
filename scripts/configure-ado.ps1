<#
.SYNOPSIS
    Prompts for the internal Azure DevOps collection URL and a PAT, verifies both
    against the server, and stores them as user environment variables.

.DESCRIPTION
    Called by `tazuna mcp add azure-devops` when either variable is missing:

      ADO_COLLECTION_URL   the collection, e.g. http://server/DefaultCollection
      ADO_PAT              a Personal Access Token issued on that server

    Both are ${ENV_VAR} placeholders in the project's .mcp.json, expanded when
    Claude Code starts the server, so no credential is ever written into a file.

    The PAT is read with Read-Host -AsSecureString: it is not echoed, does not
    enter the PowerShell history, and is never printed by this script. It is
    stored where Windows stores user environment variables, which is the registry
    under HKCU - readable by processes running as you, which is the same exposure
    the MCP server itself has once it holds the token.

    Both values are verified before being stored, not just saved. An unverified
    credential looks configured and fails later, somewhere less obvious.

.PARAMETER CollectionUrl
    The collection URL, for example http://server/DefaultCollection. Prompted for
    when omitted, defaulting to whatever is already configured.

.PARAMETER Pat
    The Personal Access Token, as a SecureString. Prompted for when omitted.
    There is deliberately no plain-string parameter: a token passed as text ends
    up in the session history and in any transcript.

.PARAMETER SkipTest
    Store the values without contacting the server. Use only when the server is
    unreachable from here right now; the values remain unverified.

.PARAMETER Scope
    Where to persist. User (default) survives a reboot; Process lasts for this
    session only, which is useful for trying a token out.

.EXAMPLE
    .\scripts\configure-ado.ps1

.EXAMPLE
    .\scripts\configure-ado.ps1 -CollectionUrl "http://tfs/DefaultCollection"

.EXAMPLE
    .\scripts\configure-ado.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$CollectionUrl,

    [System.Security.SecureString]$Pat,

    [switch]$SkipTest,

    [ValidateSet("User", "Process")]
    [string]$Scope = "User"
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\Console.psm1") -Force

# 7.0, not 7.1. On the on-premises server this was tested against, 5.0, 6.0 and 7.0 answered
# and 7.1 returned HTTP 400 on every endpoint tried. mcp/rules/azure-devops.md carries the numbers.
$apiVersion = "7.0"

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

function Test-Collection {
    <#
        Returns $null on success, or the reason it failed. Never returns the
        response: this only needs to know that the credential works.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [hashtable]$Headers
    )

    $arguments = @{
        Uri         = "$Url/_apis/projects?api-version=$apiVersion&`$top=1"
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
            return "Not found (404). Check the collection name in the URL."
        }

        return $_.Exception.Message
    }
}

Write-Banner -Title "Azure DevOps configuration" -Subtitle "  Collection URL and PAT for the azure-devops MCP"

# ---------------------------------------------------------------------------
# Collection URL
# ---------------------------------------------------------------------------

$currentUrl = [Environment]::GetEnvironmentVariable("ADO_COLLECTION_URL", $Scope)

if (-not $CollectionUrl) {

    $prompt = "Collection URL (e.g. http://server/DefaultCollection)"

    if ($currentUrl) { $prompt = "$prompt [$currentUrl]" }

    $CollectionUrl = (Read-Host -Prompt $prompt).Trim()

    # Enter keeps what is already there. Re-running to change only the token is
    # the common case, and retyping a URL to do it is how a typo gets in.
    if ((-not $CollectionUrl) -and $currentUrl) { $CollectionUrl = $currentUrl }
}

$CollectionUrl = $CollectionUrl.Trim().TrimEnd("/")

if (-not $CollectionUrl) {
    Write-Host ""
    Write-Host "No collection URL given. Nothing was changed."
    Write-Host ""
    exit 1
}

# .StartsWith, not -like: ? is a single-character wildcard in -like.
if (-not ($CollectionUrl.StartsWith("http://") -or $CollectionUrl.StartsWith("https://"))) {
    Write-Host ""
    Write-Host "Not a URL: $CollectionUrl"
    Write-Host "It must start with http:// or https:// and name the collection, as"
    Write-Host "  http://server/DefaultCollection"
    Write-Host ""
    exit 1
}

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
    Write-Host ""
    Write-Host "No PAT given. Nothing was changed."
    Write-Host ""
    exit 1
}

# ---------------------------------------------------------------------------
# Verify before storing
# ---------------------------------------------------------------------------

Write-Section "Verifying"

if ($SkipTest) {
    Write-Status -Label "SKIP" -Detail "-SkipTest: neither value was checked against the server"
}
else {

    # Azure DevOps takes the PAT as HTTP Basic with an empty username.
    $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":" + $patText))
    $patFailure = Test-Collection -Url $CollectionUrl -Headers @{ Authorization = "Basic $basic" }

    if ($patFailure) {
        Write-Status -Label "FAIL" -Detail "PAT: $patFailure"
        Write-Host ""
        Write-Host "The token was NOT stored. Check that it was issued on this server, has not"
        Write-Host "expired, and grants at least read on Code and Work Items."
        Write-Host ""
        exit 1
    }

    Write-Status -Label "OK" -Detail "PAT authenticates against the collection"
}

# ---------------------------------------------------------------------------
# Store
# ---------------------------------------------------------------------------

Write-Section "Storing"

$stored = 0

if ($CollectionUrl -eq $currentUrl) {
    Write-Status -Label "PRESENT" -Detail "ADO_COLLECTION_URL unchanged"
}
elseif ($PSCmdlet.ShouldProcess("ADO_COLLECTION_URL ($Scope)", "Set environment variable")) {

    [Environment]::SetEnvironmentVariable("ADO_COLLECTION_URL", $CollectionUrl, $Scope)
    $env:ADO_COLLECTION_URL = $CollectionUrl
    $stored++
    Write-Status -Label "SET" -Detail "ADO_COLLECTION_URL = $CollectionUrl"
}
else {
    Write-Status -Label "WHATIF" -Detail "would set ADO_COLLECTION_URL = $CollectionUrl"
}

if ($PSCmdlet.ShouldProcess("ADO_PAT ($Scope)", "Set environment variable")) {

    [Environment]::SetEnvironmentVariable("ADO_PAT", $patText, $Scope)
    $env:ADO_PAT = $patText
    $stored++

    # The value is never printed, here or anywhere else in this script.
    Write-Status -Label "SET" -Detail "ADO_PAT = (stored, not shown)"
}
else {
    Write-Status -Label "WHATIF" -Detail "would set ADO_PAT = (not shown)"
}

$patText = $null

# ---------------------------------------------------------------------------
# What to do next
# ---------------------------------------------------------------------------

Write-Section "Next"

if (($Scope -eq "User") -and ($stored -gt 0)) {
    Write-Host "  This session already has the values. A shell that was open before this"
    Write-Host "  does not - restart it, or Claude Code will start the MCP without them."
    Write-Host ""
}

exit 0
