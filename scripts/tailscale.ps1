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
if ($fs -match "https://") { Write-Output "TS_FUNNEL_ON https://$d" }
elseif ($enableUrl) { Write-Output "TS_FUNNEL_NEEDS_ENABLE $enableUrl" }
else { Write-Output "TS_FUNNEL_OFF" }
exit 0
