<#
.SYNOPSIS
  Phase 0 PoC: boot a local system image on our own emulator.exe build with WHPX.

.DESCRIPTION
  Creates (once) an AVD in <PocRoot>\avd pointing at <PocRoot>\sdk\system-images\android-<Api>\<Tag>\x86_64,
  starts the emulator in the background, and waits for sys.boot_completed via adb.
  The system image is a local test copy and must never be redistributed.

.EXAMPLE
  .\run-poc.ps1                                   # API 34, 2 GB RAM, window
  .\run-poc.ps1 -HttpProxy http://127.0.0.1:18080 -DnsServer 127.0.1.1
#>
[CmdletBinding()]
param(
    [string]$PocRoot = 'C:\mulka-poc',
    [string]$Emulator = 'C:\e\external\qemu\objs\distribution\emulator\emulator.exe',
    [int]$Api = 34,
    [string]$Tag = 'google_apis',
    [string]$Name = 'poc34',
    [int]$MemoryMb = 2048,
    [int]$Cores = 2,
    [int]$Port = 5554,
    # Phase 0 checks: -HttpProxy http://127.0.0.1:18080 -DnsServer 127.0.1.1 (ADR-0004, instance 0)
    [string]$HttpProxy,
    [string]$DnsServer,
    # Disable virtio-wifi: Wi-Fi traffic is handled by the prebuilt netsimd.exe (its own libslirp, not ours),
    # so with it the guest's UDP/ICMP bypass the slirp patch. Without it everything goes over eth0.
    [switch]$NoWifi,
    [switch]$NoWindow,
    [int]$BootTimeoutSec = 600,
    [string[]]$Extra = @()
)

$ErrorActionPreference = 'Stop'
$sdk = Join-Path $PocRoot 'sdk'
$avdHome = Join-Path $PocRoot 'avd'
$imageRel = "system-images\android-$Api\$Tag\x86_64\"
if (-not (Test-Path (Join-Path $sdk "$imageRel\system.img"))) { throw "No system.img under $sdk\$imageRel" }
if (-not (Test-Path $Emulator)) { throw "No $Emulator - run build.ps1 first." }

$adb = (Get-Command adb -ErrorAction SilentlyContinue).Source
if (-not $adb) { throw "adb not found on PATH (winget install Google.PlatformTools)" }
# emulator.exe rejects an SDK root without platform-tools\; link the installed one (junction, no admin).
$pt = Join-Path $sdk 'platform-tools'
if (-not (Test-Path $pt)) { New-Item -ItemType Junction -Path $pt -Target (Split-Path $adb) | Out-Null }

# AVD: <home>\<name>.ini + <home>\<name>.avd\config.ini
$avdDir = Join-Path $avdHome "$Name.avd"
New-Item -ItemType Directory -Force $avdDir | Out-Null
@"
avd.ini.encoding=UTF-8
path=$avdDir
path.rel=avd\$Name.avd
target=android-$Api
"@ | Set-Content -Encoding ascii (Join-Path $avdHome "$Name.ini")
@"
AvdId=$Name
avd.ini.displayname=$Name
abi.type=x86_64
hw.cpu.arch=x86_64
hw.cpu.ncore=$Cores
hw.ramSize=$MemoryMb
hw.lcd.width=1080
hw.lcd.height=1920
hw.lcd.density=420
hw.keyboard=yes
hw.gpu.enabled=yes
hw.gpu.mode=auto
disk.dataPartition.size=6G
image.sysdir.1=$imageRel
tag.id=$Tag
fastboot.forceColdBoot=yes
"@ | Set-Content -Encoding ascii (Join-Path $avdDir 'config.ini')

$env:ANDROID_SDK_ROOT = $sdk
$env:ANDROID_HOME = $sdk
$env:ANDROID_AVD_HOME = $avdHome

$serial = "emulator-$Port"
$log = Join-Path $PocRoot "$Name-$(Get-Date -Format yyyyMMdd-HHmmss).log"
$emuArgs = @('-avd', $Name, '-port', $Port, '-accel', 'on', '-no-snapshot', '-no-boot-anim', '-no-metrics') + $Extra
if ($HttpProxy) { $emuArgs += '-http-proxy', $HttpProxy }
if ($DnsServer) { $emuArgs += '-dns-server', $DnsServer }
if ($NoWifi) { $emuArgs += '-feature', '-VirtioWifi' }
if ($NoWindow) { $emuArgs += '-no-window' }
Write-Host "Starting $Emulator $($emuArgs -join ' ')"
Write-Host "Log: $log"
$p = Start-Process -FilePath $Emulator -ArgumentList $emuArgs -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru -WindowStyle Hidden

$started = Get-Date
# adb prints "device not found" to stderr until the guest is up; PowerShell 5.1 must not treat it as fatal.
$ErrorActionPreference = 'Continue'
& $adb start-server 2>$null | Out-Null
while ($true) {
    if ($p.HasExited) { throw "emulator exited with code $($p.ExitCode) - see $log and $log.err" }
    $booted = (& $adb -s $serial shell getprop sys.boot_completed 2>$null) -join ''
    if ($booted.Trim() -eq '1') { break }
    if (((Get-Date) - $started).TotalSeconds -gt $BootTimeoutSec) { throw "Boot timed out after $BootTimeoutSec s - see $log" }
    Start-Sleep -Seconds 5
}
$elapsed = (Get-Date) - $started
Write-Host ("Booted {0} in {1:mm\:ss} (pid {2})" -f $serial, $elapsed, $p.Id) -ForegroundColor Green
& $adb -s $serial shell getprop ro.build.fingerprint
Write-Host "Stop: $adb -s $serial emu kill"
