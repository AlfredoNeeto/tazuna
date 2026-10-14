# Console.psm1
#
# Console output. The only library module that writes to the host.
# invariant: a leaf - imports no other module, and only Console.psm1 writes to the host.
# Windows PowerShell 5.1 compatible.

Set-StrictMode -Version 2.0

function Test-RichOutput {
    <#
        Rich output - glyphs and box drawing - only in a terminal known to draw
        them: Windows Terminal, writing to the console itself. The legacy conhost
        has no font fallback, so a glyph there becomes a box or '?', and output
        piped through Windows PowerShell 5.1 is decoded with the OEM code page.
        TAZUNA_PLAIN=1 forces plain even inside Windows Terminal.
    #>
    return [bool]($env:WT_SESSION -and (-not [Console]::IsOutputRedirected) -and (-not $env:TAZUNA_PLAIN))
}

# invariant: decided once per import. Every script imports this module with
# -Force before it writes, so the environment it starts in decides; the
# self-test sets this variable inside the module to render the other mode.
$script:Rich = Test-RichOutput

# why: [char] codes, not literals - Windows PowerShell 5.1 reads a BOM-less
# source file as ANSI, so a literal glyph in this file would be mojibake.
$script:Glyphs = @{
    Green  = [string][char]0x2714
    Red    = [string][char]0x2716
    Yellow = [string][char]0x25B2
    Other  = [string][char]0x25CF
}

function Write-Line {
    param([string]$Text, [string]$Colour, [switch]$NoNewline)

    # Honour NO_COLOR: the convention exists because coloured output breaks
    # logs, pipes and screen readers, and this writes a lot of lines.
    if ($Colour -and (-not $env:NO_COLOR)) {
        Write-Host $Text -ForegroundColor $Colour -NoNewline:$NoNewline
    }
    else {
        Write-Host $Text -NoNewline:$NoNewline
    }
}

function Get-StatusMeaning {
    param([string]$Label)

    switch -Regex ($Label) {
        "^(OK|PASS|PRESENT|UNCHANGED|DONE)$"      { return "Green" }
        "^(FAIL|MISSING|ERROR|DENIED)$"           { return "Red" }
        "^(WARN|WHATIF|SKIP|PENDING|STALE)$"      { return "Yellow" }
        "^(INSTALL|CREATE|UPDATE|ADDED|BACKUP|REMOVE)$" { return "Cyan" }
        "^(MCP|PLUGIN|TOOL|PROFILE|POINTER)$"     { return "Magenta" }
        default                                    { return "Gray" }
    }
}

function Get-StatusColour {
    <#
        Colour by what the line means, not by which script printed it. A reader
        scanning fifty lines of output should be able to find the one that
        matters without reading any of them.
    #>
    [CmdletBinding()]
    param([string]$Label)

    if ($env:NO_COLOR) { return $null }

    return Get-StatusMeaning -Label $Label
}

function Write-Status {
    <#
    .SYNOPSIS
        Prints an aligned "LABEL  detail" status line, coloured by meaning.
    .DESCRIPTION
        The text is unchanged whether or not colour applies, because the
        self-test reads this output. Colour is decoration on top of a format
        that still works when it is stripped. Rich output puts one glyph per
        meaning in front of that same text.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [string]$Detail = ""
    )

    $glyph = ""

    if ($script:Rich) {
        $glyph = $script:Glyphs[(Get-StatusMeaning -Label $Label)]
        if (-not $glyph) { $glyph = $script:Glyphs.Other }
        $glyph += " "
    }

    Write-Line -Text ("{0}{1,-9} " -f $glyph, $Label) -Colour (Get-StatusColour -Label $Label) -NoNewline
    Write-Line -Text $Detail
}

function Write-Entry {
    <#
    .SYNOPSIS
        One "name  description" row of a listing: the name highlighted, the text plain.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$Text = ""
    )

    Write-Line -Text $Name -Colour Cyan -NoNewline
    Write-Line -Text $Text
}

