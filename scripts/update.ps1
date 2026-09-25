<#
.SYNOPSIS
    Updates the harness from its remote and reinstalls it.

.DESCRIPTION
    Fast-forwards the harness repository, then runs setup again, which ends in
    the health check. Each step gates the next, so a bad pull is not installed
    and a broken install is not reported as success.

    It refuses to touch a repository with uncommitted changes, and it never
    merges, rebases, resets or forces. If the branch has diverged, it says so
    and stops: reconciling history is a decision, not an update step.

.PARAMETER SkipPull
    Reinstall from the working tree as it is, without fetching.

.EXAMPLE
    .\scripts\update.ps1 -WhatIf

.EXAMPLE
    .\scripts\update.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$SkipPull
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\Console.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "lib\Git.psm1") -Force

$repoRoot = Split-Path -Parent $PSScriptRoot

Write-Host ""
Write-Host "Tazuna Update"
Write-Host "============="
Write-Host ""
Write-Host "Repository: $repoRoot"
Write-Host ""

if (-not $SkipPull) {

    if (-not (Get-GitRoot -Path $repoRoot)) {
        Write-Host "ERROR: the harness is not a git repository; use -SkipPull to reinstall from the working tree."
        exit 1
    }

    $status = Get-GitStatusSummary -RepositoryPath $repoRoot

    if (-not $status.IsClean) {

        Write-Host ("REFUSING to pull: the harness has {0} tracked change(s) and {1} untracked file(s)." -f `
            $status.TrackedChanges, $status.UntrackedFiles)
        Write-Host ""

        foreach ($line in ($status.Lines | Select-Object -First 20)) {
            Write-Host "  $line"
        }

        Write-Host ""
        Write-Host "Commit or stash them first, or use -SkipPull to reinstall the working tree as it is."
        Write-Host ""
        exit 1
    }

    $branch = (Invoke-GitCommand -RepositoryPath $repoRoot -Arguments @("rev-parse", "--abbrev-ref", "HEAD")).Text.Trim()

    Write-Status -Label "BRANCH" -Detail $branch

    $upstream = Invoke-GitCommand `
        -RepositoryPath $repoRoot `
        -Arguments @("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}") `
        -AllowFailure

    if ($upstream.ExitCode -ne 0) {
        Write-Status -Label "SKIP" -Detail "no upstream configured for '$branch'; nothing to pull"
    }
    else {

        $upstreamName = $upstream.Text.Trim()

        if (-not $PSCmdlet.ShouldProcess($repoRoot, "Fetch $upstreamName")) {
            Write-Status -Label "WHATIF" -Detail "would fetch and fast-forward from $upstreamName"
        }
        else {

            $fetch = Invoke-GitCommand -RepositoryPath $repoRoot -Arguments @("fetch", "--prune") -AllowFailure

            if ($fetch.ExitCode -ne 0) {
                Write-Host "ERROR: fetch failed. Nothing has been changed."
                exit 1
            }

            Write-Status -Label "FETCHED" -Detail $upstreamName

            $counts = Invoke-GitCommand `
                -RepositoryPath $repoRoot `
                -Arguments @("rev-list", "--left-right", "--count", "$branch...$upstreamName") `
                -AllowFailure

            $ahead = 0
            $behind = 0

            if ($counts.ExitCode -eq 0) {
                $parts = $counts.Text.Trim() -split "\s+"

                if ($parts.Count -eq 2) {
                    $ahead = [int]$parts[0]
                    $behind = [int]$parts[1]
                }
            }

            if ($ahead -gt 0) {
                Write-Host ""
                Write-Host ("REFUSING to update: '{0}' has {1} local commit(s) not on {2}." -f $branch, $ahead, $upstreamName)
                Write-Host "Reconciling diverged history is a decision, not an update step. Merge or rebase yourself."
                Write-Host ""
                exit 1
            }

            if ($behind -eq 0) {
                Write-Status -Label "CURRENT" -Detail "already up to date with $upstreamName"
            }
            else {

                # --ff-only: never create a merge commit, never rewrite history.
                $merge = Invoke-GitCommand -RepositoryPath $repoRoot -Arguments @("merge", "--ff-only", $upstreamName) -AllowFailure

                if ($merge.ExitCode -ne 0) {
                    Write-Host ""
                    Write-Host "ERROR: could not fast-forward. The branch has diverged; reconcile it yourself."
                    Write-Host ""
                    exit 1
                }

                Write-Status -Label "UPDATED" -Detail ("fast-forwarded {0} commit(s)" -f $behind)
            }
        }
    }
}
else {
    Write-Status -Label "SKIP" -Detail "pull skipped; reinstalling the working tree as it is"
}

Write-Host ""
Write-Host "Running setup..."

# Setup is the whole install - user harness, toolkit, skills, MCP - and ends in
# the health check. Nothing here repeats it.
& (Join-Path $PSScriptRoot "bootstrap.ps1") -WhatIf:$WhatIfPreference

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "Update pulled, but setup FAILED. See the output above."
    Write-Host ""
    exit 1
}

Write-Host ""
Write-Host "Harness updated."
Write-Host ""

exit 0
