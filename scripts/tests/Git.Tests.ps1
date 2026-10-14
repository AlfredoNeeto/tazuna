[CmdletBinding()]
param([switch]$SkipSlow, [string]$Only)

. (Join-Path $PSScriptRoot "TestKit.ps1")

Start-Section "Git helpers"

$statusRepo = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-status-" + [guid]::NewGuid().ToString("N").Substring(0, 8))

try {
    New-Item -ItemType Directory -Path $statusRepo -Force | Out-Null
    $null = Invoke-GitCommand -RepositoryPath $statusRepo -Arguments @("init", "-q") -AllowFailure

    Set-Content -LiteralPath (Join-Path $statusRepo "tracked.txt") -Value "v1" -NoNewline
    $null = Invoke-GitCommand -RepositoryPath $statusRepo -Arguments @("add", "-A") -AllowFailure
    $null = Invoke-GitCommand -RepositoryPath $statusRepo `
        -Arguments @("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init") -AllowFailure

    Set-Content -LiteralPath (Join-Path $statusRepo "tracked.txt") -Value "v2" -NoNewline
    Set-Content -LiteralPath (Join-Path $statusRepo "new.txt") -Value "new" -NoNewline

    Test-Case -Name "status separates tracked changes from untracked files" -Check {

        $summary = Get-GitStatusSummary -RepositoryPath $statusRepo

        if ($summary.TrackedChanges -ne 1) { return "tracked = $($summary.TrackedChanges), expected 1" }
        if ($summary.UntrackedFiles -ne 1) { return "untracked = $($summary.UntrackedFiles), expected 1" }
        if ($summary.IsClean) { return "reported clean with pending changes" }

        return $true
    }

    Test-Case -Name "status reports a clean tree as clean" -Check {

        $null = Invoke-GitCommand -RepositoryPath $statusRepo -Arguments @("checkout", "--", "tracked.txt") -AllowFailure
        Remove-Item -LiteralPath (Join-Path $statusRepo "new.txt") -Force

        $summary = Get-GitStatusSummary -RepositoryPath $statusRepo

        if ($summary.IsClean) { return $true }
        return "reported dirty with nothing pending"
    }
}
finally {
    if (Test-Path -LiteralPath $statusRepo) {
        Remove-Item -LiteralPath $statusRepo -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Complete-TestFile