function Write-Section {
    <#
    .SYNOPSIS
        A section heading, underlined to the width of its own title.
    .DESCRIPTION
        Replaces the hand-written "Write-Host title; Write-Host ------" pairs,
        which drifted out of step with their titles every time one was renamed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [switch]$NoLeadingBlank
    )

    if (-not $NoLeadingBlank) { Write-Host "" }

    $rule = "-"
    if ($script:Rich) { $rule = [string][char]0x2500 }

    Write-Line -Text $Title -Colour White
    Write-Line -Text ($rule * $Title.Length) -Colour DarkGray
}

function Test-RichConsole {
    <#
    .SYNOPSIS
        Whether this run draws rich output, for a caller that writes a different ending in each mode.
    #>
    [CmdletBinding()]
    param()

    return $script:Rich
}

function Get-SpritePixels {
    <#
    .SYNOPSIS
        A pixel-art source as rows of "#rrggbb" colours, $null where it is transparent.
    .DESCRIPTION
        The format docs/mascot.md defines: "<char> #rrggbb" palette lines, a "---" line, then
        rows of palette characters with "." for transparent. Palette characters are
        case-sensitive, so the lookup is a [char] dictionary, not a hashtable.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $palette = New-Object "System.Collections.Generic.Dictionary[char,string]"
    $rows = New-Object System.Collections.Generic.List[object]
    $inGrid = $false

    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {

        if (-not $inGrid) {
            if ($line -eq "---") { $inGrid = $true }
            elseif ($line -match '^(\S) (#[0-9a-fA-F]{6})$') { $palette[[char]$Matches[1]] = $Matches[2] }
            continue
        }

        $row = @()
        foreach ($character in $line.ToCharArray()) {
            if ($palette.ContainsKey($character)) { $row += $palette[$character] } else { $row += $null }
        }
        $rows.Add($row)
    }

    return , $rows.ToArray()
}

function Write-SpriteBeside {
    <#
        Draws the sprite two pixel rows per line: the upper half block takes the top pixel as
        foreground and the bottom one as background, in 24-bit colour. Text[i], when present,
        is written beside line i.
    #>
    param([object[]]$Grid, [hashtable]$Text)

    $escape = [string][char]27
    $upper = [string][char]0x2580
    $lower = [string][char]0x2584

    for ($y = 0; $y -lt $Grid.Count; $y += 2) {

        $line = "  "

        for ($x = 0; $x -lt $Grid[$y].Count; $x++) {

            $top = $Grid[$y][$x]
            $bottom = $null
            if (($y + 1) -lt $Grid.Count) { $bottom = $Grid[$y + 1][$x] }

            if ((-not $top) -and (-not $bottom)) { $line += "$escape[0m " }
            elseif (-not $bottom) { $line += (Get-AnsiColour -Hex $top -Layer 38) + $upper + "$escape[0m" }
            elseif (-not $top) { $line += (Get-AnsiColour -Hex $bottom -Layer 38) + $lower + "$escape[0m" }
            else { $line += (Get-AnsiColour -Hex $top -Layer 38) + (Get-AnsiColour -Hex $bottom -Layer 48) + $upper + "$escape[0m" }
        }

        Write-Host $line -NoNewline

        $row = $y / 2
        if ($Text.ContainsKey($row)) { Write-Line -Text ("    " + $Text[$row].Text) -Colour $Text[$row].Colour }
        else { Write-Host "" }
    }
}

function Get-AnsiColour {
    param([string]$Hex, [int]$Layer)

    $red = [Convert]::ToInt32($Hex.Substring(1, 2), 16)
    $green = [Convert]::ToInt32($Hex.Substring(3, 2), 16)
    $blue = [Convert]::ToInt32($Hex.Substring(5, 2), 16)
    return ("{0}[{1};2;{2};{3};{4}m" -f [char]27, $Layer, $red, $green, $blue)
}

