<#
.SYNOPSIS
    Canonical verification for this .NET repository.

.DESCRIPTION
    Restores, builds and tests the solution or project, then checks the working
    tree diff for whitespace damage. Prints VERIFICATION PASSED or
    VERIFICATION FAILED and exits non-zero on failure.

    Uses the dotnet CLI for SDK-style projects and Visual Studio's MSBuild plus
    vstest.console for .NET Framework ones, which the dotnet CLI cannot build.

    This is the verification a coding task must pass before it is considered
    complete. It is deliberately self-contained: it has no dependency on the
    harness repository, so it keeps working after the project is cloned
    elsewhere.

.PARAMETER Target
    Solution or project to verify. Discovered automatically when omitted.

.PARAMETER Configuration
    Debug (default) or Release.

.PARAMETER SkipRestore
    Skip the restore step. Build and test then run with --no-restore.

.PARAMETER SkipTests
    Skip the test step. Use only when explicitly verifying a build-only change.

.EXAMPLE
    .\.claude\scripts\verify.ps1

.EXAMPLE
    .\.claude\scripts\verify.ps1 -Configuration Release

.EXAMPLE
    .\.claude\scripts\verify.ps1 -Target .\src\MyApi\MyApi.csproj -SkipTests
#>
[CmdletBinding()]
param(
    [string]$Target,

    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug",

    [switch]$SkipRestore,

    [switch]$SkipTests
)

$ErrorActionPreference = "Stop"

# Invoke-Step, Test-GitWorkTree, Get-SourceFingerprint and
# Get-VerificationStateFile live here, beside this script, so the project
# stays self-contained after being cloned somewhere the harness is absent.
Import-Module (Join-Path $PSScriptRoot "VerifyCommon.psm1") -Force

# Directories that never contain the sources we are looking for. Searching
# them is slow and, worse, build output can contain copies of project files.
$excludedDirectories = @(
    "bin", "obj", "node_modules", ".git", ".vs", "packages",
    "artifacts", "TestResults"
)

function Test-ExcludedPath {
    <#
        True when the path sits under one of $excludedDirectories, relative to
        Root. Compares path segments rather than matching a regex, so no
        backslash escaping is involved and a repository that happens to live
        under a directory called "packages" is not misjudged.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$FullPath,

        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd($separator)
    $pathFull = [System.IO.Path]::GetFullPath($FullPath)

    if (-not $pathFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    $relative = $pathFull.Substring($rootFull.Length).Trim($separator)

    foreach ($segment in $relative.Split($separator)) {
        if ($excludedDirectories -contains $segment) {
            return $true
        }
    }

    return $false
}

function Get-SourceFile {
    <#
        Finds files matching an extension set, skipping build output.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string[]]$Extension,

        [switch]$Recurse
    )

    $items = Get-ChildItem -LiteralPath $Root -File -Recurse:$Recurse -ErrorAction SilentlyContinue

    return @($items | Where-Object {
        ($Extension -contains $_.Extension) -and
        -not (Test-ExcludedPath -FullPath $_.FullName -Root $Root)
    })
}

function Test-LegacyProjectFile {
    <#
        True when a project file needs the full MSBuild rather than the dotnet
        CLI.

        The reliable signal is the project format itself: an SDK-style project
        declares Sdk on <Project>, and a .NET Framework one does not. A
        packages.config beside it and the WebApplication.targets import are
        consequences of the same thing, and packages.config is checked first
        because `dotnet restore` cannot restore it whatever the format says.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $Path) "packages.config")) {
        return $true
    }

    $content = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue

    if (-not $content) {
        return $false
    }

    return ($content -notmatch "<Project[^>]*\sSdk\s*=")
}

function Find-VisualStudioFile {
    <#
        Path of a file inside the newest Visual Studio installation that can
        build, or $null when there is none.

        -requires Microsoft.Component.MSBuild is not optional: -latest orders by
        version number, and other products built on the Visual Studio shell -
        SQL Server Management Studio, for one - carry a higher version number
        than Visual Studio itself, so without it vswhere returns the MSBuild
        shipped with SSMS.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"

    if (-not (Test-Path -LiteralPath $vswhere)) {
        return $null
    }

    $found = @(& $vswhere -latest -prerelease -products '*' -requires Microsoft.Component.MSBuild -find $Pattern)

    if ($found.Count -eq 0) {
        return $null
    }

    return $found[0]
}

