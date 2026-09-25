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
        "^(WARN|WHATIF|SKIP|PENDING)$"            { return "Yellow" }
        "^(INSTALL|CREATE|UPDATE|ADDED|BACKUP)$"  { return "Cyan" }
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

function Write-Banner {
    <#
    .SYNOPSIS
        The title block a script opens with: "<Title> · <Command>".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [string]$Command = "",

        [string]$Subtitle = ""
    )

    Write-Host ""

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
}

Export-ModuleMember -Function @(
    "Get-StatusColour",
    "Write-Status",
    "Write-Entry",
    "Write-Section",
    "Write-Banner"
)