function Write-Banner {
    <#
    .SYNOPSIS
        The title block a script opens with: "<Title> · <Command>".
    .DESCRIPTION
        Details are lines the caller wants under the title; plain output prints them exactly
        as given. With -Sprite, rich output draws the mascot and writes the title, the tagline
        and the details beside it, unless NO_COLOR asks for no colour at all. The tagline
        exists only beside the art, so plain output keeps its lines.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [string]$Command = "",

        [string]$Subtitle = "",

        [string[]]$Details = @(),

        [string]$Sprite = "",

        [string]$Tagline = ""
    )

    Write-Host ""

    if ($script:Rich -and $Sprite -and (-not $env:NO_COLOR) -and (Test-Path -LiteralPath $Sprite)) {

        if ($Command) { $Title = "{0} {1} {2}" -f $Title, [char]0x00B7, $Command }

        $text = @{ 6 = @{ Text = $Title; Colour = "Cyan" } }
        if ($Tagline) { $text[7] = @{ Text = $Tagline; Colour = "DarkGray" } }

        for ($i = 0; $i -lt $Details.Count; $i++) { $text[9 + $i] = @{ Text = $Details[$i].Trim(); Colour = "Gray" } }

        Write-SpriteBeside -Grid (Get-SpritePixels -Path $Sprite) -Text $text
        return
    }

    if (-not $script:Rich) {

        if ($Command) { $Title = "$Title - $Command" }

        Write-Line -Text $Title -Colour Cyan
        Write-Line -Text ("=" * $Title.Length) -Colour DarkGray
    }
    else {

        if ($Command) { $Title = "{0} {1} {2}" -f $Title, [char]0x00B7, $Command }

        $bar = [string][char]0x2500 * ($Title.Length + 4)
        $side = [string][char]0x2502

        Write-Line -Text ("{0}{1}{2}" -f [char]0x256D, $bar, [char]0x256E) -Colour DarkGray
        Write-Line -Text "$side  " -Colour DarkGray -NoNewline
        Write-Line -Text $Title -Colour Cyan -NoNewline
        Write-Line -Text "  $side" -Colour DarkGray
        Write-Line -Text ("{0}{1}{2}" -f [char]0x2570, $bar, [char]0x256F) -Colour DarkGray
    }

    if ($Subtitle) { Write-Line -Text $Subtitle -Colour DarkGray }

    foreach ($detail in $Details) { Write-Host $detail }
}

function Write-StepHeader {
    <#
    .SYNOPSIS
        "[i/n] Title" under a rule in plain output; in rich output a bar of the steps done so far.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$Index,
        [Parameter(Mandatory = $true)][int]$Count,
        [Parameter(Mandatory = $true)][string]$Title
    )

    if (-not $script:Rich) {
        Write-Section ("[{0}/{1}] {2}" -f $Index, $Count, $Title)
        return
    }

    Write-Host ""
    Write-Line -Text ([string][char]0x2501 * (3 * $Index)) -Colour Cyan -NoNewline
    Write-Line -Text ([string][char]0x2500 * (3 * ($Count - $Index))) -Colour DarkGray -NoNewline
    Write-Line -Text ("  {0}/{1}  " -f $Index, $Count) -Colour DarkGray -NoNewline
    Write-Line -Text $Title -Colour White
}

function Write-Panel {
    <#
    .SYNOPSIS
        Lines inside a rounded box. Rich output only: a caller writes its plain ending itself.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Lines,
        [string]$Colour = "Green"
    )

    $width = ($Lines | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    $bar = [string][char]0x2500 * ($width + 4)
    $side = [string][char]0x2502

    Write-Host ""
    Write-Line -Text ("  {0}{1}{2}" -f [char]0x256D, $bar, [char]0x256E) -Colour DarkGray

    foreach ($line in $Lines) {
        Write-Line -Text "  $side  " -Colour DarkGray -NoNewline
        Write-Line -Text $line.PadRight($width) -Colour $Colour -NoNewline
        Write-Line -Text "  $side" -Colour DarkGray
    }

    Write-Line -Text ("  {0}{1}{2}" -f [char]0x2570, $bar, [char]0x256F) -Colour DarkGray
}

Export-ModuleMember -Function @(
    "Get-StatusColour",
    "Write-Status",
    "Write-Entry",
    "Write-Section",
    "Write-Banner",
    "Write-StepHeader",
    "Write-Panel",
    "Test-RichConsole",
    "Get-SpritePixels"
)
