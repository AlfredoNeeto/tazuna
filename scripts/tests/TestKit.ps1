# invariant: dot-sourced at the top of every scripts\tests\*.Tests.ps1, after its param block, so each
# file runs with the same helpers, fixtures and environment and reads its own -SkipSlow and -Only.

$ErrorActionPreference = "Stop"

$scriptsRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $scriptsRoot

Import-Module (Join-Path $scriptsRoot "lib\Paths.psm1") -Force
Import-Module (Join-Path $scriptsRoot "lib\Files.psm1") -Force
Import-Module (Join-Path $scriptsRoot "lib\Json.psm1") -Force
Import-Module (Join-Path $scriptsRoot "lib\Console.psm1") -Force
Import-Module (Join-Path $scriptsRoot "lib\Git.psm1") -Force
Import-Module (Join-Path $scriptsRoot "lib\Manifest.psm1") -Force

# invariant: the self-test never changes the persisted user PATH; V14 and Complete-TestFile compare against this.
$userPathAtStart = [Environment]::GetEnvironmentVariable("PATH", "User")
# hazard: a test file run with & in a shell shares that shell's environment, so the variable is put
# back at the end; left set, a later tazuna setup in that shell would skip the PATH step.
$skipPathAtStart = $env:TAZUNA_SKIP_PATH
$env:TAZUNA_SKIP_PATH = "1"

# invariant: the self-test never writes into the real ~/.cursor; a case that wants Cursor
# present points this at a scratch directory of its own. Put back at the end, like the PATH flag.
$cursorDirAtStart = $env:TAZUNA_CURSOR_DIR
$env:TAZUNA_CURSOR_DIR = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-no-cursor-" + [guid]::NewGuid().ToString("N").Substring(0, 8))

$script:passed = 0
$script:failed = 0
$script:skipped = 0

function Start-Section {
    param([Parameter(Mandatory = $true)][string]$Title)

    Write-Host ""
    Write-Host $Title
    Write-Host ("-" * $Title.Length)
}

function Test-Case {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Check
    )

    if ($Only -and (-not $Name.StartsWith($Only + " "))) { return }

    try {
        $result = & $Check

        if ($result -eq $true) {
            $script:passed++
            Write-Status -Label "PASS" -Detail $Name
        }
        else {
            $script:failed++
            Write-Status -Label "FAIL" -Detail "$Name -> $result"
        }
    }
    catch {
        $script:failed++
        Write-Status -Label "FAIL" -Detail "$Name -> $($_.Exception.Message)"
    }
}

function Skip-Case {
    param([string]$Name, [string]$Reason)

    if ($Only) { return }

    $script:skipped++
    Write-Status -Label "SKIP" -Detail "$Name ($Reason)"
}

function Get-RepoFile {
    <#
        Returns repository files, optionally restricted to a set of extensions.
        Extensions are filtered explicitly rather than with -Include, which does
        not filter when combined with -LiteralPath and silently returns
        everything.
    #>
    param([string[]]$Extension)

    # Ask git what is in the repository rather than walking the disk. These
    # checks exist to keep things out of commits, and a file git ignores is not
    # in the repository: the machine-local harness pointer legitimately holds an
    # absolute path, and a backup directory is transient. Walking the disk
    # reported both as defects.
    $listed = @(& git -C $repoRoot ls-files --cached --others --exclude-standard)

    if ($LASTEXITCODE -ne 0) {
        throw "Could not list repository files; is this still a git work tree?"
    }

    $items = @()

    foreach ($relative in $listed) {

        if (-not $relative) { continue }

        $full = Join-Path $repoRoot ($relative.Replace("/", [string][char]92))

        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $items += (Get-Item -LiteralPath $full -Force)
        }
    }

    if ($Extension) {
        $items = $items | Where-Object { $Extension -contains $_.Extension }
    }

    return @($items)
}

# why: the fixtures below are used by more than one test file.

# External programs are replaced by recording stubs placed first on PATH, and
# the configuration directory is a scratch CLAUDE_CONFIG_DIR. What these prove
# is our wiring to npm, tlc, npx and claude; that the upstream CLIs do what
# their READMEs say is only settled by a real `tazuna setup`.
$manifest = Get-HarnessManifest
$script:setupRuns = @{}
$script:scratchRoots = @()

function New-ScratchRoot {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-setup-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $script:scratchRoots += $root
    return $root
}

