<#
.SYNOPSIS
  Phase 0 acceptance: two instances run at the same time, each one behind its own gateway and proxy.

.DESCRIPTION
  For instance N = 0, 1 (ADR-0004 addressing):
    poc-gateway.py --instance N [--upstream-proxy <ProxyN>]   HTTP 127.0.0.1:(18080+N), DNS 127.0.1.(N+1)
    run-poc.ps1 -Name poc34-N -Port (5554+2N) -NoWifi -NoWindow
  Once both have booted, each guest asks http://api.ipify.org/?mulka=N for its public IP (over plain TCP,
  which the emulator turns into a request to its proxy). Checks:
    1. both emulators are running at the same time
    2. instance N reports the IP of its own proxy (expected IP = what the host sees through that proxy)
    3. instance N's probe reached gateway N and not the other gateway
    4. with two different proxies, the two IPs differ
  Without -Proxy0/-Proxy1 the gateways connect directly, so both report the host's IP: that still checks
  1 and 3, but 4 is skipped. Exit code = number of failed checks.

.EXAMPLE
  .\two-instances.ps1 -Proxy0 http://user:pass@1.2.3.4:8080 -Proxy1 http://5.6.7.8:3128
#>
[CmdletBinding()]
param(
    [string]$PocRoot = 'C:\mulka-poc',
    [string]$Proxy0,
    [string]$Proxy1,
    [int]$MemoryMb = 1536,
    [int]$NetTimeoutSec = 240,
    [switch]$KeepRunning
)

$ErrorActionPreference = 'Stop'
$adb = (Get-Command adb -ErrorAction SilentlyContinue).Source
if (-not $adb) { throw "adb not found on PATH" }
$stamp = Get-Date -Format yyyyMMdd-HHmmss
$proxies = @($Proxy0, $Proxy1)

$inst = foreach ($n in 0, 1) {
    $gwLog = Join-Path $PocRoot "two-gateway$n-$stamp.log"
    $gwArgs = @('-I', '-u', (Join-Path $PSScriptRoot 'poc-gateway.py'), '--instance', $n)
    if ($proxies[$n]) { $gwArgs += '--upstream-proxy', $proxies[$n] }
    [pscustomobject]@{
        N = $n; Name = "poc34-$n"; Port = 5554 + 2 * $n; Serial = "emulator-$(5554 + 2 * $n)"
        Proxy = $proxies[$n]; GwLog = $gwLog
        Gw = Start-Process python -ArgumentList $gwArgs -RedirectStandardOutput $gwLog -RedirectStandardError "$gwLog.err" -WindowStyle Hidden -PassThru
        Expected = $null; Seen = $null
    }
}

# What the outside world sees through each proxy, measured from the host.
foreach ($i in $inst) {
    $curlArgs = @('-s', '-m', '20')
    if ($i.Proxy) { $curlArgs += '-x', $i.Proxy }
    $i.Expected = (& curl.exe @curlArgs 'https://api.ipify.org' | Out-String).Trim()
    Write-Host ("Instance {0}: proxy {1}, expected IP {2}" -f $i.N, $(if ($i.Proxy) { ([uri]$i.Proxy).Authority -replace '^.*@' } else { '(direct)' }), $i.Expected)
}

$results = [ordered]@{}
try {
    foreach ($i in $inst) {
        & (Join-Path $PSScriptRoot 'run-poc.ps1') -PocRoot $PocRoot -Name $i.Name -Port $i.Port -MemoryMb $MemoryMb `
            -HttpProxy "http://127.0.0.1:$(18080 + $i.N)" -DnsServer "127.0.1.$($i.N + 1)" -NoWifi -NoWindow
    }
    $ErrorActionPreference = 'Continue'
    # The guest network (cellular over eth0) comes up a while after sys.boot_completed; on a fresh AVD
    # under memory pressure that has taken more than 2 minutes.
    foreach ($i in $inst) {
        $deadline = (Get-Date).AddSeconds($NetTimeoutSec)
        while (-not (Select-String -Path $i.GwLog -Pattern 'generate_204' -Quiet) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 3 }
        $up = Select-String -Path $i.GwLog -Pattern 'generate_204' -Quiet
        $results["Instance $($i.N) network reached gateway $($i.N)"] = [bool]$up
        if (-not $up) {
            Write-Host "Instance $($i.N): no traffic at its gateway after $NetTimeoutSec s; guest view:" -ForegroundColor Yellow
            & $adb -s $i.Serial shell "ip -4 addr show eth0 | grep inet; ip route; dumpsys connectivity | grep -m1 NetworkAgentInfo | cut -c1-200" 2>$null
        }
    }
    $devices = (& $adb devices 2>$null) -join "`n"
    $results['Both instances running at the same time'] = ($inst | Where-Object { $devices -notmatch "$($_.Serial)\s+device" }).Count -eq 0

    foreach ($i in $inst) {
        $resp = @(& $adb -s $i.Serial shell "printf 'GET /?mulka=$($i.N) HTTP/1.0\r\nHost: api.ipify.org\r\n\r\n' | timeout 15 nc api.ipify.org 80" 2>$null)
        $last = $resp | Where-Object { $_ -and $_.Trim() } | Select-Object -Last 1
        $i.Seen = if ($last) { $last.Trim() } else { '' }
        Write-Host ("Instance {0} ({1}) sees '{2}'" -f $i.N, $i.Serial, $i.Seen)
    }
    foreach ($i in $inst) {
        $other = 1 - $i.N
        $results["Instance $($i.N) shows the IP of its proxy ($($i.Expected))"] = [bool]($i.Expected -and $i.Seen -eq $i.Expected)
        $own = Select-String -Path $i.GwLog -Pattern "mulka=$($i.N)\b" -Quiet
        $foreign = Select-String -Path $inst[$other].GwLog -Pattern "mulka=$($i.N)\b" -Quiet
        $results["Instance $($i.N) goes through gateway $($i.N) only"] = [bool]($own -and -not $foreign)
    }
    if ($Proxy0 -and $Proxy1) {
        $results['The two instances show different IPs'] = ($inst[0].Seen -and $inst[0].Seen -ne $inst[1].Seen)
    } else {
        Write-Host "Different-IP check skipped: pass -Proxy0 and -Proxy1" -ForegroundColor Yellow
    }
} catch {
    Write-Host "Aborted: $_" -ForegroundColor Red
    $results['Test ran to the end'] = $false
} finally {
    if (-not $KeepRunning) {
        foreach ($i in $inst) {
            & $adb -s $i.Serial emu kill 2>$null | Out-Null
            Stop-Process -Id $i.Gw.Id -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ""
$failed = 0
foreach ($k in $results.Keys) {
    if ($results[$k]) { Write-Host "PASS  $k" -ForegroundColor Green }
    else { Write-Host "FAIL  $k" -ForegroundColor Red; $failed++ }
}
foreach ($i in $inst) { Write-Host "Gateway $($i.N) log: $($i.GwLog)" }
exit $failed
