<#
.SYNOPSIS
  Build the emulator from the tree fetched by fetch.ps1 and keep a log in emulator\out\.

.EXAMPLE
  .\build.ps1                          # incremental release build + unit tests
  .\build.ps1 -SkipTests               # incremental build, no ctest
  .\build.ps1 -Clean                   # wipe objs\ first (upstream default)
  .\build.ps1 -Config debug
  .\build.ps1 -Extra '--task','Compile' # incremental: compile only
#>
[CmdletBinding()]
param(
    [string]$Root = 'C:\e',
    [ValidateSet('release', 'debug')][string]$Config = 'release',
    # Upstream starts with a Clean task that deletes objs\ (a full ~1 h rebuild every time).
    # By default we skip it and build incrementally; -Clean restores upstream behaviour.
    [switch]$Clean,
    # Skip the ctest run (~10 min). Known environment-dependent failures: see README.
    [switch]$SkipTests,
    [string[]]$Extra = @()
)

$ErrorActionPreference = 'Stop'
$qemu = Join-Path $Root 'external\qemu'
if (-not (Test-Path (Join-Path $qemu 'android\rebuild.cmd'))) { throw "No source at $qemu - run fetch.ps1 first." }

# Mulka patches on top of the pinned upstream tree: patches\<dir>\*.patch, applied in name order.
# Idempotent: a patch that already applies in reverse is treated as applied.
$patchTargets = @{ 'external-qemu' = 'external\qemu' }
foreach ($dir in $patchTargets.Keys) {
    $projectPath = Join-Path $Root $patchTargets[$dir]
    $patches = Get-ChildItem (Join-Path $PSScriptRoot "patches\$dir") -Filter '*.patch' -ErrorAction SilentlyContinue | Sort-Object Name
    foreach ($p in $patches) {
        & git -C $projectPath apply --reverse --check $p.FullName 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Host "patch already applied: $dir\$($p.Name)"; continue }
        & git -C $projectPath apply $p.FullName
        if ($LASTEXITCODE -ne 0) { throw "Failed to apply $($p.FullName) to $projectPath" }
        Write-Host "patch applied: $dir\$($p.Name)"
    }
}

# vcvars64.bat looks for vswhere.exe on PATH; without it it prints a harmless error.
$env:PATH = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer;$env:PATH"

$outDir = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force $outDir | Out-Null
$log = Join-Path $outDir ("build-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))

Write-Host "Building in $qemu (config: $Config). Log: $log"
$started = Get-Date
Push-Location $qemu
try {
    # rebuild.cmd = python android\build\python\cmake.py --ccache auto <args>
    # stderr is merged inside cmd.exe: in Windows PowerShell 5.1 a native stderr line seen by
    # PowerShell becomes a NativeCommandError, which with ErrorActionPreference=Stop kills this
    # script on the first CMake warning while the build keeps running orphaned and unlogged.
    $taskArgs = @()
    if (-not $Clean) { $taskArgs += '--task-disable', 'Clean' }
    if ($SkipTests) { $taskArgs += '--task-disable', 'CTest' }
    $cmdLine = (@('android\rebuild.cmd', '--config', $Config) + $taskArgs + $Extra) -join ' '
    $ErrorActionPreference = 'Continue'
    & cmd.exe /d /c "$cmdLine 2>&1" | Tee-Object -FilePath $log
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
} finally {
    Pop-Location
}
$elapsed = (Get-Date) - $started

$candidates = @('objs\distribution\emulator\emulator.exe', 'objs\emulator.exe') | ForEach-Object { Join-Path $qemu $_ }
$exe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1

Write-Host ""
Write-Host ("Exit code {0}, took {1:hh\:mm\:ss}" -f $code, $elapsed)
if ($exe) { Write-Host "emulator.exe: $exe"; & $exe -version | Select-Object -First 1 }
else { Write-Host "emulator.exe not found under objs\ - see the log." -ForegroundColor Red }
exit $code
