# Json.psm1
#
# JSON validity and content comparison.
# invariant: a leaf - imports no other module, and only Console.psm1 writes to the host.
# Windows PowerShell 5.1 compatible.

Set-StrictMode -Version 2.0

function Test-JsonFile {
    <#
    .SYNOPSIS
        Returns $true when the file exists and parses as JSON.
    .DESCRIPTION
        Pass a [ref] to -ErrorMessage to receive the reason on failure.
        A [ref] is used rather than Set-Variable -Scope because scope numbers
        do not cross the module boundary.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [ref]$ErrorMessage
    )

    if ($null -ne $ErrorMessage) {
        $ErrorMessage.Value = $null
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        if ($null -ne $ErrorMessage) {
            $ErrorMessage.Value = "File not found."
        }
        return $false
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop

        if ($null -eq $raw -or $raw.Trim() -eq "") {
            if ($null -ne $ErrorMessage) {
                $ErrorMessage.Value = "File is empty."
            }
            return $false
        }

        $null = ConvertFrom-Json $raw -ErrorAction Stop
        return $true
    }
    catch {
        if ($null -ne $ErrorMessage) {
            $ErrorMessage.Value = $_.Exception.Message
        }
        return $false
    }
}

function Get-JsonCanonicalForm {
    <#
    .SYNOPSIS
        A JSON document reduced to a form where only its content matters.
    .DESCRIPTION
        Claude Code owns settings.json and rewrites it: `plugin install --scope
        user` reorders the keys and switches the line endings to LF. Comparing
        bytes therefore reported drift after every clean install, about a file
        whose content had not changed at all - and a fresh install that ends in
        a warning teaches you to ignore warnings.

        Keys are sorted at every level, so reordering is invisible here and a
        real change is not.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) { return "null" }

    if ($Value -is [System.Management.Automation.PSCustomObject]) {

        $parts = @()

        foreach ($property in ($Value.PSObject.Properties | Sort-Object Name)) {
            $parts += ('"' + $property.Name + '":' + (Get-JsonCanonicalForm -Value $property.Value))
        }

        return "{" + ($parts -join ",") + "}"
    }

    if (($Value -is [System.Array]) -or ($Value -is [System.Collections.IList])) {

        $parts = @()

        # Order is meaningful in an array - a permission list is evaluated in
        # order - so this is deliberately not sorted.
        foreach ($item in $Value) { $parts += (Get-JsonCanonicalForm -Value $item) }

        return "[" + ($parts -join ",") + "]"
    }

    if ($Value -is [bool]) { return $(if ($Value) { "true" } else { "false" }) }

    return ('"' + [string]$Value + '"')
}

function Test-JsonContentEqual {
    <#
    .SYNOPSIS
        Compares two JSON files by content, ignoring formatting and key order.
        A file that does not parse is reported as different, never as equal.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ReferenceFile,
        [Parameter(Mandatory = $true)][string]$DifferenceFile
    )

    if (-not (Test-Path -LiteralPath $DifferenceFile)) { return $false }

    try {
        $reference = Get-Content -LiteralPath $ReferenceFile -Raw | ConvertFrom-Json
        $difference = Get-Content -LiteralPath $DifferenceFile -Raw | ConvertFrom-Json
    }
    catch {
        return $false
    }

    return ((Get-JsonCanonicalForm -Value $reference) -eq (Get-JsonCanonicalForm -Value $difference))
}

Export-ModuleMember -Function @(
    "Test-JsonFile",
    "Get-JsonCanonicalForm",
    "Test-JsonContentEqual"
)
