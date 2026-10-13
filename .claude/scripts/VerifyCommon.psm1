# VerifyCommon.psm1
#
# Shared helpers for a project's verification script and hooks.
#
# This ships into the project alongside verify.ps1, so a project stays
# self-contained: it keeps working after the repository is cloned somewhere the
# harness was never installed. It is NOT one of the harness's own library modules.
#
# Windows PowerShell 5.1 compatible.

Set-StrictMode -Version 2.0

# why: build output, dependencies and machine-local state are never source, and they
# are the expensive part of any walk.
$script:excludedDirectories = @(
    "bin", "obj", "node_modules", ".git", ".vs", ".vscode", ".idea",
    "packages", "artifacts", "TestResults", "dist", "build", "target",
    "out", "coverage", ".next", ".nuxt", "__pycache__", ".venv", "venv",
    ".harness-backup", "state"
)

# why: git's list is the source except for the state this harness and the toolkit write into the
# project; it changes on every run, and a project's .gitignore does not always name it.
$script:machineStatePattern = '^\.claude\\state(\\|$)|(^|\\)(\.tlc|\.harness-backup)(\\|$)'

# Binaries, archives, media and machine-local cruft. Everything else counts.
$script:excludedExtensions = @(
    ".dll", ".exe", ".pdb", ".so", ".dylib", ".a", ".lib", ".o", ".obj",
    ".zip", ".tar", ".gz", ".bz2", ".7z", ".rar", ".nupkg", ".snupkg",
    ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".ico", ".webp", ".mp4", ".mp3",
    ".pdf", ".docx", ".xlsx", ".pptx", ".ttf", ".woff", ".woff2", ".eot",
    ".cache", ".user", ".suo", ".userprefs", ".log", ".tmp", ".bak", ".swp"
)

# why: a hash set answers per file in constant time; -contains scanned the whole list, and ignored case as this comparer does.
$script:excludedExtensionSet = New-Object "System.Collections.Generic.HashSet[string]" (
    [string[]]$script:excludedExtensions, [System.StringComparer]::OrdinalIgnoreCase)

function Invoke-Step {
    <#
    .SYNOPSIS
        Runs a native command and throws if it reports a non-zero exit code.
    .DESCRIPTION
        $LASTEXITCODE is reset first. It persists from whatever ran previously,
        so without the reset a stale value could mask a real failure or invent
        one that never happened.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,

        # Where the command runs; the current directory when omitted.
        [string]$Directory
    )

    Write-Host ""
    Write-Host "==> $Name"
    Write-Host ""

    $global:LASTEXITCODE = 0

    if ($Directory) { Push-Location -LiteralPath $Directory }

    try {
        & $Action
    }
    finally {
        if ($Directory) { Pop-Location }
    }

    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed with exit code $LASTEXITCODE."
    }

    Write-Host ""
    Write-Host "PASS: $Name"
}

function Test-GitWorkTree {
    <#
    .SYNOPSIS
        Reports whether Path sits inside a git work tree.
    .DESCRIPTION
        Walks up looking for .git rather than calling
        `git rev-parse --is-inside-work-tree`. Redirecting a native command's
        stderr in Windows PowerShell 5.1 wraps each line in a
        NativeCommandError; under $ErrorActionPreference = 'Stop' that turns
        "this is not a repository, skip the check" into a hard failure. Outside
        a work tree git also falls back to --no-index mode and prints its whole
        usage text, which is noise on every unrelated command.

        .git is a directory in a normal clone and a file in a worktree or
        submodule, so Test-Path covers both.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $current = [System.IO.Path]::GetFullPath($Path)

    while ($current) {

        if (Test-Path -LiteralPath (Join-Path $current ".git")) {
            return $true
        }

        $parent = Split-Path -Parent $current

        if (-not $parent -or $parent -eq $current) {
            break
        }

        $current = $parent
    }

    return $false
}

function Get-VerificationStateFile {
    <#
    .SYNOPSIS
        Path of the file recording the last successful verification.
    .DESCRIPTION
        Lives under .claude/state/, which is machine-local and gitignored. It is
        what lets a Stop hook tell "verification passed for this working tree"
        from "verification was never run".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot
    )

    return (Join-Path (Join-Path $ProjectRoot ".claude") (Join-Path "state" "last-verification.json"))
}

