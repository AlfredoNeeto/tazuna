<#
.SYNOPSIS
    Installs the version-controlled user harness into the Claude Code config directory.

.DESCRIPTION
    Copies everything under user/ into the directory reported by Get-ClaudeConfigDir
    (CLAUDE_CONFIG_DIR when set, otherwise ~/.claude).

    When Cursor is installed (~/.cursor exists), also copies user/skills and
    user/agents there, and writes user/CLAUDE.md as the global Cursor rule
    rules/tazuna.mdc - Cursor reads no CLAUDE.md or settings.json of its own.

    The installer is idempotent: files whose contents already match are reported
    UNCHANGED and left alone. Any file that would be overwritten is backed up to
    <config>/.harness-backup/<timestamp>/ first.

    It never touches credentials, session state or machine-local files; it only
    writes the paths that exist under user/.

    settings.json is replaced whole, which drops the hooks block the
    harness-toolkit merges into it. bootstrap.ps1 therefore always runs
    `tlc harness install` after this, and `tazuna doctor` fails when the
    toolkit hook is missing.

.PARAMETER NoTitle
    Leave the title out. tazuna setup passes it, because it prints its own.

.PARAMETER NoClaude
    Leave the Claude Code config directory alone. tazuna setup passes it on a
    machine without Claude Code, where ~/.claude/settings.json would only be
    imported by Cursor as a second set of hooks.

.NOTES
    Set TAZUNA_SKIP_PATH=1 to leave the user PATH alone; the self-test does, so
    running it from any checkout never changes the machine's PATH.

.EXAMPLE
    .\scripts\install.ps1 -WhatIf
    Shows what would change without writing anything.

.EXAMPLE
    .\scripts\install.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$NoTitle,
    [switch]$NoClaude
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\Paths.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Files.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Json.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Console.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Manifest.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Cursor.psm1") -Force

$repoRoot = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repoRoot "user"
$target = Get-ClaudeConfigDir
$cursorDir = Get-CursorConfigDir
$hasCursor = Test-Path -LiteralPath $cursorDir

if (-not $NoTitle) {
    Write-Banner -Title ("Tazuna " + (Get-HarnessManifest).Version) -Command "install"
    Write-Host ""
}

Write-Host "Source:  $source"

if (-not $NoClaude) {
    Write-Host "Target:  $target"

    if ($env:CLAUDE_CONFIG_DIR) {
        Write-Host "         (from CLAUDE_CONFIG_DIR)"
    }
}

if ($hasCursor) {
    Write-Host "Cursor:  $cursorDir"
}

Write-Host ""

if (-not (Test-Path -LiteralPath $source)) {
    Write-Host "ERROR: user/ directory not found at $source"
    exit 1
}

$sourceFiles = @(Get-ChildItem -LiteralPath $source -File -Recurse -Force)

if ($sourceFiles.Count -eq 0) {
    Write-Host "ERROR: user/ contains no files to install."
    exit 1
}

# Validate every JSON file before writing anything, so a syntax error can never
# be installed over a working configuration.
$invalid = @()

foreach ($file in $sourceFiles) {
    if ($file.Extension -eq ".json") {
        $parseError = $null

        if (-not (Test-JsonFile -Path $file.FullName -ErrorMessage ([ref]$parseError))) {
            $relative = Get-CompatibleRelativePath -BasePath $source -TargetPath $file.FullName
            $invalid += "$relative : $parseError"
        }
    }
}

if ($invalid.Count -gt 0) {
    Write-Host "ERROR: invalid JSON in the source harness; nothing was installed."
    Write-Host ""

    foreach ($entry in $invalid) {
        Write-Host "  $entry"
    }

    Write-Host ""
    exit 1
}

if ((-not $NoClaude) -and (-not (Test-Path -LiteralPath $target))) {
    # why: $WhatIfPreference before ShouldProcess, here and below - under -WhatIf
    # ShouldProcess prints its own "What if:" line, doubling the WHATIF one.
    if ($WhatIfPreference) {
        Write-Status -Label "WHATIF" -Detail "would create $target"
    }
    elseif ($PSCmdlet.ShouldProcess($target, "Create configuration directory")) {
        New-Item -ItemType Directory -Path $target -Force | Out-Null
    }
}

$backupRoot = New-HarnessBackupRoot -ParentDirectory $target

# One entry per file to write: where it comes from, where it goes, where its backup goes.
$installs = @()

if (-not $NoClaude) {
    foreach ($file in $sourceFiles) {
        $relative = Get-CompatibleRelativePath -BasePath $source -TargetPath $file.FullName
        $installs += [PSCustomObject]@{ Source = $file.FullName; Root = $target; Relative = $relative; Backup = $backupRoot; Label = $relative }
    }
}

$ruleStage = $null