function New-StubBin {
    param([Parameter(Mandatory = $true)][string]$Root)

    $bin = Join-Path $Root "stub-bin"
    New-Item -ItemType Directory -Path $bin -Force | Out-Null

    # hazard: -WhatIf:$false - the stubs run inside setup's scope, and an inherited -WhatIf left the log empty and printed "What if:".
    $record = 'Add-Content -LiteralPath $env:HARNESS_STUB_LOG -Value ("{0} " + ($args -join " ")) -WhatIf:$false'

    $stubs = @{
        "node"   = 'if ($env:HARNESS_STUB_NODE) { Write-Output $env:HARNESS_STUB_NODE } else { Write-Output "v24.15.0" }'
        "npm"    = ($record -f "npm") + "`n" + 'if ($env:HARNESS_STUB_FAIL -eq "npm") { exit 1 }' + "`n" +
                   'if ($args[0] -eq "ls") { if ($env:HARNESS_STUB_TOOLKIT) { Write-Output (''{"dependencies":{"@tech-leads-club/harness-toolkit":{"version":"'' + $env:HARNESS_STUB_TOOLKIT + ''"}}}'') } else { Write-Output "{}" } }'
        "uvx"    = ($record -f "uvx")
        "npx"    = ($record -f "npx") + @'

Add-Content -LiteralPath $env:HARNESS_STUB_LOG -Value ("catalog " + $env:SKILLS_CDN_REF) -WhatIf:$false

$names = @(); $agents = @(); $take = ""
foreach ($a in $args) {
    if ($a -eq "-s") { $take = "skills"; continue }
    if ($a -eq "-a") { $take = "agents"; continue }
    if ($a.StartsWith("-")) { $take = ""; continue }
    if ($take -eq "skills") { $names += $a }
    if ($take -eq "agents") { $agents += $a }
}
$homes = @()
if ($agents -contains "claude-code") { $homes += $env:CLAUDE_CONFIG_DIR }
if ($agents -contains "cursor") { $homes += $env:TAZUNA_CURSOR_DIR }
foreach ($skillsHome in $homes) {
    foreach ($n in $names) {
        $dir = Join-Path $skillsHome (Join-Path "skills" $n)
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir "SKILL.md") -Value "---`nname: $n`ndescription: stub`n---`n"
    }
}
'@
        "tlc"    = ($record -f "tlc") + @'

if (($args[0] -eq "harness") -and ($args[1] -eq "status") -and $env:HARNESS_STUB_GRIND) {
    Write-Output ('{"root":"stub","grind":' + $env:HARNESS_STUB_GRIND + '}')
}
if (($args[0] -eq "harness") -and ($args[1] -eq "install") -and ($env:HARNESS_STUB_FAIL -ne "tlc-hook") -and $env:TAZUNA_CURSOR_DIR -and (Test-Path -LiteralPath $env:TAZUNA_CURSOR_DIR)) {
    Set-Content -LiteralPath (Join-Path $env:TAZUNA_CURSOR_DIR "hooks.json") -Value '{"version":1,"hooks":{"stop":[{"command":"cmd /c node C:/stub/.tlc/harness/bin/tlc-exec.mjs obs-stop"}]}}'
}
if (($args[0] -eq "harness") -and ($args[1] -eq "install") -and ($env:HARNESS_STUB_FAIL -ne "tlc-hook") -and (Test-Path -LiteralPath (Join-Path $env:CLAUDE_CONFIG_DIR "settings.json"))) {
    $path = Join-Path $env:CLAUDE_CONFIG_DIR "settings.json"
    $settings = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $hook = [PSCustomObject]@{ type = "command"; command = "node"; args = @("C:/stub/.tlc/harness/bin/tlc-exec.mjs", "stop") }
    $hooks = [PSCustomObject]@{ Stop = @([PSCustomObject]@{ hooks = @($hook) }) }
    if ($settings.PSObject.Properties["hooks"]) { $settings.hooks = $hooks }
    else { Add-Member -InputObject $settings -MemberType NoteProperty -Name hooks -Value $hooks }
    [System.IO.File]::WriteAllText($path, ($settings | ConvertTo-Json -Depth 20))
}
'@
        "claude" = ($record -f "claude") + @'

if ($args[0] -eq "--version") { Write-Output "2.1.300 (Claude Code)" }
elseif (($args[0] -eq "plugin") -and ($args[1] -eq "list")) { Write-Output "[]" }
elseif (($args[0] -eq "plugin") -and ($args[1] -eq "install") -and ($env:HARNESS_STUB_FAIL -eq "claude-plugin-install")) { exit 1 }
elseif (($args[0] -eq "mcp") -and ($args[1] -eq "list")) {
    if ($env:HARNESS_STUB_MCPLIST) { Write-Output $env:HARNESS_STUB_MCPLIST }
}
elseif (($args[0] -eq "mcp") -and ($args[1] -eq "remove")) {
    if ($env:HARNESS_STUB_FAIL -eq "claude-mcp-remove") { exit 1 }
}
elseif (($args[0] -eq "mcp") -and ($args[1] -eq "add")) {
    Add-Content -LiteralPath $env:HARNESS_STUB_LOG -Value ("claude-cwd " + (Get-Location).Path) -WhatIf:$false
    # why: echoing the arguments on failure is what lets K9 prove the PAT is masked in the error path.
    if ($env:HARNESS_STUB_FAIL -eq "claude-mcp-add") { Write-Output ("error: " + ($args -join " ")); exit 1 }
}
exit 0
'@
    }

    foreach ($name in $stubs.Keys) {
        Set-Content -LiteralPath (Join-Path $bin ($name + ".ps1")) -Value $stubs[$name]
    }

    return $bin
}

