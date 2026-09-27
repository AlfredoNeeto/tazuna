<#
.SYNOPSIS
    Renders the Tazuna mascot from its text sources.

.DESCRIPTION
    Reads every docs\assets\tazuna\src\<name>.txt (a palette header, a line
    "---", then rows of one character per pixel, "." transparent), validates
    all of them against the palette listed in docs\mascot.md, and only then
    writes:

      docs\assets\tazuna\<name>.svg      one per source
      docs\assets\banner.svg             the README header, animated
      docs\assets\social-preview.png     1280x640, for GitHub's social preview

    A file is written only when its bytes would change, so a second run with
    no source change writes nothing. Any invalid source stops the run before
    the first write, naming the file and the row or the colour.

    Windows PowerShell 5.1. System.Drawing is used for the one PNG.

.PARAMETER WhatIf
    Lists the files that would be written and writes none.

.EXAMPLE
    .\scripts\render-mascot.ps1
    .\scripts\render-mascot.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param()

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$assets = Join-Path $repoRoot "docs\assets"
$tazuna = Join-Path $assets "tazuna"
$sourceDir = Join-Path $tazuna "src"
$bible = Join-Path $repoRoot "docs\mascot.md"

$requiredNames = @("view-front", "expr-success")

$utf8 = New-Object System.Text.UTF8Encoding($false)

