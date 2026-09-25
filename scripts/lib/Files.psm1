# Files.psm1
#
# Reading, hashing, comparing and writing files.
# invariant: a leaf - imports no other module, and only Console.psm1 writes to the host.
# Windows PowerShell 5.1 compatible.

Set-StrictMode -Version 2.0

function Test-FileContentEqual {
    <#
    .SYNOPSIS
        Byte-level comparison of two files. Missing target counts as different.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReferenceFile,

        [Parameter(Mandatory = $true)]
        [string]$DifferenceFile
    )

    if (-not (Test-Path -LiteralPath $DifferenceFile)) {
        return $false
    }

    return ((Get-FileSha256 -Path $ReferenceFile) -eq (Get-FileSha256 -Path $DifferenceFile))
}

function Set-Utf8Content {
    <#
    .SYNOPSIS
        Writes text as UTF-8 without a byte order mark.
    .DESCRIPTION
        Set-Content -Encoding UTF8 writes a BOM in Windows PowerShell 5.1. Every
        file in this repository is BOM-free, and a BOM written into a project's
        .mcp.json or settings.json is a difference the author did not choose and
        will see in their first diff.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)

    [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}

function Get-FileSha256 {
    <#
    .SYNOPSIS
        SHA256 of a file, computed through .NET rather than Get-FileHash.
    .DESCRIPTION
        Get-FileHash is a function in Windows PowerShell 5.1 and an inherited
        $WhatIfPreference reaches inside it: it emits "What if: Retrieve the
        value for property 'ProviderPath'" and returns nothing, so .Hash throws.
        Clearing the preference locally does not stop it, and it does not accept
        -WhatIf to opt out.

        That matters beyond tidiness. Comparing and fingerprinting files is how
        the installer decides what changed and how the verification gate decides
        whether the working tree moved. Reading a file is not a mutation, and no
        dry run anywhere up the call stack may suppress it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $algorithm = [System.Security.Cryptography.SHA256]::Create()

    try {
        $bytes = [System.IO.File]::ReadAllBytes((Convert-Path -LiteralPath $Path))

        return [System.BitConverter]::ToString($algorithm.ComputeHash($bytes)).Replace("-", "")
    }
    finally {
        $algorithm.Dispose()
    }
}

function Copy-FileIfChanged {
    <#
    .SYNOPSIS
        Copies SourceFile to TargetFile only when the contents differ.
    .DESCRIPTION
        Returns 'Unchanged', 'Created' or 'Updated'. When BackupRoot is supplied
        and an existing target is about to be overwritten, the current bytes are
        copied under BackupRoot first.

        Every mutation, including the backup, happens inside the ShouldProcess
        guard so that -WhatIf really does write nothing.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceFile,

        [Parameter(Mandatory = $true)]
        [string]$TargetFile,

        [string]$BackupRoot,

        [string]$BackupRelativePath
    )

    if (-not (Test-Path -LiteralPath $SourceFile)) {
        throw "Missing source file: $SourceFile"
    }

    $targetExists = Test-Path -LiteralPath $TargetFile

    if ($targetExists -and (Test-FileContentEqual -ReferenceFile $SourceFile -DifferenceFile $TargetFile)) {
        return "Unchanged"
    }

    if ($targetExists) {
        $action = "Update harness file"
        $result = "Updated"
    }
    else {
        $action = "Create harness file"
        $result = "Created"
    }

    # why: $WhatIfPreference first - under -WhatIf ShouldProcess prints a "What if:"
    # line, and the caller reports the dry run in its own words.
    if ($WhatIfPreference -or (-not $PSCmdlet.ShouldProcess($TargetFile, $action))) {
        return $result
    }

    if ($targetExists -and $BackupRoot) {

        if (-not $BackupRelativePath) {
            $BackupRelativePath = Split-Path -Leaf $TargetFile
        }

        $backupFile = Join-Path $BackupRoot $BackupRelativePath
        $backupDir = Split-Path -Parent $backupFile

        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        Copy-Item -LiteralPath $TargetFile -Destination $backupFile -Force
    }

    $targetDir = Split-Path -Parent $TargetFile

    if ($targetDir -and -not (Test-Path -LiteralPath $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    Copy-Item -LiteralPath $SourceFile -Destination $TargetFile -Force

    return $result
}

Export-ModuleMember -Function @(
    "Test-FileContentEqual",
    "Set-Utf8Content",
    "Get-FileSha256",
    "Copy-FileIfChanged"
)
