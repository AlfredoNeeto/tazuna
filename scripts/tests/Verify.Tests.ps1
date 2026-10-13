[CmdletBinding()]
param([switch]$SkipSlow, [string]$Only)

. (Join-Path $PSScriptRoot "TestKit.ps1")
. (Join-Path $PSScriptRoot "Runner.ps1")

Start-Section "Verifier toolchain"

# The .NET verifier has to choose between the dotnet CLI and Visual Studio's
# MSBuild. Choosing wrong is not cosmetic: the dotnet CLI cannot restore, build
# or test a .NET Framework project, so such a repository would fail
# verification on every session, and a gate that cannot be satisfied gets
# switched off.
#
# Both cases run with the toolchains hidden - no vswhere, no dotnet on PATH -
# so each one fails with the message that names the branch it took. The
# assertion is then the same on a machine with Visual Studio and on one
# without, and it costs no build.
function Invoke-VerifierToolchainCase {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Files,

        [Parameter(Mandatory = $true)]
        [string]$Expect
    )

    $project = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-toolchain-" + [guid]::NewGuid().ToString("N").Substring(0, 8))

    $previousPath = $env:Path
    $previousProgramFiles = ${env:ProgramFiles(x86)}
    $previousPreference = $ErrorActionPreference

    try {

        New-Item -ItemType Directory -Path $project -Force | Out-Null

        foreach ($name in $Files.Keys) {
            Set-Content -LiteralPath (Join-Path $project $name) -Value $Files[$name] -NoNewline
        }

        & (Join-Path $scriptsRoot "init-project.ps1") -Type dotnet -Path $project -NoTrust 6>$null | Out-Null

        $verify = Join-Path $project (Join-Path ".claude" (Join-Path "scripts" "verify.ps1"))

        if (-not (Test-Path -LiteralPath $verify)) {
            return "init-project did not install a verifier"
        }

        # vswhere lives under Program Files (x86), so pointing that variable at
        # the empty project directory is what makes the Visual Studio lookup
        # come back empty.
        $env:Path = ((($previousPath -split ";") | Where-Object { $_ -and ($_ -notmatch "dotnet") }) -join ";")
        ${env:ProgramFiles(x86)} = $project

        $ErrorActionPreference = "Continue"
        $global:LASTEXITCODE = 0

        $output = (& powershell -NoProfile -ExecutionPolicy Bypass -File $verify | Out-String)
        $code = $LASTEXITCODE

        if ($code -eq 0) {
            return "the verifier passed with no toolchain available at all"
        }

        if ($output -notlike "*$Expect*") {
            return ("expected '" + $Expect + "', got: " + ($output -replace "\s+", " "))
        }

        return $true
    }
    finally {
        $env:Path = $previousPath
        ${env:ProgramFiles(x86)} = $previousProgramFiles
        $ErrorActionPreference = $previousPreference

        Remove-Item -LiteralPath $project -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case -Name "the verifier reaches for MSBuild on a .NET Framework project" -Check {

    return (Invoke-VerifierToolchainCase `
        -Files @{
            "Legacy.csproj"   = '<Project ToolsVersion="15.0"><Import Project="$(MSBuildExtensionsPath)\Microsoft\VisualStudio\v15.0\WebApplications\Microsoft.WebApplication.targets" /></Project>'
            "packages.config" = "<packages />"
        } `
        -Expect "no Visual Studio MSBuild was found")
}

Test-Case -Name "the verifier still uses the dotnet CLI on an SDK-style project" -Check {

    return (Invoke-VerifierToolchainCase `
        -Files @{ "Modern.csproj" = '<Project Sdk="Microsoft.NET.Sdk" />' } `
        -Expect "The .NET SDK was not found in PATH")
}

Start-Section "Verification speed"

Import-Module (Join-Path $sharedRoot (Join-Path "dot-claude" (Join-Path "scripts" "VerifyCommon.psm1"))) -Force

$script:speedRoots = @()

function New-SpeedProject {
    # why: each case gets its own repository, so no case sees another's files or commits.
    param([hashtable]$Files, [string[]]$Ignore = @(), [switch]$NoGit)

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-speed-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    $script:speedRoots += $root

    foreach ($name in $Files.Keys) {
        $path = Join-Path $root $name
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [System.IO.File]::WriteAllText($path, $Files[$name])
    }

    if ($Ignore.Count -gt 0) { [System.IO.File]::WriteAllText((Join-Path $root ".gitignore"), ($Ignore -join "`n")) }

    if (-not $NoGit) {
        & git -c init.defaultBranch=main init -q $root
        Invoke-SpeedCommit -Root $root
    }

    return $root
}

function Invoke-SpeedCommit {
    param([string]$Root)
    & git -C $Root -c core.autocrlf=false add -A
    & git -C $Root -c user.name=harness -c user.email=harness@example.invalid commit -q -m commit
}

try {

    Test-Case -Name "F1 in a git work tree the project files are what git lists: tracked, untracked, never a gitignored directory" -Check {
        $root = New-SpeedProject -Files @{ "src\App.cs" = "class A {}"; "gen\Out.cs" = "x"; "node_modules\p\i.js" = "x" } -Ignore @("gen/", "node_modules/")
        [System.IO.File]::WriteAllText((Join-Path $root "New.cs"), "class N {}")

        $files = @(Get-ProjectFile -ProjectRoot $root)

        if (($files -join "|") -ne ".gitignore|New.cs|src\App.cs") { return ("listed: " + ($files -join ", ")) }
        return $true
    }

    Test-Case -Name "F2 the fingerprint changes with a listed file or a new untracked file, and not with a gitignored one" -Check {
        $root = New-SpeedProject -Files @{ "src\App.cs" = "class A {}"; "gen\Out.cs" = "x" } -Ignore @("gen/")
        $start = Get-SourceFingerprint -ProjectRoot $root

        [System.IO.File]::WriteAllText((Join-Path $root "gen\Out.cs"), "changed")
        if ((Get-SourceFingerprint -ProjectRoot $root) -ne $start) { return "a change under the gitignored gen/ changed the fingerprint" }

        [System.IO.File]::WriteAllText((Join-Path $root "src\App.cs"), "class A { int x; }")
        $edited = Get-SourceFingerprint -ProjectRoot $root
        if ($edited -eq $start) { return "editing a tracked file left the fingerprint unchanged" }

        [System.IO.File]::WriteAllText((Join-Path $root "Extra.cs"), "class E {}")
        if ((Get-SourceFingerprint -ProjectRoot $root) -eq $edited) { return "a new untracked file left the fingerprint unchanged" }

        return $true
    }

    Test-Case -Name "F3 staging and committing an edit leaves the fingerprint as it was" -Check {
        $root = New-SpeedProject -Files @{ "App.cs" = "a" }
        [System.IO.File]::WriteAllText((Join-Path $root "App.cs"), "b")
        [System.IO.File]::WriteAllText((Join-Path $root "New.cs"), "n")
        $edited = Get-SourceFingerprint -ProjectRoot $root

        Invoke-SpeedCommit -Root $root

        if ((Get-SourceFingerprint -ProjectRoot $root) -ne $edited) { return "the commit changed the fingerprint, so the gate would ask for a new verification after every commit" }
        return $true
    }

    Test-Case -Name "F4 outside git the walk lists the sources and never a path under an excluded directory" -Check {
        $root = New-SpeedProject -NoGit -Files @{ "src\App.cs" = "a"; "node_modules\p\i.js" = "x"; "src\bin\Debug\App.dll" = "x"; "src\obj\App.cs" = "x" }

        $files = @(Get-ProjectFile -ProjectRoot $root)

        if (($files -join "|") -ne "src\App.cs") { return ("listed: " + ($files -join ", ")) }
        return $true
    }

    Test-Case -Name "F5 a change inside a nested repository changes the fingerprint" -Check {
        $root = New-SpeedProject -Files @{ "App.cs" = "a" }
        $nested = Join-Path $root "lib"
        New-Item -ItemType Directory -Path $nested -Force | Out-Null
        & git -c init.defaultBranch=main init -q $nested
        [System.IO.File]::WriteAllText((Join-Path $nested "Lib.cs"), "class L {}")
        $start = Get-SourceFingerprint -ProjectRoot $root

        [System.IO.File]::WriteAllText((Join-Path $nested "Lib.cs"), "class L { int y; }")

        if ((Get-SourceFingerprint -ProjectRoot $root) -eq $start) { return "editing lib\Lib.cs in a nested repository left the fingerprint unchanged" }
        return $true
    }

    Test-Case -Name "F6 a change to a file with a non-ASCII name changes the fingerprint" -Check {
        $name = "Relat" + [char]0x00F3 + "rio.cs"
        $root = New-SpeedProject -Files @{ $name = "a" }
        $start = Get-SourceFingerprint -ProjectRoot $root

        [System.IO.File]::WriteAllText((Join-Path $root $name), "b")

        if ((Get-SourceFingerprint -ProjectRoot $root) -eq $start) { return "editing $name left the fingerprint unchanged" }
        return $true
    }

    Test-Case -Name "F13 when git cannot list a work tree, or is not installed, the walk answers and git's error stays out of the output" -Check {
        $broken = New-SpeedProject -NoGit -Files @{ "App.cs" = "a"; "node_modules\p\i.js" = "x" }
        [System.IO.File]::WriteAllText((Join-Path $broken ".git"), "gitdir: " + (Join-Path $broken "missing-gitdir"))
        $healthy = New-SpeedProject -Files @{ "App.cs" = "a"; "node_modules\p\i.js" = "x" }

        $module = Join-Path $sharedRoot "dot-claude\scripts\VerifyCommon.psm1"
        $noGit = (Join-Path $env:SystemRoot "System32") + ";" + (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0")

        foreach ($scenario in @(@{ Name = "a .git pointing at a missing gitdir"; Root = $broken; Path = $env:PATH }, @{ Name = "no git on PATH"; Root = $healthy; Path = $noGit })) {

            $command = "`$env:PATH = '$($scenario.Path)'; Import-Module '$module' -Force; (Get-ProjectFile -ProjectRoot '$($scenario.Root)') -join '|'"
            $previous = $ErrorActionPreference

            try {
                $ErrorActionPreference = "Continue"
                $output = (& powershell -NoProfile -ExecutionPolicy Bypass -Command $command 2>&1 | Out-String)
            }
            finally {
                $ErrorActionPreference = $previous
            }

            if ($output -match "fatal|Exception") { return ("$($scenario.Name): an error reached the output: " + $output.Trim()) }
            $files = @($output.Trim().Split("|"))
            if ($files -notcontains "App.cs") { return ("$($scenario.Name): the walk did not answer: " + $output.Trim()) }
            if (@($files | Where-Object { $_.StartsWith("node_modules") }).Count -gt 0) { return ("$($scenario.Name): the walk entered node_modules: " + $output.Trim()) }
        }

        return $true
    }

    Test-Case -Name "F14 in git a tracked build directory is source and the harness's own state is not" -Check {
        $root = New-SpeedProject -Files @{ "src\App.cs" = "a"; "build\_build.csproj" = "<Project />"; "build\Build.cs" = "b" }

        if (@(Get-ProjectFile -ProjectRoot $root) -notcontains "build\_build.csproj") { return "build\_build.csproj is not listed, so .NET discovery cannot see it" }

        $start = Get-SourceFingerprint -ProjectRoot $root
        foreach ($state in @(".claude\state\last-verification.json", ".tlc\harness\state\handoff.json", ".harness-backup\20261013\settings.json")) {
            New-Item -ItemType Directory -Path (Split-Path -Parent (Join-Path $root $state)) -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $root $state), "{}")
        }
        if ((Get-SourceFingerprint -ProjectRoot $root) -ne $start) { return "state under .claude\state, .tlc or .harness-backup changed the fingerprint" }

        [System.IO.File]::WriteAllText((Join-Path $root "build\Build.cs"), "changed")
        if ((Get-SourceFingerprint -ProjectRoot $root) -eq $start) { return "editing the tracked build\Build.cs left the fingerprint unchanged" }
        return $true
    }

    Test-Case -Name "F15 the shard verdict fails a crash, a missing result and an exit that contradicts its result, and passes a clean run" -Check {
        $clean = "TEST FILE RESULT: passed 5 failed 0 skipped 1"
        $cases = @(
            @{ Name = "clean run"; Ok = $true; Shards = @(@{ Index = 0; Text = $clean; ExitCode = 0 }, @{ Index = 1; Text = "TEST FILE RESULT: passed 3 failed 0 skipped 0"; ExitCode = 0 }) },
            @{ Name = "crashed shard"; Ok = $false; Shards = @(@{ Index = 0; Text = $clean; ExitCode = 0 }, @{ Index = 1; Text = "PASS one case"; ExitCode = 3 }) },
            @{ Name = "missing result"; Ok = $false; Shards = @(@{ Index = 0; Text = ""; ExitCode = 0 }) },
            @{ Name = "non-zero exit after a clean result"; Ok = $false; Shards = @(@{ Index = 0; Text = $clean; ExitCode = 2 }) },
            @{ Name = "failed case"; Ok = $false; Shards = @(@{ Index = 0; Text = "TEST FILE RESULT: passed 4 failed 1 skipped 0"; ExitCode = 1 }) },
            @{ Name = "nothing passed"; Ok = $false; Shards = @(@{ Index = 0; Text = "TEST FILE RESULT: passed 0 failed 0 skipped 2"; ExitCode = 0 }) }
        )

        foreach ($case in $cases) {
            $verdict = Get-ShardVerdict -Results @($case.Shards | ForEach-Object { [PSCustomObject]$_ })
            if ($verdict.Ok -ne $case.Ok) { return "$($case.Name): Ok is $($verdict.Ok), expected $($case.Ok)" }
            if ($case.Name -eq "clean run") {
                if (($verdict.Passed -ne 8) -or ($verdict.Skipped -ne 1) -or ($verdict.Failed -ne 0)) { return "clean run totals: $($verdict.Passed)/$($verdict.Failed)/$($verdict.Skipped), expected 8/0/1" }
            }
        }

        return $true
    }

    Test-Case -Name "F17 a shard process that prints a clean result and then exits 5 is read with exit 5 and fails the run" -Check {
        $started = Start-ShardProcess -Arguments @("-NoProfile", "-Command", "Write-Output 'TEST FILE RESULT: passed 1 failed 0 skipped 0'; exit 5")
        $result = Receive-ShardResult -Started $started -Index 7

        if ($result.ExitCode -ne 5) { return "read exit '$($result.ExitCode)', expected 5" }
        if ($result.Text -notmatch "TEST FILE RESULT: passed 1 failed 0 skipped 0") { return ("read text: " + $result.Text) }
        if (Test-Path -LiteralPath $started.Output) { return "the shard's output file was left behind" }
        if ((Get-ShardVerdict -Results @($result)).Ok) { return "the verdict passed a shard that exited 5" }
        return $true
    }

    Test-Case -Name "F18 the run returns 1 and prints FAILED for a failing, a crashing, a silent and an unread test file, and 0 for a clean set" -Check {
        $root = New-SpeedProject -NoGit -Files @{
            "Clean1.Tests.ps1"   = "Write-Output 'TEST FILE RESULT: passed 2 failed 0 skipped 1'; exit 0"
            "Clean2.Tests.ps1"   = "Write-Output 'TEST FILE RESULT: passed 3 failed 0 skipped 0'; exit 0"
            "Clean3.Tests.ps1"   = "Write-Output 'TEST FILE RESULT: passed 4 failed 0 skipped 2'; exit 0"
            "Failing.Tests.ps1"  = "Write-Output 'TEST FILE RESULT: passed 1 failed 1 skipped 0'; exit 1"
            "Crashing.Tests.ps1" = "Write-Output 'PASS one case'; throw 'the file crashed'"
            "Silent.Tests.ps1"   = "exit 0"
        }
        $clean = @(@("Clean1", "Clean2", "Clean3") | ForEach-Object { Join-Path $root "$_.Tests.ps1" })

        $invoke = {
            param([string[]]$Files)
            $output = @(Invoke-TestRun -Files $Files 6>&1)
            return [PSCustomObject]@{ Code = (@($output | Where-Object { $_ -is [int] }) -join ","); Text = (@($output | Where-Object { $_ -isnot [int] }) | Out-String) }
        }

        $run = & $invoke -Files $clean
        if ($run.Code -ne "0") { return ("the clean set returned '$($run.Code)': " + $run.Text) }
        if ($run.Text -notmatch "HARNESS SELF-TEST PASSED") { return "the clean set did not print PASSED" }
        if ($run.Text -notmatch "Passed: 9\s+Failed: 0\s+Skipped: 3") { return ("the totals are not the sum of the three files: " + $run.Text) }

        foreach ($bad in @("Failing", "Crashing", "Silent")) {
            $run = & $invoke -Files ($clean + (Join-Path $root "$bad.Tests.ps1"))
            if ($run.Code -ne "1") { return "a $bad file returned '$($run.Code)', expected 1" }
            if (($run.Text -notmatch "HARNESS SELF-TEST FAILED") -or ($run.Text -match "HARNESS SELF-TEST PASSED")) { return ("a $bad file did not print FAILED: " + $run.Text) }
        }

        $read = @(1..3 | ForEach-Object { [PSCustomObject]@{ Index = $_; Text = "TEST FILE RESULT: passed 1 failed 0 skipped 0"; ExitCode = 0 } })
        if ((Get-ShardVerdict -Results $read -Expected 4).Ok) { return "the verdict passed a run with a file never read back" }
        if (-not (Get-ShardVerdict -Results $read -Expected 3).Ok) { return "the verdict failed three clean files read back of three" }
        return $true
    }

    Test-Case -Name "F19 -Only runs the matching cases alone, and a name that matches none fails the run" -Check {
        $kit = Join-Path $PSScriptRoot "TestKit.ps1"
        $body = @(
            '[CmdletBinding()] param([switch]$SkipSlow, [string]$Only)',
            ". '$kit'",
            'Test-Case -Name "Z1 the chosen case" -Check { return $true }',
            'Test-Case -Name "Z2 a case left out" -Check { return $true }',
            'Complete-TestFile') -join "`r`n"
        $root = New-SpeedProject -NoGit -Files @{ "Pick.Tests.ps1" = $body }
        $file = Join-Path $root "Pick.Tests.ps1"

        $output = @(Invoke-TestRun -Files @($file) -Only "Z1" 6>&1)
        $code = (@($output | Where-Object { $_ -is [int] }) -join ",")
        $text = (@($output | Where-Object { $_ -isnot [int] }) | Out-String)
        if ($code -ne "0") { return ("-Only Z1 returned '$code': " + $text) }
        if ($text -notmatch "PASS\s+Z1 the chosen case") { return ("Z1 did not run: " + $text) }
        if ($text -match "Z2 a case left out") { return ("Z2 ran although -Only named Z1: " + $text) }

        $output = @(Invoke-TestRun -Files @($file) -Only "NOPE" 6>&1)
        $code = (@($output | Where-Object { $_ -is [int] }) -join ",")
        $text = (@($output | Where-Object { $_ -isnot [int] }) | Out-String)
        if (($code -ne "1") -or ($text -notmatch "no case named 'NOPE' ran")) { return ("-Only NOPE returned '$code': " + $text) }
        return $true
    }

    function New-CountingProject {
        # why: a step that only reports it ran shows whether verify.ps1 repeated the work or reused a pass.
        $root = New-SpeedProject -NoGit -Files @{ "App.txt" = "a" }
        & (Join-Path $scriptsRoot "init-project.ps1") -Type generic -Path $root -NoTrust 6>$null | Out-Null

        $verify = Join-Path $root ".claude\scripts\verify.ps1"
        $declaration = '$VerificationSteps = @('
        $step = '@{ Name = "count"; Command = { cmd /c "exit $([int]$env:HARNESS_STEP_EXIT)" }; IsTest = $true }'
        $text = [System.IO.File]::ReadAllText($verify)
        $at = $text.IndexOf($declaration) + $declaration.Length
        [System.IO.File]::WriteAllText($verify, $text.Substring(0, $at) + $step + $text.Substring($at))

        return $root
    }

    function Invoke-CountingVerify {
        param([string]$Project, [string[]]$Arguments = @(), [int]$StepExit = 0)

        $previous = $ErrorActionPreference
        $savedExit = $env:HARNESS_STEP_EXIT

        try {
            $ErrorActionPreference = "Continue"
            $env:HARNESS_STEP_EXIT = [string]$StepExit
            $global:LASTEXITCODE = 0
            $output = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Project ".claude\scripts\verify.ps1") @Arguments 2>&1 | Out-String)
            return [PSCustomObject]@{ Code = $LASTEXITCODE; Output = $output; Ran = $output.Contains("==> count") }
        }
        finally {
            $ErrorActionPreference = $previous
            $env:HARNESS_STEP_EXIT = $savedExit
        }
    }

    Test-Case -Name "F7 a second verify on unchanged sources passes without running a step; -Force and a change run it" -Check {
        $project = New-CountingProject

        $first = Invoke-CountingVerify -Project $project
        if (($first.Code -ne 0) -or (-not $first.Ran)) { return ("first run: exit $($first.Code), ran=$($first.Ran): " + $first.Output) }

        $recorded = (Get-Content -LiteralPath (Join-Path $project ".claude\state\last-verification.json") -Raw | ConvertFrom-Json).completedAt

        $second = Invoke-CountingVerify -Project $project
        if ($second.Code -ne 0) { return "second run: exit $($second.Code)" }
        if ($second.Ran) { return "the second run on unchanged sources ran the step again" }
        if ((-not $second.Output.Contains("Unchanged since the run that passed at $recorded.")) -or ($second.Output -notmatch "VERIFICATION PASSED")) { return ("second run did not name the pass of $recorded" + ": " + $second.Output) }

        if (-not (Invoke-CountingVerify -Project $project -Arguments @("-Force")).Ran) { return "-Force did not run the step" }

        [System.IO.File]::WriteAllText((Join-Path $project "App.txt"), "changed")
        if (-not (Invoke-CountingVerify -Project $project).Ran) { return "a changed source did not run the step" }

        return $true
    }

    Test-Case -Name "F8 a pass recorded with -SkipTests does not answer a full verify" -Check {
        $project = New-CountingProject

        $partial = Invoke-CountingVerify -Project $project -Arguments @("-SkipTests")
        if (($partial.Code -ne 0) -or $partial.Ran -or ($partial.Output -notmatch "SKIP: count")) { return ("-SkipTests run: exit $($partial.Code): " + $partial.Output) }

        $full = Invoke-CountingVerify -Project $project
        if (($full.Code -ne 0) -or (-not $full.Ran)) { return "the full run after -SkipTests reused the partial pass" }

        return $true
    }

    Test-Case -Name "F9 a failing step prints VERIFICATION FAILED, exits 1 and records no pass" -Check {
        $project = New-CountingProject

        $failed = Invoke-CountingVerify -Project $project -StepExit 3
        if ($failed.Code -ne 1) { return "exit $($failed.Code), expected 1" }
        if (($failed.Output -notmatch "VERIFICATION FAILED") -or ($failed.Output -notmatch "count failed with exit code 3")) { return ("output: " + $failed.Output) }

        $again = Invoke-CountingVerify -Project $project -StepExit 3
        if (-not $again.Ran) { return "the run after a failure reused it as a pass" }

        return $true
    }

    Test-Case -Name "F16 a state file that does not parse, or predates the cache, makes verify run the steps and pass" -Check {
        $project = New-CountingProject
        $stateFile = Join-Path $project ".claude\state\last-verification.json"

        if (-not (Invoke-CountingVerify -Project $project).Ran) { return "the first run did not run the step" }

        foreach ($state in @("not json {", '{ "fingerprint": "x", "testsRan": true, "completedAt": "2026-01-01" }')) {
            [System.IO.File]::WriteAllText($stateFile, $state)
            $run = Invoke-CountingVerify -Project $project
            if (($run.Code -ne 0) -or (-not $run.Ran)) { return ("state '$state': exit $($run.Code), ran=$($run.Ran): " + $run.Output) }
        }

        return $true
    }

    Test-Case -Name "F10 a pass with one set of arguments does not answer another" -Check {
        $project = New-SpeedProject -NoGit -Files @{ "App.txt" = "a" }
        $counter = Join-Path $project "..\$(Split-Path -Leaf $project).runs"
        $script:speedRoots += $counter

        foreach ($configuration in @("Debug", "Release", "Release")) {
            $null = Invoke-Verification -ProjectRoot $project -Parameters @{ Configuration = $configuration } -Body {
                Add-Content -LiteralPath $counter -Value $configuration
            } 6>$null
        }

        $runs = @(Get-Content -LiteralPath $counter)
        if (($runs -join ",") -ne "Debug,Release") { return ("runs: " + ($runs -join ",") + ", expected Debug,Release") }
        return $true
    }

    Test-Case -Name "F12 the .NET verifier builds without a separate restore, passes --no-restore only with -SkipRestore, and reuses a pass per configuration" -Check {
        # why: a project under a gitignored directory proves discovery reads git's list; a walk would see two projects and stop.
        $project = New-SpeedProject -Files @{ "Modern.csproj" = '<Project Sdk="Microsoft.NET.Sdk" />'; "generated\Other.csproj" = '<Project Sdk="Microsoft.NET.Sdk" />' } -Ignore @("generated/")
        & (Join-Path $scriptsRoot "init-project.ps1") -Type dotnet -Path $project -NoTrust 6>$null | Out-Null

        $bin = Join-Path $project "..\$(Split-Path -Leaf $project)-bin"
        $log = "$bin\dotnet.log"
        $script:speedRoots += $bin
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        [System.IO.File]::WriteAllText("$bin\dotnet.cmd", "@echo dotnet %*>>`"$log`"`r`n")

        $previousPath = $env:Path
        $previousPreference = $ErrorActionPreference

        function Invoke-StubDotnetVerify {
            param([string[]]$Arguments = @())
            $before = @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue).Count
            $global:LASTEXITCODE = 0
            $output = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $project ".claude\scripts\verify.ps1") @Arguments 2>&1 | Out-String)
            return [PSCustomObject]@{ Code = $LASTEXITCODE; Output = $output; Calls = @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue | Select-Object -Skip $before) }
        }

        try {
            $env:Path = $bin + ";" + ((($previousPath -split ";") | Where-Object { $_ -and ($_ -notmatch "dotnet") }) -join ";")
            $ErrorActionPreference = "Continue"

            $first = Invoke-StubDotnetVerify
            if ($first.Code -ne 0) { return ("first run: exit $($first.Code): " + $first.Output) }
            if (@($first.Calls | Where-Object { $_ -match "^dotnet restore" }).Count -gt 0) { return ("a separate restore ran: " + ($first.Calls -join " | ")) }
            if (@($first.Calls | Where-Object { ($_ -match "^dotnet build ") -and ($_ -notmatch "--no-restore") }).Count -ne 1) { return ("expected one dotnet build that restores: " + ($first.Calls -join " | ")) }
            if (@($first.Calls | Where-Object { $_ -match "^dotnet test .*--no-build" }).Count -ne 1) { return ("expected one dotnet test --no-build: " + ($first.Calls -join " | ")) }

            if ((Invoke-StubDotnetVerify).Calls.Count -ne 0) { return "the second Debug run on unchanged sources called dotnet again" }

            $release = Invoke-StubDotnetVerify -Arguments @("-Configuration", "Release")
            if (@($release.Calls | Where-Object { $_ -match "^dotnet build .*Release" }).Count -ne 1) { return ("a Debug pass answered a Release run: " + ($release.Calls -join " | ")) }

            $skip = Invoke-StubDotnetVerify -Arguments @("-SkipRestore", "-Force")
            if (@($skip.Calls | Where-Object { $_ -match "^dotnet build .*--no-restore" }).Count -ne 1) { return ("-SkipRestore did not pass --no-restore: " + ($skip.Calls -join " | ")) }

            return $true
        }
        finally {
            $env:Path = $previousPath
            $ErrorActionPreference = $previousPreference
        }
    }

    Test-Case -Name "F11 every verify.ps1 records its pass through Invoke-Verification and none writes the state itself" -Check {
        $scripts = @(
            (Join-Path $repoRoot "templates\_shared\dot-claude\scripts\verify.ps1"),
            (Join-Path $repoRoot ".claude\scripts\verify.ps1")
        )

        $wrong = @($scripts | Where-Object {
                $text = [System.IO.File]::ReadAllText($_)
                ($text -notmatch "Invoke-Verification") -or ($text -match "Get-VerificationStateFile")
            })

        if ($wrong.Count -eq 0) { return $true }
        return ("not on the shared runner: " + ($wrong -join ", "))
    }
}
finally {
    foreach ($root in $script:speedRoots) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

Complete-TestFile
