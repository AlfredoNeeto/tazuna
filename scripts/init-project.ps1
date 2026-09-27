<#
.SYNOPSIS
    Installs a project harness template into an existing repository.

.DESCRIPTION
    Copies every file from templates/<Type>/ into the target directory, preserving
    the template's relative layout (AGENTS.md, .claude/rules/, .claude/scripts/).

    An existing file with the same content is reported UNCHANGED. One that
    differs is left alone unless -Force is supplied, in which case the current
    version is backed up under <target>/.harness-backup/<timestamp>/ first.

    The harness-toolkit needs nothing in the project: it runs from its
    user-level hooks, installed by `tazuna setup`.

.PARAMETER Type
    Template to install. Any directory name under templates/ is valid; the
    available names are discovered at runtime and offered by tab completion.

    Detected from the target when omitted: a repository holding a .sln, .slnx
    or .csproj gets 'dotnet', everything else gets 'generic'.

.PARAMETER Path
    Target repository directory. Must already exist. Defaults to the current
    directory, so running this from inside a repository is enough.

.PARAMETER Force
    Replace files that already exist, backing them up first.

.PARAMETER NoTrust
    Do not mark the workspace as trusted. By default this script trusts it, because
    until the trust dialog is accepted Claude Code ignores the project's permission
    rules and every hook installed here, including the verification gate - silently.
    Use this for a repository whose own hooks you are not ready to run.

.EXAMPLE
    .\scripts\init-project.ps1

.EXAMPLE
    .\scripts\init-project.ps1 -Path C:\src\MyApi -WhatIf

.EXAMPLE
    .\scripts\init-project.ps1 -Type dotnet -Path C:\src\MyApi
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # Not a ValidateSet: templates are discovered from disk, so adding a
    # template directory is enough to make it usable. Not mandatory either: an
    # argument you are always forced to supply is one the script could have
    # worked out, and being asked for it every time is what made this feel like
    # a tool you have to configure rather than one you run.
    [Parameter(Mandatory = $false)]
    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

        $templatesDir = Join-Path (Split-Path -Parent $PSScriptRoot) "templates"

        if (Test-Path -LiteralPath $templatesDir) {
            Get-ChildItem -LiteralPath $templatesDir -Directory |
                Where-Object { -not $_.Name.StartsWith("_") } |
                Where-Object { $_.Name -like "$wordToComplete*" } |
                ForEach-Object { $_.Name }
        }
    })]
    [string]$Type,

    [Parameter(Mandatory = $false)]
    [string]$Path = ".",

    [switch]$Force,

    [switch]$NoTrust
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\Paths.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Files.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Json.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Console.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Manifest.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Cursor.psm1") -Force

function Get-SourceFile {
    <#
        Files under the target carrying one of the given extensions.

        Deliberately NOT `Get-ChildItem -Include`: with -LiteralPath, -Include is
        silently ignored and every file matches. That is not a theory - it is why
        the -Type dotnet check accepted any non-empty directory, and why
        detection picked 'dotnet' for a folder holding a single .txt. Filtering
        on .Extension is the part that actually filters.

        Streams rather than collecting, so a caller that pipes into
        `Select-Object -First 1` stops the walk at the first hit.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$Extension
    )

    return (Get-ChildItem -LiteralPath $Root -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $Extension -contains $_.Extension })
}

function Find-DotNetProject {
    <#
        First .sln, .slnx or .csproj anywhere under the target, or $null.
        Used both to pick the template and to reject an explicit -Type dotnet on
        a directory that holds no .NET project.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Root
    )

    return (Get-SourceFile -Root $Root -Extension @(".sln", ".slnx", ".csproj") | Select-Object -First 1)
}

function Get-DetectedType {
    <#
        Two templates exist. 'dotnet' is the one with a positive signal;
        'generic' is what everything else gets, which is also what it is for -
        its verifier detects the stack at run time.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Root
    )

    $dotnetFile = Find-DotNetProject -Root $Root

    if ($dotnetFile) {
        return [PSCustomObject]@{ Type = "dotnet"; Because = $dotnetFile.Name }
    }

    return [PSCustomObject]@{ Type = "generic"; Because = "no .sln, .slnx or .csproj found" }
}

