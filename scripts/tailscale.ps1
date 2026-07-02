# Wake Tailscale and (optionally) turn on the Funnel web link. Runs as a CHILD
# process of the app so none of the slow/blocking tailscale calls touch the UI
# thread. Prints machine-readable markers the app parses:
#   TS_NOT_FOUND | TS_NOT_CONNECTED | TS_CONNECTED <dns> | TS_FUNNEL_ON <url> | TS_FUNNEL_OFF
#   TS_LOCAL_FAIL | TS_PUBLIC_OK <url> | TS_PUBLIC_HEALED <url> | TS_PUBLIC_NODNS | TS_PUBLIC_FAIL
#
# -Action check: TRUE end-to-end test of the web link. From this machine,
# requests to our own ts.net name take a private tailnet shortcut and never
# touch Tailscale's PUBLIC relays -- so a plain reachability test can say
# "Reachable" while the internet (Claude) gets TLS resets from a stale funnel
# session. This action resolves the hostname on PUBLIC DNS and forces the
# request through a public relay IP (curl --resolve), exactly the path Claude
# takes. If that fails while the local server is fine, it heals the stale
# session by bouncing the Tailscale backend once and retests.
[CmdletBinding()]
param([ValidateSet("connect", "weblink", "check")][string]$Action = "connect", [int]$Port = 8531)

$ts = Join-Path $env:ProgramFiles "Tailscale\tailscale.exe"
if (-not (Test-Path $ts)) { $ts = Join-Path ${env:ProgramFiles(x86)} "Tailscale\tailscale.exe" }
if (-not (Test-Path $ts)) { Write-Output "TS_NOT_FOUND"; exit 0 }
$gui = Join-Path (Split-Path $ts) "tailscale-ipn.exe"

function Backend { try { [string]((& $ts status --json 2>$null | ConvertFrom-Json).BackendState) } catch { "" } }
function Dns { try { ([string]((& $ts status --json 2>$null | ConvertFrom-Json).Self.DNSName)).TrimEnd(".") } catch { "" } }

# Wake the backend if it isn't Running: opening the Tailscale app is what reliably
# brings it up (its tray icon is hidden, so we launch it directly).
if ((Backend) -ne "Running") {
    Write-Output "Waking Tailscale (opening the app)..."
    if (Test-Path $gui) { try { Start-Process $gui } catch { } }
    try { Start-Process $ts -ArgumentList "up" -WindowStyle Hidden } catch { }
    $deadline = (Get-Date).AddSeconds(30)
    while ((Backend) -ne "Running" -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 700 }
}

if ((Backend) -ne "Running") { Write-Output "TS_NOT_CONNECTED"; exit 0 }
$d = Dns

if ($Action -eq "connect") { Write-Output "TS_CONNECTED $d"; exit 0 }

