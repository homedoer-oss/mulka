<#
.SYNOPSIS
  Build the emulator from the tree fetched by fetch.ps1 and keep a log in emulator\out\.

.EXAMPLE
  .\build.ps1                          # release build, upstream defaults
  .\build.ps1 -Config debug
  .\build.ps1 -Extra '--task','Compile' # incremental: compile only
#>
[CmdletBinding()]
param(
    [string]$Root = 'C:\e',
    [ValidateSet('release', 'debug')][string]$Config = 'release',
    [string[]]$Extra = @()
)

$ErrorActionPreference = 'Stop'
$qemu = Join-Path $Root 'external\qemu'
if (-not (Test-Path (Join-Path $qemu 'android\rebuild.cmd'))) { throw "No source at $qemu - run fetch.ps1 first." }

$outDir = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force $outDir | Out-Null
$log = Join-Path $outDir ("build-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))

Write-Host "Building in $qemu (config: $Config). Log: $log"
$started = Get-Date
Push-Location $qemu
try {
    # rebuild.cmd = python android\build\python\cmake.py --ccache auto <args>
    $cmdArgs = @('/c', 'android\rebuild.cmd', '--config', $Config) + $Extra
    & cmd.exe @cmdArgs 2>&1 | Tee-Object -FilePath $log
    $code = $LASTEXITCODE
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
