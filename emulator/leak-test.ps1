<#
.SYNOPSIS
  Phase 0 leak test: boot the PoC image behind poc-gateway.py and check that nothing leaves past the proxy.

.DESCRIPTION
  Starts poc-gateway.py (instance 0: HTTP 127.0.0.1:18080, DNS 127.0.1.1:53), boots run-poc.ps1 with
  -HttpProxy/-DnsServer, then from the guest:
    1. TCP  to <host LAN IP>:9998   must arrive as CONNECT at the gateway
    2. UDP  to <host LAN IP>:9999   must NOT reach a listener on the host's LAN address
    3. ICMP ping 8.8.8.8            must fail
    4. DNS  lookup example.com      must be answered by the gateway
    5. HTTP GET http://example.com  must go through the gateway
  The LAN listener stands in for "the internet": slirp treats it as an outside address.
  Exit code = number of failed checks.
#>
[CmdletBinding()]
param(
    [string]$PocRoot = 'C:\mulka-poc',
    [switch]$KeepRunning,
    # Keep virtio-wifi on: Wi-Fi traffic then goes through the prebuilt netsimd.exe, which our slirp
    # patch does not cover (UDP leaks there). Default is the Mulka configuration: eth0 only.
    [switch]$WithWifi
)

$ErrorActionPreference = 'Stop'
$adb = (Get-Command adb -ErrorAction SilentlyContinue).Source
if (-not $adb) { throw "adb not found on PATH" }
$serial = 'emulator-5554'
$hostIp = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.PrefixOrigin -in 'Dhcp', 'Manual' -and $_.IPAddress -notmatch '^(127|169\.254)\.' } |
    Select-Object -First 1).IPAddress
if (-not $hostIp) { throw "No LAN IPv4 address on this host" }

$gwLog = Join-Path $PocRoot "leak-gateway-$(Get-Date -Format yyyyMMdd-HHmmss).log"
$gw = Start-Process python -ArgumentList '-I', '-u', (Join-Path $PSScriptRoot 'poc-gateway.py') `
    -RedirectStandardOutput $gwLog -RedirectStandardError "$gwLog.err" -WindowStyle Hidden -PassThru

# Host-side listeners on the LAN address (UDP 9999, TCP 9998); they report what reaches them directly.
$listener = @'
import socket, sys, select
ip = sys.argv[1]
u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.bind((ip, 9999))
t = socket.socket(); t.bind((ip, 9998)); t.listen(5)
end = __import__("time").time() + float(sys.argv[2])
while True:
    left = end - __import__("time").time()
    if left <= 0: break
    r, _, _ = select.select([u, t], [], [], left)
    for s in r:
        if s is u:
            d, a = u.recvfrom(512); print("UDP", a[0], d.strip().decode(errors="replace"), flush=True)
        else:
            c, a = t.accept(); print("TCP", a[0], flush=True); c.close()
'@
$listenerFile = Join-Path $env:TEMP 'mulka-leak-listener.py'
Set-Content -Path $listenerFile -Value $listener -Encoding ascii

$results = [ordered]@{}
try {
    & (Join-Path $PSScriptRoot 'run-poc.ps1') -PocRoot $PocRoot -HttpProxy 'http://127.0.0.1:18080' -DnsServer '127.0.1.1' -NoWindow -NoWifi:(-not $WithWifi)
    $ErrorActionPreference = 'Continue'
    # Guest networking comes up a little after sys.boot_completed: wait for Android's own
    # connectivity check to reach the gateway before probing.
    $deadline = (Get-Date).AddSeconds(120)
    while (-not (Select-String -Path $gwLog -Pattern 'generate_204' -Quiet) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    Start-Sleep -Seconds 5
    $lst = Start-Job -ScriptBlock { param($f, $ip) python -I $f $ip 40 } -ArgumentList $listenerFile, $hostIp
    Start-Sleep -Seconds 3
    $mark = (Get-Content $gwLog).Count

    & $adb -s $serial shell "echo tcp-probe | timeout 5 nc $hostIp 9998" 2>$null | Out-Null
    & $adb -s $serial shell "echo udp-probe | timeout 3 nc -u $hostIp 9999" 2>$null | Out-Null
    $ping = (& $adb -s $serial shell "ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1; echo `$?" 2>$null | Out-String).Trim()
    & $adb -s $serial shell "ping -c 1 -W 1 example.com >/dev/null 2>&1" 2>$null | Out-Null
    & $adb -s $serial shell "printf 'GET / HTTP/1.0\r\nHost: example.com\r\n\r\n' | timeout 8 nc example.com 80 >/dev/null" 2>$null | Out-Null

    $seen = (Receive-Job $lst -Wait) -join "`n"
    Remove-Job $lst
    $gwNew = (Get-Content $gwLog | Select-Object -Skip $mark) -join "`n"

    # The gateway itself connects onward from the host IP, so the listener may see that TCP connection;
    # what matters is that the gateway handled it.
    $results['TCP goes through the gateway (CONNECT)'] = ($gwNew -match "CONNECT $([regex]::Escape($hostIp)):9998")
    $results['UDP does not leave directly']            = -not ($seen -match 'UDP')
    $results['ICMP does not leave directly']           = ($ping -ne '0')
    $results['DNS answered by the gateway']            = ($gwNew -match '\[dns\] A example\.com')
    $results['HTTP goes through the gateway']          = ($gwNew -match 'GET http://example\.com/')
} finally {
    if (-not $KeepRunning) {
        & $adb -s $serial emu kill 2>$null | Out-Null
        Stop-Process -Id $gw.Id -ErrorAction SilentlyContinue
    }
    Remove-Item $listenerFile -ErrorAction SilentlyContinue
}

Write-Host ""
$failed = 0
foreach ($k in $results.Keys) {
    if ($results[$k]) { Write-Host "PASS  $k" -ForegroundColor Green }
    else { Write-Host "FAIL  $k" -ForegroundColor Red; $failed++ }
}
Write-Host "Gateway log: $gwLog"
exit $failed