function Get-RelativeAssetPath {
    param([string]$Path)
    return $Path.Substring($repoRoot.Length).TrimStart("\").Replace("\", "/")
}

# ---------------------------------------------------------------------------
# The palette is the hex list under "## Color palette" in the bible.
# ---------------------------------------------------------------------------
function Get-Palette {
    if (-not (Test-Path -LiteralPath $bible)) { throw "no palette: $bible does not exist" }
    $text = [System.IO.File]::ReadAllText($bible)
    $match = [regex]::Match($text, '(?s)^## Color palette\s*$(.*?)(?=^## |\z)', [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if (-not $match.Success) { throw "no '## Color palette' section in docs/mascot.md" }
    $colours = @([regex]::Matches($match.Groups[1].Value, '#[0-9a-f]{6}') | ForEach-Object { $_.Value } | Select-Object -Unique)
    if ($colours.Count -eq 0) { throw "the '## Color palette' section of docs/mascot.md lists no #rrggbb colour" }
    return $colours
}

# ---------------------------------------------------------------------------
# Sources: validate every one before anything is written.
# ---------------------------------------------------------------------------
function Read-Sprite {
    param([string]$Path, [string[]]$Palette, [System.Collections.ArrayList]$Problems)

    $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $relative = Get-RelativeAssetPath -Path $Path
    $lines = [System.IO.File]::ReadAllLines($Path)
    # why: @{} ignores case, and the palette gives "a" and "A" different colours.
    $colours = New-Object System.Collections.Hashtable ([System.StringComparer]::Ordinal)
    $rows = @()
    $inGrid = $false
    $lineNumber = 0
    $gridRow = 0
    $width = -1

    foreach ($line in $lines) {

        $lineNumber++

        if (-not $inGrid) {
            if ($line -eq "---") { $inGrid = $true; continue }
            if ($line -match '^(\S) (#[0-9a-f]{6})$') {
                if ($Palette -notcontains $Matches[2]) {
                    [void]$Problems.Add("$relative`: colour $($Matches[2]) is not in the palette of docs/mascot.md")
                }
                $colours[$Matches[1]] = $Matches[2]
                continue
            }
            [void]$Problems.Add("$relative`: line $lineNumber is neither '<char> #rrggbb' nor '---'")
            continue
        }

        if ($line -eq "") { continue }

        $gridRow++

        if ($width -lt 0) { $width = $line.Length }

        if ($line.Length -ne $width) {
            [void]$Problems.Add("$relative`: row $gridRow has $($line.Length) characters, expected $width")
        }

        foreach ($ch in $line.ToCharArray()) {
            if (($ch -ne ".") -and (-not $colours.ContainsKey([string]$ch))) {
                [void]$Problems.Add("$relative`: row $gridRow has the undeclared character '$ch'")
                break
            }
        }

        $rows += $line
    }

    if (-not $inGrid) { [void]$Problems.Add("$relative`: no '---' line separates the palette from the grid") }
    if ($rows.Count -eq 0) { [void]$Problems.Add("$relative`: no grid rows") }

    return [PSCustomObject]@{
        Name    = $name
        Colours = $colours
        Rows    = $rows
        Width   = [Math]::Max($width, 0)
        Height  = $rows.Count
    }
}

# ---------------------------------------------------------------------------
# SVG: one path per colour, one "M x y h w v1 h -w z" run per horizontal run.
# ---------------------------------------------------------------------------
function Get-SpriteRects {
    param($Sprite)

    $runs = New-Object System.Collections.Specialized.OrderedDictionary ([System.StringComparer]::Ordinal)

    for ($y = 0; $y -lt $Sprite.Height; $y++) {

        $row = $Sprite.Rows[$y]
        $x = 0

        while ($x -lt $Sprite.Width) {

            $ch = [string]$row[$x]

            if ($ch -eq ".") { $x++; continue }

            $start = $x
            while (($x -lt $Sprite.Width) -and ([string]$row[$x] -ceq $ch)) { $x++ }

            if (-not $runs.Contains($ch)) { $runs[$ch] = New-Object System.Text.StringBuilder }
            [void]$runs[$ch].Append("M$start ${y}h$($x - $start)v1h-$($x - $start)z")
        }
    }

    $out = New-Object System.Text.StringBuilder

    foreach ($ch in $runs.Keys) {
        [void]$out.Append('<path fill="').Append($Sprite.Colours[$ch]).Append('" d="').Append($runs[$ch].ToString()).Append('"/>')
    }

    return $out.ToString()
}

function Get-SpriteSvg {
    param($Sprite)

    $w = $Sprite.Width
    $h = $Sprite.Height

    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {0} {1}" width="{0}" height="{1}" shape-rendering="crispEdges" role="img" aria-label="Tameshi, the Tazuna mascot: {2}">' -f $w, $h, $Sprite.Name) + "`n" +
        ('<g id="{0}">' -f $Sprite.Name) + (Get-SpriteRects -Sprite $Sprite) + '</g>' + "`n</svg>`n"
}

function Get-BannerSvg {
    param($Hero, $Lit)

    $tagline = "A verification gate for Claude Code that works in any stack."

    $sparkles = @(@(336, 42), @(924, 34), @(906, 250)) | ForEach-Object {
        '<g fill="#d97757"><rect x="{0}" y="{1}" width="4" height="20"/><rect x="{2}" y="{3}" width="20" height="4"/></g>' -f $_[0], $_[1], ($_[0] - 8), ($_[1] + 8)
    }

    $steps = @(@("Plan", 386), @("Checks", 482), @("Build", 584), @("Verify", 686), @("Review", 794))
    $row = foreach ($step in $steps) {
        $text = '<text x="{0}" y="238" text-anchor="middle" font-family="ui-monospace, ''Cascadia Code'', Consolas, monospace" font-size="20" fill="#d97757">{1}</text>' -f $step[1], $step[0]
        if ($step[0] -eq "Verify") { '<g id="step-verify"><rect id="verify-lit" x="644" y="214" width="84" height="34" rx="17" fill="#e3b25b" fill-opacity="0.18" stroke="#e3b25b" stroke-width="2"/>' + $text + '</g>' }
        else { $text }
    }
    $arrows = @(430, 532, 634, 740) | ForEach-Object {
        '<path d="M{0} 226l6 6-6 6" fill="none" stroke="#8a877d" stroke-width="2"/>' -f $_
    }

    # why: CSS keyframes rather than SMIL, because only CSS answers prefers-reduced-motion; the lit frames rest hidden.
    $style = @(
        '<style>',
        '#tameshi-lit, #verify-lit { opacity: 0; animation: lit 6s steps(1, end) infinite; }',
        '#tameshi { animation: rest 6s steps(1, end) infinite; }',
        '@keyframes lit { 0%, 66.66% { opacity: 0; } 66.67%, 100% { opacity: 1; } }',
        '@keyframes rest { 0%, 66.66% { opacity: 1; } 66.67%, 100% { opacity: 0; } }',
        '@media (prefers-reduced-motion: reduce) { #tameshi, #tameshi-lit, #verify-lit { animation: none; } }',
        '</style>'
    ) -join "`n"

    # invariant: one ink card serves GitHub's light and dark themes; the sprite's rim light is drawn for the dark.
    return @(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 960 300" width="960" height="300" role="img" aria-label="Tazuna: Tameshi, the mascot, beside the project title; the seal on its crest lights up with the Verify step">',
        $style,
        '<rect x="1" y="1" width="958" height="298" rx="18" fill="#141413" stroke="#3d3929" stroke-width="2"/>',
        ($sparkles -join ""),
        ('<g id="tameshi" transform="translate(64 38) scale(3.5)" shape-rendering="crispEdges">' + (Get-SpriteRects -Sprite $Hero) + '</g>'),
        ('<g id="tameshi-lit" transform="translate(64 38) scale(3.5)" shape-rendering="crispEdges">' + (Get-SpriteRects -Sprite $Lit) + '</g>'),
        '<text x="360" y="130" font-family="Georgia, ''Times New Roman'', serif" font-size="64" fill="#faf9f5">Tazuna</text>',
        ('<text x="362" y="176" font-family="ui-sans-serif, ''Segoe UI'', system-ui, sans-serif" font-size="18" fill="#b0aea5">{0}</text>' -f $tagline),
        ($row -join "`n"),
        ($arrows -join ""),
        '</svg>'
    ) -join "`n"
}

# ---------------------------------------------------------------------------
# PNG: the social preview, 1280x640 on Claude ink.
# ---------------------------------------------------------------------------
function Get-SocialPreviewBytes {
    param($Hero)

    Add-Type -AssemblyName System.Drawing

    $arrow = [string][char]0x2192
    $tagline = "A verification gate for Claude Code that works in any stack."
    $bitmap = New-Object System.Drawing.Bitmap 1280, 640
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)

    try {
        $graphics.Clear([System.Drawing.ColorTranslator]::FromHtml("#141413"))
        $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

        $scale = 7
        $left = 96
        $top = 96

        for ($y = 0; $y -lt $Hero.Height; $y++) {
            $row = $Hero.Rows[$y]
            for ($x = 0; $x -lt $Hero.Width; $x++) {
                $ch = $row[$x]
                if ($ch -eq ".") { continue }
                $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($Hero.Colours[[string]$ch]))
                $graphics.FillRectangle($brush, $left + $x * $scale, $top + $y * $scale, $scale, $scale)
                $brush.Dispose()
            }
        }

        $cream = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml("#faf9f5"))
        $terracotta = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml("#d97757"))
        $grey = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml("#b0aea5"))

        $graphics.DrawString("Tazuna", (New-Object System.Drawing.Font("Georgia", 96)), $cream, 600, 170)
        $graphics.DrawString("plan $arrow checks $arrow build $arrow verify $arrow review", (New-Object System.Drawing.Font("Consolas", 20)), $terracotta, 612, 330)
        $graphics.DrawString($tagline, (New-Object System.Drawing.Font("Segoe UI", 22)), $grey, (New-Object System.Drawing.RectangleF(612, 390, 600, 120)))

        $stream = New-Object System.IO.MemoryStream
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        return $stream.ToArray()
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

