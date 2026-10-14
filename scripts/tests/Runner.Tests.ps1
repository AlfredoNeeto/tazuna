[CmdletBinding()]
param([switch]$SkipSlow, [string]$Only)

. (Join-Path $PSScriptRoot "TestKit.ps1")
. (Join-Path $PSScriptRoot "Runner.ps1")

Start-Section "Self-test runner"

function New-RunnerProject {
    param([hashtable]$Files)
    $root = New-ScratchRoot
    foreach ($name in $Files.Keys) { [System.IO.File]::WriteAllText((Join-Path $root $name), $Files[$name]) }
    return $root
}

Test-Case -Name "F15 the shard verdict fails a crash, a missing result and an exit that contradicts its result, and passes a clean run" -Check {
    $clean = "TEST FILE RESULT: passed 5 failed 0 skipped 1"
    $cases = @(
        @{ Name = "clean run"; Ok = $true; Shards = @(@{ Index = 0; Text = $clean; ExitCode = 0 }, @{ Index = 1; Text = "TEST FILE RESULT: passed 3 failed 0 skipped 0"; ExitCode = 0 }) },
        @{ Name = "crashed shard"; Ok = $false; Shards = @(@{ Index = 0; Text = $clean; ExitCode = 0 }, @{ Index = 1; Text = "PASS one case"; ExitCode = 3 }) },
        @{ Name = "missing result"; Ok = $false; Shards = @(@{ Index = 0; Text = ""; ExitCode = 0 }) },
        @{ Name = "non-zero exit after a clean result"; Ok = $false; Shards = @(@{ Index = 0; Text = $clean; ExitCode = 2 }) },
        @{ Name = "failed case"; Ok = $false; Shards = @(@{ Index = 0; Text = "TEST FILE RESULT: passed 4 failed 1 skipped 0"; ExitCode = 1 }) },
        @{ Name = "nothing passed"; Ok = $false; Shards = @(@{ Index = 0; Text = "TEST FILE RESULT: passed 0 failed 0 skipped 2"; ExitCode = 0 }) }
    )

    foreach ($case in $cases) {
        $verdict = Get-ShardVerdict -Results @($case.Shards | ForEach-Object { [PSCustomObject]$_ })
        if ($verdict.Ok -ne $case.Ok) { return "$($case.Name): Ok is $($verdict.Ok), expected $($case.Ok)" }
        if ($case.Name -eq "clean run") {
            if (($verdict.Passed -ne 8) -or ($verdict.Skipped -ne 1) -or ($verdict.Failed -ne 0)) { return "clean run totals: $($verdict.Passed)/$($verdict.Failed)/$($verdict.Skipped), expected 8/0/1" }
        }
    }

    return $true
}

Test-Case -Name "F17 a shard process that prints a clean result and then exits 5 is read with exit 5 and fails the run" -Check {
    $started = Start-ShardProcess -Arguments @("-NoProfile", "-Command", "Write-Output 'TEST FILE RESULT: passed 1 failed 0 skipped 0'; exit 5")
    $result = Receive-ShardResult -Started $started -Index 7

    if ($result.ExitCode -ne 5) { return "read exit '$($result.ExitCode)', expected 5" }
    if ($result.Text -notmatch "TEST FILE RESULT: passed 1 failed 0 skipped 0") { return ("read text: " + $result.Text) }
    if (Test-Path -LiteralPath $started.Output) { return "the shard's output file was left behind" }
    if ((Get-ShardVerdict -Results @($result)).Ok) { return "the verdict passed a shard that exited 5" }
    return $true
}

