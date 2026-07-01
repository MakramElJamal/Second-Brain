# Wake Tailscale and (optionally) turn on the Funnel web link. Runs as a CHILD
# process of the app so none of the slow/blocking tailscale calls touch the UI
# thread. Prints machine-readable markers the app parses:
#   TS_NOT_FOUND | TS_NOT_CONNECTED | TS_CONNECTED <dns> | TS_FUNNEL_ON <url> | TS_FUNNEL_OFF
[CmdletBinding()]
param([ValidateSet("connect", "weblink")][string]$Action = "connect", [int]$Port = 8531)

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

# weblink: turn on Funnel for the port.
Write-Output "Turning on Funnel for port $Port ..."
$out = (& $ts funnel --bg $Port 2>&1 | Out-String)
Write-Output $out
Start-Sleep -Milliseconds 600
$fs = (& $ts funnel status 2>&1 | Out-String)
if ($fs -match "https://") { Write-Output "TS_FUNNEL_ON https://$d" } else { Write-Output "TS_FUNNEL_OFF" }
exit 0
