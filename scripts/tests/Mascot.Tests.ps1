[CmdletBinding()]
param([switch]$SkipSlow, [string]$Only)

. (Join-Path $PSScriptRoot "TestKit.ps1")

try {

    Start-Section "Mascot"

    $mascotAssets = Join-Path $repoRoot "docs\assets\tazuna"
    $mascotNames = @("view-front", "expr-success", "expr-error")
    $mascotKept = @($mascotNames + @("icon-32"))

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

    function Get-SpriteHex {
        param($Grid, [int]$X, [int]$Y)
        $ch = [string]$Grid.Rows[$Y][$X]
        if ($ch -eq ".") { return $null }
        return $Grid.Colours[$ch]
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

    Test-Case -Name "P19 the working specs stay local: nothing under .specs is tracked and .gitignore keeps it out" -Check {
        $tracked = @((Invoke-GitCommand -RepositoryPath $repoRoot -Arguments @("ls-files", "--", ".specs")).Output)
        if ($tracked.Count -gt 0) { return ("tracked under .specs: " + (($tracked | Select-Object -First 5) -join ", ")) }
        $ignored = Invoke-GitCommand -RepositoryPath $repoRoot -Arguments @("check-ignore", "-q", "--no-index", ".specs/features/any/plan.md") -AllowFailure
        if ($ignored.ExitCode -ne 0) { return ".gitignore does not ignore .specs/" }
        return $true
    }

}
finally {
    Clear-ScratchRoot
}

Complete-TestFile
