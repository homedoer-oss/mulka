<#
.SYNOPSIS
  Install an AOSP image built by build-aosp.sh into the local PoC SDK, so run-poc.ps1 -Tag aosp can boot it.

.DESCRIPTION
  Checks the zip against its .sha256 (if it lies next to it), unpacks it into
  <PocRoot>\sdk\system-images\android-<Api>\<Tag>\x86_64\ and replaces what was there.

.EXAMPLE
  .\install-image.ps1 -Zip D:\drop\mulka-aosp-34-x86_64-android-14.0.0_r75.zip
  ..\emulator\run-poc.ps1 -Tag aosp -Name aosp34 -HttpProxy http://127.0.0.1:18080 -DnsServer 127.0.1.1 -NoWifi
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Zip,
    [string]$PocRoot = 'C:\mulka-poc',
    [int]$Api = 34,
    [string]$Tag = 'aosp'
)

$ErrorActionPreference = 'Stop'
$Zip = (Resolve-Path $Zip).Path
$shaFile = "$Zip.sha256"
if (Test-Path $shaFile) {
    $expected = ((Get-Content $shaFile -TotalCount 1) -split '\s+')[0].ToLower()
    $actual = (Get-FileHash -Algorithm SHA256 $Zip).Hash.ToLower()
    if ($expected -ne $actual) { throw "SHA-256 mismatch: expected $expected, got $actual" }
    Write-Host "SHA-256 OK"
} else {
    Write-Warning "No $shaFile - integrity not checked"
}

$dest = Join-Path $PocRoot "sdk\system-images\android-$Api\$Tag"
$tmp = Join-Path $PocRoot "tmp-install-$(Get-Date -Format yyyyMMddHHmmss)"
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
    Expand-Archive -Path $Zip -DestinationPath $tmp
    # emu_img_zip packs everything under <abi>\ (x86_64\system.img, vendor.img, kernel-ranchu, ...).
    $abi = Join-Path $tmp 'x86_64'
    if (-not (Test-Path (Join-Path $abi 'system.img'))) { throw "No x86_64\system.img in $Zip" }
    New-Item -ItemType Directory -Force $dest | Out-Null
    $target = Join-Path $dest 'x86_64'
    if (Test-Path $target) { Remove-Item -Recurse -Force $target }
    Move-Item $abi $target
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Get-ChildItem $target | Sort-Object Name | Format-Table Name, @{n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } } -AutoSize
$prop = Join-Path $target 'build.prop'
if (Test-Path $prop) { Select-String -Path $prop -Pattern '^ro\.(system\.)?build\.(fingerprint|version\.security_patch)=' | ForEach-Object Line }
Write-Host "Installed to $target. Boot: ..\emulator\run-poc.ps1 -Tag $Tag -Name aosp$Api" -ForegroundColor Green