# ---------------------------------------------------------------------------
# Run: validate everything, build everything, then write what changed.
# ---------------------------------------------------------------------------
$palette = Get-Palette
$problems = New-Object System.Collections.ArrayList
$sprites = @{}

if (-not (Test-Path -LiteralPath $sourceDir)) { throw "no sources: $sourceDir does not exist" }

foreach ($file in (Get-ChildItem -LiteralPath $sourceDir -Filter *.txt | Sort-Object Name)) {
    $sprite = Read-Sprite -Path $file.FullName -Palette $palette -Problems $problems
    $sprites[$sprite.Name] = $sprite
}

foreach ($name in $requiredNames) {
    if (-not $sprites.ContainsKey($name)) { [void]$problems.Add("docs/assets/tazuna/src/$name.txt is missing; the banner needs it") }
}

if ($problems.Count -gt 0) {
    foreach ($problem in $problems) { Write-Host "INVALID  $problem" }
    Write-Host ""
    Write-Host "$($problems.Count) problem(s); nothing was written."
    exit 1
}

$outputs = @()

foreach ($name in ($sprites.Keys | Sort-Object)) {
    $outputs += [PSCustomObject]@{ Path = (Join-Path $tazuna "$name.svg"); Bytes = $utf8.GetBytes((Get-SpriteSvg -Sprite $sprites[$name])) }
}

$outputs += [PSCustomObject]@{ Path = (Join-Path $assets "banner.svg"); Bytes = $utf8.GetBytes((Get-BannerSvg -Hero $sprites["view-front"] -Lit $sprites["expr-success"])) }
$outputs += [PSCustomObject]@{ Path = (Join-Path $assets "social-preview.png"); Bytes = (Get-SocialPreviewBytes -Hero $sprites["view-front"]) }

$written = 0
$unchanged = 0

foreach ($output in $outputs) {

    $relative = Get-RelativeAssetPath -Path $output.Path

    if (-not $PSCmdlet.ShouldProcess($relative, "write")) { continue }

    if (Test-Path -LiteralPath $output.Path) {
        $existing = [System.IO.File]::ReadAllBytes($output.Path)
        if ([System.Convert]::ToBase64String($existing) -eq [System.Convert]::ToBase64String($output.Bytes)) {
            $unchanged++
            continue
        }
    }

    $directory = Split-Path -Parent $output.Path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }

    [System.IO.File]::WriteAllBytes($output.Path, $output.Bytes)
    Write-Host "wrote    $relative"
    $written++
}

Write-Host ""
Write-Host "$written file(s) written, $unchanged unchanged."
exit 0