function Set-WorkspaceTrust {
    <#
        Marks the target workspace as trusted in Claude Code's own state file.

        This is the one step that used to leave a project looking equipped while
        being inert: until the trust dialog is accepted, Claude Code ignores the
        project's permission rules and every hook this script just installed -
        including the verification gate. Nothing warns you at the time.

        Trusting also activates hooks the repository already carried, so this is
        a real decision and -NoTrust exists for it.

        Returns a status string. It never throws: failing to trust must not take
        down a scaffold that otherwise succeeded.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$StatePath
    )

    if (-not (Test-Path -LiteralPath $StatePath)) {
        return "SKIP: $StatePath does not exist - Claude Code has not run on this machine yet"
    }

    $parseError = $null

    if (-not (Test-JsonFile -Path $StatePath -ErrorMessage ([ref]$parseError))) {
        return "SKIP: $StatePath does not parse ($parseError) - left untouched"
    }

    $original = Get-Content -LiteralPath $StatePath -Raw
    $state = $original | ConvertFrom-Json

    # Claude Code keys projects by absolute path with FORWARD slashes. A
    # backslash key is silently ignored, which would report success and trust
    # nothing.
    $key = $ProjectRoot.Replace("\", "/")

    if (-not $state.PSObject.Properties["projects"]) {
        Add-Member -InputObject $state -MemberType NoteProperty -Name "projects" -Value (New-Object PSObject)
    }

    if ($state.projects.PSObject.Properties[$key]) {

        if ($state.projects.$key.hasTrustDialogAccepted) {
            return "PRESENT"
        }
    }
    else {
        Add-Member -InputObject $state.projects -MemberType NoteProperty -Name $key -Value (New-Object PSObject)
    }

    $entry = $state.projects.$key

    if ($entry.PSObject.Properties["hasTrustDialogAccepted"]) {
        $entry.hasTrustDialogAccepted = $true
    }
    else {
        Add-Member -InputObject $entry -MemberType NoteProperty -Name "hasTrustDialogAccepted" -Value $true
    }

    $expectedKeys = @($state.PSObject.Properties.Name).Count
    $expectedProjects = @($state.projects.PSObject.Properties.Name).Count

    # Depth 100 is the ceiling in Windows PowerShell 5.1. The default is 2,
    # which would quietly truncate this file into rubble.
    $rewritten = $state | ConvertTo-Json -Depth 100

    # Prove the rewrite before it replaces anything. ConvertTo-Json round-trips
    # a file this shape well enough, but "well enough" is not a claim to make
    # about the file holding the user's credentials and every project's state.
    $check = $null

    try {
        $check = $rewritten | ConvertFrom-Json
    }
    catch {
        return "FAIL: the rewritten state did not parse - $StatePath left untouched"
    }

    if (@($check.PSObject.Properties.Name).Count -ne $expectedKeys) {
        return "FAIL: the rewrite lost top-level keys - $StatePath left untouched"
    }

    if (@($check.projects.PSObject.Properties.Name).Count -ne $expectedProjects) {
        return "FAIL: the rewrite lost projects - $StatePath left untouched"
    }

    if (-not $check.projects.$key.hasTrustDialogAccepted) {
        return "FAIL: the rewrite did not carry the trust flag - $StatePath left untouched"
    }

    # Back up beside the configuration, never into the project: this file holds
    # credentials and a project directory is something people commit.
    $backupDirectory = New-HarnessBackupRoot -ParentDirectory (Split-Path -Parent $StatePath)

    try {

        if (-not (Test-Path -LiteralPath $backupDirectory)) {
            New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
        }

        Copy-Item -LiteralPath $StatePath -Destination (Join-Path $backupDirectory ".claude.json") -Force

        Set-Utf8Content -Path $StatePath -Value $rewritten
    }
    catch {
        return ("FAIL: " + $_.Exception.Message)
    }

    return "TRUSTED"
}

function Convert-PayloadPath {
    <#
        Maps the template payload directory name to the one a project uses.
        templates/<type>/dot-claude/... installs as <project>/.claude/...,
        and dot-cursor/... as .cursor/...
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $segments = $RelativePath.Split($separator)

    if ($segments[0] -eq "dot-claude") {
        $segments[0] = ".claude"
    }
    elseif ($segments[0] -eq "dot-cursor") {
        $segments[0] = ".cursor"
    }

    return ($segments -join $separator)
}

