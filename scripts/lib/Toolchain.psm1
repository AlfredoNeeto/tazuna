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

Export-ModuleMember -Function @(
    "Get-NodeMajorVersion"
)
