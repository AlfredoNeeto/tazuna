[CmdletBinding()]
param([switch]$SkipSlow, [string]$Only)

. (Join-Path $PSScriptRoot "TestKit.ps1")

Start-Section "Extension points"

# why: R7 reads this machine's persisted PATH, so it only has something to say about the
# checkout setup installed; any other checkout (a fork, a clone, a worktree) is not on it.
$installedBin = Join-Path $repoRoot "bin"
$isInstalled = @(([Environment]::GetEnvironmentVariable("PATH", "User")) -split ";" |
    Where-Object { $_.Trim().TrimEnd("\") -eq $installedBin.TrimEnd("\") }).Count -gt 0

if (-not $isInstalled) {
    Skip-Case -Name "R7 install.ps1 puts tazuna on PATH so it runs from a project" -Reason "this checkout is not the one setup put on the user PATH"
}
else {
Test-Case -Name "R7 install.ps1 puts tazuna on PATH so it runs from a project" -Check {

    # Every instruction reads "cd into your project, then run tazuna init".
    # That is only true if the harness is on PATH: .\tazuna.ps1 is not in the
    # project, so the documented command could not work from the directory it
    # told you to be in.
    $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")

    $onPath = $false

    $binDirectory = Join-Path $repoRoot "bin"

    foreach ($entry in @($userPath -split ";" | Where-Object { $_ })) {

        $trimmed = $entry.Trim().TrimEnd("\")

        if ($trimmed -eq $binDirectory.TrimEnd("\")) { $onPath = $true }

        # The repository root on PATH puts tazuna.ps1 ahead of tazuna.cmd, so
        # its presence is a failure even when bin\ is there too.
        if ($trimmed -eq $repoRoot.TrimEnd("\")) {
            return "$repoRoot is on the user PATH; 'tazuna' resolves to the .ps1 - run install.ps1"
        }
    }

    if (-not $onPath) { return "$binDirectory is not on the user PATH; run install.ps1" }

    # The PERSISTED user PATH, not this process's. A shell inherits PATH when it
    # starts, so Get-Command here would report on whatever the environment was
    # when this process began - failing after a correct install, and passing
    # after the entry was removed. That is a worse test than none.
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot "bin\tazuna.cmd"))) {
        return "the PATH entry exists but there is no tazuna.cmd in it"
    }

    # Resolve it the way a NEW shell would: search the persisted PATH by hand.
    $found = $null

    foreach ($entry in @($userPath -split ";" | Where-Object { $_ })) {

        $candidate = Join-Path $entry.Trim() "tazuna.cmd"

        if (Test-Path -LiteralPath $candidate) { $found = $candidate; break }
    }

    if (-not $found) { return "no tazuna.cmd is reachable from the user PATH" }

    if ((Split-Path -Parent $found).TrimEnd("\") -ne $binDirectory.TrimEnd("\")) {
        return "a new shell would resolve tazuna to $found, not this repository"
    }

    # The root cause, guarded directly. PowerShell resolves an ExternalScript
    # before an Application, so a .ps1 sharing a base name with the launcher in
    # the SAME directory wins - and on an AllSigned machine it then refuses to
    # run. The launcher only works because nothing else sits beside it.
    $rival = Get-ChildItem -LiteralPath $binDirectory -File |
        Where-Object { $_.Extension -eq ".ps1" }

    if ($rival) {
        return ("bin\ must hold no .ps1: " + (($rival | ForEach-Object { $_.Name }) -join ", "))
    }

    return $true
}
}

Test-Case -Name "R4 tazuna.cmd survives a machine that refuses unsigned scripts" -Check {

    # A machine that runs AllSigned fails `.\tazuna.ps1 setup` with
    # "not digitally signed" before anything ran. This shim is the entry point
    # for that machine, and it is only worth shipping if it forwards faithfully.
    $shim = Join-Path $repoRoot "bin\tazuna.cmd"

    if (-not (Test-Path -LiteralPath $shim)) { return "tazuna.cmd is missing" }

    $text = [System.IO.File]::ReadAllText($shim)

    # CRLF is not a preference here. With LF, cmd.exe splits its own keywords and
    # every rem line fails with "'m' is not recognized" - measured.
    if ($text -notmatch "`r`n") { return "tazuna.cmd must use CRLF line endings or cmd.exe mis-parses it" }

    foreach ($required in @("-ExecutionPolicy Bypass", "-NoProfile", "%~dp0..\tazuna.ps1", "%*")) {

        if (-not $text.Contains($required)) { return "tazuna.cmd does not carry $required" }
    }

    # Behaviour, not shape: an unknown command must come back non-zero through
    # the shim exactly as it does directly, or a caller cannot trust it.
    $null = & cmd.exe /c $shim "no-such-command" 2>$null
    $throughShim = $LASTEXITCODE

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "tazuna.ps1") "no-such-command" 2>$null | Out-Null
    $direct = $LASTEXITCODE

    if ($throughShim -ne $direct) {
        return "the shim returned $throughShim where tazuna.ps1 returned $direct"
    }

    if ($throughShim -eq 0) { return "an unknown command was reported as success" }

    return $true
}

Test-Case -Name "no regex pattern ends in a backslash" -Check {

    # `-notmatch '<BS><BS>.git<BS>'` parsed clean, passed review and passed every
    # test - because .NET only compiles the pattern when there is something to
    # match, and there never was until a credential file actually leaked. A
    # pattern ending in a backslash is an illegal regex; this catches it while
    # the cost is a failing test rather than a missed secret.
    $offenders = @()

    foreach ($file in (Get-RepoFile -Extension ".ps1", ".psm1")) {

        $number = 0

        foreach ($line in Get-Content -LiteralPath $file.FullName) {

            $number++

            if ($line -notlike "*-match*" -and $line -notlike "*-notmatch*" -and
                $line -notlike "*-replace*" -and $line -notlike "*-split*") { continue }

            # A quoted literal whose last character is a single backslash.
            foreach ($quote in @("'", '"')) {

                foreach ($piece in ($line -split $quote)) {

                    if ($piece.Length -eq 0) { continue }
                    if (-not $piece.EndsWith([string][char]92)) { continue }

                    # An even run of trailing backslashes is an escaped
                    # backslash, which is legal.
                    $run = 0
                    $index = $piece.Length - 1

                    while ($index -ge 0 -and $piece[$index] -eq [char]92) {
                        $run++
                        $index--
                    }

                    if ($run % 2 -eq 1) {
                        $offenders += "$($file.Name):$number"
                    }
                }
            }
        }
    }

    $offenders = @($offenders | Select-Object -Unique)

    if ($offenders.Count -gt 0) {
        return "illegal trailing backslash in a pattern: $($offenders -join ', ')"
    }

    return $true
}

Test-Case -Name "file comparison survives an inherited -WhatIf" -Check {

    # bootstrap.ps1 passes -WhatIf down to install.ps1, and that set
    # $WhatIfPreference for everything below it. Get-FileHash is a function in
    # Windows PowerShell 5.1, the preference reaches inside it, and it returns
    # nothing - so the installer's "has this file changed?" threw, and only in
    # the dry run that exists to be safe.
    $module = Join-Path $repoRoot "scripts\lib\Files.psm1"

    # Built by replacement, not -f: the -f operator reads the probe's own braces
    # as format items.
    $probe = @'
Import-Module "MODULE" -Force
$WhatIfPreference = $true
$same = Test-FileContentEqual -ReferenceFile "SAME" -DifferenceFile "SAME"
$different = Test-FileContentEqual -ReferenceFile "SAME" -DifferenceFile "OTHER"
if ($same -and (-not $different)) { "ok" } else { "wrong result" }
'@

    $probe = $probe.Replace("MODULE", $module)
    $probe = $probe.Replace("SAME", (Join-Path $repoRoot "README.md"))
    $probe = $probe.Replace("OTHER", (Join-Path $repoRoot ".gitignore"))

    $probeFile = Join-Path ([System.IO.Path]::GetTempPath()) ("whatif-" + [guid]::NewGuid().ToString("N") + ".ps1")

    try {

        Set-Content -LiteralPath $probeFile -Value $probe -Encoding UTF8

        $output = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probeFile) | Select-Object -Last 1

        if ($output -ne "ok") { return "comparison broke under -WhatIf: $output" }
    }
    finally {
        Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue
    }

    return $true
}

Test-Case -Name "no harness script depends on Get-FileHash" -Check {

    # Reading a file is not a mutation, but Get-FileHash behaves as though it
    # were. Both places that hash files - the installer's change detection and
    # the verification gate's fingerprint - must keep working no matter what a
    # caller upstream set.
    $offenders = @()

    foreach ($file in (Get-RepoFile -Extension ".ps1", ".psm1")) {

        foreach ($line in (Get-Content -LiteralPath $file.FullName)) {

            # A call always carries a parameter. The prose explaining why this
            # is avoided says "Get-FileHash is a function in Windows...", and
            # the line just above searches for the name itself.
            # Assembled, so this line does not report itself.
            if (-not $line.Contains("Get-File" + "Hash -")) { continue }

            if ($true) {
                $offenders += (Get-CompatibleRelativePath -BasePath $repoRoot -TargetPath $file.FullName)
            }
        }
    }

    $offenders = @($offenders | Select-Object -Unique)

    if ($offenders.Count -gt 0) {
        return "use [System.Security.Cryptography.SHA256] instead: $($offenders -join ', ')"
    }

    return $true
}

Test-Case -Name "no MCP server is registered without its written justification" -Check {

    # docs/mcp.md requires five answers before a server is installed. The rule
    # only holds if something enforces it: a catalogue is exactly the kind of
    # file that accumulates entries nobody can account for later.
    $cataloguePath = Join-Path $repoRoot (Join-Path "mcp" "servers.json")
    $decisionsPath = Join-Path $repoRoot (Join-Path "docs" "mcp.md")

    if (-not (Test-Path -LiteralPath $cataloguePath)) { return "mcp/servers.json is missing" }
    if (-not (Test-Path -LiteralPath $decisionsPath)) { return "docs/mcp.md is missing" }

    $catalogue = Get-Content -LiteralPath $cataloguePath -Raw | ConvertFrom-Json
    $decisions = Get-Content -LiteralPath $decisionsPath -Raw

    if (-not $catalogue.mcpServers) { return $true }

    $undocumented = @()

    foreach ($name in @($catalogue.mcpServers.PSObject.Properties.Name | Where-Object { $_ })) {

        if (-not $decisions.Contains($name)) { $undocumented += $name }
    }

    if ($undocumented.Count -gt 0) {
        return "answer the five questions in docs/mcp.md first: $($undocumented -join ', ')"
    }

    return $true
}

Test-Case -Name "settings use the spelling Claude Code writes back" -Check {

    # defaultMode accepts "manual" and "default" for the same mode, but when the
    # CLI rewrites settings.json - which `plugin install --scope user` does - it
    # normalises "manual" to "default". Declaring "manual" therefore left every
    # freshly bootstrapped machine reporting drift against its own repository,
    # and a fresh install that ends in a warning teaches you to ignore warnings.
    $settings = Get-Content -LiteralPath (Join-Path $repoRoot "user\settings.json") -Raw | ConvertFrom-Json

    $mode = $settings.permissions.defaultMode

    if (-not $mode) { return "no permissions.defaultMode" }

    if ($mode -eq "manual") {
        return "use 'default': the CLI rewrites 'manual' to it and the harness then reports drift against itself"
    }

    # The modes that hand over control are never the default here.
    if (@("acceptEdits", "bypassPermissions", "auto") -contains $mode) {
        return "defaultMode is '$mode', which grants tools without asking"
    }

    return $true
}

# why: a fork or a local clone has another origin; the published URL itself is pinned by R8.
$origin = (Invoke-GitCommand -RepositoryPath $repoRoot -Arguments @("remote", "get-url", "origin") -AllowFailure).Text.Trim()

if ($origin -ne "https://github.com/AlfredoNeeto/tazuna.git") {
    Skip-Case -Name "the remote installer clones this repository" -Reason "origin is '$origin', not the published repository"
}
else {
Test-Case -Name "the remote installer clones this repository" -Check {

    # install.ps1 is the one file nobody runs from a working copy - it runs on a
    # machine that does not have the repository yet. A wrong URL in it is
    # therefore silent here and fails only on the new machine, which is the
    # moment it exists for.
    $installerPath = Join-Path $repoRoot "install.ps1"

    if (-not (Test-Path -LiteralPath $installerPath)) { return "install.ps1 is missing" }

    $installer = Get-Content -LiteralPath $installerPath -Raw

    $remote = (& git -C $repoRoot remote get-url origin)

    if ($LASTEXITCODE -ne 0) { return "no origin remote to compare against" }

    $remote = $remote.Trim()

    if (-not $installer.Contains($remote)) {
        return "install.ps1 does not clone origin ($remote)"
    }

    return $true
}
}

Test-Case -Name "the remote installer hands over to bootstrap.ps1" -Check {
    # A second installer that drifts from bootstrap is worse than none.
    $installer = Get-Content -LiteralPath (Join-Path $repoRoot "install.ps1") -Raw
    if (-not $installer.Contains("bootstrap.ps1")) { return "install.ps1 does not run bootstrap.ps1" }
    return $true
}

Test-Case -Name "every tazuna.ps1 command maps to a script that exists" -Check {

    # The dispatcher keeps its own table of command -> script. Rename a script
    # and the table still looks right; it fails only when someone runs that one
    # command, which may be months later.
    $dispatcher = Join-Path $repoRoot "tazuna.ps1"

    if (-not (Test-Path -LiteralPath $dispatcher)) { return "tazuna.ps1 is missing" }

    $missing = @()
    $named = @()

    foreach ($line in (Get-Content -LiteralPath $dispatcher)) {

        if (-not $line.Contains("Script = ")) { continue }

        $after = $line.Substring($line.IndexOf("Script = ") + 9).Trim()

        if ($after.StartsWith('$null')) { continue }

        $name = ($after -split '"')[1]

        if (-not $name) { continue }

        $named += $name

        if (-not (Test-Path -LiteralPath (Join-Path $repoRoot (Join-Path "scripts" $name)))) {
            $missing += $name
        }
    }

    if ($named.Count -eq 0) { return "no commands found in the dispatcher table" }

    if ($missing.Count -gt 0) {
        return "commands point at scripts that do not exist: $($missing -join ', ')"
    }

    return $true
}

Test-Case -Name "every script a skill tells you to run exists" -Check {

    # A skill is prose until something runs. When a script is renamed, the skill
    # keeps pointing at the old name and fails only in front of the user, mid
    # task - so the reference is checked here instead.
    $missing = @()

    foreach ($skill in (Get-ChildItem -LiteralPath (Join-Path $repoRoot "user\skills") -Filter "SKILL.md" -Recurse)) {

        foreach ($line in (Get-Content -LiteralPath $skill.FullName)) {

            if (-not $line.Contains("$harness/scripts/")) { continue }

            # $harness/scripts/<name>.ps1, however it is quoted.
            $rest = $line.Substring($line.IndexOf("$harness/scripts/") + "$harness/scripts/".Length)

            $name = ($rest -split '"')[0]
            $name = ($name -split "'")[0]
            $name = ($name -split " ")[0]

            if (-not $name.EndsWith(".ps1")) { continue }

            if (-not (Test-Path -LiteralPath (Join-Path $repoRoot (Join-Path "scripts" $name)))) {
                $missing += "$($skill.Directory.Name) -> scripts\$name"
            }
        }
    }

    $missing = @($missing | Select-Object -Unique)

    if ($missing.Count -gt 0) { return ($missing -join "; ") }

    return $true
}

Test-Case -Name "every slash command the documentation names exists" -Check {

    # Skills get renamed and removed; prose telling the user to run them does not
    # notice. docs/harness-model.md named /verify-loop long after it was gone.
    # Built-in commands the documentation may name are listed explicitly.
    $builtIn = @("code-review", "security-review", "config", "memory", "permissions", "plan")

    $known = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -Filter "SKILL.md" | ForEach-Object { $_.Directory.Name })
    $known += @((Get-HarnessManifest).AgentSkills)
    # why: `tlc harness install` installs harness-init; Tazuna hands every project to it.
    $known += "harness-init"

    $documents = @(Get-Item -LiteralPath (Join-Path $repoRoot "README.md"), (Join-Path $repoRoot "AGENTS.md"))
    # resumo-* are notes about external material, not documentation of this harness.
    $documents += @(Get-ChildItem -LiteralPath (Join-Path $repoRoot "docs") -Filter *.md | Where-Object { -not $_.Name.StartsWith("resumo-") })
    foreach ($folder in @("user", "mcp")) {
        $documents += @(Get-ChildItem -LiteralPath (Join-Path $repoRoot $folder) -Recurse -Filter *.md)
    }

    $unknown = @()

    foreach ($document in $documents) {

        $text = Get-Content -LiteralPath $document.FullName -Raw

        foreach ($match in [regex]::Matches($text, '(?m)(?:^|[\s`(\["''])/([a-z][a-z0-9-]+)(?=[\s`),.:;\]"'']|$)')) {

            $name = $match.Groups[1].Value

            if (($known -notcontains $name) -and ($builtIn -notcontains $name)) {
                $unknown += "$($document.Name) -> /$name"
            }
        }
    }

    $unknown = @($unknown | Select-Object -Unique)

    if ($unknown.Count -gt 0) { return ($unknown -join "; ") }

    return $true
}

Test-Case -Name "declared plugins are version-controlled, not machine-local" -Check {

    # `claude plugin install` writes to the configuration directory only. Unless
    # the declaration is in user/settings.json, a new machine silently does not
    # get the plugin - and CLAUDE.md relies on ponytail for the code-minimality
    # rules it no longer states itself.
    $settings = Get-Content -LiteralPath (Join-Path $repoRoot "user\settings.json") -Raw | ConvertFrom-Json

    if (-not $settings.enabledPlugins) { return "no enabledPlugins in user/settings.json" }

    $declared = @($settings.enabledPlugins.PSObject.Properties.Name | Where-Object { $_ })

    if ($declared.Count -eq 0) { return "enabledPlugins is empty" }

    # A plugin from a marketplace that is not declared cannot be installed on a
    # fresh machine.
    foreach ($name in $declared) {

        $marketplace = ($name -split "@")[-1]

        if ($marketplace -eq $name) { continue }

        if (-not $settings.extraKnownMarketplaces) {
            return "$name needs marketplace '$marketplace' but none are declared"
        }

        if (-not $settings.extraKnownMarketplaces.PSObject.Properties[$marketplace]) {
            return "$name needs marketplace '$marketplace', which is not declared"
        }
    }

    return $true
}

Test-Case -Name "the MCP catalogue is valid and carries no literal secrets" -Check {

    # This file is committed, so a literal credential in it is already leaked.
    $catalogue = Join-Path $repoRoot (Join-Path "mcp" "servers.json")

    $parseError = $null

    if (-not (Test-JsonFile -Path $catalogue -ErrorMessage ([ref]$parseError))) {
        return "mcp/servers.json is not valid JSON: $parseError"
    }

    $text = Get-Content -LiteralPath $catalogue -Raw

    $patterns = @(
        "-----BEGIN [A-Z ]*PRIVATE KEY-----",
        "AKIA[0-9A-Z]{16}",
        "gh[pousr]_[A-Za-z0-9]{36}",
        "xox[baprs]-[A-Za-z0-9-]{10,}",
        "sk-ant-[A-Za-z0-9_\-]{20,}"
    )

    foreach ($pattern in $patterns) {
        if ($text -match $pattern) { return "mcp/servers.json contains a literal credential" }
    }

    return $true
}

Test-Case -Name "install-mcp.ps1 reports an empty catalogue as empty" -Check {

    # @($null) is an array of one, which once made an empty catalogue report a
    # server as already present.
    #
    # -WhatIf is not optional here. Without it this case REGISTERED every server
    # in the catalogue into the real ~/.claude.json, so running the verification
    # changed machine state outside the repository - and that is how serena came
    # to be registered before anyone ran install-mcp.ps1. A suite that mutates
    # the machine it is measuring cannot be trusted about what it measured.
    # The empty-catalogue branch returns before ShouldProcess, so -WhatIf does
    # not weaken what this asserts.
    $output = & (Join-Path $scriptsRoot "install-mcp.ps1") -WhatIf 6>&1 | Out-String

    if ($LASTEXITCODE -ne 0) { return "exited $LASTEXITCODE on an empty catalogue" }

    $catalogue = Get-Content -LiteralPath (Join-Path $repoRoot (Join-Path "mcp" "servers.json")) -Raw | ConvertFrom-Json
    $defined = @($catalogue.mcpServers.PSObject.Properties.Name | Where-Object { $_ })

    if ($defined.Count -eq 0) {

        if ($output -match "No user-scope MCP servers are defined") { return $true }
        return "an empty catalogue was not reported as empty"
    }

    return $true
}

Test-Case -Name "install-mcp.ps1 refuses to register a server whose runtime is absent" -Check {

    # Registering writes a JSON entry and checks nothing, so a stdio server with
    # no runtime registered happily and then failed to start in every session.
    # Same probe as the health-check case: hide a runtime that does not live
    # beside claude.exe, so the rest of the script still works.
    $catalogue = Get-Content -LiteralPath (Join-Path $repoRoot "mcp\servers.json") -Raw | ConvertFrom-Json

    $claude = Get-Command claude -ErrorAction SilentlyContinue

    if (-not $claude) { return "claude is not on PATH, so this cannot be probed" }

    $claudeDirectory = (Split-Path -Parent $claude.Source).TrimEnd("\")
    $candidate = $null

    foreach ($property in $catalogue.mcpServers.PSObject.Properties) {

        if (-not $property.Value.command) { continue }

        $located = Get-Command $property.Value.command -ErrorAction SilentlyContinue

        if (-not $located) { continue }
        if ((Split-Path -Parent $located.Source).TrimEnd("\") -eq $claudeDirectory) { continue }

        $candidate = [PSCustomObject]@{
            Server    = $property.Name
            Command   = $property.Value.command
            Directory = (Split-Path -Parent $located.Source)
        }

        break
    }

    if (-not $candidate) {
        return "no catalogued stdio runtime could be hidden without also hiding claude"
    }

    $previousPath = $env:PATH

    try {

        $env:PATH = (($env:PATH -split ";") |
            Where-Object { $_ -and ($_.TrimEnd("\") -ne $candidate.Directory.TrimEnd("\")) }) -join ";"

        if (Get-Command $candidate.Command -ErrorAction SilentlyContinue) {
            return "could not take $($candidate.Command) off PATH, so this would prove nothing"
        }

        # -WhatIf throughout: this case must never touch the real registration.
        $output = & (Join-Path $scriptsRoot "install-mcp.ps1") -WhatIf 6>&1 | Out-String
    }
    finally {
        $env:PATH = $previousPath
    }

    if ($output -notmatch "'$($candidate.Command)' is not in PATH") {
        return "it did not report that $($candidate.Command) is missing"
    }

    if ($output -match "would register $($candidate.Server)") {
        return "it would have registered a server that cannot start"
    }

    return $true
}

Test-Case -Name "install-mcp.ps1 replaces a registration that no longer matches the catalogue" -Check {

    # Editing a definition here used to change nothing on a machine that had
    # already registered that server: the NAME was present, so it was reported
    # present and left alone, and the machine kept the old definition forever.
    # Found when serena moved from a git checkout to a pinned release.
    #
    # Isolated through CLAUDE_CONFIG_DIR, so the real registration is untouched,
    # and -WhatIf so nothing is written even there.
    $configDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-mcpcfg-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    $previousConfig = $env:CLAUDE_CONFIG_DIR

    try {

        New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
        $env:CLAUDE_CONFIG_DIR = $configDirectory

        # An HTTP entry: registering it spawns no process and reaches nothing.
        $wrong = '{\"type\":\"http\",\"url\":\"https://example.invalid/stale\"}'

        $global:LASTEXITCODE = 0
        & claude mcp add-json --scope user context7 $wrong 2>&1 | Out-Null

        if ($LASTEXITCODE -ne 0) { return "could not seed a stale registration" }

        $output = & (Join-Path $scriptsRoot "install-mcp.ps1") -WhatIf 6>&1 | Out-String

        if ($output -notmatch "STALE\s+context7") {
            return "a registration that does not match the catalogue was not reported stale"
        }

        if ($output -match "PRESENT\s+context7") {
            return "it reported the stale registration as present and left it alone"
        }

        return $true
    }
    finally {
        $env:CLAUDE_CONFIG_DIR = $previousConfig
        Remove-Item -LiteralPath $configDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case -Name "a catalogued stdio server says how to get and warm its runtime" -Check {

    # $install makes the skip message actionable; $warm is what stops a fresh
    # machine registering a server that then times out on its first start.
    # Without both, the next server added produces a dead end instead.
    $catalogue = Get-Content -LiteralPath (Join-Path $repoRoot "mcp\servers.json") -Raw | ConvertFrom-Json

    $missing = @()

    foreach ($property in $catalogue.mcpServers.PSObject.Properties) {

        if (-not $property.Value.command) { continue }

        foreach ($key in @("`$install", "`$warm")) {

            if (-not $property.Value.$key) { $missing += ($property.Name + " has no " + $key) }
        }
    }

    if ($missing.Count -gt 0) {
        return ("incomplete catalogue entry: " + ($missing -join ", "))
    }

    return $true
}

Test-Case -Name "warming runs the runtime that is actually registered" -Check {

    # A $warm command that resolves a different version from the registered one
    # warms the wrong cache and the first start is cold anyway - which is the
    # failure this whole mechanism exists to prevent, wearing a success message.
    $catalogue = Get-Content -LiteralPath (Join-Path $repoRoot "mcp\servers.json") -Raw | ConvertFrom-Json

    $wrong = @()

    foreach ($property in $catalogue.mcpServers.PSObject.Properties) {

        $warm = $property.Value."`$warm"

        if (-not $warm) { continue }

        if (-not $warm.StartsWith($property.Value.command)) {
            $wrong += ($property.Name + ": warms with '" + $warm.Split(" ")[0] + "', registered with '" + $property.Value.command + "'")
            continue
        }

        # The package specifier is what uv and npx cache. If the registered args
        # name one, the warm command has to name the same one.
        foreach ($argument in @($property.Value.args)) {

            if ($argument -match "^(--from$|-y$|--)") { continue }

            if ($argument -match "@|/") {

                if (-not $warm.Contains($argument)) {
                    $wrong += ($property.Name + ": registered with '" + $argument + "', which the warm command does not mention")
                }

                break
            }
        }
    }

    if ($wrong.Count -gt 0) { return ($wrong -join "; ") }

    return $true
}



Write-Host ""

Test-Case -Name "CI1 a GitHub Actions workflow runs the self-test with Windows PowerShell on windows-latest for every push and pull request" -Check {
    $path = Join-Path $repoRoot ".github\workflows\self-test.yml"
    if (-not (Test-Path -LiteralPath $path)) { return "no .github\workflows\self-test.yml" }
    $text = [System.IO.File]::ReadAllText($path)

    foreach ($required in @('(?m)^\s*push:', '(?m)^\s*pull_request:', '(?m)^\s*runs-on:\s*windows-latest\s*$', '(?m)^\s*shell:\s*powershell\s*$', 'scripts[\\/]test-harness\.ps1\s+-SkipSlow', 'scripts[\\/]build-installer\.ps1', '(?m)^\s*-?\s*uses:\s*actions/upload-artifact@v\d+', 'path:\s*dist/tazuna-setup\.exe')) {
        if ($text -notmatch $required) { return "the workflow does not match $required" }
    }

    # invariant: pwsh would prove nothing about Windows PowerShell 5.1, the version users run.
    if ($text -match '(?m)^\s*shell:\s*pwsh') { return "the workflow runs a step under pwsh" }
    return $true
}
Complete-TestFile