Test-Case -Name "F18 the run returns 1 and prints FAILED for a failing, a crashing, a silent and an unread test file, and 0 for a clean set" -Check {
    $root = New-RunnerProject -Files @{
        "Clean1.Tests.ps1"   = "Write-Output 'TEST FILE RESULT: passed 2 failed 0 skipped 1'; exit 0"
        "Clean2.Tests.ps1"   = "Write-Output 'TEST FILE RESULT: passed 3 failed 0 skipped 0'; exit 0"
        "Clean3.Tests.ps1"   = "Write-Output 'TEST FILE RESULT: passed 4 failed 0 skipped 2'; exit 0"
        "Failing.Tests.ps1"  = "Write-Output 'TEST FILE RESULT: passed 1 failed 1 skipped 0'; exit 1"
        "Crashing.Tests.ps1" = "Write-Output 'PASS one case'; throw 'the file crashed'"
        "Silent.Tests.ps1"   = "exit 0"
    }
    $clean = @(@("Clean1", "Clean2", "Clean3") | ForEach-Object { Join-Path $root "$_.Tests.ps1" })

    $invoke = {
        param([string[]]$Files)
        $output = @(Invoke-TestRun -Files $Files 6>&1)
        return [PSCustomObject]@{ Code = (@($output | Where-Object { $_ -is [int] }) -join ","); Text = (@($output | Where-Object { $_ -isnot [int] }) | Out-String) }
    }

    $run = & $invoke -Files $clean
    if ($run.Code -ne "0") { return ("the clean set returned '$($run.Code)': " + $run.Text) }
    if ($run.Text -notmatch "HARNESS SELF-TEST PASSED") { return "the clean set did not print PASSED" }
    if ($run.Text -notmatch "Passed: 9\s+Failed: 0\s+Skipped: 3") { return ("the totals are not the sum of the three files: " + $run.Text) }

    foreach ($bad in @("Failing", "Crashing", "Silent")) {
        $run = & $invoke -Files ($clean + (Join-Path $root "$bad.Tests.ps1"))
        if ($run.Code -ne "1") { return "a $bad file returned '$($run.Code)', expected 1" }
        if (($run.Text -notmatch "HARNESS SELF-TEST FAILED") -or ($run.Text -match "HARNESS SELF-TEST PASSED")) { return ("a $bad file did not print FAILED: " + $run.Text) }
    }

    $read = @(1..3 | ForEach-Object { [PSCustomObject]@{ Index = $_; Text = "TEST FILE RESULT: passed 1 failed 0 skipped 0"; ExitCode = 0 } })
    if ((Get-ShardVerdict -Results $read -Expected 4).Ok) { return "the verdict passed a run with a file never read back" }
    if (-not (Get-ShardVerdict -Results $read -Expected 3).Ok) { return "the verdict failed three clean files read back of three" }
    return $true
}

Test-Case -Name "F19 -Only runs the matching cases alone, and a name that matches none fails the run" -Check {
    $kit = Join-Path $PSScriptRoot "TestKit.ps1"
    $body = @(
        '[CmdletBinding()] param([switch]$SkipSlow, [string]$Only)',
        ". '$kit'",
        'Test-Case -Name "Z1 the chosen case" -Check { return $true }',
        'Test-Case -Name "Z2 a case left out" -Check { return $true }',
        'Complete-TestFile') -join "`r`n"
    $root = New-RunnerProject -Files @{ "Pick.Tests.ps1" = $body }
    $file = Join-Path $root "Pick.Tests.ps1"

    $output = @(Invoke-TestRun -Files @($file) -Only "Z1" 6>&1)
    $code = (@($output | Where-Object { $_ -is [int] }) -join ",")
    $text = (@($output | Where-Object { $_ -isnot [int] }) | Out-String)
    if ($code -ne "0") { return ("-Only Z1 returned '$code': " + $text) }
    if ($text -notmatch "PASS\s+Z1 the chosen case") { return ("Z1 did not run: " + $text) }
    if ($text -match "Z2 a case left out") { return ("Z2 ran although -Only named Z1: " + $text) }

    $output = @(Invoke-TestRun -Files @($file) -Only "NOPE" 6>&1)
    $code = (@($output | Where-Object { $_ -is [int] }) -join ",")
    $text = (@($output | Where-Object { $_ -isnot [int] }) | Out-String)
    if (($code -ne "1") -or ($text -notmatch "no case named 'NOPE' ran")) { return ("-Only NOPE returned '$code': " + $text) }
    return $true
}

Complete-TestFile
