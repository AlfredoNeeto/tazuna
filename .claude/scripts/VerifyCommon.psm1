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
        unexpected is hashed, which is harmless.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot,

        # Files larger than this are assumed not to be source.
        [int]$MaximumFileSizeBytes = 5242880
    )

    $excludedDirectories = @(
        "bin", "obj", "node_modules", ".git", ".vs", ".vscode", ".idea",
        "packages", "artifacts", "TestResults", "dist", "build", "target",
        "out", "coverage", ".next", ".nuxt", "__pycache__", ".venv", "venv",
        ".harness-backup", "state"
    )

    # Binaries, archives, media and machine-local cruft. Everything else counts.
    $excludedExtensions = @(
        ".dll", ".exe", ".pdb", ".so", ".dylib", ".a", ".lib", ".o", ".obj",
        ".zip", ".tar", ".gz", ".bz2", ".7z", ".rar", ".nupkg", ".snupkg",
        ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".ico", ".webp", ".mp4", ".mp3",
        ".pdf", ".docx", ".xlsx", ".pptx", ".ttf", ".woff", ".woff2", ".eot",
        ".cache", ".user", ".suo", ".userprefs", ".log", ".tmp", ".bak", ".swp"
    )

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $rootFull = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd($separator)

    $files = Get-ChildItem -LiteralPath $rootFull -File -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object {

            if ($excludedExtensions -contains $_.Extension.ToLowerInvariant()) { return $false }
            if ($_.Length -gt $MaximumFileSizeBytes) { return $false }

            $relative = $_.FullName.Substring($rootFull.Length).Trim($separator)

            foreach ($segment in $relative.Split($separator)) {
                if ($excludedDirectories -contains $segment) { return $false }
            }

            return $true
        } |
        Sort-Object FullName

    $builder = New-Object System.Text.StringBuilder

    # .NET rather than Get-FileHash. Get-FileHash is a function in Windows
    # PowerShell 5.1 and an inherited $WhatIfPreference reaches inside it: it
    # returns nothing, and .Hash on nothing throws. Here that would not fail
    # loudly - it would change the fingerprint, and the gate would stop matching
    # its own baseline while still reporting success.
    $algorithm = [System.Security.Cryptography.SHA256]::Create()

    try {

        foreach ($file in $files) {

            $relative = $file.FullName.Substring($rootFull.Length).Trim($separator)

            $hash = [System.BitConverter]::ToString(
                $algorithm.ComputeHash([System.IO.File]::ReadAllBytes($file.FullName))).Replace("-", "")

            $null = $builder.Append($relative).Append("|").Append($hash).Append("`n")
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
    "Get-SourceFingerprint"
)
