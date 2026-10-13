<#
.SYNOPSIS
    Canonical verification for this .NET repository.

.DESCRIPTION
    Restores, builds and tests the solution or project, then checks the working
    tree diff for whitespace damage. Prints VERIFICATION PASSED or
    VERIFICATION FAILED and exits non-zero on failure.

    Uses the dotnet CLI for SDK-style projects and Visual Studio's MSBuild plus
    vstest.console for .NET Framework ones, which the dotnet CLI cannot build.

    When the sources are unchanged since the last full pass with the same
    arguments, it reports that pass instead of repeating it.

    This is the verification a coding task must pass before it is considered
    complete. It is deliberately self-contained: it has no dependency on the
    harness repository, so it keeps working after the project is cloned
    elsewhere.

.PARAMETER Target
    Solution or project to verify. Discovered automatically when omitted.

.PARAMETER Configuration
    Debug (default) or Release.

.PARAMETER SkipRestore
    Build and test with --no-restore.

.PARAMETER SkipTests
    Skip the test step. Use only when explicitly verifying a build-only change.

.PARAMETER Force
    Run every step even when the sources already passed.

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

    [switch]$SkipTests,

    [switch]$Force
)

$ErrorActionPreference = "Stop"

# Invoke-Verification, Invoke-Step and Get-ProjectFile live here, beside this
# script, so the project stays self-contained after being cloned somewhere the
# harness is absent.
Import-Module (Join-Path $PSScriptRoot "VerifyCommon.psm1") -Force

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

exit (Invoke-Verification -ProjectRoot $projectRoot -Parameters $PSBoundParameters -Body {

    Write-Host "Configuration: $Configuration"

    # why: one listing from git serves every lookup below; each recursive Get-ChildItem
    # used to walk bin, obj and node_modules in full.
    $files = @(Get-ProjectFile -ProjectRoot $projectRoot)
    $solutionFiles = @($files | Where-Object { ($_ -like "*.sln") -or ($_ -like "*.slnx") })
    $projectFiles = @($files | Where-Object { $_ -like "*.csproj" })

    if (-not $Target) {

        # Prefer a solution at the repository root, then a solution anywhere,
        # then a single project, so a src/ layout is not silently missed.
        $solutions = @($solutionFiles | Where-Object { $_ -notlike "*\*" })

        if ($solutions.Count -eq 0) {
            $solutions = $solutionFiles
        }

        if ($solutions.Count -eq 1) {
            $Target = Join-Path $projectRoot $solutions[0]
        }
        elseif ($solutions.Count -gt 1) {

            Write-Host ""
            Write-Host "Multiple solution files were found:"

            foreach ($solution in $solutions) {
                Write-Host "  - $(Join-Path $projectRoot $solution)"
            }

            throw "Specify the target explicitly with -Target."
        }
        elseif ($projectFiles.Count -eq 1) {
            $Target = Join-Path $projectRoot $projectFiles[0]
        }
        elseif ($projectFiles.Count -gt 1) {

            Write-Host ""
            Write-Host "No solution file was found, and multiple projects exist:"

            foreach ($project in $projectFiles) {
                Write-Host "  - $(Join-Path $projectRoot $project)"
            }

            throw "Specify the target explicitly with -Target."
        }
        else {
            throw "No .NET solution or project was found under $projectRoot."
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
    $allProjects = @($projectFiles | ForEach-Object { Get-Item -LiteralPath (Join-Path $projectRoot $_) })
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

        # why: dotnet build restores on its own; a separate dotnet restore cost one more
        # MSBuild evaluation of every project for the same result.
        $restore = @()
        if ($SkipRestore) { $restore = @("--no-restore") }

        Invoke-Step -Name "dotnet build" -Action {
            dotnet build "$Target" --configuration $Configuration @restore
        }

        if (-not $SkipTests) {
            Invoke-Step -Name "dotnet test" -Action {
                dotnet test "$Target" --configuration $Configuration --no-build --no-restore
            }
        }
    }
})
