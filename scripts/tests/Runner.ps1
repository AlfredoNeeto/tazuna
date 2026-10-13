# invariant: dot-sourced by test-harness.ps1 and by Verify.Tests.ps1, which drives it with stub test files.

function Get-ShardVerdict {
    # invariant: a run passes only when every file it started was read back, printed its result, exited
    # as that result says, and at least one case passed. A crashed file must never read as a quiet one.
    param([Parameter(Mandatory = $true)][object[]]$Results, [int]$Expected = $Results.Count)

    $verdict = [PSCustomObject]@{ Passed = 0; Failed = 0; Skipped = 0; Broken = @(); Ok = $false }

    foreach ($result in $Results) {

        # why: the last result line is the file's own; RightToLeft finds it first.
        $summary = [regex]::Match([string]$result.Text, "TEST FILE RESULT: passed (\d+) failed (\d+) skipped (\d+)",
            [System.Text.RegularExpressions.RegexOptions]::RightToLeft)

        if (-not $summary.Success) {
            $verdict.Broken += "file $($result.Index) (exit $($result.ExitCode), no result)"
            continue
        }

        $failed = [int]$summary.Groups[2].Value
        $verdict.Passed += [int]$summary.Groups[1].Value
        $verdict.Failed += $failed
        $verdict.Skipped += [int]$summary.Groups[3].Value

        if (($result.ExitCode -eq 0) -ne ($failed -eq 0)) {
            $verdict.Broken += "file $($result.Index) (exit $($result.ExitCode))"
        }
    }

    if ($Results.Count -lt $Expected) {
        $verdict.Broken += "$($Expected - $Results.Count) of $Expected file(s) never read back"
    }

    $verdict.Ok = ($verdict.Broken.Count -eq 0) -and ($verdict.Failed -eq 0) -and ($verdict.Passed -gt 0)
    return $verdict
}

function Start-ShardProcess {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-shard-" + [guid]::NewGuid().ToString("N").Substring(0, 8) + ".txt")

    $process = Start-Process -FilePath "powershell" -ArgumentList $Arguments -NoNewWindow -PassThru `
        -RedirectStandardOutput $output -RedirectStandardError ($output + ".err")

    # hazard: Windows PowerShell 5.1 reports no ExitCode for a Start-Process object whose handle was never read.
    $null = $process.Handle

    return [PSCustomObject]@{ Process = $process; Output = $output }
}

function Receive-ShardResult {
    # invariant: the exit code returned is the process's own; a file read as exit 0 would pass whatever it did.
    param([Parameter(Mandatory = $true)]$Started, $Index)

    $Started.Process.WaitForExit()

    $text = ""
    foreach ($file in @($Started.Output, ($Started.Output + ".err"))) {
        if (Test-Path -LiteralPath $file) {
            $text += [System.IO.File]::ReadAllText($file)
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
    }

    return [PSCustomObject]@{ Index = $Index; Text = $text; ExitCode = $Started.Process.ExitCode }
}

function Invoke-TestRun {
    # invariant: returns 0 only when the verdict over every file it was given is clean; the caller exits with it.
    param(
        [Parameter(Mandatory = $true)][string[]]$Files,
        [string]$Only,
        [switch]$SkipSlow
    )

    Write-Host ""
    Write-Host "Harness Self-Test ($($Files.Count) files)"
    Write-Host "================="

    # why: every file starts before any is read, so the run takes as long as the slowest file.
    $started = @()

    foreach ($file in $Files) {
        $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$file`"")
        if ($Only) { $arguments += @("-Only", "`"$Only`"") }
        if ($SkipSlow) { $arguments += "-SkipSlow" }
        $started += Start-ShardProcess -Arguments $arguments
    }

    $results = @()

    for ($index = 0; $index -lt $started.Count; $index++) {
        $result = Receive-ShardResult -Started $started[$index] -Index (Split-Path -Leaf $Files[$index])
        Write-Host ""
        Write-Host ("# " + $result.Index)
        Write-Host $result.Text.TrimEnd()
        $results += $result
    }

    $verdict = Get-ShardVerdict -Results $results -Expected $Files.Count

    Write-Host ""
    Write-Host "================="
    Write-Host ("Passed: {0}   Failed: {1}   Skipped: {2}" -f $verdict.Passed, $verdict.Failed, $verdict.Skipped)
    Write-Host "================="
    Write-Host ""

    if ($verdict.Ok) {
        Write-Host "HARNESS SELF-TEST PASSED"
        Write-Host ""
        return 0
    }

    if ($verdict.Broken.Count -gt 0) { Write-Host ("Did not finish cleanly: " + ($verdict.Broken -join ", ")) }

    if ($Only -and (($verdict.Passed + $verdict.Failed) -eq 0)) {
        Write-Host "HARNESS SELF-TEST FAILED: no case named '$Only' ran"
    }
    else {
        Write-Host "HARNESS SELF-TEST FAILED"
    }

    Write-Host ""
    return 1
}
