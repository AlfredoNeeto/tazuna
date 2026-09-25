<#
.SYNOPSIS
    Registers the user-scope MCP servers defined in mcp/servers.json.

.DESCRIPTION
    User-scope MCP servers live in ~/.claude.json, which is machine-local state and must never
    be version-controlled. This script is how they get version-controlled anyway: the
    definitions live in mcp/servers.json, and this registers them on each machine.

    Project-scope servers do not need it. Those belong in a project's own .mcp.json, which is
    already version-controlled with the project: `tazuna mcp add <name>` writes them
    from mcp/catalog.json.

    Secrets are never written into the definition. Use ${ENV_VAR} placeholders; this script
    refuses to register an entry that contains a literal-looking credential, because
    mcp/servers.json is committed.

.PARAMETER Force
    Re-register servers that are already present.

.PARAMETER NoTitle
    Leave the title out. tazuna setup passes it, because it prints its own.

.EXAMPLE
    .\scripts\install-mcp.ps1 -WhatIf

.EXAMPLE
    .\scripts\install-mcp.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Force,

    [switch]$NoTitle
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\Json.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Console.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Manifest.psm1") -Force

# High-signal shapes only. A noisy check would be worked around rather than fixed.
$secretPatterns = @(
    @{ Name = "private key block"; Pattern = "-----BEGIN [A-Z ]*PRIVATE KEY-----" },
    @{ Name = "AWS access key id"; Pattern = "AKIA[0-9A-Z]{16}" },
    @{ Name = "GitHub token";      Pattern = "gh[pousr]_[A-Za-z0-9]{36}" },
    @{ Name = "Slack token";       Pattern = "xox[baprs]-[A-Za-z0-9-]{10,}" },
    @{ Name = "Google API key";    Pattern = "AIza[0-9A-Za-z_\-]{35}" },
    @{ Name = "Anthropic API key"; Pattern = "sk-ant-[A-Za-z0-9_\-]{20,}" },
    @{ Name = "OpenAI API key";    Pattern = "sk-[A-Za-z0-9]{32,}" }
)

$repoRoot = Split-Path -Parent $PSScriptRoot
$definitionFile = Join-Path $repoRoot (Join-Path "mcp" "servers.json")

if (-not $NoTitle) {
    Write-Banner -Title ("Tazuna " + (Get-HarnessManifest).Version) -Command "mcp"
    Write-Host ""
}

Write-Host "Definitions: $definitionFile"
Write-Host ""

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Claude Code was not found in PATH."
    exit 1
}

$parseError = $null

if (-not (Test-JsonFile -Path $definitionFile -ErrorMessage ([ref]$parseError))) {
    Write-Host "ERROR: $definitionFile is not valid JSON: $parseError"
    exit 1
}

$definition = Get-Content -LiteralPath $definitionFile -Raw | ConvertFrom-Json

if (-not $definition.mcpServers) {
    Write-Host "No mcpServers section found; nothing to register."
    Write-Host ""
    exit 0
}

# Filter explicitly: an empty object yields $null, and @($null) is an array
# of one, which would make an empty catalogue look like one server.
$names = @($definition.mcpServers.PSObject.Properties.Name | Where-Object { $_ })

if ($names.Count -eq 0) {
    Write-Host "No user-scope MCP servers are defined."
    Write-Host ""
    Write-Host "This is the default. Before adding one, answer the questions in docs/mcp.md:"
    Write-Host "what it makes possible, its trust boundary, how its tools are scoped in the"
    Write-Host "permission model, user or project level, and what it displaces."
    Write-Host ""
    exit 0
}

# Refuse the whole file rather than registering the clean entries: a committed
# credential is already leaked, and a partial success hides that.
$leaks = @()

foreach ($name in $names) {

    $entryText = $definition.mcpServers.$name | ConvertTo-Json -Depth 20

    foreach ($secret in $secretPatterns) {
        if ($entryText -match $secret.Pattern) {
            $leaks += "$name contains what looks like a $($secret.Name)"
        }
    }
}

if ($leaks.Count -gt 0) {

    Write-Host "REFUSING to register: mcp/servers.json is version-controlled and contains"
    Write-Host "literal credentials."
    Write-Host ""

    foreach ($leak in $leaks) {
        Write-Host "  - $leak"
    }

    Write-Host ""
    Write-Host "Replace them with `${ENV_VAR} placeholders, then rotate the exposed values:"
    Write-Host "they are in the file's history even after you edit it."
    Write-Host ""
    exit 1
}