function Get-TestAssembly {
    <#
        Built assemblies of the projects that reference a test framework.

        vstest.console runs assemblies, not projects, so the output has to be
        located after the build. The search is recursive under bin\<config> so
        a project that writes to bin\Debug\net48\ is found too.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Project,

        [Parameter(Mandatory = $true)]
        [string]$Configuration
    )

    $assemblies = @()

    foreach ($file in $Project) {

        $directory = Split-Path -Parent $file.FullName
        $content = Get-Content -LiteralPath $file.FullName -Raw
        $packages = Join-Path $directory "packages.config"

        if (Test-Path -LiteralPath $packages) {
            $content += (Get-Content -LiteralPath $packages -Raw)
        }

        if ($content -notmatch "xunit|nunit|MSTest|UnitTestFramework|Test\.Sdk") {
            continue
        }

        $name = [System.IO.Path]::GetFileNameWithoutExtension($file.FullName)

        if ($content -match "<AssemblyName>\s*([^<]+?)\s*</AssemblyName>") {
            $name = $Matches[1]
        }

        $output = Join-Path $directory (Join-Path "bin" $Configuration)

        if (-not (Test-Path -LiteralPath $output)) {
            continue
        }

        $built = @(Get-ChildItem -LiteralPath $output -Filter "$name.dll" -File -Recurse -ErrorAction SilentlyContinue)

        if ($built.Count -gt 0) {
            $assemblies += $built[0].FullName
        }
    }

    return $assemblies
}

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

Push-Location $projectRoot

