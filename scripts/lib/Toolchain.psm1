# Toolchain.psm1
#
# Reading the versions of the external tools the harness runs on.
# invariant: a leaf - imports no other module, and only Console.psm1 writes to the host.
# Windows PowerShell 5.1 compatible.

Set-StrictMode -Version 2.0

function Get-NodeMajorVersion {
    <#
        The major version of the node on PATH, or 0 when there is none, so a
        missing node and an old one fail the same minimum check.
    #>
    [CmdletBinding()]
    param()

    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        return 0
    }

    return [int](((& node --version) -replace "^v", "").Split(".")[0])
}

function Get-GlobalNpmPackageVersion {
    <#
        The version of a globally installed npm package, or $null when it is
        absent or npm cannot say. `npm ls` answers from the local prefix, so it
        costs no network round-trip.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        $global:LASTEXITCODE = 0
        # why: npm ls exits 1 for a missing package; the JSON still says so, and stderr is noise here.
        $listing = ((& npm ls -g $Name --depth=0 --json 2>$null) -join "`n") | ConvertFrom-Json
        $package = $listing.dependencies.PSObject.Properties[$Name]
        if ($package) { return [string]$package.Value.version }
        return $null
    }
    catch {
        return $null
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

Export-ModuleMember -Function @(
    "Get-NodeMajorVersion",
    "Get-GlobalNpmPackageVersion"
)