$repoRoot = Split-Path -Parent $PSScriptRoot

# Resolve against PowerShell's location, not the process working directory.
# They are not the same, and .NET's does not follow Set-Location. See
# Resolve-HarnessPath: every harness script that takes a path goes through it.
$targetRoot = Resolve-HarnessPath -Path $Path

# Detection needs the target, so this check comes before anything that uses it.
if (-not (Test-Path -LiteralPath $targetRoot)) {
    Write-Host ""
    Write-Host "ERROR: target directory does not exist: $targetRoot"
    exit 1
}

$typeReason = ""

if (-not $Type) {
    $detectedType = Get-DetectedType -Root $targetRoot
    $Type = $detectedType.Type
    $typeReason = $detectedType.Because
}

$templateRoot = Join-Path $repoRoot (Join-Path "templates" $Type)

Write-Banner -Title ("Tazuna " + (Get-HarnessManifest).Version) -Command "init"
Write-Host ""

$typeLine = "Template: $Type"

if ($typeReason) { $typeLine += " (detected: $typeReason)" }

Write-Host $typeLine

Write-Host "Target:   $targetRoot"
Write-Host ""

if ($typeReason) {
    Write-Host "Override with -Type."
    Write-Host ""
}

# templates/_shared is content every project gets, not a template you pick.
if ($Type.StartsWith("_")) {
    Write-Host "ERROR: '$Type' is shared template content, not a selectable template."
    exit 1
}

if (-not (Test-Path -LiteralPath $templateRoot)) {

    Write-Host "ERROR: unknown template '$Type'."
    Write-Host ""
    Write-Host "Available templates:"

    $templatesDir = Join-Path $repoRoot "templates"

    if (Test-Path -LiteralPath $templatesDir) {
        foreach ($candidate in (Get-ChildItem -LiteralPath $templatesDir -Directory)) {

            if ($candidate.Name.StartsWith("_")) {
                continue
            }

            Write-Host "  $($candidate.Name)"
        }
    }
    else {
        Write-Host "  (none: $templatesDir does not exist)"
    }

    Write-Host ""
    exit 1
}

if ($Type -eq "dotnet") {

    # Only reachable with an explicit -Type: detection picks dotnet from the
    # same signal, so a detected one cannot fail here.
    if (-not (Find-DotNetProject -Root $targetRoot)) {
        Write-Host "ERROR: the target directory does not appear to contain a .NET project."
        exit 1
    }
}

# Claude Code reads AGENTS.md only when no CLAUDE.md exists at or above the
# working directory. A pre-existing CLAUDE.md would silently shadow the
# AGENTS.md this template installs, so say so rather than install something
# that will never be read.
$shadowing = @()

foreach ($name in @("CLAUDE.md", "CLAUDE.local.md")) {
    if (Test-Path -LiteralPath (Join-Path $targetRoot $name)) {
        $shadowing += $name
    }
}

if ($shadowing.Count -gt 0) {
    Write-Host ("WARNING: the target already has {0}." -f ($shadowing -join " and "))
    Write-Host "         Claude Code reads AGENTS.md only when no CLAUDE.md is present,"
    Write-Host "         so the AGENTS.md installed here will be ignored until you either"
    Write-Host "         merge it into CLAUDE.md or switch /config -> Project instructions"
    Write-Host "         to 'claude-md-and-agents-md'."
    Write-Host ""
}

$backupRoot = New-HarnessBackupRoot -ParentDirectory $targetRoot

# Shared content first, then the type-specific files. Both are addressed by
# their path relative to their own root, so a template may override a shared
# file simply by shipping its own copy at the same path.
$sharedRoot = Join-Path $repoRoot (Join-Path "templates" "_shared")

$sources = @()

if (Test-Path -LiteralPath $sharedRoot) {
    foreach ($file in (Get-ChildItem -LiteralPath $sharedRoot -File -Recurse -Force)) {
        $sources += [PSCustomObject]@{
            File = $file
            Root = $sharedRoot
        }
    }
}