try {
    Write-Host ""
    Write-Host "Verification Harness"
    Write-Host "===================="
    Write-Host ""
    Write-Host "Project root:  $projectRoot"
    Write-Host "Configuration: $Configuration"

    if (-not $Target) {

        # Prefer a solution at the repository root, then a solution anywhere,
        # then a single project. Solutions and projects are both searched
        # recursively so a src/ layout is not silently missed.
        $solutions = @(Get-SourceFile -Root $projectRoot -Extension ".sln", ".slnx")

        if ($solutions.Count -eq 0) {
            $solutions = @(Get-SourceFile -Root $projectRoot -Extension ".sln", ".slnx" -Recurse)
        }

        if ($solutions.Count -eq 1) {
            $Target = $solutions[0].FullName
        }
        elseif ($solutions.Count -gt 1) {

            Write-Host ""
            Write-Host "Multiple solution files were found:"

            foreach ($solution in $solutions) {
                Write-Host "  - $($solution.FullName)"
            }

            throw "Specify the target explicitly with -Target."
        }
        else {
            $projects = @(Get-SourceFile -Root $projectRoot -Extension ".csproj" -Recurse)

            if ($projects.Count -eq 1) {
                $Target = $projects[0].FullName
            }
            elseif ($projects.Count -gt 1) {

                Write-Host ""
                Write-Host "No solution file was found, and multiple projects exist:"

                foreach ($project in $projects) {
                    Write-Host "  - $($project.FullName)"
                }

                throw "Specify the target explicitly with -Target."
            }
            else {
                throw "No .NET solution or project was found under $projectRoot."
            }
        }
    }

    $Target = [System.IO.Path]::GetFullPath($Target)

    if (-not (Test-Path -LiteralPath $Target)) {
        throw "Target does not exist: $Target"
    }

    Write-Host "Target:        $Target"

    # The dotnet CLI cannot restore, build or test a .NET Framework project, so
    # the toolchain is chosen once here and every step follows it. One legacy
    # project is enough: MSBuild builds SDK-style projects as well, while
    # `dotnet build` fails on the whole solution the moment one project is old.
    $allProjects = @(Get-SourceFile -Root $projectRoot -Extension ".csproj" -Recurse)
    $legacyProjects = @($allProjects | Where-Object { Test-LegacyProjectFile -Path $_.FullName })

    if ($legacyProjects.Count -gt 0) {

        $msbuild = Find-VisualStudioFile -Pattern "MSBuild\**\Bin\MSBuild.exe"

        if (-not $msbuild) {
            throw ("This is a .NET Framework project, which the dotnet CLI cannot build, " +
                   "and no Visual Studio MSBuild was found. Install Visual Studio or the " +
                   "Build Tools for Visual Studio.")
        }

        Write-Host "Toolchain:     $msbuild"

        # Restore needs SolutionDir: packages.config restore refuses to run
        # without one, and it is not set when the target is a project file.
        $solutionDirectory = (Split-Path -Parent $Target).TrimEnd("\") + "\"

        if (-not $SkipRestore) {
            Invoke-Step -Name "msbuild -t:restore" -Action {
                & $msbuild "$Target" -t:restore -p:RestorePackagesConfig=true "-p:SolutionDir=$solutionDirectory" -v:minimal -nologo
            }
        }

        Invoke-Step -Name "msbuild" -Action {
            & $msbuild "$Target" -p:Configuration=$Configuration -m -v:minimal -nologo
        }

        if (-not $SkipTests) {

            $testAssemblies = @(Get-TestAssembly -Project $allProjects -Configuration $Configuration)

            if ($testAssemblies.Count -eq 0) {

                # Same outcome as `dotnet test` on a solution with no test
                # project: the step ran, there was nothing to run.
                Write-Host ""
                Write-Host "SKIP: vstest.console (no built test assembly was found)"
            }
            else {

                $vstest = Find-VisualStudioFile -Pattern "Common7\IDE\Extensions\TestPlatform\vstest.console.exe"

                if (-not $vstest) {
                    throw ("Test assemblies were built but vstest.console.exe was not found in " +
                           "the Visual Studio installation.")
                }

                $resultsDirectory = Join-Path $projectRoot (Join-Path ".claude" (Join-Path "state" "TestResults"))

                if (Test-Path -LiteralPath $resultsDirectory) {
                    Remove-Item -LiteralPath $resultsDirectory -Recurse -Force
                }

                Invoke-Step -Name "vstest.console" -Action {
                    & $vstest $testAssemblies "/Logger:trx" "/ResultsDirectory:$resultsDirectory"
                }

                # vstest.console exits 0 when it discovers no test at all, so a
                # test project whose adapter never reached the output directory
                # would report green having run nothing. The trx has the count,
                # and unlike the console text it is not localised.
                $executed = 0

                foreach ($trx in @(Get-ChildItem -LiteralPath $resultsDirectory -Filter "*.trx" -File -Recurse -ErrorAction SilentlyContinue)) {

                    foreach ($counters in ([xml](Get-Content -LiteralPath $trx.FullName -Raw)).TestRun.ResultSummary.Counters) {
                        $executed += [int]$counters.total
                    }
                }

                if ($executed -eq 0) {
                    throw ("vstest.console discovered no test in " + $testAssemblies.Count +
                           " test assembly(ies). The test adapter is usually missing from the " +
                           "output directory.")
                }

                Write-Host ""
                Write-Host "Tests run: $executed"
            }
        }
    }
    else {

        if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
            throw "The .NET SDK was not found in PATH."
        }

        if (-not $SkipRestore) {
            Invoke-Step -Name "dotnet restore" -Action {
                dotnet restore "$Target"
            }
        }

        Invoke-Step -Name "dotnet build" -Action {
            dotnet build "$Target" --configuration $Configuration --no-restore
        }

        if (-not $SkipTests) {
            Invoke-Step -Name "dotnet test" -Action {
                dotnet test "$Target" --configuration $Configuration --no-build --no-restore
            }
        }
    }

    if ((Get-Command git -ErrorAction SilentlyContinue) -and (Test-GitWorkTree -Path $projectRoot)) {

        Invoke-Step -Name "git diff --check" -Action {
            git diff --check
        }

        Write-Host ""
        Write-Host "Working tree:"
        Write-Host ""

        git status --short
    }
    else {
        Write-Host ""
        Write-Host "SKIP: git checks (not a git work tree)"
    }

    # Record that this exact set of sources passed, so a Stop hook can tell
    # "verified" from "never run". -SkipTests is recorded honestly: a partial
    # run must not satisfy a gate that means "the tests pass".
    $stateFile = Get-VerificationStateFile -ProjectRoot $projectRoot
    $stateDirectory = Split-Path -Parent $stateFile

    if (-not (Test-Path -LiteralPath $stateDirectory)) {
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    }

    $state = [PSCustomObject]@{
        fingerprint   = Get-SourceFingerprint -ProjectRoot $projectRoot
        target        = $Target
        configuration = $Configuration
        testsRan      = (-not $SkipTests)
        completedAt   = (Get-Date).ToString("o")
    }

    $state | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8

    Write-Host ""
    Write-Host "===================="
    Write-Host "VERIFICATION PASSED"
    Write-Host "===================="
    Write-Host ""
}
catch {
    Write-Host ""
    Write-Host "===================="
    Write-Host "VERIFICATION FAILED"
    Write-Host "===================="
    Write-Host ""
    Write-Host $_.Exception.Message
    Write-Host ""

    exit 1
}
finally {
    Pop-Location
}

exit 0