function Get-GitListedFile {
    <#
        What git tracks or would track under Root, relative to it, or $null
        when git cannot answer.

        A Process with a UTF-8 reader rather than `& git`: PowerShell decodes a
        native command's output with the console's code page, and a hook may
        run with no console at all. A non-ASCII name decoded two ways would
        give the hook and verify.ps1 two fingerprints for the same tree, and
        the gate would never match its own verification.
    #>
    param([string]$Root)

    try {
        $start = New-Object System.Diagnostics.ProcessStartInfo
        $start.FileName = "git"
        # why: "\." keeps a drive root ("C:") from meaning "the current directory on C:".
        $start.Arguments = "-C `"$Root\.`" ls-files -z --cached --others --exclude-standard"
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
        # why: a "fatal: not a git repository" from a broken .git would otherwise print in every hook.
        $start.RedirectStandardError = $true

        $process = [System.Diagnostics.Process]::Start($start)
        # hazard: stderr is drained in the background; a full stderr pipe would block git, and this read with it.
        $errors = $process.StandardError.ReadToEndAsync()
        $output = $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        $null = $errors.Result

        if ($process.ExitCode -ne 0) { return $null }

        $separator = [string][System.IO.Path]::DirectorySeparatorChar
        $paths = New-Object System.Collections.Generic.List[string]

        foreach ($entry in $output.Split([char]0)) {
            if ($entry) { $paths.Add($entry.Replace("/", $separator)) }
        }

        return , $paths.ToArray()
    }
    catch {
        return $null
    }
}

function Get-WalkedFile {
    <#
        Files under Start, relative to Root. Never enters an excluded directory
        or a link, so node_modules costs nothing and a junction cannot loop.
    #>
    param([string]$Root, [string]$Start)

    $pending = New-Object System.Collections.Stack
    $pending.Push($Start)

    while ($pending.Count -gt 0) {

        $directory = $pending.Pop()

        try {
            foreach ($child in [System.IO.Directory]::GetDirectories($directory)) {

                $isLink = (([System.IO.File]::GetAttributes($child) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)

                if ((-not $isLink) -and ($script:excludedDirectories -notcontains [System.IO.Path]::GetFileName($child))) {
                    $pending.Push($child)
                }
            }

            foreach ($file in [System.IO.Directory]::GetFiles($directory)) {
                $file.Substring($Root.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar)
            }
        }
        catch {
            # why: an unreadable directory is skipped, as Get-ChildItem -ErrorAction SilentlyContinue did.
        }
    }
}

function Get-ProjectFile {
    <#
    .SYNOPSIS
        The project's files, relative to ProjectRoot, in ordinal order.
    .DESCRIPTION
        In a git work tree these are the files git tracks or would track, which
        git answers from its index in milliseconds; .gitignore already says what
        is not source, and a tracked build/ directory is source. Only the state
        this harness writes (.claude/state, .tlc, .harness-backup) is dropped.
        The walk this replaced enumerated node_modules, bin and obj in full
        before discarding them: 11.6 s on a 35,000-file checkout, paid at every
        Stop.

        Outside git, or when git cannot answer, the tree is walked without
        entering an excluded directory. git lists a submodule, or a nested
        repository it does not track, as one entry for its directory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot
    )

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $rootFull = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd($separator)

    $listed = $null

    if (Test-GitWorkTree -Path $rootFull) {
        $listed = Get-GitListedFile -Root $rootFull
    }

    $files = New-Object System.Collections.Generic.List[string]

    if ($null -eq $listed) {
        foreach ($relative in (Get-WalkedFile -Root $rootFull -Start $rootFull)) { $files.Add($relative) }
    }
    else {
        foreach ($relative in $listed) {
            if ($relative -notmatch $script:machineStatePattern) { $files.Add($relative) }
        }
    }

    $sorted = $files.ToArray()
    [System.Array]::Sort($sorted, [System.StringComparer]::Ordinal)

    return $sorted
}

function Get-SourceFingerprint {
    <#
    .SYNOPSIS
        A hash over the content of the project's source files.
    .DESCRIPTION
        Two working trees with the same sources produce the same fingerprint.
        Comparing the current fingerprint with the one recorded at the last
        passing verification answers "has anything changed since it passed?"
        without needing git, so it also works in a repository-less checkout.

        Files are selected by EXCLUSION, not by an allowlist of extensions. An
        allowlist silently misses whatever it forgot - .razor, .yml, .tf, .sh -
        and a gate that cannot see a change permits ending the turn without
        verifying it. That is the same failure mode as a gate that never fires.
        Excluding build output and binaries fails the other way: something
        unexpected is hashed, which is harmless. Get-ProjectFile decides which
        files exist; this drops binaries and anything over the size limit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot,

        # Files larger than this are assumed not to be source.
        [int]$MaximumFileSizeBytes = 5242880
    )

    $rootFull = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar)

    $builder = New-Object System.Text.StringBuilder

    # .NET rather than Get-FileHash. Get-FileHash is a function in Windows
    # PowerShell 5.1 and an inherited $WhatIfPreference reaches inside it: it
    # returns nothing, and .Hash on nothing throws. Here that would not fail
    # loudly - it would change the fingerprint, and the gate would stop matching
    # its own baseline while still reporting success.
    $algorithm = [System.Security.Cryptography.SHA256]::Create()

    try {

        # ponytail: reads every listed file, about 4 s per 20,000 on this hardware. Past
        # that, take unchanged files' ids from `git ls-files -s` and hash only what
        # `git ls-files -m -o` reports.
        foreach ($entry in (Get-ProjectFile -ProjectRoot $rootFull)) {

            $paths = @($entry)
            $full = [System.IO.Path]::Combine($rootFull, $entry)

            # invariant: a directory entry is a submodule or a nested repository; walking
            # it keeps a change inside it visible to the gate.
            if ((-not [System.IO.File]::Exists($full)) -and [System.IO.Directory]::Exists($full)) {
                $paths = @(Get-WalkedFile -Root $rootFull -Start $full)
            }

            foreach ($relative in $paths) {

                $file = [System.IO.FileInfo]::new([System.IO.Path]::Combine($rootFull, $relative))

                if ((-not $file.Exists) -or ($file.Length -gt $MaximumFileSizeBytes)) { continue }
                if ($script:excludedExtensionSet.Contains($file.Extension)) { continue }

                $hash = [System.BitConverter]::ToString(
                    $algorithm.ComputeHash([System.IO.File]::ReadAllBytes($file.FullName))).Replace("-", "")

                $null = $builder.Append($relative).Append("|").Append($hash).Append("`n")
            }
        }

        if ($builder.Length -eq 0) {
            return "empty"
        }

        return [System.BitConverter]::ToString($algorithm.ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($builder.ToString()))).Replace("-", "")
    }
    finally {
        $algorithm.Dispose()
    }
}

