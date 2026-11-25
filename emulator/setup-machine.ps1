<#
.SYNOPSIS
  One-time machine setup for building the Android Emulator. Run from an elevated PowerShell.

  Changes (machine-wide):
    - Developer Mode on (lets git create symlinks without admin)
    - Win32 long paths on
    - Adds VC ATL, ATL/MFC and CMake components to the installed VS 2022 / Build Tools 2022
    - Enables the 'Windows Hypervisor Platform' feature (WHPX) if it is off
  Does NOT change git config, TEMP or Defender settings, and installs nothing from third-party hosts.
  A reboot may be required afterwards (the script says so).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$SkipVisualStudio,
    [switch]$SkipHypervisor
)

$ErrorActionPreference = 'Stop'

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script from an elevated PowerShell (Run as Administrator)."
}

$rebootNeeded = $false

function Set-DwordValue([string]$Path, [string]$Name, [int]$Value) {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    $current = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    if ($current -eq $Value) { Write-Host "  already set: $Path\$Name = $Value"; return }
    if ($PSCmdlet.ShouldProcess("$Path\$Name", "set to $Value")) {
        New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
        Write-Host "  set: $Path\$Name = $Value"
    }
}

Write-Host "== Developer Mode"
Set-DwordValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' 'AllowDevelopmentWithoutDevLicense' 1

Write-Host "== Long paths"
Set-DwordValue 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled' 1

if (-not $SkipVisualStudio) {
    Write-Host "== Visual Studio components"
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $installer = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\setup.exe"
    $vsPath = & $vswhere -products * -version '[17.0,18.0)' -latest -property installationPath
    if (-not $vsPath) { throw "VS 2022 / Build Tools 2022 not found. Install it first." }
    $wanted = @(
        'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        'Microsoft.VisualStudio.Component.Windows11SDK.22621',
        'Microsoft.VisualStudio.Component.VC.ATL',
        'Microsoft.VisualStudio.Component.VC.ATLMFC',
        'Microsoft.VisualStudio.Component.VC.CMake.Project'
    )
    # Note: do not use `vswhere -path` here - it ignores -requires and reports every component as present.
    $missing = $wanted | Where-Object {
        $found = & $vswhere -products * -version '[17.0,18.0)' -requires $_ -property installationPath
        -not ($found -contains $vsPath)
    }
    if (-not $missing) {
        Write-Host "  all components present in $vsPath"
    } elseif ($PSCmdlet.ShouldProcess($vsPath, "add $($missing -join ', ')")) {
        $installArgs = @('modify', '--installPath', "`"$vsPath`"", '--passive', '--norestart') + ($missing | ForEach-Object { '--add', $_ })
        Write-Host "  installing: $($missing -join ', ') (the installer window shows progress)"
        $p = Start-Process -FilePath $installer -ArgumentList $installArgs -Wait -PassThru
        # 3010 = success, reboot required
        if ($p.ExitCode -eq 3010) { $rebootNeeded = $true }
        elseif ($p.ExitCode -ne 0) { throw "VS installer exited with code $($p.ExitCode)" }
    }
}

if (-not $SkipHypervisor) {
    Write-Host "== Windows Hypervisor Platform (WHPX)"
    $f = Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform
    if ($f.State -eq 'Enabled') {
        Write-Host "  already enabled"
    } elseif ($PSCmdlet.ShouldProcess('HypervisorPlatform', 'enable')) {
        $r = Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -NoRestart
        if ($r.RestartNeeded) { $rebootNeeded = $true }
        Write-Host "  enabled"
    }
}

Write-Host ""
if ($rebootNeeded) { Write-Host "Done. Reboot required before building." -ForegroundColor Yellow }
else { Write-Host "Done. Open a NEW terminal so the settings apply, then run check-prereqs.ps1." -ForegroundColor Green }
