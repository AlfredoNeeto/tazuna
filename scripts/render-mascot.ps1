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

    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {0} {1}" width="{0}" height="{1}" shape-rendering="crispEdges" role="img" aria-label="Frenatus, the Tazuna mascot: {2}">' -f $w, $h, $Sprite.Name) + "`n" +
        ('<g id="{0}">' -f $Sprite.Name) + (Get-SpriteRects -Sprite $Sprite) + '</g>' + "`n</svg>`n"
}

# The hero bleeds off the lower-right corner of both images, so its reins leave the picture on
# the right; the lead line continues its cavesson (row 44) leftwards, ending where the chin
# begins (column 13). Both are measured on the 64x64 master; docs/mascot.md fixes them.
$leadRow = 44
$leadEnd = 13

function Get-LeadSprite {
    # The lead line in hero pixels: leather over its shade over ink, like the reins, with a gold
    # ferrule three pixels wide centred on each of the given columns.
    param([int]$Width, [int[]]$Ferrules)

    $top = New-Object System.Text.StringBuilder
    $shade = New-Object System.Text.StringBuilder
    for ($x = 0; $x -lt $Width; $x++) {
        $ferrule = @($Ferrules | Where-Object { [Math]::Abs($_ - $x) -le 1 }).Count -gt 0
        if ($ferrule) { [void]$top.Append("O"); [void]$shade.Append("o") }
        else { [void]$top.Append("L"); [void]$shade.Append("l") }
    }
    $colours = New-Object System.Collections.Hashtable ([System.StringComparer]::Ordinal)
    $colours["L"] = "#6c4326"
    $colours["l"] = "#3a2215"
    $colours["O"] = "#d9a948"
    $colours["o"] = "#a5752a"
    $colours["K"] = "#0c0809"
    return [PSCustomObject]@{ Name = "lead"; Colours = $colours; Rows = @($top.ToString(), $shade.ToString(), ("K" * $Width)); Width = $Width; Height = 3 }
}

function Get-BannerSvg {
    param($Hero, $Lit)

    $tagline = "A verification gate for Claude Code and Cursor that works in any stack."

    $heroLeft = 960 - 64 * 3.5
    $heroTop = 300 - 64 * 3.5
    $leadLeft = 64
    $leadWidth = [int](($heroLeft + $leadEnd * 3.5 - $leadLeft) / 3.5)
    $leadTop = $heroTop + $leadRow * 3.5

    # why: each step sits over a ferrule of the lead, so its x is that ferrule's centre, in whole pixels.
    $steps = @(@("Plan", 19), @("Checks", 58), @("Build", 97), @("Verify", 136), @("Review", 175))
    $lead = Get-LeadSprite -Width $leadWidth -Ferrules @($steps | ForEach-Object { $_[1] })
    $row = foreach ($step in $steps) {
        $x = [int]($leadLeft + ($step[1] + 0.5) * 3.5)
        $text = '<text x="{0}" y="218" text-anchor="middle" font-family="ui-monospace, ''Cascadia Code'', Consolas, monospace" font-size="20" fill="#e25a5c">{1}</text>' -f $x, $step[0]
        if ($step[0] -eq "Verify") { ('<g id="step-verify"><rect id="verify-lit" x="{0}" y="194" width="84" height="34" rx="17" fill="#d9a948" fill-opacity="0.18" stroke="#d9a948" stroke-width="2"/>' -f ($x - 42)) + $text + '</g>' }
        else { $text }
    }

    # why: CSS keyframes rather than SMIL, because only CSS answers prefers-reduced-motion; the lit frames rest hidden.
    $style = @(
        '<style>',
        '#frenatus-lit, #verify-lit { opacity: 0; animation: lit 6s steps(1, end) infinite; }',
        '#frenatus { animation: rest 6s steps(1, end) infinite; }',
        '@keyframes lit { 0%, 66.66% { opacity: 0; } 66.67%, 100% { opacity: 1; } }',
        '@keyframes rest { 0%, 66.66% { opacity: 1; } 66.67%, 100% { opacity: 0; } }',
        '@media (prefers-reduced-motion: reduce) { #frenatus, #frenatus-lit, #verify-lit { animation: none; } }',
        '</style>'
    ) -join "`n"

    $place = 'transform="translate({0} {1}) scale(3.5)" shape-rendering="crispEdges"' -f $heroLeft, $heroTop

    # invariant: one dark card serves GitHub's light and dark themes; the frame is drawn again over the horse it crops.
    return @(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 960 300" width="960" height="300" role="img" aria-label="Tazuna: Frenatus, the mascot, a barded horse whose lead line runs under the five steps; the seal on its chanfron lights up with the Verify step">',
        $style,
        '<rect x="1" y="1" width="958" height="298" rx="18" fill="#1c1419" stroke="#6a4716" stroke-width="2"/>',
        '<clipPath id="card"><rect x="1" y="1" width="958" height="298" rx="18"/></clipPath>',
        '<text x="64" y="118" font-family="Georgia, ''Times New Roman'', serif" font-size="64" fill="#f9e7a8">Tazuna</text>',
        ('<text x="66" y="160" font-family="ui-sans-serif, ''Segoe UI'', system-ui, sans-serif" font-size="18" fill="#e2d6bb">{0}</text>' -f $tagline),
        (('<g id="lead" transform="translate({0} {1}) scale(3.5)" shape-rendering="crispEdges">' -f $leadLeft, $leadTop) + (Get-SpriteRects -Sprite $lead) + '</g>'),
        ($row -join "`n"),
        '<g clip-path="url(#card)">',
        ('<g id="frenatus" ' + $place + '>' + (Get-SpriteRects -Sprite $Hero) + '</g>'),
        ('<g id="frenatus-lit" ' + $place + '>' + (Get-SpriteRects -Sprite $Lit) + '</g>'),
        '</g>',
        '<rect x="1" y="1" width="958" height="298" rx="18" fill="none" stroke="#6a4716" stroke-width="2"/>',
        '</svg>'
    ) -join "`n"
}

