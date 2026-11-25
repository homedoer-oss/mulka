<#
.SYNOPSIS
  Read-only check of everything needed to fetch and build the Android Emulator on Windows.
  Exit code 0 = ready, 1 = something blocking is missing. Changes nothing.
#>
[CmdletBinding()]
param(
    [string]$Root = 'C:\e'
)

$ErrorActionPreference = 'Continue'
$script:blocking = 0

function Write-Check([string]$Name, [bool]$Ok, [string]$Fix, [switch]$Optional) {
    if ($Ok) { Write-Host ("[ OK ] {0}" -f $Name) -ForegroundColor Green; return }
    if ($Optional) { Write-Host ("[WARN] {0} -> {1}" -f $Name, $Fix) -ForegroundColor Yellow; return }
    Write-Host ("[MISS] {0} -> {1}" -f $Name, $Fix) -ForegroundColor Red
    $script:blocking++
}

function Get-RegValue([string]$Path, [string]$Name) {
    (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
}

Write-Host "== OS and hardware"
$cs = Get-CimInstance Win32_ComputerSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$ramGb = [math]::Round($cs.TotalPhysicalMemory / 1GB)
Write-Host ("     {0}; {1} cores / {2} threads; {3} GB RAM" -f $cpu.Name, $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors, $ramGb)
Write-Check "RAM >= 16 GB for a comfortable build" ($ramGb -ge 16) "build will be slow; close other apps, use fewer -Jobs" -Optional
Write-Check "Hypervisor running (needed for WHPX)" ([bool]$cs.HypervisorPresent) "enable 'Windows Hypervisor Platform' (setup-machine.ps1)" -Optional

Write-Host "== Windows settings"
Write-Check "Developer Mode (symlinks without admin)" ((Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' 'AllowDevelopmentWithoutDevLicense') -eq 1) "run setup-machine.ps1 as Administrator"
Write-Check "Long paths enabled" ((Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled') -eq 1) "run setup-machine.ps1 as Administrator"

Write-Host "== Visual Studio 2022"
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
    $vsPath = & $vswhere -products * -version '[17.0,18.0)' -latest -property installationPath
    Write-Check "VS 2022 / Build Tools 2022 installed" ([bool]$vsPath) "install VS 2022 Build Tools"
    $components = @(
        'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        'Microsoft.VisualStudio.Component.Windows11SDK.22621',
        'Microsoft.VisualStudio.Component.VC.ATL',
        'Microsoft.VisualStudio.Component.VC.ATLMFC',
        'Microsoft.VisualStudio.Component.VC.CMake.Project'
    )
    foreach ($c in $components) {
        $has = & $vswhere -products * -version '[17.0,18.0)' -requires $c -property installationPath
        Write-Check $c ([bool]$has) "run setup-machine.ps1 as Administrator"
    }
    $ideOnly = & $vswhere -version '[17.0,18.0)' -latest -property installationPath
    Write-Check "VS visible to vswhere without '-products *'" ([bool]$ideOnly) "only Build Tools present; upstream discovery may miss it - verify on first build" -Optional
} else {
    Write-Check "vswhere.exe" $false "install VS 2022 Build Tools"
}
Write-Check "Windows ADK (dismapi, only for emulator-check)" (Test-Path "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit") "install Windows ADK if the build asks for dismapi.h" -Optional

Write-Host "== Tools on PATH"
foreach ($t in 'git', 'python', 'curl.exe', 'java') {
    Write-Check $t ([bool](Get-Command $t -ErrorAction SilentlyContinue)) "install $t and add it to PATH"
}
$py = Get-Command python -ErrorAction SilentlyContinue
if ($py) {
    $ver = & python -c "import sys; print('%d.%d' % sys.version_info[:2])"
    Write-Check "Python >= 3.11 (found $ver)" ([version]$ver -ge [version]'3.11') "install Python 3.11+"
    $mods = & python -c "import importlib.util as u; print(','.join(m for m in ['psutil','packaging','mako','yaml','configparser','certifi'] if not u.find_spec(m)))"
    Write-Check "Python packages psutil packaging Mako PyYAML certifi" ([string]::IsNullOrWhiteSpace($mods)) "python -m pip install psutil packaging Mako PyYAML certifi  (missing: $mods)"
}

Write-Host "== Source location $Root"
$drive = Get-PSDrive -Name $Root.Substring(0, 1) -ErrorAction SilentlyContinue
if ($drive) {
    $freeGb = [math]::Round($drive.Free / 1GB)
    Write-Check ("Free space on {0}: {1} GB (want >= 100)" -f $drive.Name, $freeGb) ($freeGb -ge 100) "free space or pass -Root on another drive"
}
Write-Check "Short source path ($Root, <= 8 chars)" ($Root.Length -le 8) "use a short root such as C:\e (MAX_PATH)" -Optional

Write-Host ""
if ($script:blocking -eq 0) { Write-Host "Ready." -ForegroundColor Green; exit 0 }
Write-Host ("{0} blocking item(s) missing." -f $script:blocking) -ForegroundColor Red
exit 1
