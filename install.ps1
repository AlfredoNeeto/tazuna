<#
.SYNOPSIS
    Gets this harness onto a new Windows machine in one line.

.DESCRIPTION
    Intended to be run remotely:

      irm https://raw.githubusercontent.com/AlfredoNeeto/tazuna/main/install.ps1 | iex

    That form needs the repository to be public: for a private fork,
    raw.githubusercontent.com returns 404 without a token. Git does not have
    that problem - it uses the Windows Credential Manager - so the path the
    README documents works for both, and is one line of git:

      git clone <repo> "$HOME\tazuna"; & "$HOME\tazuna\bin\tazuna.cmd" setup

    This script clones the repository and hands over to scripts/bootstrap.ps1,
    which does the actual work. Nothing here duplicates that script - it exists
    only to solve the one problem bootstrap cannot: not being on the machine
    yet.

    The clone is deliberate and not an implementation detail. The harness reads
    its own working tree at runtime: update.ps1 fast-forwards from upstream,
    health-check.ps1 compares every installed file against the repository to
    detect drift. A copy of the files without the git history
    would be a harness that cannot update itself or tell you when it has drifted.

    Set $env:TAZUNA_PATH first to clone somewhere other than the default.
    Running it again on a machine that already has the harness is safe: it
    re-runs bootstrap, which is idempotent, and never touches the working tree.

.NOTES
    Piped into iex, this runs code fetched over the network without review. That
    is the same code you would get from `git clone`, but you get to read it
    first only if you fetch it first. If that matters to you, and it reasonably
    might: irm <url> -OutFile install.ps1, read it, then run it.
#>

$ErrorActionPreference = "Stop"

$repositoryUrl = "https://github.com/AlfredoNeeto/tazuna.git"

$target = $env:TAZUNA_PATH

if (-not $target) { $target = Join-Path $HOME "tazuna" }

Write-Host ""
Write-Host "Tazuna"
Write-Host "======"
Write-Host "  Target: $target"
Write-Host ""

# git is not merely how the files arrive: the drift check and update.ps1 shell
# out to it. Without git there is no harness to install.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {

    Write-Host "git is required and was not found on PATH."
    Write-Host ""
    Write-Host "  winget install --id=Git.Git -e"
    Write-Host ""
    Write-Host "Then run this again."
    exit 1
}

if (Test-Path -LiteralPath $target) {

    # Never clone over something that is already there. A directory at this path
    # is either this harness, in which case bootstrap is the right next step, or
    # someone else's work, in which case stopping is the only safe answer.
    $isHarness = Test-Path -LiteralPath (Join-Path $target (Join-Path "scripts" "bootstrap.ps1"))

    if (-not $isHarness) {
        Write-Host "$target already exists and is not this harness. Move it, or set"
        Write-Host '$env:TAZUNA_PATH to another location, then run this again.'
        exit 1
    }

    Write-Host "Already cloned. Running bootstrap to install or repair."
}
else {

    Write-Host "Cloning..."

    & git clone $repositoryUrl $target

    if ($LASTEXITCODE -ne 0) { throw "git clone failed." }
}

$bootstrap = Join-Path $target (Join-Path "scripts" "bootstrap.ps1")

if (-not (Test-Path -LiteralPath $bootstrap)) {
    throw "The clone is missing scripts/bootstrap.ps1."
}

# -File, not dot-sourcing: bootstrap gets its own scope and its own exit code,
# which is what an installer should hand back.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bootstrap

exit $LASTEXITCODE