foreach ($file in (Get-ChildItem -LiteralPath $templateRoot -File -Recurse -Force)) {
    $sources += [PSCustomObject]@{
        File = $file
        Root = $templateRoot
    }
}

$seen = @{}
$templateFiles = @()

foreach ($source in $sources) {

    $relative = Get-CompatibleRelativePath -BasePath $source.Root -TargetPath $source.File.FullName

    # Template payload lives under dot-claude/ rather than .claude/ so that it
    # is inert in this repository: a nested .claude/rules/ directory would be
    # loaded as live rules while working on the harness, and permission rules
    # written for a project's .claude/ match at any depth and would lock the
    # template sources against editing.
    $relative = Convert-PayloadPath -RelativePath $relative

    # A later entry with the same relative path replaces the earlier one, so
    # the type-specific file wins over the shared default.
    $seen[$relative] = $source.File
}

foreach ($key in ($seen.Keys | Sort-Object)) {
    $templateFiles += [PSCustomObject]@{
        FullName = $seen[$key].FullName
        Relative = $key
    }
}

# why: Cursor reads rules only as .mdc under .cursor/rules; generated from the
# .claude/rules source so one rule has one source. Staged outside the project,
# so -WhatIf and SKIP treat them exactly like any other template file.
$ruleStage = Join-Path ([System.IO.Path]::GetTempPath()) ("tazuna-rules-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$claudeRules = ".claude" + [System.IO.Path]::DirectorySeparatorChar + "rules" + [System.IO.Path]::DirectorySeparatorChar

foreach ($file in @($templateFiles | Where-Object { $_.Relative.StartsWith($claudeRules) -and $_.Relative.EndsWith(".md") })) {

    $name = [System.IO.Path]::GetFileNameWithoutExtension($file.Relative) + ".mdc"
    $staged = Join-Path $ruleStage $name

    New-Item -ItemType Directory -Path $ruleStage -Force -WhatIf:$false | Out-Null
    [System.IO.File]::WriteAllText($staged, (ConvertTo-CursorRule -Text ([System.IO.File]::ReadAllText($file.FullName))))

    $templateFiles += [PSCustomObject]@{
        FullName = $staged
        Relative = Join-Path ".cursor" (Join-Path "rules" $name)
    }
}

$created = 0
$updated = 0
$unchanged = 0
$skipped = 0

foreach ($file in $templateFiles) {

    $relative = $file.Relative
    $targetFile = Join-Path $targetRoot $relative

    if ((Test-Path -LiteralPath $targetFile) -and (-not $Force) -and
        (-not (Test-FileContentEqual -ReferenceFile $file.FullName -DifferenceFile $targetFile))) {
        $skipped++
        Write-Status -Label "SKIP" -Detail "$relative (differs - yours is kept, -Force replaces it)"
        continue
    }

    $willOverwrite = (Test-Path -LiteralPath $targetFile) -and
                     -not (Test-FileContentEqual -ReferenceFile $file.FullName -DifferenceFile $targetFile)

    # -WhatIf must be passed explicitly: PowerShell preference variables do not
    # cross the module boundary, so the module function would otherwise write
    # for real during a dry run.
    $result = Copy-FileIfChanged `
        -SourceFile $file.FullName `
        -TargetFile $targetFile `
        -BackupRoot $backupRoot `
        -BackupRelativePath $relative `
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

if (Test-Path -LiteralPath $ruleStage) {
    Remove-Item -LiteralPath $ruleStage -Recurse -Force -WhatIf:$false
}

# The backup directory lives inside the user's repository, so keep it out of
# their commits rather than leaving untracked noise behind.
$gitignorePath = Join-Path $targetRoot ".gitignore"

# .claude/state/ holds machine-specific paths and verification state, so it must
# be ignored even when the project has no .gitignore yet. Writing that state and
# leaving it committable would put one machine's paths into everyone's history.
# The harness-toolkit's user-level hooks write their own session state under
# .tlc/harness/state/ in the directory Claude Code was opened in - same
# reasoning, and **/ because that can be a subdirectory of a monorepo.
$gitignoreLines = @()

if (Test-Path -LiteralPath $gitignorePath) {
    $gitignoreLines = @(Get-Content -LiteralPath $gitignorePath)
}

$missingIgnores = @()

foreach ($entry in @(".harness-backup/", ".claude/state/", "**/.tlc/harness/state/")) {
    if ($gitignoreLines -notcontains $entry) {
        $missingIgnores += $entry
    }
}

if ($missingIgnores.Count -gt 0) {

    # why: $WhatIfPreference before ShouldProcess, here and below - under -WhatIf
    # ShouldProcess prints its own "What if:" line, doubling the WHATIF one.
    if ($WhatIfPreference) {
        $verb = "update"
        if ($gitignoreLines.Count -eq 0) { $verb = "create" }
        Write-Status -Label "WHATIF" -Detail ("would {0} .gitignore: {1}" -f $verb, ($missingIgnores -join ", "))
    }
    elseif ($PSCmdlet.ShouldProcess($gitignorePath, "Ignore harness machine-local state")) {

        if ($gitignoreLines.Count -gt 0) {
            Add-Content -LiteralPath $gitignorePath -Value ""
        }

        Add-Content -LiteralPath $gitignorePath -Value "# Claude Code harness"

        foreach ($entry in $missingIgnores) {
            Add-Content -LiteralPath $gitignorePath -Value $entry
        }

        $label = "GITIGNORE"

        if ($gitignoreLines.Count -eq 0) {
            $label = "CREATE"
        }

        Write-Status -Label $label -Detail (".gitignore: " + ($missingIgnores -join ", "))
    }
}

Write-Host ""

if ($WhatIfPreference) {
    Write-Host ("Dry run: {0} to create, {1} to update, {2} unchanged, {3} skipped. Nothing was changed." -f `
        $created, $updated, $unchanged, $skipped)
}
else {
    Write-Host ("Project harness: {0} created, {1} updated, {2} unchanged, {3} skipped." -f `
        $created, $updated, $unchanged, $skipped)
}

if (($updated -gt 0) -and (Test-Path -LiteralPath $backupRoot)) {
    Write-Host ""
    Write-Host "Previous versions backed up to:"
    Write-Host "  $backupRoot"
}

if ($skipped -gt 0) {
    Write-Host ""
    Write-Host "Re-run with -Force to replace the skipped files (they will be backed up first)."
}

# Workspace trust
# ---------------
# Project permissions and hooks are trust-requiring features. Installing them
# and saying nothing would leave the project looking protected when it is not,
# and the old advice - "accept the dialog next time you start Claude Code" - is
# a step that gets forgotten, with no symptom when it is.
Write-Host ""
Write-Host "Workspace trust"
Write-Host "---------------"

if ($NoTrust) {
    Write-Status -Label "SKIP" -Detail "-NoTrust: the rules and hooks installed here stay inert"
    Write-Host "            until you accept the dialog in Claude Code."
}
elseif ($WhatIfPreference -or (-not $PSCmdlet.ShouldProcess($targetRoot, "Trust this workspace in Claude Code"))) {
    Write-Status -Label "WHATIF" -Detail "would trust $targetRoot"
}
else {

    $statePath = Get-ClaudeStateFile
    $trust = Set-WorkspaceTrust -ProjectRoot $targetRoot -StatePath $statePath

    if ($trust -eq "TRUSTED") {

        Write-Status -Label "TRUST" -Detail "trusted in $statePath"
        Write-Host "            The permission rules and hooks in this project are now ACTIVE,"
        Write-Host "            including any the repository already carried. -NoTrust opts out."
        Write-Host "            A Claude Code session already open here must be restarted: it"
        Write-Host "            rewrites this file on exit and would undo this."
    }
    elseif ($trust -eq "PRESENT") {
        Write-Status -Label "TRUST" -Detail "this workspace was already trusted"
    }
    elseif ($trust.StartsWith("FAIL")) {
        Write-Status -Label "FAIL" -Detail $trust
        Write-Host "            Accept the dialog in Claude Code instead."
    }
    else {
        Write-Status -Label "SKIP" -Detail $trust
        Write-Host "            Accept the dialog the first time you start Claude Code here."
    }
}

Write-Host ""
Write-Host "Next:"
Write-Host "  git -C `"$targetRoot`" status"
Write-Host "  claude"
Write-Host ""

exit 0