$existing = @()

$previous = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$listing = (& claude mcp list | Out-String)
$ErrorActionPreference = $previous

$registered = 0
$skipped = 0
$wouldRegister = 0

$unrunnable = 0

foreach ($name in $names) {

    # Registering writes a JSON entry; it does not check that the command
    # exists. A stdio server whose runtime is absent therefore registers
    # happily, is reported as installed, and then fails to start in every
    # session - which is reported as a connection problem, because that is what
    # a server that does not answer looks like from the outside.
    #
    # Measured on a second machine: serena registered with no uvx installed.
    $entryCommand = $definition.mcpServers.$name.command
    $alreadyRegistered = ($listing -match ("(?m)^\s*" + [regex]::Escape($name) + "\b"))

    if ($entryCommand -and (-not (Get-Command $entryCommand -ErrorAction SilentlyContinue))) {

        $unrunnable++

        # Already registered is a different sentence from not registered. Saying
        # "skipped" about a server that is sitting in ~/.claude.json failing to
        # start every session would send someone to re-register it.
        if ($alreadyRegistered) {
            Write-Status -Label "BROKEN" -Detail "$name is registered but '$entryCommand' is not in PATH"
            Write-Host "            it will fail to start in every session until that is fixed."
        }
        else {
            Write-Status -Label "SKIP" -Detail "$name not registered: '$entryCommand' is not in PATH"
            Write-Host "            registering it would only produce a server that cannot start."
        }

        $hint = $definition.mcpServers.$name."`$install"

        if ($hint) { Write-Host ("            install: " + $hint) }

        Write-Host "            then open a new shell and run this again"
        continue
    }

    # A registered server is not necessarily the CATALOGUED server. Editing a
    # definition here changed nothing on a machine that had already registered
    # it: the name was present, so it was reported present and left alone, and
    # the machine kept running the old definition forever. Measured when serena
    # moved from a git checkout to a pinned release.
    #
    # `claude mcp list` prints the effective command line, so it is what settles
    # whether what is registered is what this repository declares.
    $entry = $definition.mcpServers.$name
    $expected = $null

    if ($entry.command) {
        $expected = (@($entry.command) + @($entry.args | Where-Object { $_ })) -join " "
    }
    elseif ($entry.url) {
        $expected = $entry.url
    }

    $registeredLine = @($listing -split "`n" | Where-Object { $_.TrimStart().StartsWith($name + ":") }) |
        Select-Object -First 1

    $matchesCatalogue = $true

    if ($alreadyRegistered -and $expected) {
        $matchesCatalogue = ($registeredLine -and $registeredLine.Contains($expected))
    }

    if ($alreadyRegistered -and $matchesCatalogue -and (-not $Force)) {
        $skipped++
        Write-Status -Label "PRESENT" -Detail "$name (pass -Force to re-register)"
        continue
    }

    if ($alreadyRegistered) {

        if (-not $matchesCatalogue) {
            Write-Status -Label "STALE" -Detail "$name is registered with a different definition; replacing it"
        }

        if ($WhatIfPreference) {
            Write-Status -Label "WHATIF" -Detail "would remove the registered $name before replacing it"
        }
        elseif ($PSCmdlet.ShouldProcess($name, "Remove the existing registration before replacing it")) {

            # `claude mcp add-json` REFUSES a name that already exists - it does
            # not replace. Without this removal, -Force failed with "exited 1"
            # and re-registration was impossible.
            $ErrorActionPreference = "Continue"
            $global:LASTEXITCODE = 0
            & claude mcp remove $name --scope user | Out-Null
            $removeCode = $LASTEXITCODE
            $ErrorActionPreference = $previous

            if ($removeCode -ne 0) {
                Write-Status -Label "FAIL" -Detail "$name could not be removed (claude mcp remove exited $removeCode)"
                Write-Host ""
                exit 1
            }
        }
    }

    if ($WhatIfPreference -or (-not $PSCmdlet.ShouldProcess($name, "Register user-scope MCP server"))) {

        # Counted separately. Adding these to $registered made the summary
        # report work that a dry run had explicitly not done.
        $wouldRegister++
        Write-Status -Label "WHATIF" -Detail "would register $name"
        continue
    }

    # Documentation keys are stripped before the definition is sent: `claude mcp
    # add-json` validates strictly and rejects the whole entry on an unknown
    # field. Keeping the reason next to the definition is worth this much code -
    # a catalogue that cannot say why a server is in it becomes a list nobody
    # dares to prune.
    $entry = $definition.mcpServers.$name
    $clean = New-Object PSObject

    foreach ($property in $entry.PSObject.Properties) {

        if ($property.Name.StartsWith("$")) { continue }

        Add-Member -InputObject $clean -MemberType NoteProperty -Name $property.Name -Value $property.Value
    }

    $json = $clean | ConvertTo-Json -Depth 20 -Compress

    # Windows PowerShell 5.1 does not escape embedded quotes when it hands an
    # argument to a native executable, so the JSON arrives at `claude` with its
    # quotes stripped and is rejected as "Invalid input". Escaping them here is
    # the documented workaround; PowerShell 7 does not need it, and doing it
    # unconditionally is still correct because the escape survives either way.
    $json = $json.Replace('"', '\"')

    $ErrorActionPreference = "Continue"
    $global:LASTEXITCODE = 0
    & claude mcp add-json --scope user $name $json | Out-Null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous

    if ($code -ne 0) {
        Write-Status -Label "FAIL" -Detail "$name (claude mcp add-json exited $code)"
        Write-Host ""
        exit 1
    }

    $registered++
    Write-Status -Label "ADDED" -Detail $name
}

