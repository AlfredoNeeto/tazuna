<#
.SYNOPSIS
    Builds tazuna-setup.exe, a double-click start for the installer.

.DESCRIPTION
    Compiles installer\TazunaSetup.cs with the csc.exe of .NET Framework 4, which
    every Windows has, embedding the repository's install.ps1 and an icon drawn
    from docs\assets\tazuna\src\icon-32.txt. Nothing is downloaded and no tool is
    installed.

    The exe is not signed. Downloaded from the internet, Windows SmartScreen
    shows it as coming from an unknown publisher; signing needs a code signing
    certificate.

.PARAMETER OutDirectory
    Where to write tazuna-setup.exe. Defaults to dist\ in the repository.

.EXAMPLE
    .\scripts\build-installer.ps1

.EXAMPLE
    .\scripts\build-installer.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$OutDirectory
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "lib\Console.psm1") -Force

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutDirectory) { $OutDirectory = Join-Path $repoRoot "dist" }
$exe = Join-Path $OutDirectory "tazuna-setup.exe"

function New-IconFile {
    <#
        Writes an .ico holding the sprite at 16, 32, 64, 128 and 256 pixels, each a PNG
        (Windows reads PNG entries since Vista). Scaled nearest-neighbour, so pixel art
        stays sharp.
    #>
    param([object[]]$Grid, [string]$Path)

    Add-Type -AssemblyName System.Drawing

    $height = $Grid.Count
    $width = $Grid[0].Count
    $base = New-Object System.Drawing.Bitmap $width, $height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)

    for ($y = 0; $y -lt $height; $y++) {
        for ($x = 0; $x -lt $width; $x++) {
            if ($Grid[$y][$x]) { $base.SetPixel($x, $y, [System.Drawing.ColorTranslator]::FromHtml($Grid[$y][$x])) }
        }
    }

    $images = @()

    foreach ($size in @(16, 32, 64, 128, 256)) {

        $bitmap = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
        $graphics.DrawImage($base, 0, 0, $size, $size)
        $graphics.Dispose()

        $png = New-Object System.IO.MemoryStream
        $bitmap.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
        $bitmap.Dispose()

        $images += [PSCustomObject]@{ Size = $size; Bytes = $png.ToArray() }
    }

    $base.Dispose()

    # invariant: ICONDIR (6 bytes), one 16-byte ICONDIRENTRY per image, then the images in that order.
    $file = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter $file
    $writer.Write([uint16]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]$images.Count)

    $offset = 6 + (16 * $images.Count)

    foreach ($image in $images) {
        $side = $image.Size
        if ($side -ge 256) { $side = 0 }
        $writer.Write([byte]$side)
        $writer.Write([byte]$side)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]32)
        $writer.Write([uint32]$image.Bytes.Length)
        $writer.Write([uint32]$offset)
        $offset += $image.Bytes.Length
    }

    foreach ($image in $images) { $writer.Write($image.Bytes) }

    $writer.Flush()
    [System.IO.File]::WriteAllBytes($Path, $file.ToArray())
    $writer.Dispose()
}

Write-Banner -Title "Tazuna installer" -Command "build"

$compiler = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe" }

if (-not (Test-Path -LiteralPath $compiler)) {
    Write-Status -Label "FAIL" -Detail "csc.exe, the C# compiler of .NET Framework 4, was not found under $env:WINDIR\Microsoft.NET"
    Write-Host ""
    exit 1
}

if ($WhatIfPreference -or (-not $PSCmdlet.ShouldProcess($exe, "Build the installer"))) {
    Write-Status -Label "WHATIF" -Detail "would build $exe"
    Write-Host ""
    exit 0
}

$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("tazuna-build-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Path $stage -Force | Out-Null

try {
    $icon = Join-Path $stage "tazuna.ico"
    New-IconFile -Grid (Get-SpritePixels -Path (Join-Path $repoRoot "docs\assets\tazuna\src\icon-32.txt")) -Path $icon

    New-Item -ItemType Directory -Path $OutDirectory -Force | Out-Null

    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $global:LASTEXITCODE = 0
    # why: csc embeds its default manifest, which asks for asInvoker; without one, a name with "setup"
    # in it would make Windows ask for administrator rights the per-user install does not need.
    $output = @(& $compiler /nologo /target:exe /platform:anycpu "/out:$exe" "/win32icon:$icon" `
        ("/resource:" + (Join-Path $repoRoot "install.ps1") + ",install.ps1") (Join-Path $repoRoot "installer\TazunaSetup.cs") 2>&1)
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous

    if ($code -ne 0) {
        foreach ($line in $output) { Write-Host "  $line" }
        Write-Status -Label "FAIL" -Detail "csc exited $code"
        Write-Host ""
        exit 1
    }

    Write-Status -Label "OK" -Detail ("built {0} ({1:N0} KB)" -f $exe, ((Get-Item -LiteralPath $exe).Length / 1KB))
    Write-Host "            It is not signed: SmartScreen names an unknown publisher when it is downloaded."
    Write-Host ""
}
finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

exit 0
