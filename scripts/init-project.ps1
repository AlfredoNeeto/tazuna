<#
.SYNOPSIS
    Moves a project off Tazuna 1.x's verification gate and hands it to harness-toolkit.

.DESCRIPTION
    Tazuna 1.x wrote its own Stop gate into each project. In 2.0 the project's
    gate is harness-toolkit's grind, set up by /harness-init. Left in place, the
    old gate would keep running beside it, so this removes what 1.x installed,
    backing every file up under <project>/.harness-backup/<timestamp>/ first:

      - always: the three hooks in .claude/hooks, .claude/scripts/VerifyCommon.psm1
        and .claude/state/, which 1.x overwrote without asking and which belong
        to no one else;
      - only while identical to a version 1.x shipped: .claude/scripts/verify.ps1
        and the stack rules in .claude/rules and .cursor/rules. An edited
        verify.ps1 is kept, and its steps are printed as the gate command to set;
      - surgically: the hook entries and verify.ps1 allow rules in
        .claude/settings.json, Tazuna's entries in .cursor/hooks.json (the file
        goes when nothing else is left in it), and .claude/state/ in .gitignore.

    AGENTS.md is the project's and is not touched. It ends with how to set up
    the project with harness-toolkit. Running it again changes nothing.

.PARAMETER Path
    The project directory. Defaults to the current directory.

.EXAMPLE
    .\scripts\init-project.ps1 -WhatIf

.EXAMPLE
    .\scripts\init-project.ps1 -Path C:\src\MyApi
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Path = "."
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\Paths.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Files.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Console.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Manifest.psm1") -Force

$projectRoot = Resolve-HarnessPath -Path $Path

if (-not (Test-Path -LiteralPath $projectRoot -PathType Container)) {
    Write-Host "ERROR: $projectRoot is not a directory."
    exit 1
}

$manifest = Get-HarnessManifest
$backupRoot = New-HarnessBackupRoot -ParentDirectory $projectRoot
$hookNames = @("require-verification.ps1", "record-session-baseline.ps1", "block-secret-commit.ps1")
$changes = 0

Write-Banner -Title ("Tazuna " + $manifest.Version) -Command "init"
Write-Host ""
Write-Host "Project: $projectRoot"
Write-Host ""

function Write-Change {
    param([string]$Detail)
    $script:changes++
    if ($WhatIfPreference) { Write-Status -Label "WHATIF" -Detail "would $Detail" }
    else { Write-Status -Label "REMOVE" -Detail $Detail }
}

function Save-Backup {
    param([string]$Relative)
    $backup = Join-Path $backupRoot $Relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $projectRoot $Relative) -Destination $backup -Force
}

function Save-Json {
    # why: backed up first, because ConvertTo-Json rewrites the whole layout of the file.
    param([string]$Relative, [object]$Value)
    if ($WhatIfPreference) { return }
    Save-Backup -Relative $Relative
    Set-Utf8Content -Path (Join-Path $projectRoot $Relative) -Value ($Value | ConvertTo-Json -Depth 100)
}

function Test-TazunaHook {
    # invariant: a 1.x hook entry names one of the three gate scripts in its command or its arguments.
    param([object]$Entry)
    $text = (@($Entry.command) + @($Entry.args) | Where-Object { $_ }) -join " "
    foreach ($name in $hookNames) {
        if ($text -like "*.claude/hooks/$name*") { return $true }
    }
    return $false
}

# why: 1.x overwrote these on every init, so they are Tazuna's whatever they hold.
$owned = @($hookNames | ForEach-Object { Join-Path ".claude" (Join-Path "hooks" $_) }) + @(Join-Path ".claude" (Join-Path "scripts" "VerifyCommon.psm1"))

foreach ($relative in $owned) {
    $file = Join-Path $projectRoot $relative
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
    $null = Remove-FileIfUnchanged -TargetFile $file -Sha256 @(Get-FileSha256 -Path $file) -BackupRoot $backupRoot `
        -BackupRelativePath $relative -StopAt $projectRoot -WhatIf:$WhatIfPreference
    Write-Change -Detail "remove $relative"
}

$state = Join-Path $projectRoot (Join-Path ".claude" "state")

if (Test-Path -LiteralPath $state) {
    if ((-not $WhatIfPreference) -and $PSCmdlet.ShouldProcess($state, "Remove the 1.x gate state")) {
        Remove-Item -LiteralPath $state -Recurse -Force
    }
    Write-Change -Detail ("remove " + (Join-Path ".claude" "state") + " (the old gate's state)")
}

# why: these were a starting point the project could edit; an edit is the project's, so only an untouched copy goes.
foreach ($relative in @($manifest.Retired.Project.Keys | Sort-Object)) {

    $file = Join-Path $projectRoot $relative
    $result = Remove-FileIfUnchanged -TargetFile $file -Sha256 $manifest.Retired.Project[$relative] -BackupRoot $backupRoot `
        -BackupRelativePath $relative -StopAt $projectRoot -WhatIf:$WhatIfPreference

    if ($result -eq "Removed") { Write-Change -Detail "remove $relative" }
    elseif ($result -eq "Kept") {
        Write-Status -Label "WARN" -Detail "kept $($relative): edited since Tazuna installed it"

        if ($relative.EndsWith("verify.ps1")) {
            $steps = [regex]::Match([System.IO.File]::ReadAllText($file), '(?ms)^\$VerificationSteps = @\((.*?)^\)')
            if ($steps.Success -and $steps.Groups[1].Value.Trim()) {
                Write-Host "            its steps, to set as the gate command:"
                foreach ($line in ($steps.Groups[1].Value.Trim() -split "\r?\n")) { Write-Host "              $($line.Trim())" }
            }
            Write-Host "            the old gate no longer runs it; delete it once the toolkit gate runs these steps"
        }
    }
}