# ---------------------------------------------------------------------------
# PNG: the social preview, 1280x640, the banner's card at twice the scale.
# ---------------------------------------------------------------------------
function Add-SpritePixels {
    param($Graphics, $Sprite, [int]$Left, [int]$Top, [int]$Scale)

    $brushes = @{}
    try {
        for ($y = 0; $y -lt $Sprite.Height; $y++) {
            $row = $Sprite.Rows[$y]
            for ($x = 0; $x -lt $Sprite.Width; $x++) {
                $ch = [string]$row[$x]
                if ($ch -eq ".") { continue }
                $hex = $Sprite.Colours[$ch]
                if (-not $brushes.ContainsKey($hex)) { $brushes[$hex] = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($hex)) }
                $Graphics.FillRectangle($brushes[$hex], $Left + $x * $Scale, $Top + $y * $Scale, $Scale, $Scale)
            }
        }
    }
    finally {
        foreach ($brush in $brushes.Values) { $brush.Dispose() }
    }
}

function Get-SocialPreviewBytes {
    param($Hero)

    Add-Type -AssemblyName System.Drawing

    $arrow = [string][char]0x2192
    $tagline = "A verification gate for Claude Code and Cursor that works in any stack."
    $bitmap = New-Object System.Drawing.Bitmap 1280, 640
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)

    try {
        $graphics.Clear([System.Drawing.ColorTranslator]::FromHtml("#1c1419"))
        $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

        $scale = 7
        $left = 1280 - $Hero.Width * $scale
        $top = 640 - $Hero.Height * $scale
        $leadWidth = [int][Math]::Floor(($left + $leadEnd * $scale - 96) / $scale)
        $leadLeft = $left + ($leadEnd - $leadWidth) * $scale

        Add-SpritePixels -Graphics $graphics -Sprite (Get-LeadSprite -Width $leadWidth -Ferrules @()) -Left $leadLeft -Top ($top + $leadRow * $scale) -Scale $scale
        Add-SpritePixels -Graphics $graphics -Sprite $Hero -Left $left -Top $top -Scale $scale

        $gilt = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml("#f9e7a8"))
        $crimson = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml("#e25a5c"))
        $bone = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml("#e2d6bb"))
        $frame = New-Object System.Drawing.Pen ([System.Drawing.ColorTranslator]::FromHtml("#6a4716")), 4

        $graphics.DrawString("Tazuna", (New-Object System.Drawing.Font("Georgia", 96)), $gilt, 80, 96)
        $graphics.DrawString($tagline, (New-Object System.Drawing.Font("Segoe UI", 22)), $bone, (New-Object System.Drawing.RectangleF(100, 270, 660, 120)))
        $graphics.DrawString("plan $arrow checks $arrow build $arrow verify $arrow review", (New-Object System.Drawing.Font("Consolas", 20)), $crimson, 100, 440)
        $graphics.DrawRectangle($frame, 2, 2, 1275, 635)

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
