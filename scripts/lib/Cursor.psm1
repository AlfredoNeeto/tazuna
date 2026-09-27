# Cursor.psm1
#
# What Cursor reads that Claude Code does not: its rule format and its MCP file.
# invariant: a leaf - imports no other module, and only Console.psm1 writes to the host.
# Windows PowerShell 5.1 compatible.

Set-StrictMode -Version 2.0

function ConvertTo-CursorRule {
    <#
        Turns a Claude Code rule (optional frontmatter with a `paths:` list) into
        the text of a Cursor .mdc rule. With paths, the rule attaches to those
        globs; without, it applies always. The body is carried unchanged.

        Cursor ignores a .md in .cursor/rules because it has no frontmatter, so
        the conversion is what makes a rule visible there at all.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [string]$Description
    )

    $normalized = $Text.Replace("`r`n", "`n")
    $body = $normalized
    $globs = @()

    $match = [regex]::Match($normalized, '(?s)\A---\n(.*?)\n---\n(.*)\z')

    if ($match.Success) {
        $body = $match.Groups[2].Value
        $inPaths = $false

        foreach ($line in ($match.Groups[1].Value -split "`n")) {

            if ($line -match '^paths:\s*$') { $inPaths = $true; continue }
            if ($line -notmatch '^\s') { $inPaths = $false; continue }

            if ($inPaths -and ($line -match '^\s*-\s*"?([^"]+?)"?\s*$')) { $globs += $Matches[1] }
        }
    }

    $head = @("---")
    if ($Description) { $head += "description: $Description" }

    if ($globs.Count -gt 0) {
        $head += "globs: " + ($globs -join ",")
        $head += "alwaysApply: false"
    }
    else {
        $head += "alwaysApply: true"
    }

    $head += "---"

    return (($head -join "`n") + "`n" + $body)
}

function Add-CursorMcpServer {
    <#
        Merges the catalogue's servers into the text of a Cursor mcp.json.
        A server already present by name is left exactly as it is - the file is
        the user's, and so is any entry they changed. Keys starting with '$' are
        this repository's documentation and never reach Cursor.

        Returns the new text and the names added; Added is empty when nothing
        changed, so the caller writes nothing.
    #>
    param(
        [AllowEmptyString()][string]$ExistingJson,
        [Parameter(Mandatory = $true)]$Catalogue
    )

    $document = New-Object PSObject
    if ($ExistingJson -and $ExistingJson.Trim()) { $document = $ExistingJson | ConvertFrom-Json }

    if (-not $document.PSObject.Properties["mcpServers"]) {
        Add-Member -InputObject $document -MemberType NoteProperty -Name "mcpServers" -Value (New-Object PSObject)
    }

    $added = @()

    foreach ($name in @($Catalogue.PSObject.Properties.Name)) {

        if ($document.mcpServers.PSObject.Properties[$name]) { continue }

        $server = New-Object PSObject
        foreach ($property in $Catalogue.$name.PSObject.Properties) {
            if (-not $property.Name.StartsWith('$')) {
                Add-Member -InputObject $server -MemberType NoteProperty -Name $property.Name -Value $property.Value
            }
        }

        Add-Member -InputObject $document.mcpServers -MemberType NoteProperty -Name $name -Value $server
        $added += $name
    }

    return [PSCustomObject]@{ Json = ($document | ConvertTo-Json -Depth 20); Added = $added }
}

Export-ModuleMember -Function @(
    "ConvertTo-CursorRule",
    "Add-CursorMcpServer"
)