Write-Host ""

if ($wouldRegister -gt 0) {
    Write-Host ("MCP: would register {0}, {1} already present. Nothing was changed." -f $wouldRegister, $skipped)
}
else {
    Write-Host ("MCP: {0} registered, {1} already present." -f $registered, $skipped)
}

# Counted separately and stated separately. Folded into "already present" this
# would read as success, which is the whole failure being fixed here.
if ($unrunnable -gt 0) {
    Write-Host ("     {0} cannot run on this machine - see the lines above." -f $unrunnable)
}

# Warm-up
# -------
# A registered server still has to START, and the first start of a uvx or npx
# server downloads and resolves its whole runtime. That exceeds the MCP client's
# startup timeout, so the server is reported as registered and then fails to
# connect - measured on a second machine, where serena had uvx installed and
# still did not come up.
#
# Warming runs the same third-party code that was just registered and would run
# on first use anyway, so it is not a new trust decision. It is skipped under
# -WhatIf and is never fatal: a cold cache is slow, not broken.
$warmable = @($names | Where-Object { $definition.mcpServers.$_."`$warm" })

if ($warmable.Count -gt 0) {

    Write-Host ""
    Write-Host "Warming up"
    Write-Host "----------"

    foreach ($name in $warmable) {

        $entryCommand = $definition.mcpServers.$name.command

        if ($entryCommand -and (-not (Get-Command $entryCommand -ErrorAction SilentlyContinue))) {
            continue
        }

        $warm = $definition.mcpServers.$name."`$warm"

        if ($WhatIfPreference -or (-not $PSCmdlet.ShouldProcess($name, "Warm the server's runtime cache"))) {
            Write-Status -Label "WHATIF" -Detail "would warm $name"
            continue
        }

        Write-Status -Label "WARM" -Detail "$name (first run downloads its runtime; this can take minutes)"

        $ErrorActionPreference = "Continue"
        $global:LASTEXITCODE = 0

        # invariant: never fatal. Handled here because setup traps every error
        # that reaches it, and an unhandled one would end setup at this step.
        try {
            Invoke-Expression $warm 2>&1 | Out-Null
            $warmCode = $LASTEXITCODE
        }
        catch {
            $warmCode = 1
        }

        $ErrorActionPreference = $previous

        if ($warmCode -ne 0) {
            Write-Status -Label "WARN" -Detail "$name did not warm (exit $warmCode); its first start will be slow"
        }
    }
}

Write-Host ""
Write-Host "Scope their tools in the permission model as mcp__<server>__<tool>, and treat"
Write-Host "every response as untrusted input rather than instructions."
Write-Host ""

exit 0
