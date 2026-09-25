# Paths.psm1
#
# Where things are: the Claude Code directories and path parameters resolved against the shell's location.
# invariant: a leaf - imports no other module, and only Console.psm1 writes to the host.
# Windows PowerShell 5.1 compatible.

Set-StrictMode -Version 2.0

function Get-ClaudeConfigDir {
    <#
    .SYNOPSIS
        Resolves the Claude Code configuration directory.
    .DESCRIPTION
        Honours CLAUDE_CONFIG_DIR when set, otherwise falls back to ~/.claude.
        Every harness script must use this so the installer and the health
        check can never disagree about which directory they are acting on.
    #>
    [CmdletBinding()]
    param()

    $configured = $env:CLAUDE_CONFIG_DIR

    if ($configured -and $configured.Trim() -ne "") {
        return [System.IO.Path]::GetFullPath($configured.Trim())
    }

    return [System.IO.Path]::GetFullPath((Join-Path $HOME ".claude"))
}

function Resolve-HarnessPath {
    <#
    .SYNOPSIS
        Turns a path parameter into an absolute path, relative to where the
        user actually is.
    .DESCRIPTION
        [System.IO.Path]::GetFullPath resolves a relative path against the
        PROCESS working directory, and that is not PowerShell's location:
        Set-Location does not move it. So a parameter defaulting to "." pointed
        at wherever powershell.exe was started, not at the directory you cd'd
        into.

        Measured, before this existed: `cd C:\src\MyApp`, then the dispatcher's
        since-removed `spec -Name X` created the spec inside the harness repository. It reported the path it
        used, and the path was wrong.

        Every harness script that accepts a path must resolve it through here.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $PWD.ProviderPath
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $PWD.ProviderPath $Path))
}

function Get-ClaudeStateFile {
    <#
    .SYNOPSIS
        Resolves Claude Code's machine-local state file, .claude.json.
    .DESCRIPTION
        It is NOT inside the configuration directory by default. The default
        layout is ~/.claude/ for configuration and ~/.claude.json BESIDE it;
        only under CLAUDE_CONFIG_DIR do both live in the same directory.

        Getting this wrong writes a file Claude Code never reads, which is the
        worst kind of wrong: it reports success and changes nothing.

        The file holds per-project state, including hasTrustDialogAccepted, and
        credentials. Never copy it into a project directory.
    #>
    [CmdletBinding()]
    param()

    $configured = $env:CLAUDE_CONFIG_DIR

    if ($configured -and $configured.Trim() -ne "") {
        return [System.IO.Path]::GetFullPath((Join-Path $configured.Trim() ".claude.json"))
    }

    return [System.IO.Path]::GetFullPath((Join-Path $HOME ".claude.json"))
}

function Get-CompatibleRelativePath {
    <#
    .SYNOPSIS
        Returns TargetPath expressed relative to BasePath.
    .DESCRIPTION
        [System.IO.Path]::GetRelativePath is .NET Core / PowerShell 7 only, so
        this uses System.Uri instead. Uri.MakeRelativeUri silently returns an
        absolute path when the two paths sit on different volumes, which would
        then be fed to Join-Path and produce a malformed result, so that case
        is detected and reported instead.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath,

        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    $baseFull = [System.IO.Path]::GetFullPath($BasePath)
    $targetFull = [System.IO.Path]::GetFullPath($TargetPath)

    $baseRoot = [System.IO.Path]::GetPathRoot($baseFull)
    $targetRoot = [System.IO.Path]::GetPathRoot($targetFull)

    if ($baseRoot -ne $targetRoot) {
        throw ("Cannot build a relative path across different volumes: " +
               "'$baseFull' and '$targetFull'.")
    }

    if (-not $baseFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $baseFull += [System.IO.Path]::DirectorySeparatorChar
    }

    $baseUri = New-Object System.Uri($baseFull)
    $targetUri = New-Object System.Uri($targetFull)

    $relativeUri = $baseUri.MakeRelativeUri($targetUri)
    $relativePath = [System.Uri]::UnescapeDataString($relativeUri.ToString())

    return $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
}

function New-HarnessBackupRoot {
    <#
    .SYNOPSIS
        Builds a timestamped backup directory path. Does not create it;
        creation is deferred until something is actually backed up.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ParentDirectory
    )

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

    return (Join-Path (Join-Path $ParentDirectory ".harness-backup") $timestamp)
}

Export-ModuleMember -Function @(
    "Get-ClaudeConfigDir",
    "Resolve-HarnessPath",
    "Get-ClaudeStateFile",
    "Get-CompatibleRelativePath",
    "New-HarnessBackupRoot"
)