function Invoke-Verification {
    <#
    .SYNOPSIS
        Runs a project's verification and records a pass for the Stop gate.
    .DESCRIPTION
        Body runs the project's steps with Invoke-Step and throws to fail. This
        prints VERIFICATION PASSED or VERIFICATION FAILED and returns the exit
        code, 0 or 1, for verify.ps1 to exit with.

        A pass on these exact sources, with tests and the same arguments, is
        reported instead of repeated: the Stop gate already accepts it as proof
        for these sources, and the tlc Verifier re-runs verify.ps1 on the tree
        its author just verified. -Force runs it anyway.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot,

        # The caller's $PSBoundParameters. -SkipTests and -Force are read from
        # it, and every other argument is part of the cache key.
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.IDictionary]$Parameters,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Body
    )

    $skipTests = $Parameters.ContainsKey("SkipTests") -and [bool]$Parameters["SkipTests"]
    $force = $Parameters.ContainsKey("Force") -and [bool]$Parameters["Force"]

    # invariant: a Release run is never answered by a Debug pass; any argument that is
    # not -SkipTests or -Force keys the cache.
    $arguments = (@($Parameters.Keys | Where-Object { ($_ -ne "SkipTests") -and ($_ -ne "Force") } | Sort-Object |
            ForEach-Object { "-" + $_ + " " + $Parameters[$_] }) -join " ")

    $stateFile = Get-VerificationStateFile -ProjectRoot $ProjectRoot

    Push-Location $ProjectRoot

    try {
        Write-Host ""
        Write-Host "Verification Harness"
        Write-Host "===================="
        Write-Host ""
        Write-Host "Project root: $ProjectRoot"

        $cached = $null

        if ((-not $force) -and (Test-Path -LiteralPath $stateFile)) {
            try {
                $last = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json

                if (($last.arguments -eq $arguments) -and ($last.testsRan -eq $true) -and
                    ($last.fingerprint -eq (Get-SourceFingerprint -ProjectRoot $ProjectRoot))) {
                    $cached = $last.completedAt
                }
            }
            catch {
                # why: a state file that does not parse, or predates "arguments", means no pass on record, not a failure.
                $cached = $null
            }
        }

        if ($cached) {
            Write-Host ""
            Write-Host "Unchanged since the run that passed at $cached. -Force runs it again."
        }
        else {
            & $Body | Out-Host

            if ((Get-Command git -ErrorAction SilentlyContinue) -and (Test-GitWorkTree -Path $ProjectRoot)) {

                Invoke-Step -Name "git diff --check" -Action { git diff --check } | Out-Host

                Write-Host ""
                Write-Host "Working tree:"
                Write-Host ""

                git status --short | Out-Host
            }
            else {
                Write-Host ""
                Write-Host "SKIP: git checks (not a git work tree)"
            }

            # why: this records that this exact set of sources passed, so a Stop hook can
            # tell "verified" from "never run". -SkipTests is recorded honestly: a partial
            # run must not satisfy a gate that means "the tests pass".
            $stateDirectory = Split-Path -Parent $stateFile

            if (-not (Test-Path -LiteralPath $stateDirectory)) {
                New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
            }

            [PSCustomObject]@{
                fingerprint = Get-SourceFingerprint -ProjectRoot $ProjectRoot
                arguments   = $arguments
                testsRan    = (-not $skipTests)
                completedAt = (Get-Date).ToString("o")
            } | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8
        }

        Write-Host ""
        Write-Host "===================="
        Write-Host "VERIFICATION PASSED"
        Write-Host "===================="
        Write-Host ""

        return 0
    }
    catch {
        Write-Host ""
        Write-Host "===================="
        Write-Host "VERIFICATION FAILED"
        Write-Host "===================="
        Write-Host ""
        Write-Host $_.Exception.Message
        Write-Host ""

        return 1
    }
    finally {
        Pop-Location
    }
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
    param([Parameter(Mandatory = $true)][string]$Path)

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
    param([Parameter(Mandatory = $true)][string]$Pattern)

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
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Project,
        [Parameter(Mandatory = $true)][string]$Configuration
    )

    $assemblies = @()

    foreach ($file in $Project) {

        $directory = Split-Path -Parent $file
        $content = Get-Content -LiteralPath $file -Raw
        $packages = Join-Path $directory "packages.config"

        if (Test-Path -LiteralPath $packages) {
            $content += (Get-Content -LiteralPath $packages -Raw)
        }

        if ($content -notmatch "xunit|nunit|MSTest|UnitTestFramework|Test\.Sdk") {
            continue
        }

        $name = [System.IO.Path]::GetFileNameWithoutExtension($file)

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

function Invoke-FrameworkTest {
    <#
        Runs the built test assemblies of a .NET Framework solution through
        vstest.console. The assemblies exist only after the build step, so they
        are looked up here rather than at detection.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Step)

    $testAssemblies = @(Get-TestAssembly -Project $Step.Projects -Configuration $Step.Configuration)

    if ($testAssemblies.Count -eq 0) {
        # why: same outcome as `dotnet test` on a solution with no test project - nothing to run.
        Write-Host "SKIP: vstest.console (no built test assembly was found)"
        return
    }

    $vstest = Find-VisualStudioFile -Pattern "Common7\IDE\Extensions\TestPlatform\vstest.console.exe"

    if (-not $vstest) {
        throw ("Test assemblies were built but vstest.console.exe was not found in " +
               "the Visual Studio installation.")
    }

    $resultsDirectory = Join-Path $Step.ProjectRoot (Join-Path ".claude" (Join-Path "state" "TestResults"))

    if (Test-Path -LiteralPath $resultsDirectory) {
        Remove-Item -LiteralPath $resultsDirectory -Recurse -Force
    }

    & $vstest $testAssemblies "/Logger:trx" "/ResultsDirectory:$resultsDirectory"

    if ($LASTEXITCODE -ne 0) { return }

    # hazard: vstest.console exits 0 when it discovers no test at all, so a test project whose
    # adapter never reached the output directory would report green having run nothing. The trx
    # has the count, and unlike the console text it is not localised.
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

function Test-UnderDirectory {
    # invariant: "." is the project root and contains every other directory.
    param([string]$Directory, [string[]]$Parents)

    foreach ($parent in $Parents) {
        if (($parent -eq ".") -or ($Directory -eq $parent) -or $Directory.StartsWith($parent + "\")) { return $true }
    }

    return $false
}

function Select-OutermostDirectory {
    # why: a manifest below another of the same ecosystem is a workspace member, and the outer one builds it.
    param([string[]]$Directories)

    $kept = @()

    foreach ($directory in @($Directories | Sort-Object -Unique | Sort-Object Length)) {
        if (-not (Test-UnderDirectory -Directory $directory -Parents $kept)) { $kept += $directory }
    }

    return @($kept | Sort-Object)
}

function Get-DotNetStep {
    param([string]$ProjectRoot, [string[]]$Files, [string]$Target, [string]$Configuration, [switch]$SkipRestore)

    $solutionFiles = @($Files | Where-Object { ($_ -like "*.sln") -or ($_ -like "*.slnx") })
    $projectFiles = @($Files | Where-Object { ($_ -like "*.csproj") -or ($_ -like "*.fsproj") -or ($_ -like "*.vbproj") })

    if ((-not $Target) -and ($solutionFiles.Count -eq 0) -and ($projectFiles.Count -eq 0)) { return @() }

    if (-not $Target) {

        # Prefer a solution at the repository root, then a solution anywhere,
        # then a single project, so a src/ layout is not silently missed.
        $solutions = @($solutionFiles | Where-Object { $_ -notlike "*\*" })

        if ($solutions.Count -eq 0) {
            $solutions = $solutionFiles
        }

        if ($solutions.Count -eq 1) {
            $Target = Join-Path $ProjectRoot $solutions[0]
        }
        elseif ($solutions.Count -gt 1) {

            Write-Host ""
            Write-Host "Multiple solution files were found:"

            foreach ($solution in $solutions) {
                Write-Host "  - $(Join-Path $ProjectRoot $solution)"
            }

            throw "Specify the target explicitly with -Target."
        }
        elseif ($projectFiles.Count -eq 1) {
            $Target = Join-Path $ProjectRoot $projectFiles[0]
        }
        else {

            Write-Host ""
            Write-Host "No solution file was found, and multiple projects exist:"

            foreach ($project in $projectFiles) {
                Write-Host "  - $(Join-Path $ProjectRoot $project)"
            }

            throw "Specify the target explicitly with -Target."
        }
    }

    $Target = [System.IO.Path]::GetFullPath($Target)

    if (-not (Test-Path -LiteralPath $Target)) {
        throw "Target does not exist: $Target"
    }

    Write-Host "Target:        $Target"
    Write-Host "Configuration: $Configuration"

    # The dotnet CLI cannot restore, build or test a .NET Framework project, so
    # the toolchain is chosen once here and every step follows it. One legacy
    # project is enough: MSBuild builds SDK-style projects as well, while
    # `dotnet build` fails on the whole solution the moment one project is old.
    $allProjects = @($projectFiles | ForEach-Object { Join-Path $ProjectRoot $_ })
    $legacyProjects = @($allProjects | Where-Object { Test-LegacyProjectFile -Path $_ })

    if ($legacyProjects.Count -gt 0) {

        $msbuild = Find-VisualStudioFile -Pattern "MSBuild\**\Bin\MSBuild.exe"
        $missing = $null

        if (-not $msbuild) {
            $missing = ("this is a .NET Framework project, which the dotnet CLI cannot build, " +
                        "and no Visual Studio MSBuild was found. Install Visual Studio or the " +
                        "Build Tools for Visual Studio")
        }
        else {
            Write-Host "Toolchain:     $msbuild"
        }

        # Restore needs SolutionDir: packages.config restore refuses to run
        # without one, and it is not set when the target is a project file.
        $solutionDirectory = (Split-Path -Parent $Target).TrimEnd("\") + "\"

        $steps = @()

        if (-not $SkipRestore) {
            $steps += @{ Name = "msbuild -t:restore"; Tool = $msbuild; Missing = $missing; Directory = "."
                Arguments = @($Target, "-t:restore", "-p:RestorePackagesConfig=true", "-p:SolutionDir=$solutionDirectory", "-v:minimal", "-nologo") }
        }

        $steps += @{ Name = "msbuild"; Tool = $msbuild; Missing = $missing; Directory = "."
            Arguments = @($Target, "-p:Configuration=$Configuration", "-m", "-v:minimal", "-nologo") }

        $steps += @{ Name = "vstest.console"; Tool = $msbuild; Missing = $missing; Directory = "."; IsTest = $true
            Projects = $allProjects; Configuration = $Configuration; ProjectRoot = $ProjectRoot
            Command = { param($Step) Invoke-FrameworkTest -Step $Step } }

        return $steps
    }

    # why: dotnet build restores on its own; a separate dotnet restore cost one more
    # MSBuild evaluation of every project for the same result.
    $build = @("build", $Target, "--configuration", $Configuration)
    if ($SkipRestore) { $build += "--no-restore" }

    $missing = "The .NET SDK was not found in PATH"

    return @(
        @{ Name = "dotnet build"; Tool = "dotnet"; Missing = $missing; Directory = "."; Arguments = $build },
        @{ Name = "dotnet test"; Tool = "dotnet"; Missing = $missing; Directory = "."; IsTest = $true
            Arguments = @("test", $Target, "--configuration", $Configuration, "--no-build", "--no-restore") }
    )
}

function Get-DetectedStep {
    <#
    .SYNOPSIS
        The build, analysis and test steps this project's files call for.
    .DESCRIPTION
        Each ecosystem is found wherever its manifest sits in the project files,
        so a Flutter app in app/ and an API in api/ are both verified, each from
        its own directory. A manifest below another of the same ecosystem is a
        workspace member and is built by the outer one; the android/ build of a
        Flutter or Node app is the app's, not a Gradle project of its own.

        Deliberately conservative: build, analysis and test commands only, never
        install or provisioning ones. A verifier that quietly runs `npm ci` is
        changing the thing it is measuring.

        Each step is a hashtable: Name, Tool, Arguments, Directory (relative to
        the root, "." for the root), IsTest, and Command when a native call is
        not enough. Invoke-StepList runs them.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [string]$Target,
        [string]$Configuration = "Debug",
        [switch]$SkipRestore
    )

    $files = @(Get-ProjectFile -ProjectRoot $ProjectRoot)

    $byName = @{}

    foreach ($file in $files) {
        $name = [System.IO.Path]::GetFileName($file).ToLowerInvariant()
        $directory = Split-Path -Parent $file
        if (-not $directory) { $directory = "." }
        if (-not $byName.ContainsKey($name)) { $byName[$name] = @() }
        $byName[$name] += $directory
    }

    function Get-ManifestDirectory {
        param([string[]]$Names)
        $found = @()
        foreach ($name in $Names) { if ($byName.ContainsKey($name)) { $found += $byName[$name] } }
        return @(Select-OutermostDirectory -Directories $found)
    }

    function Test-HasEntry {
        param([string]$Directory, [string]$Pattern)
        return (@(Get-ChildItem -LiteralPath (Join-Path $ProjectRoot $Directory) -Filter $Pattern -ErrorAction SilentlyContinue).Count -gt 0)
    }

    $steps = @(Get-DotNetStep -ProjectRoot $ProjectRoot -Files $files -Target $Target -Configuration $Configuration -SkipRestore:$SkipRestore)

    $dartDirectories = @(Get-ManifestDirectory -Names @("pubspec.yaml"))

    foreach ($directory in $dartDirectories) {

        $pubspec = Get-Content -LiteralPath (Join-Path $ProjectRoot (Join-Path $directory "pubspec.yaml")) -Raw -ErrorAction SilentlyContinue
        $tool = "dart"
        if ($pubspec -match "(?m)^\s*sdk:\s*flutter\s*$") { $tool = "flutter" }

        $steps += @{ Name = "$tool analyze"; Tool = $tool; Arguments = @("analyze"); Directory = $directory }

        if (Test-Path -LiteralPath (Join-Path $ProjectRoot (Join-Path $directory "test")) -PathType Container) {
            $steps += @{ Name = "$tool test"; Tool = $tool; Arguments = @("test"); Directory = $directory; IsTest = $true }
        }
    }

    # why: only a package.json with something to run is a unit, so a root one that holds nothing
    # but formatter settings does not hide the app below it.
    $nodeScripts = @{}

    foreach ($directory in @(if ($byName.ContainsKey("package.json")) { $byName["package.json"] })) {
        try {
            $scripts = (Get-Content -LiteralPath (Join-Path $ProjectRoot (Join-Path $directory "package.json")) -Raw | ConvertFrom-Json).scripts
        }
        catch {
            $scripts = $null
        }

        if (-not $scripts) { continue }

        $names = @()

        foreach ($name in @("typecheck", "lint", "build", "test")) {

            if (-not $scripts.PSObject.Properties[$name]) { continue }

            # `npm init` writes a "test" script that exits 1 with a message.
            # Running it would fail verification for every project that has no
            # tests yet, which is how people learn to pass -SkipTests.
            if (($name -eq "test") -and ([string]$scripts.test -like "*no test specified*")) { continue }

            $names += $name
        }

        if ($names.Count -gt 0) { $nodeScripts[$directory] = $names }
    }

    $nodeDirectories = @(Select-OutermostDirectory -Directories @($nodeScripts.Keys))

    foreach ($directory in $nodeDirectories) {

        $manager = "npm"
        if (Test-HasEntry -Directory $directory -Pattern "pnpm-lock.yaml") { $manager = "pnpm" }
        elseif (Test-HasEntry -Directory $directory -Pattern "yarn.lock") { $manager = "yarn" }
        elseif ((Test-HasEntry -Directory $directory -Pattern "bun.lock") -or (Test-HasEntry -Directory $directory -Pattern "bun.lockb")) { $manager = "bun" }

        foreach ($name in $nodeScripts[$directory]) {
            $steps += @{ Name = "$manager run $name"; Tool = $manager; Arguments = @("run", $name); Directory = $directory; IsTest = ($name -eq "test") }
        }
    }

    foreach ($directory in @(Get-ManifestDirectory -Names @("pyproject.toml", "setup.py", "requirements.txt"))) {
        if ((Test-Path -LiteralPath (Join-Path $ProjectRoot (Join-Path $directory "tests")) -PathType Container) -or
            (Test-HasEntry -Directory $directory -Pattern "test_*.py")) {
            $steps += @{ Name = "pytest"; Tool = "python"; Arguments = @("-m", "pytest"); Directory = $directory; IsTest = $true }
        }
    }

    foreach ($directory in @(Get-ManifestDirectory -Names @("go.mod"))) {
        $steps += @{ Name = "go build"; Tool = "go"; Arguments = @("build", "./..."); Directory = $directory }
        $steps += @{ Name = "go test"; Tool = "go"; Arguments = @("test", "./..."); Directory = $directory; IsTest = $true }
    }

    foreach ($directory in @(Get-ManifestDirectory -Names @("cargo.toml"))) {
        $steps += @{ Name = "cargo build"; Tool = "cargo"; Arguments = @("build", "--locked"); Directory = $directory }
        $steps += @{ Name = "cargo test"; Tool = "cargo"; Arguments = @("test"); Directory = $directory; IsTest = $true }
    }

    # why: the android/ build of a Flutter or React Native app belongs to the app, and cannot build
    # without the app's own toolchain having generated its files first.
    $appDirectories = @($dartDirectories + $nodeDirectories)
    $mavenDirectories = @(Get-ManifestDirectory -Names @("pom.xml") | Where-Object { -not (Test-UnderDirectory -Directory $_ -Parents $appDirectories) })

    foreach ($directory in $mavenDirectories) {
        $steps += @{ Name = "mvn verify"; Tool = "mvn"; Arguments = @("-B", "verify"); Directory = $directory; IsTest = $true }
    }

    foreach ($directory in @(Get-ManifestDirectory -Names @("build.gradle", "build.gradle.kts"))) {

        if (Test-UnderDirectory -Directory $directory -Parents ($appDirectories + $mavenDirectories)) { continue }

        $wrapper = Join-Path $ProjectRoot (Join-Path $directory "gradlew.bat")

        if (Test-Path -LiteralPath $wrapper) {
            $steps += @{ Name = "gradlew.bat build"; Tool = $wrapper; Arguments = @("build"); Directory = $directory; IsTest = $true }
        }
        else {
            $steps += @{ Name = "gradle build"; Tool = "gradle"; Arguments = @("build"); Directory = $directory; IsTest = $true }
        }
    }

    # Make last, and only alone: a Makefile beside a package.json is usually a
    # wrapper around the commands already detected.
    if (($steps.Count -eq 0) -and ($byName.ContainsKey("makefile")) -and ($byName["makefile"] -contains ".")) {
        $steps += @{ Name = "make"; Tool = "make"; Arguments = @(); Directory = "." }
    }

    return $steps
}

function Invoke-StepList {
    <#
    .SYNOPSIS
        Runs verification steps in order, failing on the first that fails.
    .DESCRIPTION
        A step whose tool is not installed is skipped by name rather than
        failing the run, so one missing SDK does not block verifying the rest of
        a mixed repository. A run where every step was skipped that way has
        verified nothing, and fails.

        Steps are hashtables: either Command (a scriptblock, as a project writes
        them in verify.ps1) or Tool and Arguments (as Get-DetectedStep returns
        them), with optional Directory and IsTest.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Step,
        [switch]$SkipTests
    )

    $ran = 0
    $missing = @()

    foreach ($item in $Step) {

        $label = $item.Name
        $directory = $null

        if ($item.ContainsKey("Directory") -and $item.Directory) {
            $label = $item.Name + " @ " + $item.Directory
            $directory = Join-Path $ProjectRoot $item.Directory
        }

        if ($item.ContainsKey("IsTest") -and [bool]$item.IsTest -and $SkipTests) {
            Write-Host ""
            Write-Host "SKIP: $label (-SkipTests)"
            continue
        }

        if ($item.ContainsKey("Tool")) {

            # invariant: a step with no Tool was found missing at detection, and Missing says why.
            $reason = $null

            if (-not $item.Tool) {
                $reason = $item["Missing"]
            }
            elseif (-not (Get-Command $item.Tool -ErrorAction SilentlyContinue)) {
                $reason = "$($item.Tool) was not found in PATH"
                if ($item["Missing"]) { $reason = $item["Missing"] }
            }

            if ($reason) {
                $missing += $reason
                Write-Host ""
                Write-Host "SKIP: $label ($reason)"
                continue
            }
        }

        $current = $item

        if ($current.ContainsKey("Command") -and $current.Command) {
            Invoke-Step -Name $current.Name -Directory $directory -Action { & $current.Command $current }
        }
        else {
            # hazard: splat a variable; npm and pnpm resolve to .ps1 shims, which take an inline array as one argument.
            $arguments = @($current.Arguments)
            Invoke-Step -Name $current.Name -Directory $directory -Action { & $current.Tool @arguments }
        }

        $ran++
    }

    if (($ran -eq 0) -and ($missing.Count -gt 0)) {
        throw ("Nothing to verify: every detected step was skipped because its tool is missing (" +
               (($missing | Sort-Object -Unique) -join "; ") + ").")
    }

    if ($Step.Count -eq 0) {
        throw ("Nothing to verify: no build or test commands were found for this project. " +
               "Edit .claude\scripts\verify.ps1 and populate `$VerificationSteps with " +
               "the commands that prove this project works.")
    }
}

Export-ModuleMember -Function @(
    "Get-DetectedStep",
    "Invoke-StepList",
    "Invoke-Step",
    "Test-GitWorkTree",
    "Get-VerificationStateFile",
    "Get-ProjectFile",
    "Get-SourceFingerprint",
    "Invoke-Verification"
)