if ($Action -eq "check") {
    $curl = Join-Path $env:SystemRoot "System32\curl.exe"   # ships with Windows 10 1803+

    # 1. The local server itself: if IT is down, the web link isn't the problem.
    $localOk = $false
    if (Test-Path $curl) {
        $code = & $curl -s -m 5 -o NUL -w "%{http_code}" "http://127.0.0.1:$Port/health" 2>$null
        $localOk = ($code -eq "200")
    }
    else {
        try { $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 5 -UseBasicParsing; $localOk = ($r.StatusCode -eq 200) } catch { }
    }
    if (-not $localOk) { Write-Output "TS_LOCAL_FAIL"; exit 0 }
    if (-not $d) { Write-Output "TS_NOT_CONNECTED"; exit 0 }

    # 2. Funnel must be configured at all before the public edge can work.
    $fs = (& $ts funnel status 2>&1 | Out-String)
    if ($fs -notmatch "https://") { Write-Output "TS_FUNNEL_OFF"; exit 0 }

    # 3. The real test: through a PUBLIC relay, like Claude. Without curl.exe we
    # cannot force the public route; fall back to the (weaker) direct request.
    function Test-PublicEdge([string]$dns) {
        if (-not (Test-Path $curl)) {
            try { $r = Invoke-WebRequest -Uri "https://$dns/health" -TimeoutSec 12 -UseBasicParsing; if ($r.StatusCode -eq 200) { return "OK" } } catch { }
            return "FAIL"
        }
        $ips = @()
        try {
            $ips = @(Resolve-DnsName -Name $dns -Type A -Server 8.8.8.8 -ErrorAction Stop |
                Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress })
        }
        catch { }
        if (-not $ips) { return "NODNS" }
        foreach ($ip in ($ips | Select-Object -First 2)) {
            $code = & $curl -s -m 12 -o NUL -w "%{http_code}" --resolve "${dns}:443:$ip" "https://$dns/health" 2>$null
            if ($code -eq "200") { return "OK" }
        }
        return "FAIL"
    }

    $probe = Test-PublicEdge $d
    if ($probe -eq "OK") { Write-Output "TS_PUBLIC_OK https://$d"; exit 0 }
    if ($probe -eq "NODNS") { Write-Output "TS_PUBLIC_NODNS"; exit 0 }

    # 4. Local fine + funnel on + public dead = the classic stale funnel session
    # (common after sleep/wake). Bounce the backend once and retest.
    Write-Output "Public path failed; reconnecting Tailscale to refresh the web link..."
    & $ts down 2>$null | Out-Null
    Start-Sleep -Seconds 2
    & $ts up 2>$null | Out-Null
    $deadline = (Get-Date).AddSeconds(20)
    while ((Backend) -ne "Running" -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 700 }
    Start-Sleep -Seconds 3
    if ((Test-PublicEdge $d) -eq "OK") { Write-Output "TS_PUBLIC_HEALED https://$d"; exit 0 }
    Write-Output "TS_PUBLIC_FAIL"
    exit 0
}

# weblink: turn on Funnel for the port.
# IMPORTANT: `tailscale funnel` HANGS waiting for approval if Funnel isn't enabled
# on the tailnet yet (it prints a login.tailscale.com/f/funnel URL first). So we
# run it in the background and watch its output incrementally - the moment we see
# the approval URL (or success) we act, instead of blocking on it.
Write-Output "Turning on Funnel for port $Port ..."
$fo = [System.IO.Path]::GetTempFileName(); $fe = [System.IO.Path]::GetTempFileName()
$fp = Start-Process $ts -ArgumentList "funnel", "--bg", "$Port" -WindowStyle Hidden -PassThru -RedirectStandardOutput $fo -RedirectStandardError $fe
$enableUrl = $null; $started = $false
$deadline = (Get-Date).AddSeconds(18)
while ($true) {
    Start-Sleep -Milliseconds 400
    $c = ((Get-Content $fo, $fe -Raw -ErrorAction SilentlyContinue) -join "`n")
    if ($c -match "https://login\.tailscale\.com/f/funnel\S+") { $enableUrl = $matches[0]; break }
    if ($c -match "Funnel started|Available on the internet") { $started = $true; break }
    if ($fp.HasExited -or ((Get-Date) -gt $deadline)) { break }
}
$full = ((Get-Content $fo, $fe -Raw -ErrorAction SilentlyContinue) -join "`n")
Write-Output $full
# Stop a still-hanging funnel command (waiting for approval); the funnel itself,
# once enabled, is served by the tailscaled service and persists.
if (-not $fp.HasExited) { try { Stop-Process -Id $fp.Id -Force } catch { } }
Remove-Item $fo, $fe -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
$fs = (& $ts funnel status 2>&1 | Out-String)
if (-not $d) { $d = Dns }   # re-read; DNS can lag right after the backend wakes
if (($fs -match "https://") -and $d) { Write-Output "TS_FUNNEL_ON https://$d" }
elseif ($enableUrl) { Write-Output "TS_FUNNEL_NEEDS_ENABLE $enableUrl" }
elseif ($fs -match "https://") { Write-Output "Funnel is on but the device name isn't ready yet - try Turn on again in a few seconds."; Write-Output "TS_FUNNEL_OFF" }
else { Write-Output "TS_FUNNEL_OFF" }
exit 0
