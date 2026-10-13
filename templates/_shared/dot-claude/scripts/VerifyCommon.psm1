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

# why: one match per path instead of a loop over its segments; -match ignores case, as -contains did.
$script:excludedPathPattern = "(^|\\)(" + (($script:excludedDirectories | ForEach-Object { [regex]::Escape($_) }) -join "|") + ")(\\|$)"

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
        [scriptblock]$Action
    )

    Write-Host ""
    Write-Host "==> $Name"
    Write-Host ""

    $global:LASTEXITCODE = 0

    & $Action

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

        $process = [System.Diagnostics.Process]::Start($start)
        $output = $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()

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
        is not source. The walk this replaced enumerated node_modules, bin and
        obj in full before discarding them: 11.6 s on a 35,000-file checkout,
        paid at every Stop.

        Outside git, or when git cannot answer, the tree is walked without
        entering an excluded directory. Either way no path with an excluded
        directory segment is returned. git lists a submodule, or a nested
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

    if ($null -eq $listed) {
        $listed = @(Get-WalkedFile -Root $rootFull -Start $rootFull)
    }

    $files = New-Object System.Collections.Generic.List[string]

    foreach ($relative in $listed) {
        if ($relative -notmatch $script:excludedPathPattern) { $files.Add($relative) }
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

Export-ModuleMember -Function @(
    "Invoke-Step",
    "Test-GitWorkTree",
    "Get-VerificationStateFile",
    "Get-ProjectFile",
    "Get-SourceFingerprint"
)
