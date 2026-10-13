[CmdletBinding()]
param([switch]$SkipSlow, [string]$Only)

. (Join-Path $PSScriptRoot "TestKit.ps1")

try {

    Start-Section "MCP"

    # S3 - mcp add

    $adoEnvironment = @{ ADO_COLLECTION_URL = "http://tfs.invalid/DefaultCollection"; ADO_PAT = "not-a-real-token" }

    function Invoke-McpAdd {
        param([string]$Project, [string[]]$Arguments, [hashtable]$Environment = $adoEnvironment, [string[]]$Drop = @())
        return (Invoke-WithStubs -Root (Split-Path -Parent $Project) -Script (Join-Path $scriptsRoot "project-mcp.ps1") `
            -Arguments (@($Arguments) + @("-Path", $Project)) -Environment $Environment -DropPathContaining $Drop)
    }

    function New-McpProject {
        $project = Join-Path (New-ScratchRoot) "project"
        New-Item -ItemType Directory -Path (Join-Path $project ".claude") -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $project ".mcp.json") -Value '{ "mcpServers": { "mine": { "command": "mine" } } }'
        Set-Content -LiteralPath (Join-Path $project ".claude\settings.json") -Value '{ "permissions": { "allow": ["Read(x)"] } }'
        return $project
    }

    Test-Case -Name "C16 mcp add writes each of the 4 shared catalog entries and keeps an existing one" -Check {
        if ($catalogNames.Count -ne 5) { return "the catalog has $($catalogNames.Count) entries, expected 5" }

        # why: azure-devops is registered in Claude Code local scope instead (C20, C21, K1).
        foreach ($name in @($catalogNames | Where-Object { $_ -ne "azure-devops" })) {
            $project = New-McpProject
            $run = Invoke-McpAdd -Project $project -Arguments @("add", $name)
            if ($run.Code -ne 0) { return "$name exited $($run.Code): $($run.Output)" }

            $mcp = Get-Content -LiteralPath (Join-Path $project ".mcp.json") -Raw | ConvertFrom-Json
            if (-not $mcp.mcpServers.mine) { return "$name dropped the existing entry" }
            if ((Get-JsonCanonicalForm -Value $mcp.mcpServers.$name) -ne (Get-JsonCanonicalForm -Value $catalog.$name.server)) { return "$name entry differs from the catalog" }
            $settings = Get-Content -LiteralPath (Join-Path $project ".claude\settings.json") -Raw | ConvertFrom-Json
            if (@($settings.enabledMcpjsonServers) -notcontains $name) { return "$name is not in enabledMcpjsonServers" }
        }
        return $true
    }

    Test-Case -Name "C17 mcp add enables the server and keeps the existing permissions" -Check {
        $project = New-McpProject
        $null = Invoke-McpAdd -Project $project -Arguments @("add", "mermaid")
        $settings = Get-Content -LiteralPath (Join-Path $project ".claude\settings.json") -Raw | ConvertFrom-Json
        if (@($settings.enabledMcpjsonServers) -notcontains "mermaid") { return "mermaid is not enabled" }
        if (@($settings.permissions.allow) -notcontains "Read(x)") { return "the existing permissions were lost" }
        return $true
    }

    Test-Case -Name "C18 a second identical mcp add prints UNCHANGED and changes no byte" -Check {
        $project = New-McpProject
        $null = Invoke-McpAdd -Project $project -Arguments @("add", "mermaid")
        $before = @((Get-FileSha256 -Path (Join-Path $project ".mcp.json")), (Get-FileSha256 -Path (Join-Path $project ".claude\settings.json")))
        $run = Invoke-McpAdd -Project $project -Arguments @("add", "mermaid")
        $after = @((Get-FileSha256 -Path (Join-Path $project ".mcp.json")), (Get-FileSha256 -Path (Join-Path $project ".claude\settings.json")))
        if ($run.Code -ne 0) { return "exit $($run.Code)" }
        if ($run.Output -notmatch "UNCHANGED\s+mermaid") { return "no 'UNCHANGED mermaid'" }
        if (($before -join ",") -ne ($after -join ",")) { return "a file changed on the second run" }
        return $true
    }

    Test-Case -Name "C19 mcp add of an unknown name lists the catalog, exits 1 and writes nothing" -Check {
        $project = Join-Path (New-ScratchRoot) "project"
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        $run = Invoke-McpAdd -Project $project -Arguments @("add", "nope")
        if ($run.Code -ne 1) { return "exit $($run.Code), expected 1" }
        foreach ($name in $catalogNames) { if ($run.Output -notmatch [regex]::Escape($name)) { return "$name not listed" } }
        if (Test-Path -LiteralPath (Join-Path $project ".mcp.json")) { return ".mcp.json was written" }
        return $true
    }

    function New-AdoConfiguratorStub {
        # A configurator that records its -Path and whether .mcp.json existed when it ran.
        param([string]$Project, [int]$Code = 0)
        $marker = Join-Path (Split-Path -Parent $Project) "configurator.txt"
        $stub = Join-Path (Split-Path -Parent $Project) "configure-stub.ps1"
        Set-Content -LiteralPath $stub -Value ('param([string]$Path) Set-Content -LiteralPath "' + $marker + '" -Value ("path=" + $Path + ";mcp-existed=" + (Test-Path -LiteralPath "' + (Join-Path $Project ".mcp.json") + '")) -WhatIf:$false; exit ' + $Code)
        return [PSCustomObject]@{ Script = $stub; Marker = $marker }
    }

    Test-Case -Name "C20 mcp add azure-devops runs the configurator for the project before writing" -Check {
        $project = Join-Path (New-ScratchRoot) "project"
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        $stub = New-AdoConfiguratorStub -Project $project

        $run = Invoke-McpAdd -Project $project -Arguments @("add", "azure-devops", "-AdoConfigurator", $stub.Script)

        if (-not (Test-Path -LiteralPath $stub.Marker)) { return "the configurator did not run" }
        $expected = "path=" + (Resolve-Path -LiteralPath $project).ProviderPath + ";mcp-existed=False"
        if ((Get-Content -LiteralPath $stub.Marker -Raw).Trim() -ne $expected) { return ("configurator saw '" + (Get-Content -LiteralPath $stub.Marker -Raw).Trim() + "', expected '$expected'") }
        if ($run.Code -ne 0) { return "exit $($run.Code)" }
        return $true
    }

    Test-Case -Name "C21 mcp add azure-devops installs its rule and leaves it out of .mcp.json and enabledMcpjsonServers" -Check {
        $project = New-McpProject
        $stub = New-AdoConfiguratorStub -Project $project
        $run = Invoke-McpAdd -Project $project -Arguments @("add", "azure-devops", "-AdoConfigurator", $stub.Script)
        if ($run.Code -ne 0) { return "exit $($run.Code): $($run.Output)" }
        $rule = Join-Path $project ".claude\rules\azure-devops.md"
        if (-not (Test-FileContentEqual -ReferenceFile (Join-Path $repoRoot "mcp\rules\azure-devops.md") -DifferenceFile $rule)) { return "the rule was not installed" }
        $mcp = Get-Content -LiteralPath (Join-Path $project ".mcp.json") -Raw | ConvertFrom-Json
        if ($mcp.mcpServers.PSObject.Properties["azure-devops"]) { return ".mcp.json got an azure-devops entry" }
        if (-not $mcp.mcpServers.mine) { return "the existing entry was dropped" }
        $settings = Get-Content -LiteralPath (Join-Path $project ".claude\settings.json") -Raw | ConvertFrom-Json
        if ($settings.PSObject.Properties["enabledMcpjsonServers"] -and (@($settings.enabledMcpjsonServers) -contains "azure-devops")) { return "azure-devops was enabled in settings.json" }
        return $true
    }

    Start-Section "Azure DevOps"

    # K - azure-devops per project: configure-ado.ps1 run in-process against a stub HTTP server and a stub claude.

    function Start-AdoStubServer {
        # hazard: HttpListener on a localhost prefix needs no URL ACL; any other host would need admin.
        $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()

        $job = Start-Job -ArgumentList $port -ScriptBlock {
            param($port)
            $listener = New-Object System.Net.HttpListener
            $listener.Prefixes.Add("http://localhost:$port/")
            $listener.Start()
            $good = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":good-pat"))
            while ($true) {
                $context = $listener.GetContext()
                $path = [Uri]::UnescapeDataString($context.Request.Url.AbsolutePath)
                if ($path -eq "/stop") { $context.Response.Close(); $listener.Stop(); break }
                $status = 404
                if ($context.Request.Headers["Authorization"] -ne $good) { $status = 401 }
                elseif (($path -eq "/MOBILE/_apis/projects/MyProject") -or ($path -eq "/tfs/DefaultCollection/_apis/projects/My Project")) { $status = 200 }
                elseif ($path -eq "/OLD/_apis/projects/MyProject") { $status = 400 }
                $bytes = [Text.Encoding]::ASCII.GetBytes("{}")
                $context.Response.StatusCode = $status
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $context.Response.Close()
            }
        }

        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline) {
            try { $null = Invoke-WebRequest -Uri "http://localhost:$port/" -UseBasicParsing -TimeoutSec 2 } catch { if ($_.Exception.Response) { break } }
            Start-Sleep -Milliseconds 200
        }

        return [PSCustomObject]@{ Job = $job; Url = "http://localhost:$port" }
    }

    $script:adoServer = $null

    function Get-AdoStubServer {
        if (-not $script:adoServer) { $script:adoServer = Start-AdoStubServer }
        return $script:adoServer
    }

    function Stop-AdoStubServer {
        param([Parameter(Mandatory = $true)]$Server)
        # why: the job blocks in GetContext(), which Remove-Job cannot interrupt; it waited 120 s on every run.
        try { $null = Invoke-WebRequest -Uri ($Server.Url + "/stop") -UseBasicParsing -TimeoutSec 5 } catch { }
        Remove-Job -Job $Server.Job -Force -ErrorAction SilentlyContinue
    }

    function Invoke-AdoConfigure {
        <#
            Runs configure-ado.ps1 in this process with the stub claude first on PATH (or no claude at
            all) and Read-Host replaced, so no case can block on a prompt. Returns code, output, calls.
        #>
        param(
            [string]$ProjectUrl,
            [string]$PatText = "good-pat",
            [switch]$SkipTest,
            [switch]$WhatIf,
            [switch]$NoClaude,
            [string]$Fail = ""
        )

        $root = New-ScratchRoot
        $project = Join-Path $root "project"
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        $bin = New-StubBin -Root $root
        $log = Join-Path $root "calls.log"

        $path = $bin + ";" + $env:PATH
        if ($NoClaude) { $path = (Join-Path $env:SystemRoot "System32") + ";" + (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0") }

        $saved = @{}
        $variables = @{ PATH = $path; HARNESS_STUB_LOG = $log; HARNESS_STUB_FAIL = $Fail }
        foreach ($key in $variables.Keys) {
            $saved[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
            [Environment]::SetEnvironmentVariable($key, $variables[$key], "Process")
        }

        $secure = New-Object System.Security.SecureString
        foreach ($character in $PatText.ToCharArray()) { $secure.AppendChar($character) }

        $arguments = @{ ProjectUrl = $ProjectUrl; Pat = $secure; Path = $project }
        if ($SkipTest) { $arguments["SkipTest"] = $true }
        if ($WhatIf) { $arguments["WhatIf"] = $true }

        # why: a function shadows the cmdlet for the script called below; a prompt is recorded instead of blocking.
        function Read-Host { Write-Host "PROMPTED"; return "" }

        $previous = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $global:LASTEXITCODE = 0
            $output = (& (Join-Path $scriptsRoot "configure-ado.ps1") @arguments *>&1 | Out-String)
            $code = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previous
            foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key], "Process") }
        }

        $calls = @()
        if (Test-Path -LiteralPath $log) { $calls = @(Get-Content -LiteralPath $log) }
        $mcpCalls = @($calls | Where-Object { $_.StartsWith("claude mcp ") })

        return [PSCustomObject]@{ Code = $code; Output = $output; Calls = $calls; McpCalls = $mcpCalls; Project = $project }
    }

    Test-Case -Name "K1 a project URL registers azure-devops in local scope with the collection, project, PAT and API 7.0" -Check {
        $server = Get-AdoStubServer
        $run = Invoke-AdoConfigure -ProjectUrl ($server.Url + "/MOBILE/MyProject")
        if ($run.Code -ne 0) { return "exit $($run.Code): $($run.Output)" }
        $add = @($run.McpCalls | Where-Object { $_.StartsWith("claude mcp add ") })
        if ($add.Count -ne 1) { return ("expected one claude mcp add, got: " + ($run.McpCalls -join " | ")) }
        $expected = @(
            "claude mcp add azure-devops -s local ",
            ("-e AZURE_DEVOPS_ORG_URL=" + $server.Url + "/MOBILE "),
            "-e AZURE_DEVOPS_AUTH_METHOD=pat ",
            "-e AZURE_DEVOPS_API_VERSION=7.0 ",
            "-e AZURE_DEVOPS_PAT=good-pat ",
            "-e AZURE_DEVOPS_DEFAULT_PROJECT=MyProject ",
            " -- npx -y @tiberriver256/mcp-server-azure-devops"
        )
        foreach ($part in $expected) { if (-not $add[0].Contains($part)) { return "missing '$part' in: $($add[0])" } }
        $cwd = @($run.Calls | Where-Object { $_.StartsWith("claude-cwd ") })
        if ($cwd[0] -ne ("claude-cwd " + (Resolve-Path -LiteralPath $run.Project).ProviderPath)) { return "claude ran in '$($cwd[0])', not the project" }
        if ($run.Output.Contains("PROMPTED")) { return "it prompted although every value was given" }
        return $true
    }

    Test-Case -Name "K2 a project URL with a virtual directory, an encoded name, a page suffix and a trailing slash is split into collection and project" -Check {
        $server = Get-AdoStubServer
        $run = Invoke-AdoConfigure -ProjectUrl ($server.Url + "/tfs/DefaultCollection/My%20Project/_git/repo/")
        if ($run.Code -ne 0) { return "exit $($run.Code): $($run.Output)" }
        $add = @($run.McpCalls | Where-Object { $_.StartsWith("claude mcp add ") })
        if (-not $add[0].Contains("-e AZURE_DEVOPS_ORG_URL=" + $server.Url + "/tfs/DefaultCollection ")) { return "wrong collection: $($add[0])" }
        if (-not $add[0].Contains("-e AZURE_DEVOPS_DEFAULT_PROJECT=My Project ")) { return "wrong project: $($add[0])" }
        return $true
    }

    Test-Case -Name "K3 the PAT reaches no console output, no project file and no environment variable" -Check {
        $marker = "selftest-not-a-real-token-" + [guid]::NewGuid().ToString("N")
        $userBefore = [Environment]::GetEnvironmentVariable("ADO_PAT", "User")
        $run = Invoke-AdoConfigure -ProjectUrl "http://tfs.invalid/DefaultCollection/MyProject" -PatText $marker -SkipTest
        if ($run.Code -ne 0) { return "exit $($run.Code): $($run.Output)" }
        if (-not (@($run.McpCalls) -join " ").Contains("AZURE_DEVOPS_PAT=" + $marker)) { return "the PAT did not reach claude mcp add, so this case proves nothing" }
        if ($run.Output.Contains($marker)) { return "the PAT appeared in the output" }
        foreach ($file in @(Get-ChildItem -LiteralPath $run.Project -Recurse -File -Force)) {
            if ([System.IO.File]::ReadAllText($file.FullName).Contains($marker)) { return "the PAT was written to $($file.FullName)" }
        }
        if ([Environment]::GetEnvironmentVariable("ADO_PAT", "User") -ne $userBefore) { return "the User ADO_PAT changed" }
        foreach ($name in @("ADO_PAT", "AZURE_DEVOPS_PAT")) {
            foreach ($scope in @("Process", "User")) {
                if ([string][Environment]::GetEnvironmentVariable($name, $scope) -eq $marker) { return "the $scope $name holds the PAT" }
            }
        }
        return $true
    }

    Test-Case -Name "K4 a re-run removes the local entry before adding it, and a failed remove does not stop it" -Check {
        $run = Invoke-AdoConfigure -ProjectUrl "http://tfs.invalid/DefaultCollection/MyProject" -SkipTest -Fail "claude-mcp-remove"
        if ($run.Code -ne 0) { return "exit $($run.Code): $($run.Output)" }
        if ($run.McpCalls.Count -ne 2) { return ("expected remove then add, got: " + ($run.McpCalls -join " | ")) }
        if ($run.McpCalls[0] -ne "claude mcp remove azure-devops -s local") { return "first call was: $($run.McpCalls[0])" }
        if (-not $run.McpCalls[1].StartsWith("claude mcp add azure-devops -s local ")) { return "second call was: $($run.McpCalls[1])" }
        return $true
    }

    Test-Case -Name "K5 a PAT the server refuses, a project it does not have, and a server that does not answer each register nothing and exit 1" -Check {
        $server = Get-AdoStubServer
        $cases = @(
            @{ Url = ($server.Url + "/MOBILE/MyProject"); Pat = "bad-pat"; Expect = "Not authorized (401)" },
            @{ Url = ($server.Url + "/MOBILE/Missing"); Pat = "good-pat"; Expect = "Project 'Missing' not found (404)" },
            @{ Url = ($server.Url + "/OLD/MyProject"); Pat = "good-pat"; Expect = "HTTP 400 - usually the api-version" },
            @{ Url = "http://127.0.0.1:9/MOBILE/MyProject"; Pat = "good-pat"; Expect = "FAIL" }
        )
        foreach ($case in $cases) {
            $run = Invoke-AdoConfigure -ProjectUrl $case.Url -PatText $case.Pat
            if ($run.Code -ne 1) { return "$($case.Url): exit $($run.Code), expected 1" }
            if ($run.Output -notmatch "FAIL") { return "$($case.Url): no FAIL" }
            if (-not $run.Output.Contains($case.Expect)) { return "$($case.Url): output lacks '$($case.Expect)'" }
            if ($run.McpCalls.Count -ne 0) { return "$($case.Url): claude mcp was called" }
        }
        return $true
    }

    Test-Case -Name "K6 a bare collection URL is refused as not a project URL, with an example" -Check {
        foreach ($url in @("http://azuredevops/MOBILE", "http://azuredevops/MOBILE/_git/x")) {
            $run = Invoke-AdoConfigure -ProjectUrl $url -SkipTest
            if ($run.Code -ne 1) { return "${url}: exit $($run.Code), expected 1" }
            if (-not $run.Output.Contains("Not a project URL")) { return "${url}: no 'Not a project URL'" }
            if (-not $run.Output.Contains("http://server/DefaultCollection/MyProject")) { return "${url}: no example" }
            if ($run.McpCalls.Count -ne 0) { return "${url}: claude mcp was called" }
        }
        return $true
    }

    Test-Case -Name "K7 a URL without a scheme, an empty URL and an empty PAT each exit 1 without calling claude mcp" -Check {
        $runs = @(
            (Invoke-AdoConfigure -ProjectUrl "azuredevops/MOBILE/P" -SkipTest),
            (Invoke-AdoConfigure -ProjectUrl "" -SkipTest),
            (Invoke-AdoConfigure -ProjectUrl "http://azuredevops/MOBILE/P" -PatText "" -SkipTest)
        )
        $names = @("no scheme", "empty URL", "empty PAT")
        for ($i = 0; $i -lt 3; $i++) {
            if ($runs[$i].Code -ne 1) { return "$($names[$i]): exit $($runs[$i].Code), expected 1" }
            if ($runs[$i].McpCalls.Count -ne 0) { return "$($names[$i]): claude mcp was called" }
        }
        return $true
    }

    Test-Case -Name "K8 without claude on PATH it says Claude Code is required and exits 1 before any prompt" -Check {
        $run = Invoke-AdoConfigure -ProjectUrl "" -NoClaude
        if ($run.Code -ne 1) { return "exit $($run.Code), expected 1" }
        if (-not $run.Output.Contains("Claude Code (claude) is required")) { return "no 'Claude Code (claude) is required'" }
        if ($run.Output.Contains("PROMPTED")) { return "it prompted before refusing" }
        return $true
    }

    Test-Case -Name "K9 a failing claude mcp add prints FAIL, masks the PAT in what claude printed, and exits 1" -Check {
        $marker = "selftest-not-a-real-token-" + [guid]::NewGuid().ToString("N")
        $run = Invoke-AdoConfigure -ProjectUrl "http://tfs.invalid/DefaultCollection/MyProject" -PatText $marker -SkipTest -Fail "claude-mcp-add"
        if ($run.Code -ne 1) { return "exit $($run.Code), expected 1" }
        if ($run.Output -notmatch "FAIL\s+claude mcp add exited 1") { return "no 'FAIL claude mcp add exited 1'" }
        if (-not $run.Output.Contains("AZURE_DEVOPS_PAT=(PAT)")) { return "claude's echoed arguments were not printed masked, so this case proves nothing" }
        if ($run.Output.Contains($marker)) { return "the PAT appeared in the failure output" }
        return $true
    }

    Test-Case -Name "K10 -WhatIf registers nothing and tazuna mcp add azure-devops -WhatIf writes no project file" -Check {
        $run = Invoke-AdoConfigure -ProjectUrl "http://tfs.invalid/DefaultCollection/MyProject" -SkipTest -WhatIf
        if ($run.Code -ne 0) { return "exit $($run.Code): $($run.Output)" }
        if (Test-Path -LiteralPath (Join-Path $run.Project ".claude")) { return "configure-ado -WhatIf created a project file" }
        if ($run.Output -notmatch "WHATIF\s+would register azure-devops") { return "no 'WHATIF would register azure-devops'" }
        if ($run.McpCalls.Count -ne 0) { return ("claude mcp was called: " + ($run.McpCalls -join " | ")) }

        $project = New-McpProject
        $before = @(Get-ChildItem -LiteralPath $project -Recurse -File -Force | ForEach-Object { $_.FullName + "=" + (Get-FileSha256 -Path $_.FullName) })
        $stub = New-AdoConfiguratorStub -Project $project
        $add = Invoke-McpAdd -Project $project -Arguments @("add", "azure-devops", "-AdoConfigurator", $stub.Script, "-WhatIf")
        $after = @(Get-ChildItem -LiteralPath $project -Recurse -File -Force | ForEach-Object { $_.FullName + "=" + (Get-FileSha256 -Path $_.FullName) })
        if ($add.Code -ne 0) { return "mcp add -WhatIf exit $($add.Code)" }
        if ($add.Output -notmatch "WHATIF\s+would write \.claude\\rules\\azure-devops\.md") { return "no WHATIF line for the rule" }
        if (($before -join ",") -ne ($after -join ",")) { return "mcp add -WhatIf changed a project file" }
        return $true
    }

    Test-Case -Name "K11 the Azure DevOps stub server stops within 5 s of a stop request" -Check {
        $server = Start-AdoStubServer
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        Stop-AdoStubServer -Server $server
        $elapsed = $clock.Elapsed.TotalSeconds

        if (Get-Job -Id $server.Job.Id -ErrorAction SilentlyContinue) { return "the stub server's job is still there" }
        if ($elapsed -ge 5) { return ("stopping took {0:N1} s" -f $elapsed) }
        return $true
    }

    Test-Case -Name "C22 every credential-bearing value in the MCP catalogs is a placeholder" -Check {
        $placeholder = '^\$\{[A-Z_][A-Z0-9_]*(:-[^}]*)?\}$'
        $plainLiterals = @("pat", "7.0")
        $problems = @()

        $user = (Get-Content -LiteralPath (Join-Path $repoRoot "mcp\servers.json") -Raw | ConvertFrom-Json).mcpServers
        $servers = @()
        foreach ($p in $user.PSObject.Properties) { $servers += [PSCustomObject]@{ Name = $p.Name; Server = $p.Value } }
        foreach ($name in $catalogNames) { $servers += [PSCustomObject]@{ Name = $name; Server = $catalog.$name.server } }

        foreach ($entry in $servers) {
            foreach ($section in @("env", "headers")) {
                if (-not $entry.Server.PSObject.Properties[$section]) { continue }
                foreach ($value in $entry.Server.$section.PSObject.Properties) {
                    if (($value.Value -notmatch $placeholder) -and ($plainLiterals -notcontains $value.Value)) {
                        $problems += "$($entry.Name).$section.$($value.Name)"
                    }
                }
            }
            $text = $entry.Server | ConvertTo-Json -Depth 20
            foreach ($pattern in @("-----BEGIN [A-Z ]*PRIVATE KEY-----", "AKIA[0-9A-Z]{16}", "gh[pousr]_[A-Za-z0-9]{36}", "sk-ant-[A-Za-z0-9_\-]{20,}", "sk-[A-Za-z0-9]{32,}", "AIza[0-9A-Za-z_\-]{35}")) {
                if ($text -match $pattern) { $problems += "$($entry.Name) matches $pattern" }
            }
        }

        if ($problems.Count -gt 0) { return ("literal values: " + ($problems -join ", ")) }
        return $true
    }

    Test-Case -Name "C23 mcp list prints the 5 names with their purpose" -Check {
        $project = Join-Path (New-ScratchRoot) "project"
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        $run = Invoke-McpAdd -Project $project -Arguments @("list")
        if ($run.Code -ne 0) { return "exit $($run.Code)" }
        foreach ($name in @("azure-devops", "serena", "drawio", "plantuml", "mermaid")) {
            $purpose = $catalog.$name.purpose
            if (-not $purpose) { return "$name has no purpose" }
            if ($run.Output -notmatch ([regex]::Escape($name) + "\s+" + [regex]::Escape($purpose))) { return "$name is not printed with its purpose" }
        }
        return $true
    }

    Test-Case -Name "C24 mcp add serena without uvx says how to get it, exits 1 and writes nothing" -Check {
        $project = Join-Path (New-ScratchRoot) "project"
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        Remove-Item -LiteralPath (Join-Path (New-StubBin -Root (Split-Path -Parent $project)) "uvx.ps1")

        $run = Invoke-McpAdd -Project $project -Arguments @("add", "serena") -Drop @("uvx.exe", "uvx.cmd", "uvx.ps1", "uvx")
        if ($run.Code -ne 1) { return "exit $($run.Code), expected 1" }
        if ($run.Output -notmatch "uvx required") { return "no 'uvx required'" }
        if ($run.Output -notmatch [regex]::Escape("irm https://astral.sh/uv/install.ps1 | iex")) { return "no install command" }
        if (Test-Path -LiteralPath (Join-Path $project ".mcp.json")) { return ".mcp.json was written" }
        return $true
    }
}
finally {
    if ($script:adoServer) { Stop-AdoStubServer -Server $script:adoServer }
    Clear-ScratchRoot
}

Complete-TestFile