# invariant: only the entries 1.x added leave settings.json; the project's own keys and hooks stay.
$settingsRelative = Join-Path ".claude" "settings.json"
$settingsFile = Join-Path $projectRoot $settingsRelative

if (Test-Path -LiteralPath $settingsFile) {

    $settings = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
    $before = $settings | ConvertTo-Json -Depth 100

    if ($settings.PSObject.Properties["hooks"]) {
        foreach ($event in @($settings.hooks.PSObject.Properties)) {
            $groups = @()
            foreach ($group in @($event.Value)) {
                $group.hooks = @($group.hooks | Where-Object { -not (Test-TazunaHook -Entry $_) })
                if ($group.hooks.Count -gt 0) { $groups += $group }
            }
            if ($groups.Count -gt 0) { $settings.hooks.($event.Name) = $groups }
            else { $settings.hooks.PSObject.Properties.Remove($event.Name) }
        }
        if (@($settings.hooks.PSObject.Properties).Count -eq 0) { $settings.PSObject.Properties.Remove("hooks") }
    }

    if ($settings.PSObject.Properties["permissions"] -and $settings.permissions.PSObject.Properties["allow"]) {
        $settings.permissions.allow = @($settings.permissions.allow | Where-Object { $_ -notlike "*verify.ps1*" })
    }

    if (($settings | ConvertTo-Json -Depth 100) -ne $before) {
        Save-Json -Relative $settingsRelative -Value $settings
        Write-Change -Detail "remove the old gate's hooks and verify.ps1 rules from $settingsRelative"
    }
}

# invariant: hooks.json itself goes only when the old gate was all it held.
$cursorRelative = Join-Path ".cursor" "hooks.json"
$cursorFile = Join-Path $projectRoot $cursorRelative

if (Test-Path -LiteralPath $cursorFile) {

    $cursor = Get-Content -LiteralPath $cursorFile -Raw | ConvertFrom-Json
    $removedHere = 0
    $left = 0

    if ($cursor.PSObject.Properties["hooks"]) {
        foreach ($event in @($cursor.hooks.PSObject.Properties)) {
            $kept = @($event.Value | Where-Object { -not (Test-TazunaHook -Entry $_) })
            $removedHere += @($event.Value).Count - $kept.Count
            $left += $kept.Count
            if ($kept.Count -gt 0) { $cursor.hooks.($event.Name) = $kept }
            else { $cursor.hooks.PSObject.Properties.Remove($event.Name) }
        }
    }

    if (($removedHere -gt 0) -and ($left -eq 0)) {
        $null = Remove-FileIfUnchanged -TargetFile $cursorFile -Sha256 @(Get-FileSha256 -Path $cursorFile) -BackupRoot $backupRoot `
            -BackupRelativePath $cursorRelative -StopAt $projectRoot -WhatIf:$WhatIfPreference
        Write-Change -Detail "remove $cursorRelative (it held only the old gate)"
    }
    elseif ($removedHere -gt 0) {
        Save-Json -Relative $cursorRelative -Value $cursor
        Write-Change -Detail "remove the old gate's hooks from $cursorRelative"
    }
}

$gitignore = Join-Path $projectRoot ".gitignore"

if (Test-Path -LiteralPath $gitignore) {
    $lines = [System.IO.File]::ReadAllLines($gitignore)
    $kept = @($lines | Where-Object { $_.Trim() -ne ".claude/state/" })
    if ($kept.Count -ne $lines.Count) {
        if (-not $WhatIfPreference) {
            Save-Backup -Relative ".gitignore"
            Set-Utf8Content -Path $gitignore -Value (($kept -join [Environment]::NewLine) + [Environment]::NewLine)
        }
        Write-Change -Detail "remove .claude/state/ from .gitignore"
    }
}

$agents = Join-Path $projectRoot "AGENTS.md"

if ((Test-Path -LiteralPath $agents) -and ([System.IO.File]::ReadAllText($agents) -match "verify\.ps1")) {
    Write-Status -Label "WARN" -Detail "AGENTS.md still names verify.ps1; point it at the toolkit's test command"
}

Write-Host ""

if ($changes -eq 0) { Write-Host "Nothing from Tazuna 1.x here." }
elseif ($WhatIfPreference) { Write-Host "Dry run: $changes change(s). Nothing was changed." }
else { Write-Host "Removed the Tazuna 1.x gate: $changes change(s), backed up to $backupRoot" }

Write-Host ""
Write-Host "Set the project up with harness-toolkit, in your own terminal or agent:"
Write-Host "  1. /harness-init in Claude Code or Cursor, or: tlc harness init --write"
Write-Host "  2. tlc harness gate test-command <command> [args]"
Write-Host "  3. tlc harness grind on"
Write-Host ""
Write-Host "The gate starts its command without a shell, so on Windows it must start with an .exe:"
Write-Host "  dotnet test | cmd /c npm test | powershell.exe -NoProfile -File scripts\test.ps1"
Write-Host ""

exit 0
