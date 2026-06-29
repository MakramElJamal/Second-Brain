# Stop the local Second Brain MCP server (and an attached Cloudflare quick tunnel).
# The vault is never touched. Tailscale Funnel, if used, is left to you to disable.
[CmdletBinding()]
param([switch]$Quiet)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

# Read the port the server listens on (default 8531).
$port = "8531"
$envFile = Join-Path $root ".env"
if (Test-Path $envFile) {
    $line = Get-Content $envFile | Where-Object { $_ -match "^\s*VAULT_MCP_PORT\s*=" } | Select-Object -First 1
    if ($line) { $v = ($line -replace "^\s*VAULT_MCP_PORT\s*=\s*", "").Trim(); if ($v) { $port = $v } }
}

$stopped = $false
try {
    $conns = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    foreach ($procId in ($conns.OwningProcess | Select-Object -Unique)) {
        if (Get-Process -Id $procId -ErrorAction SilentlyContinue) {
            Stop-Process -Id $procId -Force
            Write-Host "Stopped server (PID $procId) on port $port." -ForegroundColor Green
            $stopped = $true
        }
    }
} catch { }
if (-not $stopped -and -not $Quiet) { Write-Host "No server was listening on port $port." }

# Stop a Cloudflare quick tunnel we may have started.
$cf = Get-Process cloudflared -ErrorAction SilentlyContinue
if ($cf) { $cf | Stop-Process -Force; Write-Host "Stopped cloudflared tunnel." -ForegroundColor Green }

if (-not $Quiet) {
    Write-Host "(If you used Tailscale Funnel, turn it off with:  tailscale funnel off)"
}
