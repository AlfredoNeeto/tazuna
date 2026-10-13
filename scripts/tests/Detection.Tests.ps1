[CmdletBinding()]
param([switch]$SkipSlow, [string]$Only)

. (Join-Path $PSScriptRoot "TestKit.ps1")

Start-Section "Verifier detection"

# Every case runs the installed verify.ps1 in a fresh project with PATH cut down to stub
# tools plus System32, so what ran - and from which directory - is read from the stubs'
# log rather than from a real toolchain this machine may or may not have.

$script:detectRoots = @()
$script:stubTools = @("flutter", "dart", "npm", "pnpm", "yarn", "bun", "dotnet", "go", "cargo", "mvn", "gradle", "python", "make")

function Invoke-DetectCase {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Files,
        [string[]]$Tools = $script:stubTools,
        [string[]]$Arguments = @(),
        [string]$Steps
    )

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-detect-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    $script:detectRoots += $root
    $project = Join-Path $root "project"
    $bin = Join-Path $root "bin"
    $log = Join-Path $root "calls.log"

    foreach ($name in $Files.Keys) {
        $path = Join-Path $project $name
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [System.IO.File]::WriteAllText($path, $Files[$name])
    }

    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    & (Join-Path $scriptsRoot "init-project.ps1") -Type generic -Path $project -NoTrust 6>$null | Out-Null

    $verify = Join-Path $project ".claude\scripts\verify.ps1"

    if ($Steps) {
        $declaration = '$VerificationSteps = @('
        $text = [System.IO.File]::ReadAllText($verify)
        $at = $text.IndexOf($declaration) + $declaration.Length
        [System.IO.File]::WriteAllText($verify, $text.Substring(0, $at) + $Steps + $text.Substring($at))
    }

    foreach ($tool in $Tools) {

        # hazard: the real npm resolves to npm.ps1 in PowerShell, which takes an array as one
        # argument where a .cmd splits it; its stub is a script so both kinds are exercised.
        if ($tool -eq "npm") {
            [System.IO.File]::WriteAllText((Join-Path $bin "npm.ps1"), "Add-Content -LiteralPath '$log' -Value ((Get-Location).Path + '|npm ' + (`$args -join ' '))`r`n")
            continue
        }

        [System.IO.File]::WriteAllText((Join-Path $bin "$tool.cmd"), "@echo %CD%^|$tool %*>>`"$log`"`r`n")
    }

    # why: a gradlew.bat in the project is the wrapper the verifier must prefer; it logs like the stubs.
    foreach ($wrapper in @(Get-ChildItem -LiteralPath $project -Filter "gradlew.bat" -File -Recurse -ErrorAction SilentlyContinue)) {
        [System.IO.File]::WriteAllText($wrapper.FullName, "@echo %CD%^|gradlew.bat %*>>`"$log`"`r`n")
    }

    $previousPath = $env:Path
    $previousPreference = $ErrorActionPreference
    $powershell = (Get-Command powershell).Source

    try {
        $env:Path = $bin + ";" + (Join-Path $env:SystemRoot "System32") + ";" + (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0")
        $ErrorActionPreference = "Continue"
        $global:LASTEXITCODE = 0
        $output = (& $powershell -NoProfile -ExecutionPolicy Bypass -File $verify @Arguments 2>&1 | Out-String)
        $code = $LASTEXITCODE
    }
    finally {
        $env:Path = $previousPath
        $ErrorActionPreference = $previousPreference
    }

    $calls = @()

    foreach ($line in @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue)) {
        $parts = $line.Split([char]"|", 2)
        $directory = $parts[0].Trim()
        if ($directory.StartsWith($project)) { $directory = $directory.Substring($project.Length).TrimStart("\") }
        if (-not $directory) { $directory = "." }
        $calls += ($directory + "|" + $parts[1].Trim())
    }

    return [PSCustomObject]@{ Code = $code; Output = $output; Calls = $calls; Project = $project }
}

function Test-Calls {
    # why: one comparison for every case, so a failure always prints what actually ran.
    param([object]$Run, [string[]]$Expected)

    if ($Run.Code -ne 0) { return ("exit $($Run.Code): " + ($Run.Output -replace "\s+", " ")) }
    if (($Run.Calls -join " ; ") -ne ($Expected -join " ; ")) { return ("calls: " + ($Run.Calls -join " ; ") + " -- expected: " + ($Expected -join " ; ")) }
    return $true
}

$flutterPubspec = "name: app`nenvironment:`n  sdk: '>=3.0.0 <4.0.0'`ndependencies:`n  flutter:`n    sdk: flutter`n"
$dartPubspec = "name: tool`nenvironment:`n  sdk: '>=3.0.0 <4.0.0'`n"
$allScripts = '{ "scripts": { "test": "vitest", "build": "tsc -b", "lint": "eslint .", "typecheck": "tsc --noEmit" } }'

try {

    Test-Case -Name "D1 a nested flutter app runs flutter analyze and, with a test directory, flutter test, from its own directory" -Check {
        $with = Invoke-DetectCase -Files @{ "app\pubspec.yaml" = $flutterPubspec; "app\test\app_test.dart" = "void main() {}" }
        $result = Test-Calls -Run $with -Expected @("app|flutter analyze", "app|flutter test")
        if ($result -ne $true) { return "with test/: $result" }

        $without = Invoke-DetectCase -Files @{ "app\pubspec.yaml" = $flutterPubspec; "app\lib\main.dart" = "void main() {}" }
        $result = Test-Calls -Run $without -Expected @("app|flutter analyze")
        if ($result -ne $true) { return "without test/: $result" }
        return $true
    }

    Test-Case -Name "D2 a pubspec without the flutter sdk runs dart analyze and dart test, never flutter" -Check {
        $run = Invoke-DetectCase -Files @{ "pubspec.yaml" = $dartPubspec; "test\tool_test.dart" = "void main() {}" }
        return (Test-Calls -Run $run -Expected @(".|dart analyze", ".|dart test"))
    }

    Test-Case -Name "D3 package.json scripts run in the order typecheck, lint, build, test with the package manager its lockfile names" -Check {
        $cases = @(
            @{ Lock = "pnpm-lock.yaml"; Manager = "pnpm" },
            @{ Lock = "yarn.lock"; Manager = "yarn" },
            @{ Lock = "bun.lock"; Manager = "bun" },
            @{ Lock = "bun.lockb"; Manager = "bun" },
            @{ Lock = $null; Manager = "npm" }
        )

        foreach ($case in $cases) {
            $files = @{ "package.json" = $allScripts }
            if ($case.Lock) { $files[$case.Lock] = "" }
            $run = Invoke-DetectCase -Files $files
            $m = $case.Manager
            $result = Test-Calls -Run $run -Expected @(".|$m run typecheck", ".|$m run lint", ".|$m run build", ".|$m run test")
            if ($result -ne $true) { return "$m`: $result" }
        }

        $partial = Invoke-DetectCase -Files @{ "package.json" = '{ "scripts": { "build": "tsc", "start": "node ." } }' }
        $result = Test-Calls -Run $partial -Expected @(".|npm run build")
        if ($result -ne $true) { return "only build present: $result" }
        return $true
    }

    Test-Case -Name "D4 the test script npm init writes is not run" -Check {
        # why: the chain operator is assembled, so the self-test's scan for && in executable code does not see one.
        $chain = "&" + "&"
        $run = Invoke-DetectCase -Files @{ "package.json" = ('{ "scripts": { "build": "tsc", "test": "echo \"Error: no test specified\" ' + $chain + ' exit 1" } }') }
        return (Test-Calls -Run $run -Expected @(".|npm run build"))
    }

    Test-Case -Name "D5 go, cargo, maven, gradle and the gradle wrapper each run their build and test commands" -Check {
        $cases = @(
            @{ Files = @{ "go.mod" = "module x" }; Expected = @(".|go build ./...", ".|go test ./...") },
            @{ Files = @{ "Cargo.toml" = "[package]" }; Expected = @(".|cargo build --locked", ".|cargo test") },
            @{ Files = @{ "pom.xml" = "<project />" }; Expected = @(".|mvn -B verify") },
            @{ Files = @{ "build.gradle" = "" }; Expected = @(".|gradle build") },
            @{ Files = @{ "build.gradle.kts" = "" }; Expected = @(".|gradle build") },
            @{ Files = @{ "build.gradle.kts" = ""; "gradlew.bat" = "" }; Expected = @(".|gradlew.bat build") }
        )

        foreach ($case in $cases) {
            $run = Invoke-DetectCase -Files $case.Files
            $result = Test-Calls -Run $run -Expected $case.Expected
            if ($result -ne $true) { return (($case.Files.Keys -join "+") + ": $result") }
        }
        return $true
    }

    Test-Case -Name "D6 python runs pytest only where tests exist" -Check {
        $with = Invoke-DetectCase -Files @{ "svc\pyproject.toml" = "[project]"; "svc\tests\test_a.py" = "def test_a(): pass"; "README.md" = "x" }
        $result = Test-Calls -Run $with -Expected @("svc|python -m pytest")
        if ($result -ne $true) { return "with tests/: $result" }

        $flat = Invoke-DetectCase -Files @{ "setup.py" = "from setuptools import setup"; "test_main.py" = "def test_a(): pass" }
        $result = Test-Calls -Run $flat -Expected @(".|python -m pytest")
        if ($result -ne $true) { return "setup.py with test_*.py: $result" }

        $without = Invoke-DetectCase -Files @{ "requirements.txt" = "requests"; "main.py" = "print(1)"; "package.json" = '{ "scripts": { "build": "tsc" } }' }
        $result = Test-Calls -Run $without -Expected @(".|npm run build")
        if ($result -ne $true) { return "without tests: $result" }
        return $true
    }

    $mixed = @{
        "app\pubspec.yaml"       = $flutterPubspec
        "app\test\app_test.dart" = "void main() {}"
        "api\Api.csproj"         = '<Project Sdk="Microsoft.NET.Sdk" />'
        "web\package.json"       = '{ "scripts": { "build": "vite build" } }'
        "web\pnpm-lock.yaml"     = ""
    }

    Test-Case -Name "D7 a repository with flutter, .NET and pnpm units verifies each from its own directory and names them in Detected" -Check {
        $run = Invoke-DetectCase -Files $mixed

        if ($run.Code -ne 0) { return ("exit $($run.Code): " + ($run.Output -replace "\s+", " ")) }
        if (@($run.Calls | Where-Object { $_ -like "app|flutter *" }).Count -ne 2) { return ("flutter calls from app: " + ($run.Calls -join " ; ")) }
        if (@($run.Calls | Where-Object { $_ -eq "web|pnpm run build" }).Count -ne 1) { return ("pnpm call from web: " + ($run.Calls -join " ; ")) }
        if (@($run.Calls | Where-Object { $_ -like "*|dotnet build *api\Api.csproj*" }).Count -ne 1) { return ("dotnet build of api\Api.csproj: " + ($run.Calls -join " ; ")) }
        if (@($run.Calls | Where-Object { $_ -like "*|dotnet test *api\Api.csproj*" }).Count -ne 1) { return ("dotnet test of api\Api.csproj: " + ($run.Calls -join " ; ")) }

        $detected = @($run.Output -split "`r?`n" | Where-Object { $_.StartsWith("Detected: ") })
        if ($detected.Count -ne 1) { return ("no single Detected line: " + $run.Output) }
        if ($run.Output.IndexOf($detected[0]) -gt $run.Output.IndexOf("==> ")) { return "Detected was printed after the first step" }
        foreach ($token in @("flutter analyze @ app", "pnpm run build @ web")) {
            if (-not $detected[0].Contains($token)) { return ("Detected line lacks '$token': " + $detected[0]) }
        }
        return $true
    }

    Test-Case -Name "D8 a package.json below another one is part of its workspace, not a unit of its own" -Check {
        $run = Invoke-DetectCase -Files @{ "package.json" = '{ "scripts": { "build": "tsc -b" } }'; "libs\a\package.json" = '{ "scripts": { "build": "tsc" } }' }
        return (Test-Calls -Run $run -Expected @(".|npm run build"))
    }

    Test-Case -Name "D9 the android build of a flutter or react native app is not a gradle unit" -Check {
        $run = Invoke-DetectCase -Files @{
            "app\pubspec.yaml"             = $flutterPubspec
            "app\android\build.gradle"     = ""
            "mobile\package.json"          = '{ "scripts": { "lint": "eslint ." } }'
            "mobile\android\build.gradle"  = ""
        }
        return (Test-Calls -Run $run -Expected @("app|flutter analyze", "mobile|npm run lint"))
    }

    Test-Case -Name "D10 a root Makefile runs make only when nothing else was detected" -Check {
        $alone = Invoke-DetectCase -Files @{ "Makefile" = "all:" }
        $result = Test-Calls -Run $alone -Expected @(".|make")
        if ($result -ne $true) { return "Makefile alone: $result" }

        $beside = Invoke-DetectCase -Files @{ "Makefile" = "all:"; "package.json" = '{ "scripts": { "build": "tsc" } }' }
        $result = Test-Calls -Run $beside -Expected @(".|npm run build")
        if ($result -ne $true) { return "Makefile beside package.json: $result" }
        return $true
    }

    Test-Case -Name "D11 a step whose tool is missing is skipped by name, and a run where every step was skipped fails" -Check {
        $noFlutter = @($script:stubTools | Where-Object { $_ -ne "flutter" })
        $run = Invoke-DetectCase -Files $mixed -Tools $noFlutter

        if ($run.Code -ne 0) { return ("some skipped: exit $($run.Code), expected 0: " + ($run.Output -replace "\s+", " ")) }
        foreach ($line in @("SKIP: flutter analyze @ app (flutter was not found in PATH)", "SKIP: flutter test @ app (flutter was not found in PATH)")) {
            if (-not $run.Output.Contains($line)) { return ("missing '$line': " + ($run.Output -replace "\s+", " ")) }
        }
        if (@($run.Calls | Where-Object { $_ -eq "web|pnpm run build" }).Count -ne 1) { return ("pnpm did not run after the skip: " + ($run.Calls -join " ; ")) }
        if (@($run.Calls | Where-Object { $_ -like "*|dotnet build *" }).Count -ne 1) { return ("dotnet did not run after the skip: " + ($run.Calls -join " ; ")) }

        $noDotnet = Invoke-DetectCase -Files $mixed -Tools @($script:stubTools | Where-Object { $_ -ne "dotnet" })
        if ($noDotnet.Code -ne 0) { return ("no dotnet: exit $($noDotnet.Code), expected 0") }
        if (-not $noDotnet.Output.Contains("SKIP: dotnet build @ . (The .NET SDK was not found in PATH)")) { return ("no dotnet: no SKIP line: " + ($noDotnet.Output -replace "\s+", " ")) }
        if (@($noDotnet.Calls | Where-Object { $_ -eq "web|pnpm run build" }).Count -ne 1) { return ("no dotnet: pnpm did not run: " + ($noDotnet.Calls -join " ; ")) }

        $all = Invoke-DetectCase -Files @{ "app\pubspec.yaml" = $flutterPubspec; "app\test\app_test.dart" = "void main() {}" } -Tools $noFlutter
        if (($all.Code -ne 1) -or (-not $all.Output.Contains("Nothing to verify"))) { return ("all skipped: exit $($all.Code): " + ($all.Output -replace "\s+", " ")) }
        return $true
    }

    Test-Case -Name "D12 a project with nothing to build fails with Nothing to verify" -Check {
        $run = Invoke-DetectCase -Files @{ "README.md" = "hello" }
        if (($run.Code -ne 1) -or (-not $run.Output.Contains("Nothing to verify"))) { return ("exit $($run.Code): " + ($run.Output -replace "\s+", " ")) }
        return $true
    }

    Test-Case -Name "D13 two solutions and no root one fail and ask for -Target" -Check {
        $run = Invoke-DetectCase -Files @{ "a\A.sln" = ""; "b\B.sln" = "" }
        if ($run.Code -ne 1) { return "exit $($run.Code), expected 1" }
        foreach ($text in @("Multiple solution files were found", "Specify the target explicitly with -Target")) {
            if (-not $run.Output.Contains($text)) { return ("missing '$text': " + ($run.Output -replace "\s+", " ")) }
        }
        return $true
    }

    Test-Case -Name "D14 one verify.ps1 ships, from _shared, and both templates install it unchanged" -Check {
        $shared = Join-Path $sharedRoot "dot-claude\scripts\verify.ps1"
        if (-not (Test-Path -LiteralPath $shared)) { return "templates\_shared has no verify.ps1" }

        $copies = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot "templates") -Filter "verify.ps1" -File -Recurse | Where-Object { $_.FullName -ne $shared })
        if ($copies.Count -gt 0) { return ("other copies: " + (($copies | ForEach-Object { $_.FullName }) -join ", ")) }

        foreach ($case in @(@{ Type = "generic"; Files = @{ "notes.txt" = "x" } }, @{ Type = "dotnet"; Files = @{ "App.csproj" = '<Project Sdk="Microsoft.NET.Sdk" />' } })) {
            $project = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-detect-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
            $script:detectRoots += $project
            New-Item -ItemType Directory -Path $project -Force | Out-Null
            foreach ($name in $case.Files.Keys) { [System.IO.File]::WriteAllText((Join-Path $project $name), $case.Files[$name]) }

            & (Join-Path $scriptsRoot "init-project.ps1") -Type $case.Type -Path $project -NoTrust 6>$null | Out-Null

            $installed = Join-Path $project ".claude\scripts\verify.ps1"
            if (-not (Test-Path -LiteralPath $installed)) { return "$($case.Type): no verify.ps1 installed" }
            if (-not (Test-FileContentEqual -ReferenceFile $shared -DifferenceFile $installed)) { return "$($case.Type): installed verify.ps1 differs from _shared" }
        }
        return $true
    }

    Test-Case -Name "D15 explicit verification steps replace detection" -Check {
        $run = Invoke-DetectCase -Files @{ "package.json" = $allScripts } -Steps '@{ Name = "mine"; Command = { cmd /c exit 0 } }'

        if ($run.Code -ne 0) { return ("exit $($run.Code): " + ($run.Output -replace "\s+", " ")) }
        if (-not $run.Output.Contains("PASS: mine")) { return "the explicit step did not run" }
        if ($run.Calls.Count -ne 0) { return ("detected steps ran too: " + ($run.Calls -join " ; ")) }
        return $true
    }

    Test-Case -Name "D16 VerifyCommon still serves a verify.ps1 written before detection moved into it" -Check {
        $module = Import-Module (Join-Path $sharedRoot "dot-claude\scripts\VerifyCommon.psm1") -Force -PassThru
        foreach ($name in @("Invoke-Verification", "Invoke-Step", "Get-ProjectFile")) {
            if (-not $module.ExportedFunctions.ContainsKey($name)) { return "$name is not exported" }
        }

        $null = Invoke-Step -Name "x" -Action { cmd /c exit 0 } 6>$null
        return $true
    }
}
finally {
    foreach ($root in $script:detectRoots) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

Complete-TestFile