if ($hasCursor) {

    $cursorBackup = New-HarnessBackupRoot -ParentDirectory $cursorDir

    foreach ($file in $sourceFiles) {
        $relative = Get-CompatibleRelativePath -BasePath $source -TargetPath $file.FullName
        $top = $relative.Split([System.IO.Path]::DirectorySeparatorChar)[0]

        if (@("skills", "agents") -contains $top) {
            $installs += [PSCustomObject]@{ Source = $file.FullName; Root = $cursorDir; Relative = $relative; Backup = $cursorBackup; Label = "cursor: $relative" }
        }
    }

    # why: Cursor keeps global rules as .mdc files in ~/.cursor/rules; it reads no ~/.claude/CLAUDE.md.
    $ruleStage = Join-Path ([System.IO.Path]::GetTempPath()) ("tazuna-rule-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $ruleStage -Force -WhatIf:$false | Out-Null
    $staged = Join-Path $ruleStage "tazuna.mdc"
    $instructions = [System.IO.File]::ReadAllText((Join-Path $source "CLAUDE.md"))
    [System.IO.File]::WriteAllText($staged, (ConvertTo-CursorRule -Text $instructions -Description "Tazuna engineering instructions"))

    $relative = Join-Path "rules" "tazuna.mdc"
    $installs += [PSCustomObject]@{ Source = $staged; Root = $cursorDir; Relative = $relative; Backup = $cursorBackup; Label = "cursor: $relative" }
}

$created = 0
$updated = 0
$unchanged = 0

foreach ($install in $installs) {

    $relative = $install.Label
    $targetFile = Join-Path $install.Root $install.Relative

    $willOverwrite = (Test-Path -LiteralPath $targetFile) -and
                     -not (Test-FileContentEqual -ReferenceFile $install.Source -DifferenceFile $targetFile)

    # -WhatIf must be passed explicitly: PowerShell preference variables do not
    # cross the module boundary, so the module function would otherwise write
    # for real during a dry run.
    $result = Copy-FileIfChanged `
        -SourceFile $install.Source `
        -TargetFile $targetFile `
        -BackupRoot $install.Backup `
        -BackupRelativePath $install.Relative `
        -WhatIf:$WhatIfPreference

    switch ($result) {
        "Created" {
            $created++

            if ($WhatIfPreference) { Write-Status -Label "WHATIF" -Detail "would install $relative" }
            else { Write-Status -Label "INSTALL" -Detail $relative }
        }
        "Updated" {
            $updated++

            if ($WhatIfPreference) {
                Write-Status -Label "WHATIF" -Detail "would update $relative, backing up the current one"
            }
            elseif ($willOverwrite) {
                Write-Status -Label "BACKUP" -Detail $relative
            }

            if (-not $WhatIfPreference) { Write-Status -Label "UPDATE" -Detail $relative }
        }
        "Unchanged" {
            $unchanged++
            Write-Status -Label "UNCHANGED" -Detail $relative
        }
    }
}

if ($ruleStage) {
    Remove-Item -LiteralPath $ruleStage -Recurse -Force -WhatIf:$false
}

# Put the harness on PATH, so `tazuna init` works from inside a project.
# Without this every instruction that says "cd into your project, then run
# tazuna init" is wrong: .\tazuna.ps1 is not there, and the documented
# command cannot work from the directory it tells you to be in.
#
# It is bin\ on PATH, not the repository root, and that is not tidiness.
# PowerShell resolves an ExternalScript BEFORE an Application, so with
# tazuna.ps1 and tazuna.cmd in one directory `tazuna` picks the .ps1 every
# time - measured with Get-Command -All. On a machine whose ExecutionPolicy is
# AllSigned that reintroduces the exact failure the .cmd exists to avoid.
# bin\ holds only the .cmd.
#
# User scope, no elevation, reversible from the same Environment Variables
# dialog. configure-ado.ps1 already writes user environment variables, so this
# is not a new kind of change to the machine.
$binDirectory = Join-Path $repoRoot "bin"
$userPath = [Environment]::GetEnvironmentVariable("PATH", "User")

$entries = @($userPath -split ";" | Where-Object { $_ })

$onPath = $false
$staleRoot = $false

foreach ($entry in $entries) {

    $trimmed = $entry.Trim().TrimEnd("\")

    if ($trimmed -eq $binDirectory.TrimEnd("\")) { $onPath = $true }

    # An earlier version put the repository root itself on PATH. Left there, it
    # comes first and `tazuna` resolves to tazuna.ps1 again, so adding bin\
    # would fix nothing on a machine that already ran that version.
    if ($trimmed -eq $repoRoot.TrimEnd("\")) { $staleRoot = $true }
}

if ($env:TAZUNA_SKIP_PATH -and ((-not $onPath) -or $staleRoot)) {
    # why: the self-test runs this installer from scratch checkouts, and each would otherwise
    # leave its own bin\ on the real user PATH.
    Write-Status -Label "SKIP" -Detail "user PATH left alone (TAZUNA_SKIP_PATH is set)"
}
elseif ((-not $onPath) -or $staleRoot) {

    if ($WhatIfPreference) {
        Write-Status -Label "WHATIF" -Detail "would put $binDirectory on the user PATH"
    }
    elseif ($PSCmdlet.ShouldProcess($binDirectory, "Put the harness launcher on the user PATH")) {

        $kept = @($entries | Where-Object { $_.Trim().TrimEnd("\") -ne $repoRoot.TrimEnd("\") })

        if (-not $onPath) { $kept += $binDirectory }

        [Environment]::SetEnvironmentVariable("PATH", ($kept -join ";"), "User")

        # This process too, so the rest of a bootstrap run can use it. Other
        # shells only pick it up when they start.
        $env:PATH = $env:PATH.TrimEnd(";") + ";" + $binDirectory

        if ($staleRoot) {
            Write-Status -Label "PATH" -Detail "removed $repoRoot - it made 'tazuna' resolve to the .ps1"
        }

        if (-not $onPath) {
            Write-Status -Label "PATH" -Detail "added $binDirectory - 'tazuna' now works from any directory"
            Write-Host "            shells already open must be restarted to see it"
        }
    }
}

Write-Host ""

if ($WhatIfPreference) {
    Write-Host ("Dry run: {0} to create, {1} to update, {2} unchanged. Nothing was changed." -f $created, $updated, $unchanged)
}
else {
    Write-Host ("Installed: {0} created, {1} updated, {2} unchanged." -f $created, $updated, $unchanged)
}

if ($updated -gt 0) {
    foreach ($backup in @(@($installs | ForEach-Object { $_.Backup }) | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ })) {
        Write-Host ""
        Write-Host "Previous versions backed up to:"
        Write-Host "  $backup"
    }
}

Write-Host ""

exit 0
