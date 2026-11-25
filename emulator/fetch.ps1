<#
.SYNOPSIS
  Fetch the Android Emulator source tree with `repo` and record the exact commits in manifest.pinned.xml.

.DESCRIPTION
  - Installs the `repo` launcher into %LOCALAPPDATA%\mulka-tools if it is missing (no admin).
  - Git settings the tree needs (symlinks, long paths, no CRLF conversion) are passed through
    GIT_CONFIG_* environment variables for this process only; the user's global git config is untouched.
  - With -Pinned, syncs exactly the commits in manifest.pinned.xml (reproducible build).
  - Without -Pinned, syncs the tip of -Branch and writes a fresh manifest.pinned.xml to commit.

.EXAMPLE
  .\fetch.ps1                 # first fetch: tip of emu-main-dev into C:\e, writes the pin
  .\fetch.ps1 -Pinned         # reproduce the pinned tree
#>
[CmdletBinding()]
param(
    [string]$Root = 'C:\e',
    [string]$Branch = 'emu-main-dev',
    [int]$Jobs = 4,
    [int]$Depth = 1,
    [switch]$Pinned,
    # Fetching does not need Visual Studio; lets the sync start while VS components are still installing.
    [switch]$SkipPrereqCheck
)

$ErrorActionPreference = 'Stop'
$manifestUrl = 'https://android.googlesource.com/platform/manifest'
$pinFile = Join-Path $PSScriptRoot 'manifest.pinned.xml'

if (-not $SkipPrereqCheck) {
    & (Join-Path $PSScriptRoot 'check-prereqs.ps1') -Root $Root
    if ($LASTEXITCODE -ne 0) { throw "Prerequisites missing - see above." }
}

# repo launcher
$toolsDir = Join-Path $env:LOCALAPPDATA 'mulka-tools'
$repoLauncher = Join-Path $toolsDir 'repo'
if (-not (Test-Path $repoLauncher)) {
    New-Item -ItemType Directory -Force $toolsDir | Out-Null
    Write-Host "Downloading repo launcher to $repoLauncher"
    & curl.exe -fsSL -o $repoLauncher 'https://storage.googleapis.com/git-repo-downloads/repo'
    if ($LASTEXITCODE -ne 0) { throw "Failed to download repo launcher" }
}

# Per-process git config (does not touch ~/.gitconfig)
$gitConfig = [ordered]@{
    'core.symlinks'  = 'true'
    'core.longpaths' = 'true'
    'core.autocrlf'  = 'false'
    'color.ui'       = 'false'
}
if (-not (& git config --get user.email)) { $gitConfig['user.email'] = 'builder@localhost' }
if (-not (& git config --get user.name)) { $gitConfig['user.name'] = 'builder' }
$i = 0
foreach ($k in $gitConfig.Keys) {
    Set-Item "env:GIT_CONFIG_KEY_$i" $k
    Set-Item "env:GIT_CONFIG_VALUE_$i" $gitConfig[$k]
    $i++
}
$env:GIT_CONFIG_COUNT = "$i"

function Invoke-Repo {
    & python $repoLauncher @args
    if ($LASTEXITCODE -ne 0) { throw "repo $($args -join ' ') failed with exit code $LASTEXITCODE" }
}

New-Item -ItemType Directory -Force $Root | Out-Null
Push-Location $Root
try {
    $initArgs = @('init', '-u', $manifestUrl, '-b', $Branch, '--no-clone-bundle')
    if ($Depth -gt 0) { $initArgs += "--depth=$Depth" }
    Invoke-Repo @initArgs

    # Drop projects the Windows build does not need (see local_manifest.xml)
    $localManifests = Join-Path $Root '.repo\local_manifests'
    New-Item -ItemType Directory -Force $localManifests | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'local_manifest.xml') (Join-Path $localManifests 'mulka.xml') -Force

    if ($Pinned) {
        if (-not (Test-Path $pinFile)) { throw "No $pinFile yet - run without -Pinned first." }
        Copy-Item $pinFile (Join-Path $Root '.repo\manifests\mulka-pinned.xml') -Force
        Invoke-Repo init -m 'mulka-pinned.xml'
    }

    $started = Get-Date
    Invoke-Repo sync -c --no-tags --fail-fast "-j$Jobs"
    Write-Host ("repo sync finished in {0:hh\:mm\:ss}" -f ((Get-Date) - $started))

    if (-not $Pinned) {
        Invoke-Repo manifest -r -o $pinFile
        & python -I (Join-Path $PSScriptRoot 'complete-pin.py') $Root $pinFile
        if ($LASTEXITCODE -ne 0) { throw "complete-pin.py failed" }
        Write-Host "Pinned manifest written to $pinFile - commit it."
    }
} finally {
    Pop-Location
}

$size = (Get-ChildItem $Root -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
Write-Host ("Source tree: {0:N1} GB in {1}" -f ($size / 1GB), $Root)