function Invoke-WithStubs {
    <#
        Runs a harness script in a child powershell with the stubs first on PATH
        and a scratch configuration directory. Returns code, output and the
        recorded calls.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Script,
        [string[]]$Arguments = @(),
        [hashtable]$Environment = @{},
        [string[]]$DropPathContaining = @()
    )

    $bin = Join-Path $Root "stub-bin"
    if (-not (Test-Path -LiteralPath $bin)) { $bin = New-StubBin -Root $Root }

    $log = Join-Path $Root "calls.log"
    $saved = @{}
    $variables = @{
        "PATH"              = $bin + ";" + ((($env:PATH -split ";") | Where-Object {
                                    $entry = $_
                                    $_ -and (-not ($DropPathContaining | Where-Object { Test-Path -LiteralPath (Join-Path $entry $_) }))
                                }) -join ";")
        "CLAUDE_CONFIG_DIR" = (Join-Path $Root "config")
        "HARNESS_STUB_LOG"  = $log
        # invariant: Cursor is absent unless a case creates this directory, whatever the machine has in ~/.cursor.
        "TAZUNA_CURSOR_DIR" = (Join-Path $Root "cursor")
    }

    foreach ($key in $Environment.Keys) { $variables[$key] = $Environment[$key] }

    foreach ($key in $variables.Keys) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
        [Environment]::SetEnvironmentVariable($key, $variables[$key], "Process")
    }

    $previous = $ErrorActionPreference

    try {
        $ErrorActionPreference = "Continue"
        $global:LASTEXITCODE = 0
        $output = (& powershell -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>&1 | Out-String)
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous

        foreach ($key in $saved.Keys) {
            [Environment]::SetEnvironmentVariable($key, $saved[$key], "Process")
        }
    }

    $calls = @()
    if (Test-Path -LiteralPath $log) { $calls = @(Get-Content -LiteralPath $log) }

    return [PSCustomObject]@{ Code = $code; Output = $output; Calls = $calls; Config = (Join-Path $Root "config") }
}

function Get-SetupRun {
    # One stubbed setup per scenario, run on first use, so -Only runs only what it needs.
    param([string]$Key, [hashtable]$Environment = @{}, [string[]]$Arguments = @())

    if (-not $script:setupRuns.ContainsKey($Key)) {
        $root = New-ScratchRoot
        $script:setupRuns[$Key] = Invoke-WithStubs -Root $root -Script (Join-Path $scriptsRoot "bootstrap.ps1") `
            -Environment $Environment -Arguments $Arguments
        $script:setupRuns[$Key] | Add-Member -NotePropertyName Root -NotePropertyValue $root
    }

    return $script:setupRuns[$Key]
}

$skillsLine = "npx -y " + $manifest.AgentSkillsPackage + " install -s " + ($manifest.AgentSkills -join " ") + " -a claude-code -g"

function New-InitProject {
    # A project holding Files (relative path -> text), and tazuna init run on it with Arguments.
    param([hashtable]$Files, [string[]]$Arguments = @())
    $project = Join-Path (New-ScratchRoot) "project"
    New-Item -ItemType Directory -Path $project -Force | Out-Null
    foreach ($name in $Files.Keys) {
        $path = Join-Path $project $name
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [System.IO.File]::WriteAllText($path, $Files[$name])
    }
    $run = Invoke-WithStubs -Root (Split-Path -Parent $project) -Script (Join-Path $scriptsRoot "init-project.ps1") -Arguments (@("-Path", $project) + $Arguments)
    $run | Add-Member -NotePropertyName Project -NotePropertyValue $project
    return $run
}

$catalog = (Get-Content -LiteralPath (Join-Path $repoRoot "mcp\catalog.json") -Raw | ConvertFrom-Json).servers
$catalogNames = @($catalog.PSObject.Properties.Name)

$readme = Get-Content -LiteralPath (Join-Path $repoRoot "README.md") -Raw -Encoding UTF8

function Clear-ScratchRoot {
    foreach ($root in $script:scratchRoots) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
    $script:scratchRoots = @()
}

function Complete-TestFile {
    # invariant: the last line a file prints is its result, and its exit code agrees with it;
    # the runner reads both and fails a file whose two disagree.
    Clear-ScratchRoot

    $env:TAZUNA_SKIP_PATH = $skipPathAtStart
    $env:TAZUNA_CURSOR_DIR = $cursorDirAtStart

    $now = [Environment]::GetEnvironmentVariable("PATH", "User")
    if ($now -ne $userPathAtStart) {
        $script:failed++
        Write-Status -Label "FAIL" -Detail "the persisted user PATH changed while this file ran: '$userPathAtStart' -> '$now'"
    }

    Write-Host ""
    Write-Host ("TEST FILE RESULT: passed {0} failed {1} skipped {2}" -f $script:passed, $script:failed, $script:skipped)

    if ($script:failed -gt 0) { exit 1 }
    exit 0
}
