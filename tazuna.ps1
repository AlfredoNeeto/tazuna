<#
.SYNOPSIS
    One entry point for everything in this harness.

.DESCRIPTION
    A dispatcher, not a layer. Every command here forwards to the script that
    already does the work, with its arguments untouched, so there is nothing to
    keep in step and nothing new to learn once you know the scripts.

    It exists so that `tazuna` with no arguments tells you what there is.

.EXAMPLE
    .\tazuna.ps1
    .\tazuna.ps1 doctor
    tazuna init                             # from inside the project; detects the rest
    tazuna mcp add azure-devops
#>
# Deliberately NOT [CmdletBinding()]. An advanced function rejects a named
# parameter it does not declare, so `tazuna.ps1 setup -WhatIf` failed with
# "a positional parameter cannot be found" instead of forwarding -WhatIf - which
# would have made this dispatcher's one promise false. Without CmdletBinding,
# everything unbound lands in $args and passes straight through.
param(
    [string]$Command
)

$Arguments = @($args)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "scripts\lib\Console.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "scripts\lib\Manifest.psm1") -Force

# name -> script, one line of help. Order is the order help prints them, which
# is roughly the order you need them in.
$commands = [ordered]@{
    "setup"  = @{ Script = "bootstrap.ps1";    Help = "Set up or repair this machine: toolkit, skills, MCP, then verify" }
    "init"   = @{ Script = "init-project.ps1"; Help = "Connect the project you are in: AGENTS.md, verify.ps1, toolkit policy" }
    "mcp"    = @{ Script = "project-mcp.ps1";  Help = "Add an MCP to the project you are in:  mcp list | mcp add <name>" }
    "doctor" = @{ Script = "health-check.ps1"; Help = "Check the toolchain, the installed harness and drift against this repository" }
    "update" = @{ Script = "update.ps1";       Help = "Fast-forward this repository, then run setup again" }
    "test"   = @{ Script = "test-harness.ps1"; Help = "Run the self-test" }
}

function Show-Help {

    Write-Banner -Title ("Tazuna " + (Get-HarnessManifest).Version) -Subtitle "  tazuna <command> [options]"

    Write-Section "Commands"

    foreach ($name in $commands.Keys) {
        Write-Entry -Name ("  {0,-10}" -f $name) -Text $commands[$name].Help
    }

    Write-Entry -Name ("  {0,-10}" -f "help") -Text "Show what a command does, its options and examples:  help <command>"
    Write-Entry -Name ("  {0,-10}" -f "version") -Text "Print the installed version"

    Write-Host ""
    Write-Host "  Every command forwards its arguments untouched. setup, init, mcp and update"
    Write-Host "  accept -WhatIf. tazuna <command> --help does not run the command."
    Write-Host ""
}

function Show-CommandHelp {
    <# Reads the comment-based help the script already carries, so there is no second copy to drift. #>
    param([string]$Name)

    $file = $commands[$Name].Script
    $help = Get-Help (Join-Path $PSScriptRoot (Join-Path "scripts" $file))
    $usage = "tazuna $Name"

    Write-Banner -Title ("Tazuna " + (Get-HarnessManifest).Version) -Command $Name -Subtitle ("  " + ([string]$help.Synopsis).Trim())

    $options = @($help.parameters.parameter | Where-Object { $_.name -and ($_.name -ne "Confirm") })

    if ($options.Count -gt 0) {

        Write-Section "Options"

        foreach ($option in $options) {
            $text = (@($option.description | ForEach-Object { $_.Text }) -join "`n").Replace("`r", "")
            if ($option.name -eq "WhatIf") { $text = "Show what would change, and change nothing" }
            $lines = @(($text -split "`n`n")[0] -split "`n")
            Write-Entry -Name ("  -{0,-18}" -f $option.name) -Text $lines[0].Trim()
            foreach ($line in ($lines | Select-Object -Skip 1)) { Write-Host ((" " * 21) + $line.Trim()) }
        }
    }

    Write-Section "Examples"

    foreach ($example in @($help.examples.example)) {
        $lines = @($example.code) + @($example.remarks | ForEach-Object { $_.Text -split "`n" })
        foreach ($line in ($lines | Where-Object { $_ -and $_.Trim() })) {
            # why: the examples name the script; the reader types the command.
            Write-Host ("  " + $line.Trim().Replace(".\scripts\" + $file, $usage))
        }
    }

    Write-Host ""
}

function Get-EditDistance {
    param([string]$A, [string]$B)

    $previous = 0..$B.Length

    for ($i = 1; $i -le $A.Length; $i++) {
        $current = @($i) + @(0) * $B.Length
        for ($j = 1; $j -le $B.Length; $j++) {
            $cost = [int]($A[$i - 1] -ne $B[$j - 1])
            $current[$j] = [Math]::Min([Math]::Min($current[$j - 1] + 1, $previous[$j] + 1), $previous[$j - 1] + $cost)
        }
        $previous = $current
    }

    return $previous[$B.Length]
}

function Exit-UnknownCommand {
    param([string]$Name)

    $names = @($commands.Keys) + @("help", "version")

    Write-Host ""
    Write-Host "Unknown command: $Name"

    # invariant: 2 edits catches doctr, setpu and updte without suggesting an unrelated command.
    $closest = $names | Sort-Object { Get-EditDistance -A $Name -B $_ } | Select-Object -First 1
    if ((Get-EditDistance -A $Name -B $closest) -le 2) { Write-Host "Did you mean 'tazuna $closest'?" }

    Write-Host ("Commands: " + ($names -join ", "))
    Write-Host ""
    exit 1
}

# why: `tazuna -v` binds nothing to -Command - PowerShell reads "-v" as a parameter name - so the flag arrives in $Arguments.
if ((-not $Command) -and ($Arguments.Count -gt 0)) {
    $Command = [string]$Arguments[0]
    $Arguments = @($Arguments | Select-Object -Skip 1)
}

$helpFlags = @("-h", "--help", "-?", "/?")

if ((-not $Command) -or ($Command -eq "help") -or ($Command -in $helpFlags)) {

    $topic = $null
    if ($Command -eq "help") { $topic = $Arguments | Select-Object -First 1 }

    if ((-not $topic) -or ($topic -in @("help", "version"))) {
        Show-Help
        exit 0
    }

    if (-not $commands.Contains([string]$topic)) { Exit-UnknownCommand -Name $topic }

    Show-CommandHelp -Name $topic
    exit 0
}

if ($Command -in @("version", "--version", "-v")) {
    Write-Host ("tazuna " + (Get-HarnessManifest).Version)
    exit 0
}

if (-not $commands.Contains($Command)) { Exit-UnknownCommand -Name $Command }

if (@($Arguments | Where-Object { $helpFlags -contains $_ }).Count -gt 0) {
    Show-CommandHelp -Name $Command
    exit 0
}

$scriptName = $commands[$Command].Script
$forward = $Arguments

$scriptPath = Join-Path $PSScriptRoot (Join-Path "scripts" $scriptName)

if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Missing $scriptPath. The dispatcher and the scripts have drifted apart."
}

# Cleared first: a script that returns without calling exit leaves $LASTEXITCODE
# holding whatever the last native command set, and the dispatcher would hand
# that back as its own result.
$global:LASTEXITCODE = 0

& $scriptPath @forward

exit $LASTEXITCODE
