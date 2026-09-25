# Git.psm1
#
# Running git and reading work tree state.
# invariant: a leaf - imports no other module, and only Console.psm1 writes to the host.
# Windows PowerShell 5.1 compatible.

Set-StrictMode -Version 2.0

function Invoke-GitCommand {
    <#
    .SYNOPSIS
        Runs git against a repository and returns its output and exit code.
    .DESCRIPTION
        Does not redirect git's stderr. In Windows PowerShell 5.1 redirecting a
        native command's stderr wraps each line in a NativeCommandError, which
        under $ErrorActionPreference = 'Stop' turns an expected non-zero exit
        into a thrown terminating error. Preference is therefore relaxed for the
        duration of the call and the exit code is inspected explicitly.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [switch]$AllowFailure
    )

    $previous = $ErrorActionPreference
    $output = $null
    $code = 0

    try {
        $ErrorActionPreference = "Continue"
        $global:LASTEXITCODE = 0
        $output = & git -C $RepositoryPath @Arguments
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }

    if ((-not $AllowFailure) -and ($code -ne 0)) {
        throw ("git " + ($Arguments -join " ") + " failed with exit code $code.")
    }

    $lines = @($output | Where-Object { $null -ne $_ })

    return [PSCustomObject]@{
        Output   = $lines
        Text     = ($lines -join "`n")
        ExitCode = $code
    }
}

function Get-GitRoot {
    <#
        Returns the work tree root for Path, or $null when Path is not inside a
        git repository. Walks up for .git rather than shelling out, so it is
        safe under $ErrorActionPreference = 'Stop'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $current = [System.IO.Path]::GetFullPath($Path)

    while ($current) {

        if (Test-Path -LiteralPath (Join-Path $current ".git")) {
            return $current
        }

        $parent = Split-Path -Parent $current

        if (-not $parent -or $parent -eq $current) {
            break
        }

        $current = $parent
    }

    return $null
}

function Get-GitStatusSummary {
    <#
        Reports whether a work tree has uncommitted changes, counting tracked
        modifications and untracked files separately. Untracked files count as
        work in progress: removing a worktree would destroy them.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath
    )

    $status = Invoke-GitCommand -RepositoryPath $RepositoryPath -Arguments @("status", "--porcelain=v1", "-uall")

    $tracked = 0
    $untracked = 0

    foreach ($line in $status.Output) {

        # StartsWith, not -like "??*": in PowerShell '?' is a single-character
        # wildcard, so "??*" matches every non-empty line and every modified
        # file would be miscounted as untracked.
        if ($line.StartsWith("??")) {
            $untracked++
        }
        elseif ($line.Trim() -ne "") {
            $tracked++
        }
    }

    return [PSCustomObject]@{
        TrackedChanges   = $tracked
        UntrackedFiles   = $untracked
        IsClean          = (($tracked -eq 0) -and ($untracked -eq 0))
        Lines            = $status.Output
    }
}

Export-ModuleMember -Function @(
    "Invoke-GitCommand",
    "Get-GitRoot",
    "Get-GitStatusSummary"
)
