# Text-menu version of the manager (fallback for the GUI, or for headless use).
$ErrorActionPreference = "Stop"
$scripts = $PSScriptRoot
$root = Split-Path -Parent $scripts

function Get-Port {
    $port = "8531"; $envFile = Join-Path $root ".env"
    if (Test-Path $envFile) {
        $l = Get-Content $envFile | Where-Object { $_ -match "^\s*VAULT_MCP_PORT\s*=" } | Select-Object -First 1
        if ($l) { $v = ($l -replace "^\s*VAULT_MCP_PORT\s*=\s*", "").Trim(); if ($v) { $port = $v } }
    }
    $port
}
function Test-Running {
    try { [bool](Get-NetTCPConnection -LocalPort (Get-Port) -State Listen -ErrorAction SilentlyContinue) } catch { $false }
}
function New-Window([string]$file, [string[]]$rest) {
    Start-Process powershell -ArgumentList (@("-NoProfile", "-ExecutionPolicy", "Bypass", "-NoExit", "-File", "`"$file`"") + $rest)
}

while ($true) {
    Clear-Host
    Write-Host "==================================="
    Write-Host "   Second Brain MCP"
    Write-Host "==================================="
    Write-Host ("  Installed : " + $(if (Test-Path (Join-Path $root '.venv')) { 'yes' } else { 'no  - run Set up' }))
    Write-Host ("  Configured: " + $(if (Test-Path (Join-Path $root '.env')) { 'yes' } else { 'no  - run Set up' }))
    Write-Host ("  Server    : " + $(if (Test-Running) { "RUNNING on port $(Get-Port)" } else { 'stopped' }))
    Write-Host ""
    Write-Host "  [1] Set up (first time)"
    Write-Host "  [2] Choose how to connect (local / tunnel)"
    Write-Host "  [3] Start the server"
    Write-Host "  [4] Stop the server"
    Write-Host "  [5] Open the health check in a browser"
    Write-Host "  [6] Uninstall"
    Write-Host "  [0] Exit"
    Write-Host ""
    switch (Read-Host "Choose") {
        "1" { & (Join-Path $scripts "setup.ps1") }
        "2" { & (Join-Path $scripts "connect.ps1") }
        "3" { New-Window (Join-Path $root "run.ps1") @(); Write-Host "Server starting in a new window." }
        "4" { & (Join-Path $scripts "stop.ps1") }
        "5" { Start-Process ("http://127.0.0.1:" + (Get-Port) + "/health") }
        "6" { & (Join-Path $scripts "uninstall.ps1") }
        "0" { return }
        default { Write-Host "Please choose a number from the menu." }
    }
    Read-Host "`nPress Enter to return to the menu" | Out-Null
}
