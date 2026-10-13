[CmdletBinding()]
param([switch]$SkipSlow, [string]$Only)

. (Join-Path $PSScriptRoot "TestKit.ps1")

Start-Section "Installer exe"

$script:launcherDirectory = $null

function Get-BuiltLauncher {
    # why: one build serves every case in this file; it takes about a second.
    if (-not $script:launcherDirectory) {
        $script:launcherDirectory = New-ScratchRoot
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsRoot "build-installer.ps1") -OutDirectory $script:launcherDirectory | Out-Null
    }
    return (Join-Path $script:launcherDirectory "tazuna-setup.exe")
}

function New-FakeHarness {
    # invariant: install.ps1 treats a directory holding scripts\bootstrap.ps1 as the harness and runs that file.
    param([int]$ExitCode, [string]$Marker = "")
    $target = Join-Path (New-ScratchRoot) "tazuna"
    New-Item -ItemType Directory -Path (Join-Path $target "scripts") -Force | Out-Null
    $body = "exit $ExitCode"
    if ($Marker) { $body = "Set-Content -LiteralPath '$Marker' -Value done`r`n" + $body }
    Set-Content -LiteralPath (Join-Path $target "scripts\bootstrap.ps1") -Value $body
    return $target
}

function Invoke-Launcher {
    # why: started from this console with an empty stdin, the exe never waits, and the stub git keeps it off the network.
    param([string]$Target)

    $root = New-ScratchRoot
    $bin = New-StubBin -Root $root
    Set-Content -LiteralPath (Join-Path $bin "git.ps1") -Value ('Add-Content -LiteralPath $env:HARNESS_STUB_LOG -Value ("git " + ($args -join " "))' + "`r`nexit 1")
    $log = Join-Path $root "calls.log"

    $saved = @{}
    $variables = @{ PATH = ($bin + ";" + $env:PATH); HARNESS_STUB_LOG = $log; TAZUNA_PATH = $Target }
    foreach ($key in $variables.Keys) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
        [Environment]::SetEnvironmentVariable($key, $variables[$key], "Process")
    }

    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $global:LASTEXITCODE = 0
        $output = ($null | & (Get-BuiltLauncher) 2>&1 | Out-String)
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
        foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key], "Process") }
    }

    $calls = @()
    if (Test-Path -LiteralPath $log) { $calls = @(Get-Content -LiteralPath $log) }
    return [PSCustomObject]@{ Code = $code; Output = $output; Calls = $calls }
}

Test-Case -Name "EX1 build-installer writes tazuna-setup.exe with install.ps1 byte for byte, five icon images and an asInvoker manifest" -Check {
    $exe = Get-BuiltLauncher
    if (-not (Test-Path -LiteralPath $exe)) { return "no tazuna-setup.exe was built" }

    $bytes = [System.IO.File]::ReadAllBytes($exe)
    if (($bytes[0] -ne 0x4D) -or ($bytes[1] -ne 0x5A)) { return "the output is not a Windows executable" }

    $text = [System.Text.Encoding]::ASCII.GetString($bytes)
    if (-not $text.Contains("asInvoker")) { return "no asInvoker manifest: a name with setup in it would ask for administrator rights" }
    if ([regex]::Matches($text, "IHDR").Count -ne 5) { return "expected five PNG icon images, found $([regex]::Matches($text, 'IHDR').Count)" }

    $stream = [System.Reflection.Assembly]::Load($bytes).GetManifestResourceStream("install.ps1")
    if (-not $stream) { return "install.ps1 is not embedded" }
    $embedded = New-Object System.IO.MemoryStream
    $stream.CopyTo($embedded)
    $expected = [System.IO.File]::ReadAllBytes((Join-Path $repoRoot "install.ps1"))
    if ([Convert]::ToBase64String($embedded.ToArray()) -ne [Convert]::ToBase64String($expected)) { return "the embedded install.ps1 differs from the repository's" }
    return $true
}

Test-Case -Name "EX2 the exe runs install.ps1 and hands back its exit code: a failed clone gives 1, a harness that exits 7 gives 7" -Check {
    $target = Join-Path (New-ScratchRoot) "fresh-tazuna"
    $clone = Invoke-Launcher -Target $target
    if ($clone.Code -ne 1) { return "a failed clone returned $($clone.Code), expected 1: $($clone.Output)" }
    if ($clone.Calls -notcontains "git clone https://github.com/AlfredoNeeto/tazuna.git $target") { return ("install.ps1 did not clone into the target: " + ($clone.Calls -join "; ")) }

    $seven = Invoke-Launcher -Target (New-FakeHarness -ExitCode 7)
    if ($seven.Code -ne 7) { return "a harness that exits 7 returned $($seven.Code): $($seven.Output)" }
    if ($seven.Output -match "Press Enter") { return "started from a console, the exe still waited for Enter" }
    return $true
}

Test-Case -Name "EX3 a double-clicked exe, alone on its console, waits for Enter after the installer ends" -Check {
    $marker = Join-Path (New-ScratchRoot) "bootstrap-ran.txt"
    $target = New-FakeHarness -ExitCode 0 -Marker $marker
    $saved = $env:TAZUNA_PATH
    $process = $null

    try {
        $env:TAZUNA_PATH = $target
        # why: ShellExecute gives the exe a console of its own, as a double-click does; hidden, so no window flashes.
        $process = Start-Process -FilePath (Get-BuiltLauncher) -WindowStyle Hidden -PassThru
        $deadline = (Get-Date).AddSeconds(30)
        while ((-not (Test-Path -LiteralPath $marker)) -and ((Get-Date) -lt $deadline)) { Start-Sleep -Milliseconds 200 }
        if (-not (Test-Path -LiteralPath $marker)) { return "the installer never ran" }

        Start-Sleep -Seconds 3
        if ($process.HasExited) { return "the exe closed its own console without waiting (exit $($process.ExitCode))" }
        return $true
    }
    finally {
        $env:TAZUNA_PATH = $saved
        if ($process -and (-not $process.HasExited)) { $process.Kill() }
    }
}

Test-Case -Name "EX4 build-installer -WhatIf writes nothing, and without csc.exe it exits 1 naming it" -Check {
    $out = Join-Path (New-ScratchRoot) "would-be-dist"
    $previous = $ErrorActionPreference

    try {
        $ErrorActionPreference = "Continue"
        $global:LASTEXITCODE = 0
        $dry = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsRoot "build-installer.ps1") -OutDirectory $out -WhatIf 2>&1 | Out-String)
        $dryCode = $LASTEXITCODE

        $savedWindir = $env:WINDIR
        $env:WINDIR = New-ScratchRoot
        $global:LASTEXITCODE = 0
        $missing = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsRoot "build-installer.ps1") -OutDirectory $out 2>&1 | Out-String)
        $missingCode = $LASTEXITCODE
    }
    finally {
        if ($savedWindir) { $env:WINDIR = $savedWindir }
        $ErrorActionPreference = $previous
    }

    if (($dryCode -ne 0) -or ($dry -notmatch "WHATIF")) { return "-WhatIf: exit $dryCode, $dry" }
    if (Test-Path -LiteralPath $out) { return "-WhatIf created $out" }
    if (($missingCode -ne 1) -or ($missing -notmatch "csc\.exe")) { return "without csc: exit $missingCode, $missing" }
    return $true
}

Complete-TestFile
