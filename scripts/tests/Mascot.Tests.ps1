[CmdletBinding()]
param([switch]$SkipSlow, [string]$Only)

. (Join-Path $PSScriptRoot "TestKit.ps1")

try {

    Start-Section "Mascot"

    # The mascot, Frenatus. The geometry constants are the ones the consistency
    # checklist in docs/mascot.md fixes: rein lines, seal glass, halo window,
    # eye. They describe the drawing, so a redrawn master changes them here and in
    # docs/mascot.md together.

    $mascotSource = Join-Path $repoRoot "docs\assets\tazuna\src"
    $mascotAssets = Join-Path $repoRoot "docs\assets\tazuna"
    $mascotBible = Join-Path $repoRoot "docs\mascot.md"
    $mascotNames = @("view-front", "expr-success", "expr-error")
    $mascotKept = @($mascotNames + @("icon-32"))
    $mascotDeleted = @("view-side", "view-back", "view-34", "expr-neutral", "expr-happy", "expr-thinking", "expr-focused",
        "expr-confused", "expr-surprised", "pose-standing", "pose-coding", "pose-inspecting", "pose-planning", "pose-debugging", "pose-celebrating")
    $mascotInk = "#0c0809"

    function Read-SpriteGrid {
        # A text sprite: palette lines, "---", then rows. Read here on its own so the
        # test does not trust the renderer's parser.
        param([string]$Path)
        $colours = New-Object System.Collections.Hashtable ([System.StringComparer]::Ordinal)
        $rows = @()
        $inGrid = $false
        foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
            if (-not $inGrid) {
                if ($line -eq "---") { $inGrid = $true }
                elseif ($line -match '^(\S) (#[0-9a-f]{6})$') { $colours[$Matches[1]] = $Matches[2] }
                continue
            }
            if ($line -ne "") { $rows += $line }
        }
        $width = 0
        if ($rows.Count -gt 0) { $width = $rows[0].Length }
        return [PSCustomObject]@{ Colours = $colours; Rows = $rows; Width = $width; Height = $rows.Count }
    }

    function Get-MascotGrid { param([string]$Name) return (Read-SpriteGrid -Path (Join-Path $mascotSource "$Name.txt")) }

    function Get-SpriteHex {
        param($Grid, [int]$X, [int]$Y)
        $ch = [string]$Grid.Rows[$Y][$X]
        if ($ch -eq ".") { return $null }
        return $Grid.Colours[$ch]
    }

    function Get-RelativeLuminance {
        param([string]$Hex)
        $parts = @(1, 3, 5) | ForEach-Object {
            $v = [Convert]::ToInt32($Hex.Substring($_, 2), 16) / 255.0
            if ($v -le 0.03928) { $v / 12.92 } else { [Math]::Pow(($v + 0.055) / 1.055, 2.4) }
        }
        return 0.2126 * $parts[0] + 0.7152 * $parts[1] + 0.0722 * $parts[2]
    }

    function Get-ContrastRatio {
        param([string]$Hex, [string]$Against)
        $a = Get-RelativeLuminance -Hex $Hex
        $b = Get-RelativeLuminance -Hex $Against
        if ($a -lt $b) { $swap = $a; $a = $b; $b = $swap }
        return ($a + 0.05) / ($b + 0.05)
    }

    function New-TestGrid {
        # A sprite grid built in memory, for the planted negative controls.
        param([hashtable]$Colours, [string[]]$Rows)
        return [PSCustomObject]@{ Colours = $Colours; Rows = $Rows; Width = $Rows[0].Length; Height = $Rows.Count }
    }

    function Find-OpenEdge {
        # "x,y" of each pixel that is neither ink nor transparent and faces a transparent pixel.
        param($Grid)
        $hits = @()
        for ($y = 0; $y -lt $Grid.Height; $y++) {
            for ($x = 0; $x -lt $Grid.Width; $x++) {
                $hex = Get-SpriteHex -Grid $Grid -X $x -Y $y
                if (($null -eq $hex) -or ($hex -eq $mascotInk)) { continue }
                foreach ($step in @(@(1, 0), @(-1, 0), @(0, 1), @(0, -1))) {
                    $nx = $x + $step[0]
                    $ny = $y + $step[1]
                    if (($nx -lt 0) -or ($ny -lt 0) -or ($nx -ge $Grid.Width) -or ($ny -ge $Grid.Height)) { continue }
                    if ([string]$Grid.Rows[$ny][$nx] -eq ".") { $hits += "$x,$y"; break }
                }
            }
        }
        return $hits
    }

    function Find-ReinBreak {
        # "x,y" of the first pixel where the straight line from (X0,Y0) to (X1,Y1) is not rein
        # leather or a gold keeper - or, with -Shade, has no leather shade under it; $null if unbroken.
        param($Grid, [int]$X0, [int]$Y0, [int]$X1, [int]$Y1, [switch]$Shade)
        for ($x = $X0; $x -le $X1; $x++) {
            $y = [int][Math]::Round($Y0 + ($Y1 - $Y0) * ($x - $X0) / ($X1 - $X0))
            if (@("#6c4326", "#d9a948") -notcontains (Get-SpriteHex -Grid $Grid -X $x -Y $y)) { return "$x,$y" }
            if ($Shade -and ((Get-SpriteHex -Grid $Grid -X $x -Y ($y + 1)) -ne "#3a2215")) { return "$x,$($y + 1)" }
        }
        return $null
    }

    function Get-SealGlass {
        # The colours of the seal's glass: a Size x Size block from (X,Y).
        param($Grid, [int]$X, [int]$Y, [int]$Size)
        $glass = @()
        for ($dy = 0; $dy -lt $Size; $dy++) {
            for ($dx = 0; $dx -lt $Size; $dx++) { $glass += (Get-SpriteHex -Grid $Grid -X ($X + $dx) -Y ($Y + $dy)) }
        }
        return $glass
    }

    function Get-FigureCount {
        # Figure pixels in columns 0..Width-1 and rows 0..Height-1.
        param($Grid, [int]$Width, [int]$Height)
        $count = 0
        for ($y = 0; $y -lt $Height; $y++) {
            for ($x = 0; $x -lt $Width; $x++) { if ([string]$Grid.Rows[$y][$x] -ne ".") { $count++ } }
        }
        return $count
    }

    function Get-BibleSection {
        # The body of one "## " section of docs/mascot.md, up to the next "## " or the end.
        param([string]$Heading)
        $text = [System.IO.File]::ReadAllText($mascotBible)
        $match = [regex]::Match($text, '(?s)^## ' + [regex]::Escape($Heading) + '\s*$(.*?)(?=^## |\z)', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        if (-not $match.Success) { return $null }
        return $match.Groups[1].Value
    }

    function Get-MascotPalette {
        $section = Get-BibleSection -Heading "Color palette"
        if ($null -eq $section) { return @() }
        return @([regex]::Matches($section, '#[0-9a-f]{6}') | ForEach-Object { $_.Value } | Select-Object -Unique)
    }

    function Copy-MascotScratch {
        # scripts/render-mascot.ps1 and docs/, so the renderer runs with its fixed
        # relative paths and never touches the repository's own assets.
        $root = New-ScratchRoot
        New-Item -ItemType Directory -Path (Join-Path $root "scripts") -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $scriptsRoot "render-mascot.ps1") -Destination (Join-Path $root "scripts")
        Copy-Item -LiteralPath (Join-Path $repoRoot "docs") -Destination (Join-Path $root "docs") -Recurse
        return $root
    }

    function Get-RenderedOutput {
        param([string]$Root)
        return @(Get-ChildItem -LiteralPath (Join-Path $Root "docs\assets") -Recurse -File |
            Where-Object { ($_.Extension -in @(".svg", ".png")) -and ($_.DirectoryName -notlike "*\src") })
    }

    function Remove-RenderedOutput {
        param([string]$Root)
        foreach ($file in (Get-RenderedOutput -Root $Root)) { Remove-Item -LiteralPath $file.FullName -Force }
    }

    function Invoke-MascotRenderer {
        param([string]$Root, [string[]]$Arguments = @())
        $previous = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $global:LASTEXITCODE = 0
        $output = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "scripts\render-mascot.ps1") @Arguments 2>&1 | Out-String)
        $code = $LASTEXITCODE
        $ErrorActionPreference = $previous
        return [PSCustomObject]@{ Code = $code; Output = $output }
    }

    function Compare-RenderedSvg {
        # Names of the .svg files under docs/assets that differ between a render root and the repository.
        param([string]$Root)
        $differs = @()
        foreach ($mine in @(Get-ChildItem -LiteralPath $mascotAssets -Filter *.svg) + @(Get-Item -LiteralPath (Join-Path $repoRoot "docs\assets\banner.svg"))) {
            $theirs = Join-Path $Root (Get-CompatibleRelativePath -BasePath $repoRoot -TargetPath $mine.FullName)
            if (-not (Test-Path -LiteralPath $theirs)) { $differs += ($mine.Name + " (not rendered)"); continue }
            if (-not (Test-FileContentEqual -ReferenceFile $mine.FullName -DifferenceFile $theirs)) { $differs += $mine.Name }
        }
        return $differs
    }

    function Find-MissingAssetPath {
        # Every docs/assets/... path a markdown text references that does not exist under the root.
        param([string]$Root, [string]$Text)
        $missing = @()
        foreach ($hit in @([regex]::Matches($Text, 'docs/assets/[A-Za-z0-9_./-]+') | ForEach-Object { $_.Value } | Select-Object -Unique)) {
            if (-not (Test-Path -LiteralPath (Join-Path $Root $hit.Replace("/", "\")))) { $missing += $hit }
        }
        return $missing
    }

    Test-Case -Name "M3 the renderer rejects a colour outside the palette, names the file and the colour, and writes nothing" -Check {
        $root = Copy-MascotScratch
        Remove-RenderedOutput -Root $root
        $grid = @("Z #ff0000", "K #0c0809", "---") + @(1..64 | ForEach-Object { "Z" * 64 })
        Set-Content -LiteralPath (Join-Path $root "docs\assets\tazuna\src\bad-colour.txt") -Value ($grid -join "`n")
        $run = Invoke-MascotRenderer -Root $root
        if ($run.Code -eq 0) { return "the renderer exited 0" }
        if (-not $run.Output.Contains("bad-colour.txt")) { return "the output does not name bad-colour.txt: $($run.Output)" }
        if (-not $run.Output.Contains("#ff0000")) { return "the output does not name #ff0000" }
        $written = @(Get-RenderedOutput -Root $root)
        if ($written.Count -gt 0) { return ("written despite the rejection: " + (($written | ForEach-Object { $_.Name }) -join ", ")) }
        return $true
    }

    Test-Case -Name "M4 the bible's palette has 12 to 16 colours, among them the ink, the seal's garnet, the gold and the rein leather" -Check {
        $palette = @(Get-MascotPalette)
        if (($palette.Count -lt 12) -or ($palette.Count -gt 16)) { return "$($palette.Count) colours" }
        foreach ($required in @($mascotInk, "#3e0c13", "#d9a948", "#6c4326")) {
            if ($palette -notcontains $required) { return "$required is not in the palette" }
        }
        return $true
    }

    Test-Case -Name "M5 the icon source is 32x32 and every other source is 64x64" -Check {
        $icon = Get-MascotGrid -Name "icon-32"
        if (($icon.Width -ne 32) -or ($icon.Height -ne 32)) { return "icon-32.txt is $($icon.Width)x$($icon.Height)" }
        foreach ($name in $mascotNames) {
            $grid = Get-MascotGrid -Name $name
            if (($grid.Width -ne 64) -or ($grid.Height -ne 64)) { return "$name.txt is $($grid.Width)x$($grid.Height)" }
        }
        return $true
    }

    Test-Case -Name "M6 ink closes every sprite's silhouette: no other colour faces transparency" -Check {
        foreach ($name in $mascotKept) {
            $open = @(Find-OpenEdge -Grid (Get-MascotGrid -Name $name))
            if ($open.Count -gt 0) { return "$name`: $($open.Count) pixel(s) face transparency without ink, the first at $($open[0])" }
        }
        # why: a scan that never reports would pass here too; a gold pixel beside a transparent one must be reported.
        $planted = @(Find-OpenEdge -Grid (New-TestGrid -Colours @{ "K" = $mascotInk; "O" = "#d9a948" } -Rows @("KKK", "KO.", "KKK")))
        if (($planted -join ";") -ne "1,1") { return ("the planted grid was reported as: " + ($planted -join ";")) }
        return $true
    }

    Test-Case -Name "M7 two straight reins run unbroken from the bit to the right edge of every sprite" -Check {
        foreach ($name in $mascotNames) {
            $grid = Get-MascotGrid -Name $name
            foreach ($rein in @(@(24, 47, 63, 35), @(24, 55, 63, 43))) {
                $break = Find-ReinBreak -Grid $grid -X0 $rein[0] -Y0 $rein[1] -X1 $rein[2] -Y1 $rein[3] -Shade
                if ($null -ne $break) { return "$name`: the rein from ($($rein[0]),$($rein[1])) breaks at $break" }
            }
        }
        $icon = Get-MascotGrid -Name "icon-32"
        foreach ($rein in @(@(13, 27, 31, 19), @(12, 31, 31, 24))) {
            $break = Find-ReinBreak -Grid $icon -X0 $rein[0] -Y0 $rein[1] -X1 $rein[2] -Y1 $rein[3]
            if ($null -ne $break) { return "icon-32: the rein from ($($rein[0]),$($rein[1])) breaks at $break" }
        }
        # why: a scan that never finds a break would pass here too; one cut pixel on the upper rein must be found.
        $cut = Get-MascotGrid -Name "view-front"
        $cut.Rows[41] = $cut.Rows[41].Substring(0, 42) + "." + $cut.Rows[41].Substring(43)
        $found = Find-ReinBreak -Grid $cut -X0 24 -Y0 47 -X1 63 -Y1 35 -Shade
        if ($found -ne "42,41") { return "the cut rein was reported as: $found" }
        return $true
    }

    Test-Case -Name "M8 the seal's glass is dark at rest, bone and gold on pass, and cracked with ink on fail" -Check {
        foreach ($entry in @(@("view-front", 22, 30, 3), @("icon-32", 9, 16, 2))) {
            foreach ($hex in (Get-SealGlass -Grid (Get-MascotGrid -Name $entry[0]) -X $entry[1] -Y $entry[2] -Size $entry[3])) {
                if (@("#3e0c13", "#1c1419") -notcontains $hex) { return "$($entry[0]): the seal's glass holds $hex at rest" }
            }
        }
        foreach ($hex in (Get-SealGlass -Grid (Get-MascotGrid -Name "expr-success") -X 22 -Y 30 -Size 3)) {
            if (@("#e2d6bb", "#f9e7a8") -notcontains $hex) { return "expr-success: the seal's glass holds $hex, not bone or gold" }
        }
        $fissure = @(Get-SealGlass -Grid (Get-MascotGrid -Name "expr-error") -X 22 -Y 30 -Size 3 | Where-Object { $_ -eq $mascotInk })
        if ($fissure.Count -lt 2) { return "expr-error: the seal's glass holds $($fissure.Count) ink pixel(s), expected a fissure of at least 2" }
        return $true
    }

    Test-Case -Name "M9 every figure row of every sprite has a pixel at 3:1 contrast on GitHub dark and on white" -Check {
        foreach ($name in $mascotKept) {
            $grid = Get-MascotGrid -Name $name
            foreach ($ground in @("#0d1117", "#ffffff")) {
                for ($y = 0; $y -lt $grid.Height; $y++) {
                    $figure = $false
                    $readable = $false
                    for ($x = 0; $x -lt $grid.Width; $x++) {
                        $hex = Get-SpriteHex -Grid $grid -X $x -Y $y
                        if ($null -eq $hex) { continue }
                        $figure = $true
                        if ((Get-ContrastRatio -Hex $hex -Against $ground) -ge 3.0) { $readable = $true; break }
                    }
                    if ($figure -and (-not $readable)) { return "$name`: row $y has no pixel readable on $ground" }
                }
            }
        }
        return $true
    }

    Test-Case -Name "M10 the resplendor grows on pass and shrinks on fail" -Check {
        # invariant: columns 0-15, rows 0-33 hold only the halo and its rays, in every state.
        $count = @{}
        foreach ($name in $mascotNames) { $count[$name] = Get-FigureCount -Grid (Get-MascotGrid -Name $name) -Width 16 -Height 34 }
        if ($count["expr-success"] -le $count["view-front"]) { return "the halo holds $($count['expr-success']) pixels on pass and $($count['view-front']) at rest" }
        if ($count["expr-error"] -ge $count["view-front"]) { return "the halo holds $($count['expr-error']) pixels on fail and $($count['view-front']) at rest" }
        # why: a count that is always zero or always full would fail above only by luck; a planted grid must count exactly.
        if ((Get-FigureCount -Grid (New-TestGrid -Colours @{ "O" = "#d9a948" } -Rows @("O..", ".O.", "..O")) -Width 2 -Height 2) -ne 2) { return "the planted grid was miscounted" }
        return $true
    }

    Test-Case -Name "M11 only the 4 kept sprites have a source and a rendered svg, and there is no sheet" -Check {
        $expected = @($mascotKept | Sort-Object)
        $svgs = @(Get-ChildItem -LiteralPath $mascotAssets -File | ForEach-Object { $_.Name } | Sort-Object)
        if (($svgs -join ",") -ne (($expected | ForEach-Object { "$_.svg" }) -join ",")) { return ("docs/assets/tazuna holds: " + ($svgs -join ", ")) }
        $folders = @(Get-ChildItem -LiteralPath $mascotAssets -Directory | ForEach-Object { $_.Name })
        if (($folders -join ",") -ne "src") { return ("folders: " + ($folders -join ", ")) }
        $sources = @(Get-ChildItem -LiteralPath $mascotSource -Force | ForEach-Object { $_.Name } | Sort-Object)
        if (($sources -join ",") -ne (($expected | ForEach-Object { "$_.txt" }) -join ",")) { return ("src holds: " + ($sources -join ", ")) }
        if (Test-Path -LiteralPath (Join-Path $mascotAssets "sheet.svg")) { return "sheet.svg exists" }
        return $true
    }

    Test-Case -Name "M12 success and error differ by shape, not only by colour" -Check {
        $success = Get-MascotGrid -Name "expr-success"
        $failure = Get-MascotGrid -Name "expr-error"
        $different = 0
        for ($y = 0; $y -lt 64; $y++) {
            for ($x = 0; $x -lt 64; $x++) {
                if (([string]$success.Rows[$y][$x] -eq ".") -ne ([string]$failure.Rows[$y][$x] -eq ".")) { $different++ }
            }
        }
        if ($different -ge 4) { return $true }
        return "the transparency masks differ in $different pixel(s), expected at least 4"
    }

    Test-Case -Name "M14 the bible has the 14 sections of the brief in order" -Check {
        $expected = @("Project interpretation", "Design objective", "Concept 1", "Concept 2", "Concept 3", "Recommended direction",
            "Character bible", "Harness architecture", "Pixel art specification", "Color palette", "Character sheet", "GitHub usage",
            "Image generation prompt", "Consistency checklist")
        $text = [System.IO.File]::ReadAllText($mascotBible)
        $found = @([regex]::Matches($text, '(?m)^## (.+?)\s*$') | ForEach-Object { $_.Groups[1].Value })
        if (($found -join "|") -ne ($expected -join "|")) { return ("sections: " + ($found -join " | ")) }
        return $true
    }

    Test-Case -Name "M15 the character bible answers the 19 fields in order" -Check {
        $expected = @("Name", "Role", "Concept", "Personality", "Visual identity", "Body proportions", "Head design", "Eyes", "Face",
            "Harness design", "Primary colors", "Secondary colors", "Accent colors", "Mandatory features", "Forbidden features",
            "Pixel-art rules", "Signature silhouette", "Accessories", "Expression system")
        $section = Get-BibleSection -Heading "Character bible"
        if ($null -eq $section) { return "no '## Character bible' section" }
        $found = @([regex]::Matches($section, '(?m)^### (.+?)\s*$') | ForEach-Object { $_.Groups[1].Value })
        if (($found -join "|") -ne ($expected -join "|")) { return ("fields: " + ($found -join " | ")) }
        return $true
    }

    Test-Case -Name "M16 the image-generation prompt names the palette, the grid, the Andalusian horse and the mood-only rule" -Check {
        $prompt = Get-BibleSection -Heading "Image generation prompt"
        if ($null -eq $prompt) { return "no '## Image generation prompt' section" }
        foreach ($colour in @(Get-MascotPalette)) {
            if (-not $prompt.Contains($colour)) { return "the prompt does not name $colour" }
        }
        foreach ($token in @("64x64", "Andalusian", "mood only")) {
            if (-not $prompt.Contains($token)) { return "the prompt does not say '$token'" }
        }
        return $true
    }

    Test-Case -Name "M17 the forbidden features name the Penitent One, Torrent and every agent's logo" -Check {
        $bible = Get-BibleSection -Heading "Character bible"
        $match = [regex]::Match($bible, '(?s)^### Forbidden features\s*$(.*?)(?=^### |\z)', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        if (-not $match.Success) { return "no '### Forbidden features' field" }
        foreach ($name in @("Penitent One", "Torrent", "Anthropic logo", "Cursor logo")) {
            if (-not $match.Groups[1].Value.Contains($name)) { return "$name is not forbidden by name" }
        }
        return $true
    }

    Test-Case -Name "M18 the banner keeps its viewBox, is titled Tazuna and carries the mascot" -Check {
        $banner = [System.IO.File]::ReadAllText((Join-Path $repoRoot "docs\assets\banner.svg"))
        if (-not $banner.Contains('viewBox="0 0 960 300"')) { return "the viewBox is not 0 0 960 300" }
        if ([regex]::Matches($banner, '<text[^>]*>Tazuna</text>').Count -ne 1) { return "no text element reading exactly Tazuna" }
        $group = [regex]::Match($banner, '(?s)<g id="frenatus"[^>]*>(.*?)</g>')
        if (-not $group.Success) { return "no <g id=`"frenatus`">" }
        $runs = [regex]::Matches($group.Groups[1].Value, 'M\d+ \d+h\d+').Count
        if ($runs -lt 200) { return "the mascot group has $runs pixel runs, expected at least 200" }
        return $true
    }

    Test-Case -Name "M19 the README shows the banner in its header and a mascot sprite in its footer" -Check {
        $header = $readme.Substring(0, $readme.IndexOf("`n## "))
        if (-not $header.Contains('<img src="docs/assets/banner.svg"')) { return "no banner image before the first section" }
        $footer = $readme.Substring($readme.LastIndexOf("`n## "))
        $sprite = [regex]::Match($footer, '<img src="docs/assets/tazuna/([a-z0-9-]+)\.svg"')
        if (-not $sprite.Success) { return "no docs/assets/tazuna sprite after the last section" }
        if ($mascotKept -notcontains $sprite.Groups[1].Value) { return "the footer sprite '$($sprite.Groups[1].Value)' is not one of the 4 kept sprites" }
        return $true
    }

    Test-Case -Name "M20 the Acknowledgments credit Frenatus as the original mascot, the Tech Leads Club and the video, and Clawd is gone" -Check {
        $credits = Get-ReadmeSection -Heading "Acknowledgments"
        if ($null -eq $credits) { return "no '## Acknowledgments' section" }
        foreach ($token in @("Frenatus", "the original mascot", "Tech Leads Club", "https://www.youtube.com/watch?v=yKLedmyUDMA")) {
            if (-not $credits.Contains($token)) { return "the Acknowledgments do not contain '$token'" }
        }
        if ($readme -match "(?i)clawd") { return "the README still mentions Clawd" }
        return $true
    }

    Test-Case -Name "M21 the Clawd art is gone from the tree and from git" -Check {
        $old = "docs/assets/clawd-knight.svg"
        if (Test-Path -LiteralPath (Join-Path $repoRoot $old.Replace("/", "\"))) { return "$old exists" }
        $listed = (Invoke-GitCommand -RepositoryPath $repoRoot -Arguments @("ls-files", "--", $old)).Output
        if (@($listed | Where-Object { $_ }).Count -gt 0) { return "$old is tracked" }
        return $true
    }

    Test-Case -Name "M22 the social preview is a 1280x640 PNG" -Check {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $repoRoot "docs\assets\social-preview.png"))
        if (($bytes.Length -lt 24) -or ($bytes[1] -ne 0x50) -or ($bytes[2] -ne 0x4E) -or ($bytes[3] -ne 0x47)) { return "not a PNG" }
        # hazard: -shl on a [byte] stays a byte and wraps, so 0x05 shl 8 reads as 0; widen first.
        $width = ([int]$bytes[16] -shl 24) + ([int]$bytes[17] -shl 16) + ([int]$bytes[18] -shl 8) + [int]$bytes[19]
        $height = ([int]$bytes[20] -shl 24) + ([int]$bytes[21] -shl 16) + ([int]$bytes[22] -shl 8) + [int]$bytes[23]
        if (($width -ne 1280) -or ($height -ne 640)) { return "${width}x${height}" }
        return $true
    }

    Test-Case -Name "M23 every docs/assets path the README references exists, and a planted missing one is reported" -Check {
        $missing = @(Find-MissingAssetPath -Root $repoRoot -Text $readme)
        if ($missing.Count -gt 0) { return ("referenced but missing: " + ($missing -join ", ")) }
        # why: a scanner that never reports anything would pass here too; the planted path proves it can fail.
        $planted = @(Find-MissingAssetPath -Root (New-ScratchRoot) -Text '<img src="docs/assets/planted-missing.svg">')
        if (($planted -join ",") -ne "docs/assets/planted-missing.svg") { return ("the planted path was reported as: " + ($planted -join ", ")) }
        return $true
    }

    Test-Case -Name "M24 a second render with no source change writes nothing" -Check {
        $root = Copy-MascotScratch
        $first = Invoke-MascotRenderer -Root $root
        if ($first.Code -ne 0) { return "the first run exited $($first.Code): $($first.Output)" }
        $before = @{}
        foreach ($file in (Get-RenderedOutput -Root $root)) { $before[$file.FullName] = $file.LastWriteTimeUtc.Ticks }
        $second = Invoke-MascotRenderer -Root $root
        if ($second.Code -ne 0) { return "the second run exited $($second.Code)" }
        if (-not $second.Output.Contains("0 file(s) written")) { return "the second run did not report 0 file(s) written: $($second.Output)" }
        foreach ($file in (Get-RenderedOutput -Root $root)) {
            if ($before[$file.FullName] -ne $file.LastWriteTimeUtc.Ticks) { return "$($file.Name) was rewritten" }
        }
        return $true
    }

    Test-Case -Name "M25 the renderer refuses a ragged row and an undeclared character, names the row, and writes nothing" -Check {
        foreach ($fault in @(@("ragged", 5), @("undeclared", 3))) {
            $root = Copy-MascotScratch
            Remove-RenderedOutput -Root $root
            $path = Join-Path $root "docs\assets\tazuna\src\view-front.txt"
            $lines = [System.IO.File]::ReadAllLines($path)
            $separator = [array]::IndexOf($lines, "---")
            $index = $separator + $fault[1]
            if ($fault[0] -eq "ragged") { $lines[$index] = $lines[$index].Substring(1) }
            else { $lines[$index] = "?" + $lines[$index].Substring(1) }
            [System.IO.File]::WriteAllLines($path, $lines)
            $run = Invoke-MascotRenderer -Root $root
            if ($run.Code -eq 0) { return "$($fault[0]): the renderer exited 0" }
            if (-not $run.Output.Contains("view-front.txt")) { return "$($fault[0]): the output does not name view-front.txt: $($run.Output)" }
            if (-not $run.Output.Contains("row $($fault[1])")) { return "$($fault[0]): the output does not name row $($fault[1]): $($run.Output)" }
            $written = @(Get-RenderedOutput -Root $root)
            if ($written.Count -gt 0) { return ("$($fault[0]): written despite the rejection: " + (($written | ForEach-Object { $_.Name }) -join ", ")) }
        }
        return $true
    }

    Test-Case -Name "M26 render-mascot.ps1 -WhatIf names exactly the 6 files it would write and writes none" -Check {
        $root = Copy-MascotScratch
        Remove-RenderedOutput -Root $root
        $run = Invoke-MascotRenderer -Root $root -Arguments @("-WhatIf")
        if ($run.Code -ne 0) { return "exited $($run.Code): $($run.Output)" }
        $expected = @(@($mascotKept | ForEach-Object { "docs/assets/tazuna/$_.svg" }) + @("docs/assets/banner.svg", "docs/assets/social-preview.png") | Sort-Object)
        # why: the -WhatIf sentence is localised ("on target", "no destino"); the quoted path is not.
        $named = @([regex]::Matches($run.Output, '"(docs/[^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
        if (($named -join ",") -ne ($expected -join ",")) { return ("-WhatIf names: " + ($named -join ", ")) }
        $written = @(Get-RenderedOutput -Root $root)
        if ($written.Count -gt 0) { return ("-WhatIf wrote: " + (($written | ForEach-Object { $_.Name }) -join ", ")) }
        return $true
    }

    Test-Case -Name "M27 the committed svgs match a fresh render, and a changed source is reported by file" -Check {
        $root = Copy-MascotScratch
        Remove-RenderedOutput -Root $root
        $run = Invoke-MascotRenderer -Root $root
        if ($run.Code -ne 0) { return "the renderer exited $($run.Code): $($run.Output)" }
        $differs = @(Compare-RenderedSvg -Root $root)
        if ($differs.Count -gt 0) { return ("out of date with their sources: " + ($differs -join ", ") + " - run .\scripts\render-mascot.ps1") }

        # why: a comparison that never differs would pass here too; one changed pixel proves it can fail.
        $path = Join-Path $root "docs\assets\tazuna\src\view-front.txt"
        $lines = [System.IO.File]::ReadAllLines($path)
        $index = [array]::IndexOf($lines, "---") + 31
        $replacement = "c"
        if ([string]$lines[$index][30] -eq "c") { $replacement = "g" }
        $lines[$index] = $lines[$index].Substring(0, 30) + $replacement + $lines[$index].Substring(31)
        [System.IO.File]::WriteAllLines($path, $lines)
        $run = Invoke-MascotRenderer -Root $root
        if ($run.Code -ne 0) { return "the re-render exited $($run.Code): $($run.Output)" }
        $differs = @(Compare-RenderedSvg -Root $root)
        if ($differs -notcontains "view-front.svg") { return ("the changed source was reported as: " + ($differs -join ", ")) }
        return $true
    }

    Test-Case -Name "M32 a lower-case and an upper-case character keep their own colours in the reader and the render" -Check {
        $root = Copy-MascotScratch
        Remove-RenderedOutput -Root $root
        $path = Join-Path $root "docs\assets\tazuna\src\case-pair.txt"
        $grid = @("A #d9a948", "a #a5752a", "---") + @(1..64 | ForEach-Object { ("Aa" * 32) })
        Set-Content -LiteralPath $path -Value ($grid -join "`n")
        $read = Read-SpriteGrid -Path $path
        $pair = @((Get-SpriteHex -Grid $read -X 0 -Y 0), (Get-SpriteHex -Grid $read -X 1 -Y 0))
        if (($pair -join ",") -ne "#d9a948,#a5752a") { return ("the reader saw A,a as " + ($pair -join ",")) }
        $run = Invoke-MascotRenderer -Root $root
        if ($run.Code -ne 0) { return "the renderer exited $($run.Code): $($run.Output)" }
        $svg = [System.IO.File]::ReadAllText((Join-Path $root "docs\assets\tazuna\case-pair.svg"))
        foreach ($hex in @("#d9a948", "#a5752a")) { if (-not $svg.Contains('fill="' + $hex + '"')) { return "case-pair.svg has no $hex" } }
        return $true
    }

    # Tenebrism and the expression system: most of the figure sinks into shadow,
    # the light comes from the upper left, the eye answers the seal, and the
    # README wears the same palette.

    function Get-DarkShare {
        # The fraction of figure pixels whose relative luminance is at most that of the coat's shadow, #2f2530.
        param($Grid)
        $limit = Get-RelativeLuminance -Hex "#2f2530"
        $figure = 0
        $dark = 0
        for ($y = 0; $y -lt $Grid.Height; $y++) {
            for ($x = 0; $x -lt $Grid.Width; $x++) {
                $hex = Get-SpriteHex -Grid $Grid -X $x -Y $y
                if ($null -eq $hex) { continue }
                $figure++
                if ((Get-RelativeLuminance -Hex $hex) -le $limit) { $dark++ }
            }
        }
        if ($figure -eq 0) { return 0 }
        return $dark / $figure
    }

    function Test-LitFromLeft {
        # $true when the right half's figure pixels are darker on average than the left half's.
        param($Grid)
        $half = [int]($Grid.Width / 2)
        $sum = @(0.0, 0.0)
        $count = @(0, 0)
        for ($y = 0; $y -lt $Grid.Height; $y++) {
            for ($x = 0; $x -lt $Grid.Width; $x++) {
                $hex = Get-SpriteHex -Grid $Grid -X $x -Y $y
                if ($null -eq $hex) { continue }
                $side = [int]($x -ge $half)
                $sum[$side] += Get-RelativeLuminance -Hex $hex
                $count[$side]++
            }
        }
        if (($count[0] -eq 0) -or ($count[1] -eq 0)) { return "one half holds no figure pixel" }
        $left = $sum[0] / $count[0]
        $right = $sum[1] / $count[1]
        if ($right -lt $left) { return $true }
        return ("right half mean luminance {0:N4} is not below the left half's {1:N4}" -f $right, $left)
    }

    Test-Case -Name "M28 the eye's bone catchlight shows at rest and on pass and is gone on fail" -Check {
        foreach ($name in @("view-front", "expr-success")) {
            if ((Get-SpriteHex -Grid (Get-MascotGrid -Name $name) -X 35 -Y 19) -ne "#e2d6bb") { return "$name`: no bone catchlight at (35,19)" }
        }
        $closed = Get-MascotGrid -Name "expr-error"
        for ($y = 17; $y -le 21; $y++) {
            for ($x = 33; $x -le 39; $x++) {
                if ((Get-SpriteHex -Grid $closed -X $x -Y $y) -eq "#e2d6bb") { return "expr-error: the eye still shows a catchlight at ($x,$y)" }
            }
        }
        return $true
    }

    Test-Case -Name "M29 most of every figure sinks into shadow: half of each sprite" -Check {
        foreach ($name in $mascotKept) {
            $share = Get-DarkShare -Grid (Get-MascotGrid -Name $name)
            if ($share -lt 0.5) { return ("{0}: {1:P0} of figure pixels are dark, expected at least 50%" -f $name, $share) }
        }
        # why: a share that is always high would pass here too; an all-gold grid must read as 0.
        $planted = New-TestGrid -Colours @{ "A" = "#d9a948" } -Rows @("AAAA", "AAAA")
        if ((Get-DarkShare -Grid $planted) -ne 0) { return "an all-gold grid was read as dark" }
        return $true
    }

    Test-Case -Name "M30 the hero is lit from the left: its right half is darker than its left" -Check {
        $verdict = Test-LitFromLeft -Grid (Get-MascotGrid -Name "view-front")
        if ($verdict -ne $true) { return "view-front: $verdict" }
        # why: a comparison that never fails would pass here too; a grid lit from the right must be refused.
        $planted = New-TestGrid -Colours @{ "K" = $mascotInk; "W" = "#f9e7a8" } -Rows @("KKWW", "KKWW")
        if ((Test-LitFromLeft -Grid $planted) -eq $true) { return "a grid lit from the right was accepted" }
        return $true
    }

    function Find-MissingStyleWord {
        # "<where>: <word>" for each of tenebrist, baroque and gothic a text does not contain.
        param([string]$Where, [string]$Text)
        $missing = @()
        foreach ($word in @("tenebrist", "baroque", "gothic")) {
            if ($Text.IndexOf($word, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { $missing += "${Where}: $word" }
        }
        return $missing
    }

    Test-Case -Name "M31 the bible names the style tenebrist, baroque and gothic in the identity, the pixel rules and the prompt" -Check {
        $bible = Get-BibleSection -Heading "Character bible"
        if ($null -eq $bible) { return "no '## Character bible' section" }
        $missing = @()
        foreach ($field in @("Visual identity", "Pixel-art rules")) {
            $match = [regex]::Match($bible, '(?s)^### ' + [regex]::Escape($field) + '\s*$(.*?)(?=^### |\z)', [System.Text.RegularExpressions.RegexOptions]::Multiline)
            if (-not $match.Success) { return "no '### $field' field" }
            $missing += @(Find-MissingStyleWord -Where $field -Text $match.Groups[1].Value)
        }
        $prompt = Get-BibleSection -Heading "Image generation prompt"
        if ($null -eq $prompt) { return "no '## Image generation prompt' section" }
        $missing += @(Find-MissingStyleWord -Where "Image generation prompt" -Text $prompt)
        if ($missing.Count -gt 0) { return ("missing: " + ($missing -join ", ")) }
        # why: a scan that never reports would pass here too; a text without gothic must be reported.
        $planted = @(Find-MissingStyleWord -Where "planted" -Text "A tenebrist, baroque samurai.")
        if (($planted -join ",") -ne "planted: gothic") { return ("the planted text was reported as: " + ($planted -join ", ")) }
        return $true
    }

    function Find-SectionWithoutEpigraph {
        # The "## " headings of a markdown text whose first non-blank line is not an italic blockquote "> *...*".
        param([string]$Text)
        $missing = @()
        foreach ($match in [regex]::Matches($Text, '(?ms)^## (.+?)[ \t]*\r?\n(.*?)(?=^## |\z)')) {
            $first = @($match.Groups[2].Value -split "`r?`n" | Where-Object { $_.Trim() })[0]
            if ($first -notmatch '^> \*[^*].*\*\s*$') { $missing += $match.Groups[1].Value }
        }
        return $missing
    }

    Test-Case -Name "P21 each of the 9 README sections opens with an italic blockquote epigraph" -Check {
        $missing = @(Find-SectionWithoutEpigraph -Text $readme)
        if ($missing.Count -gt 0) { return ("no epigraph: " + ($missing -join ", ")) }
        $found = [regex]::Matches($readme, '(?m)^## ').Count
        if ($found -ne $readmeSections.Count) { return "$found sections checked, expected $($readmeSections.Count)" }
        # why: a scan that never reports would pass here too; a plain opening line must be reported.
        $planted = @(Find-SectionWithoutEpigraph -Text "## One`n`n> *A vow.*`n`ntext`n`n## Two`n`nplain text`n")
        if (($planted -join ",") -ne "Two") { return ("the planted text was reported as: " + ($planted -join ", ")) }
        return $true
    }

    function Find-OffPaletteBadge {
        # Each shields.io badge whose colour or labelColor is not in the palette, as "<colour> in <badge path>".
        param([string]$Text, [string[]]$Palette)
        $hits = @()
        foreach ($match in [regex]::Matches($Text, 'img\.shields\.io/badge/([^?)\s]+)\?([^)\s]*)')) {
            $colour = "#" + (($match.Groups[1].Value -split "-")[-1]).ToLowerInvariant()
            $label = [regex]::Match($match.Groups[2].Value, '(?:^|&)labelColor=([0-9a-fA-F]{6})')
            if ($Palette -notcontains $colour) { $hits += "$colour in $($match.Groups[1].Value)" }
            if (-not $label.Success) { $hits += "no labelColor in $($match.Groups[1].Value)" }
            elseif ($Palette -notcontains ("#" + $label.Groups[1].Value.ToLowerInvariant())) { $hits += "labelColor #$($label.Groups[1].Value) in $($match.Groups[1].Value)" }
        }
        return $hits
    }

    Test-Case -Name "P22 every README badge is coloured from the mascot palette" -Check {
        $palette = @(Get-MascotPalette)
        if ([regex]::Matches($readme, 'img\.shields\.io/badge/').Count -lt 4) { return "fewer than 4 badges" }
        $hits = @(Find-OffPaletteBadge -Text $readme -Palette $palette)
        if ($hits.Count -gt 0) { return ("off the palette: " + ($hits -join "; ")) }
        # why: a scan that never reports would pass here too; a red badge must be reported.
        $planted = @(Find-OffPaletteBadge -Text "(https://img.shields.io/badge/x-y-ff0000?style=flat-square&labelColor=0c0809)" -Palette $palette)
        if (($planted -join ",") -ne "#ff0000 in x-y-ff0000") { return ("the planted badge was reported as: " + ($planted -join ", ")) }
        return $true
    }

    function Find-MermaidThemeProblem {
        # Why a mermaid block is not coloured only from the palette, or nothing when it is.
        param([string]$Block, [string[]]$Palette)
        $problems = @()
        $colours = @([regex]::Matches($Block, '#[0-9a-fA-F]{6}\b') | ForEach-Object { $_.Value.ToLowerInvariant() } | Select-Object -Unique)
        if ($colours.Count -eq 0) { $problems += "no colour" }
        foreach ($colour in $colours) { if ($Palette -notcontains $colour) { $problems += "$colour is off the palette" } }
        $kind = Get-MermaidKind -Block $Block
        if ($kind -eq "stateDiagram-v2") {
            $aliases = @{}
            foreach ($m in [regex]::Matches($Block, '(?m)^\s*state\s+"[^"]+"\s+as\s+(\w+)')) { $aliases[$m.Groups[1].Value] = $true }
            $states = @{}
            foreach ($m in [regex]::Matches($Block, '(?m)^\s*(\[\*\]|\w+)\s*-->\s*(\[\*\]|\w+)')) {
                foreach ($id in @($m.Groups[1].Value, $m.Groups[2].Value)) { if ($id -ne "[*]") { $states[$id] = $true } }
            }
            foreach ($id in $aliases.Keys) { $states[$id] = $true }
            $classed = @{}
            foreach ($m in [regex]::Matches($Block, '(?m)^\s*class\s+([\w,]+)\s+\w+\s*$')) { foreach ($id in ($m.Groups[1].Value -split ",")) { $classed[$id] = $true } }
            foreach ($id in ($states.Keys | Sort-Object)) { if (-not $classed.ContainsKey($id)) { $problems += "state $id has no class" } }
        }
        else {
            $first = @($Block -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })[0]
            if ((-not $first.StartsWith("%%{init:")) -or ($first -notmatch "theme['""]?\s*:\s*['""]base['""]")) { $problems += "$kind does not open with a %%{init:} directive setting theme base" }
        }
        return $problems
    }

    Test-Case -Name "P23 the 4 README diagrams are coloured only from the palette, the loop through classDef" -Check {
        $palette = @(Get-MascotPalette)
        $blocks = @(Get-MermaidBlock -Text $readme)
        if ($blocks.Count -ne 4) { return "$($blocks.Count) mermaid blocks" }
        foreach ($block in $blocks) {
            $problems = @(Find-MermaidThemeProblem -Block $block -Palette $palette)
            if ($problems.Count -gt 0) { return ((Get-MermaidKind -Block $block) + ": " + ($problems -join "; ")) }
        }
        # why: a scan that never reports would pass here too; a red flowchart and an unclassed state must be reported.
        $red = @(Find-MermaidThemeProblem -Block "%%{init: {'theme': 'base', 'themeVariables': {'primaryColor': '#ff0000'}}}%%`nflowchart TD`n  a --> b" -Palette $palette)
        if (($red -join ",") -ne "#ff0000 is off the palette") { return ("the planted flowchart was reported as: " + ($red -join ", ")) }
        $state = @(Find-MermaidThemeProblem -Block "stateDiagram-v2`n  A --> B`n  classDef x fill:#0c0809`n  class A x" -Palette $palette)
        if (($state -join ",") -ne "state B has no class") { return ("the planted state diagram was reported as: " + ($state -join ", ")) }
        return $true
    }

    function Find-OffPaletteColour {
        # The hex colours of an SVG text that are not in the palette; "no colour" when it holds none.
        param([string]$Svg, [string[]]$Palette)
        $colours = @([regex]::Matches($Svg, '#[0-9a-fA-F]{6}\b') | ForEach-Object { $_.Value.ToLowerInvariant() } | Select-Object -Unique)
        if ($colours.Count -eq 0) { return @("no colour") }
        return @($colours | Where-Object { $Palette -notcontains $_ })
    }

    Test-Case -Name "P24 the README shows the palette divider at least 3 times" -Check {
        $shown = [regex]::Matches($readme, '<img src="docs/assets/divider\.svg"').Count
        if ($shown -lt 3) { return "the divider is shown $shown time(s), expected at least 3" }
        $palette = @(Get-MascotPalette)
        $svg = [System.IO.File]::ReadAllText((Join-Path $repoRoot "docs\assets\divider.svg"))
        $off = @(Find-OffPaletteColour -Svg $svg -Palette $palette)
        if ($off.Count -gt 0) { return ("divider.svg: " + ($off -join ", ")) }
        # why: a scan that never reports would pass here too; a red rect must be reported.
        $planted = @(Find-OffPaletteColour -Svg '<svg><rect fill="#d9a948"/><rect fill="#FF0000"/></svg>' -Palette $palette)
        if (($planted -join ",") -ne "#ff0000") { return ("the planted svg was reported as: " + ($planted -join ", ")) }
        return $true
    }

    # The animated banner and the smaller mascot set.

    $bannerTagline = "A verification gate for Claude Code and Cursor that works in any stack."

    function Get-SvgGroup {
        # The inner markup of the flat <g id="..."> group, or $null.
        param([string]$Svg, [string]$Id)
        $match = [regex]::Match($Svg, '(?s)<g id="' + [regex]::Escape($Id) + '"[^>]*>(.*?)</g>')
        if (-not $match.Success) { return $null }
        return $match.Groups[1].Value
    }

    function Get-CssRuleBody {
        # The bodies of every CSS rule whose selector list names "#<id>".
        param([string]$Svg, [string]$Id)
        return @([regex]::Matches($Svg, '#' + [regex]::Escape($Id) + '(?![\w-])[^{}<]*\{([^{}]*)\}') | ForEach-Object { $_.Groups[1].Value })
    }

    function Get-CssAnimation {
        # The keyframes name and duration of the first animation declared for "#<id>".
        param([string]$Svg, [string]$Id)
        foreach ($body in (Get-CssRuleBody -Svg $Svg -Id $Id)) {
            $animation = [regex]::Match($body, 'animation:\s*([\w-]+)\s+([\d.]+m?s)\b')
            if ($animation.Success) { return [PSCustomObject]@{ Name = $animation.Groups[1].Value; Duration = $animation.Groups[2].Value } }
        }
        return $null
    }

    function Get-RenderedBanner {
        $root = Copy-MascotScratch
        Remove-RenderedOutput -Root $root
        $run = Invoke-MascotRenderer -Root $root
        if ($run.Code -ne 0) { throw "the renderer exited $($run.Code): $($run.Output)" }
        return [PSCustomObject]@{
            Banner  = [System.IO.File]::ReadAllText((Join-Path $root "docs\assets\banner.svg"))
            Success = [System.IO.File]::ReadAllText((Join-Path $root "docs\assets\tazuna\expr-success.svg"))
        }
    }

    $committedBanner = [System.IO.File]::ReadAllText((Join-Path $repoRoot "docs\assets\banner.svg"))

    Test-Case -Name "P12 the renderer writes a banner whose front and lit frames alternate over a 6s cycle" -Check {
        $render = Get-RenderedBanner
        $front = Get-SvgGroup -Svg $render.Banner -Id "frenatus"
        $lit = Get-SvgGroup -Svg $render.Banner -Id "frenatus-lit"
        if ($null -eq $front) { return "no <g id=`"frenatus`">" }
        if ($null -eq $lit) { return "no <g id=`"frenatus-lit`">" }
        foreach ($frame in @(@("frenatus", $front), @("frenatus-lit", $lit))) {
            $runs = [regex]::Matches($frame[1], 'M\d+ \d+h\d+').Count
            if ($runs -lt 200) { return "$($frame[0]) has $runs pixel runs, expected at least 200" }
        }
        $success = Get-SvgGroup -Svg $render.Success -Id "expr-success"
        if ($lit -ne $success) { return "the lit frame is not the expr-success drawing" }
        $animation = Get-CssAnimation -Svg $render.Banner -Id "frenatus-lit"
        if ($null -eq $animation) { return "#frenatus-lit declares no animation" }
        if ($animation.Duration -ne "6s") { return "#frenatus-lit animates over $($animation.Duration)" }
        if ($render.Banner -notmatch ('@keyframes\s+' + [regex]::Escape($animation.Name) + '\s*\{')) { return "no @keyframes $($animation.Name)" }
        # invariant: 4 s front, 2 s lit, so the lit frame turns on at two thirds of the cycle and the front frame turns off there.
        $rest = Get-CssAnimation -Svg $render.Banner -Id "frenatus"
        if (($null -eq $rest) -or ($rest.Duration -ne "6s")) { return "#frenatus does not alternate on a 6s cycle" }
        foreach ($pair in @(@($animation.Name, "0", "1"), @($rest.Name, "1", "0"))) {
            $frames = [regex]::Match($render.Banner, '@keyframes\s+' + [regex]::Escape($pair[0]) + '\s*\{(.*?\})\s*\}')
            if ($frames.Groups[1].Value -notmatch ('0%, 66\.66% \{ opacity: ' + $pair[1] + '; \} 66\.67%, 100% \{ opacity: ' + $pair[2] + '; \}')) { return "@keyframes $($pair[0]) does not switch from $($pair[1]) to $($pair[2]) at two thirds" }
        }
        return $true
    }

    Test-Case -Name "P13 the banner stops on the front frame when the viewer prefers reduced motion" -Check {
        $render = Get-RenderedBanner
        $media = [regex]::Match($render.Banner, '(?s)@media\s*\(prefers-reduced-motion:\s*reduce\)\s*\{(.*?\})\s*\}')
        if (-not $media.Success) { return "no @media (prefers-reduced-motion: reduce) block" }
        if ($media.Groups[1].Value -notmatch 'animation:\s*none') { return "the reduced-motion block does not set animation: none" }
        foreach ($id in @("frenatus", "frenatus-lit", "verify-lit")) {
            if (@(Get-CssRuleBody -Svg $media.Groups[1].Value -Id $id | Where-Object { $_ -match 'animation:\s*none' }).Count -eq 0) { return "the reduced-motion block does not stop #$id" }
        }
        $resting = @(Get-CssRuleBody -Svg $render.Banner -Id "frenatus-lit" | Where-Object { $_ -match 'opacity:\s*0\s*(;|$)' })
        if ($resting.Count -eq 0) { return "#frenatus-lit does not rest at opacity 0" }
        return $true
    }

    function Find-MiddleMascot {
        # The mascot sprites a markdown text shows between its first "## " section and its last one.
        param([string]$Text)
        $first = $Text.IndexOf("`n## ")
        $last = $Text.LastIndexOf("`n## ")
        if (($first -lt 0) -or ($last -le $first)) { return @() }
        return @([regex]::Matches($Text.Substring($first, $last - $first), 'docs/assets/tazuna/([a-z0-9-]+)\.svg') | ForEach-Object { $_.Groups[1].Value })
    }

    Test-Case -Name "P14 the mascot stays out of the middle of the README: only the banner and the footer show it" -Check {
        $middle = @(Find-MiddleMascot -Text $readme)
        if ($middle.Count -gt 0) { return ("the middle of the README shows: " + ($middle -join ", ")) }
        # why: a scan that never reports would pass here too; a sprite planted between two sections must be reported.
        $planted = @(Find-MiddleMascot -Text "head`n## One`n<img src=`"docs/assets/tazuna/expr-error.svg`">`n## Two`nfoot")
        if (($planted -join ",") -ne "expr-error") { return ("the planted README was reported as: " + ($planted -join ", ")) }
        return $true
    }

    Test-Case -Name "P15 the banner has no Japanese and reads exactly the title, the tagline and the five steps" -Check {
        foreach ($ch in $committedBanner.ToCharArray()) {
            if (([int]$ch -ge 0x3000) -and ([int]$ch -le 0x9FFF)) { return ("the banner holds U+{0:X4}" -f [int]$ch) }
        }
        $texts = @([regex]::Matches($committedBanner, '<text\b[^>]*>([^<]*)</text>') | ForEach-Object { $_.Groups[1].Value })
        $expected = @("Tazuna", $bannerTagline, "Plan", "Checks", "Build", "Verify", "Review")
        if (($texts -join "|") -ne ($expected -join "|")) { return ("texts: " + ($texts -join " | ")) }
        return $true
    }

    Test-Case -Name "P16 the banner is a dark card with a gilded title" -Check {
        $card = [regex]::Match($committedBanner, '<rect\b[^>]*>')
        if ((-not $card.Success) -or ($card.Value -notmatch 'fill="#1c1419"')) { return "the first rect is not filled #1c1419: $($card.Value)" }
        if ($committedBanner -notmatch '<text\b[^>]*fill="#f9e7a8"[^>]*>Tazuna</text>') { return "the title is not filled #f9e7a8" }
        return $true
    }

    Test-Case -Name "P17 the Verify step lights with the seal, on the same keyframes and cycle" -Check {
        $group = [regex]::Match($committedBanner, '(?s)<g\b[^>]*>((?:(?!</?g\b).)*<text\b[^>]*>Verify</text>(?:(?!</?g\b).)*)</g>')
        if (-not $group.Success) { return "no <g> holding the Verify text" }
        $ids = @([regex]::Matches($group.Groups[1].Value, '\bid="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
        $seal = Get-CssAnimation -Svg $committedBanner -Id "frenatus-lit"
        if ($null -eq $seal) { return "#frenatus-lit declares no animation" }
        foreach ($id in $ids) {
            $step = Get-CssAnimation -Svg $committedBanner -Id $id
            if (($null -ne $step) -and ($step.Name -eq $seal.Name) -and ($step.Duration -eq $seal.Duration)) { return $true }
        }
        return ("no element beside Verify animates on " + $seal.Name + " " + $seal.Duration + "; ids: " + ($ids -join ", "))
    }

    Test-Case -Name "P18 the renderer draws both images with the English tagline and holds no Portuguese" -Check {
        $path = Join-Path $scriptsRoot "render-mascot.ps1"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        foreach ($name in @("Get-SocialPreviewBytes", "Get-BannerSvg")) {
            $function = $ast.Find({ param($node) ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($node.Name -eq $name) }, $true)
            if ($null -eq $function) { return "no function $name" }
            if (-not $function.Extent.Text.Contains($bannerTagline)) { return "$name does not use the tagline" }
        }
        $source = [System.IO.File]::ReadAllText($path)
        foreach ($token in @("Um port", "o de verifica", "qualquer stack", "[char]0xE3", "[char]0xE7")) {
            if ($source.Contains($token)) { return "render-mascot.ps1 still holds '$token'" }
        }
        return $true
    }

    Test-Case -Name "P19 the working specs stay local: nothing under .specs is tracked and .gitignore keeps it out" -Check {
        $tracked = @((Invoke-GitCommand -RepositoryPath $repoRoot -Arguments @("ls-files", "--", ".specs")).Output)
        if ($tracked.Count -gt 0) { return ("tracked under .specs: " + (($tracked | Select-Object -First 5) -join ", ")) }
        $ignored = Invoke-GitCommand -RepositoryPath $repoRoot -Arguments @("check-ignore", "-q", "--no-index", ".specs/features/any/plan.md") -AllowFailure
        if ($ignored.ExitCode -ne 0) { return ".gitignore does not ignore .specs/" }
        return $true
    }

    function Find-MissingBiblePath {
        # Backticked docs/... or .specs/... paths in a markdown text that do not exist under the root.
        param([string]$Root, [string]$Text)
        $missing = @()
        foreach ($hit in @([regex]::Matches($Text, '`((?:docs|\.specs)/[^`<>*]+)`') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)) {
            if (-not (Test-Path -LiteralPath (Join-Path $Root $hit.TrimEnd("/").Replace("/", "\")))) { $missing += $hit }
        }
        return $missing
    }

    Test-Case -Name "P20 the bible names no deleted sprite or sheet, and every path it names exists" -Check {
        $bible = [System.IO.File]::ReadAllText($mascotBible)
        foreach ($name in $mascotDeleted) {
            if ($bible -match ([regex]::Escape($name) + '\.(svg|txt)\b')) { return "the bible names $name as a file" }
        }
        if ($bible.Contains("sheet.svg")) { return "the bible names sheet.svg" }
        # why: .specs/ is gitignored, so a path into it exists here and is missing in every clone.
        if ($bible.Contains(".specs/")) { return "the bible names a path under .specs/, which is not published" }
        $missing = @(Find-MissingBiblePath -Root $repoRoot -Text $bible)
        if ($missing.Count -gt 0) { return ("named but missing: " + ($missing -join ", ")) }
        # why: a scan that never reports anything would pass here too; the planted path proves it can fail.
        $planted = @(Find-MissingBiblePath -Root $repoRoot -Text 'Files: `.specs/features/mascot-hitch/concepts/Z9/`.')
        if (($planted -join ",") -ne ".specs/features/mascot-hitch/concepts/Z9/") { return ("the planted path was reported as: " + ($planted -join ", ")) }
        return $true
    }
}
finally {
    Clear-ScratchRoot
}

Complete-TestFile
